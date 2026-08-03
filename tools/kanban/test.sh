#!/usr/bin/env bash
# 看板回归测试：每个修掉的 bug 都要能复现出「已修好」。
#
#   bash tools/kanban/test.sh        （或 npm test）
#
# 测试跑在一个临时目录里（KANBAN_CARDS_DIR），**绝不碰真实的 cards/**。
# 上一版直接 rm 真实 cards/，真删掉过 12 张卡——那种测试比没有测试更糟。
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/kanban-test.XXXXXX")"
CARDS="$TMPROOT/cards"
mkdir -p "$CARDS"
# 4531 而不是 44xx：44xx 是分发给各项目看板用的号段。测试端口若和某个项目的看板
# 撞上，测试自己的 server 绑不上端口，整套断言会转而打到**真实的看板**上去。
PORT=${KANBAN_TEST_PORT:-4531}
# 卡号前缀固定成 TEST，不读宿主项目的 config.json。否则装到前缀非 DASH 的项目里，
# 下面写死的 TEST-002 之类会打到 404，测试莫名其妙地失败（实测 medical_tourism 用
# MT 前缀时就是这样）。测试必须是封闭的——数据目录已经隔离了，前缀也要隔离。
export KANBAN_ID_PREFIX=TEST
BASE="http://127.0.0.1:$PORT"
PASS=0; FAIL=0

# 安全阀：万一 mktemp 出意外指到仓库里，立刻停，不要往下删任何东西。
case "$CARDS" in
  "$REPO"/*) echo "拒绝运行：测试数据目录落在仓库内（$CARDS）"; exit 1 ;;
esac

ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; echo "     got: $2"; FAIL=$((FAIL+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "expected [$3] got [$2]"; }

# 先跑数据层单元测试（不经 HTTP，快且定位准）；挂了就没必要往下跑集成测试。
echo "══ card-store 单元测试 ══"
mkdir -p "$TMPROOT/unit"
if ! KANBAN_CARDS_DIR="$TMPROOT/unit" node "$REPO/tools/kanban/test-store.mjs"; then
  echo "card-store 单元测试失败，中止"
  exit 1
fi
echo
echo "══ HTTP 集成测试 ══"

KANBAN_PORT=$PORT KANBAN_CARDS_DIR="$CARDS" node "$REPO/tools/kanban/server.mjs" >/tmp/t1.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$TMPROOT"' EXIT
curl -sf --retry 15 --retry-connrefused --retry-delay 1 "$BASE/api/cards" >/dev/null || { echo "server 起不来"; cat /tmp/t1.log; exit 1; }

post(){ curl -sf -X POST "$BASE/api/cards" -H 'Content-Type: application/json' -d "$1"; }
jq_(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "── U4：order 不撞号 ──"
for t in A B C; do post "{\"title\":\"$t\",\"stage\":\"backlog\"}" >/dev/null; done
chk "三张卡 order = 1,2,3" \
  "$(curl -s "$BASE/api/cards" | jq_ "','.join(str(c['order']) for c in d if c['stage']=='backlog')")" "1,2,3"
curl -sf -X DELETE "$BASE/api/cards/TEST-002" >/dev/null   # 删中间那张
post '{"title":"D","stage":"backlog"}' >/dev/null
chk "删中间再建，order 变 1,3,4（不复用 2）" \
  "$(curl -s "$BASE/api/cards" | jq_ "','.join(str(c['order']) for c in d if c['stage']=='backlog')")" "1,3,4"

echo "── U3：ID 不复用 ──"
MAXID=$(curl -s "$BASE/api/cards" | jq_ "max(c['id'] for c in d)")
curl -sf -X DELETE "$BASE/api/cards/$MAXID" >/dev/null      # 删掉编号最大的
NEWID=$(post '{"title":"E","stage":"backlog"}' | jq_ "d['id']")
[ "$NEWID" != "$MAXID" ] && ok "删掉最大编号 ${MAXID} 后新卡是 ${NEWID}，未复用" \
  || no "ID 复用了" "${NEWID} == ${MAXID}"
chk ".seq 文件已写入" "$([ -f "$CARDS/.seq" ] && echo yes || echo no)" "yes"

echo "── U5：删掉被依赖的卡不会锁死 ──"
DEP=$(post '{"title":"被依赖","stage":"backlog"}' | jq_ "d['id']")
USER=$(post "{\"title\":\"依赖者\",\"stage\":\"backlog\",\"dependsOn\":[\"$DEP\"]}" | jq_ "d['id']")
DELRESP=$(curl -sf -X DELETE "$BASE/api/cards/$DEP")
chk "删除时上报清理了哪些卡" "$(echo "$DELRESP" | jq_ "','.join(d['dependsOnCleaned'])")" "$USER"
chk "依赖者的 dependsOn 已清空" \
  "$(curl -s "$BASE/api/cards" | jq_ "[c['dependsOn'] for c in d if c['id']=='$USER'][0]")" "[]"
# 关键：清理后这张卡还能被拖动（整批 PUT 不再被悬空引用拒绝）
BULK=$(curl -s "$BASE/api/cards" | python3 -c "
import sys,json;d=json.load(sys.stdin)
for c in d:
    if c['id']=='$USER': c['stage']='ready'
print(json.dumps([c for c in d if c['id']=='$USER']))")
CODE=$(curl -s -o /tmp/bulk.json -w '%{http_code}' -X PUT "$BASE/api/cards" -H 'Content-Type: application/json' -d "$BULK")
chk "清理后仍可整批 PUT（车道没被锁死）" "$CODE" "200"

echo "── U9：乐观锁挡住静默覆盖 ──"
CUR=$(curl -s "$BASE/api/cards" | python3 -c "
import sys,json;d=json.load(sys.stdin);print(json.dumps([c for c in d if c['id']=='$USER'][0]))")
REV=$(echo "$CUR" | jq_ "d['rev']")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/cards/$USER" \
  -H 'Content-Type: application/json' -H "If-Match: $REV" -d "$CUR")
chk "If-Match 对得上 → 200" "$CODE" "200"
CODE=$(curl -s -o /tmp/conflict.json -w '%{http_code}' -X PUT "$BASE/api/cards/$USER" \
  -H 'Content-Type: application/json' -H "If-Match: $REV" -d "$CUR")
chk "同一个 rev 再打一次（模拟过期客户端）→ 409" "$CODE" "409"
chk "409 里带了磁盘上的真实 rev" "$(jq_ "d['conflict']" </tmp/conflict.json)" "True"
# bulk 也要挡
STALEBULK=$(echo "$CUR" | python3 -c "import sys,json;c=json.load(sys.stdin);c['rev']=1;print(json.dumps([c]))")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/cards" -H 'Content-Type: application/json' -d "$STALEBULK")
chk "整批 PUT 带过期 rev → 409" "$CODE" "409"

echo "── U2：坏档不废掉整块看板 ──"
BEFORE=$(curl -s "$BASE/api/cards" | jq_ "len(d)")
printf '{"id":"TEST-999","title":"坏档",,,}' > "$CARDS/TEST-999.json"
CODE=$(curl -s -o /tmp/after.json -w '%{http_code}' "$BASE/api/cards")
chk "有坏档时 GET /api/cards 仍是 200（不是 400）" "$CODE" "200"
chk "其余卡片全部还在" "$(jq_ "len(d)" </tmp/after.json)" "$BEFORE"
chk "/api/issues 指名道姓报出坏档" \
  "$(curl -s "$BASE/api/issues" | jq_ "d['broken'][0]['file']")" "TEST-999.json"
rm -f "$CARDS/TEST-999.json"

echo "── track=fullstack 不再让整批拒绝 ──"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/cards" \
  -H 'Content-Type: application/json' -d '{"title":"全栈卡","track":"fullstack"}')
chk "POST track=fullstack → 201" "$CODE" "201"

echo "── comment API：只追加 + 身份判定 ──"
CID=$(post '{"title":"留言测试","stage":"backlog"}' | jq_ "d['id']")
# 人写决策
HUMAN=$(curl -s -X POST "$BASE/api/cards/$CID/comments" -H 'Content-Type: application/json' \
  -d '{"kind":"decision","text":"侧边栏用可收合，不要 drawer"}')
chk "人可以写 decision" "$(echo "$HUMAN" | jq_ "d['comment']['kind']")" "decision"
chk "authorKind=human" "$(echo "$HUMAN" | jq_ "d['comment']['authorKind']")" "human"
chk "默认 status=open" "$(echo "$HUMAN" | jq_ "d['comment']['status']")" "open"
DID=$(echo "$HUMAN" | jq_ "d['comment']['id']")
# agent 不能写决策
CODE=$(curl -s -o /tmp/f.json -w '%{http_code}' -X POST "$BASE/api/cards/$CID/comments" \
  -H 'Content-Type: application/json' -H 'X-Kanban-Agent: claude-code' \
  -d '{"kind":"decision","text":"我说了算"}')
chk "agent 写 decision → 403" "$CODE" "403"
# agent 可以 ack
CODE=$(curl -s -o /tmp/a.json -w '%{http_code}' -X PATCH "$BASE/api/cards/$CID/comments/$DID" \
  -H 'Content-Type: application/json' -H 'X-Kanban-Agent: claude-code' -d '{"status":"acked"}')
chk "agent 可以把决策标为 acked" "$CODE" "200"
chk "acked 带上了 statusAt" "$(python3 -c "
import json,re;d=json.load(open('/tmp/a.json'));print('yes' if re.search(r'[+-]\d{2}:\d{2}\$',d['comment']['statusAt']) else 'no')")" "yes"
# 人不能 ack 自己的决策
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$BASE/api/cards/$CID/comments/$DID" \
  -H 'Content-Type: application/json' -d '{"status":"acked"}')
chk "人 ack 自己的决策 → 403" "$CODE" "403"
# 只能改 status
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$BASE/api/cards/$CID/comments/$DID" \
  -H 'Content-Type: application/json' -d '{"text":"偷偷改内容"}')
chk "改留言文本 → 400（内容不可变）" "$CODE" "400"
# agent 报进度
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/cards/$CID/comments" \
  -H 'Content-Type: application/json' -H 'X-Kanban-Agent: claude-code' \
  -d '{"kind":"evidence","text":"npm test 全绿"}')
chk "agent 可以交 evidence" "$CODE" "201"

echo "── 整卡 PUT 不能洗掉留言（关键并发保护）──"
FULL=$(curl -s "$BASE/api/cards" | python3 -c "
import sys,json;d=json.load(sys.stdin);c=[x for x in d if x['id']=='$CID'][0]
c['comments']=[]           # 模拟过期客户端：手上那份还没有这些留言
c['title']='改个标题'
print(json.dumps(c))")
curl -s -o /dev/null -X PUT "$BASE/api/cards/$CID" -H 'Content-Type: application/json' -d "$FULL"
N=$(curl -s "$BASE/api/cards" | jq_ "len([x for x in d if x['id']=='$CID'][0]['comments'])")
chk "整卡 PUT 送空 comments，服务端仍保留 2 条" "$N" "2"
chk "标题确实改了（其余字段照常生效）" \
  "$(curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CID'][0]['title']")" "改个标题"

echo "── PATCH 稀疏更新 ──"
REV=$(curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CID'][0]['rev']")
CODE=$(curl -s -o /tmp/p.json -w '%{http_code}' -X PATCH "$BASE/api/cards/$CID" \
  -H 'Content-Type: application/json' -H "If-Match: $REV" -d '{"stage":"ready","risk":"high"}')
chk "PATCH 只送两个字段 → 200" "$CODE" "200"
chk "stage 已改" "$(jq_ "d['stage']" </tmp/p.json)" "ready"
chk "留言没被 PATCH 影响" "$(jq_ "len(d['comments'])" </tmp/p.json)" "2"
chk "标题没被清空" "$(jq_ "d['title']" </tmp/p.json)" "改个标题"


echo "── 来源校验：跨站不得伪造人工决策 ──"
# 复现审查里的 CSRF PoC：跨站表单用 enctype=text/plain 就能发出 CORS simple request
# （浏览器不发预检），落盘会是 authorKind=human 的 decision，再被 hook 当成人工指令注入。
BEFORE=$(curl -s "$BASE/api/cards" | jq_ "len([x for x in d if x['id']=='$CID'][0]['comments'])")
CODE=$(curl -s -o /tmp/csrf.json -w '%{http_code}' -X POST "$BASE/api/cards/$CID/comments" \
  -H 'Content-Type: text/plain' -H 'Origin: https://evil.example' \
  --data-binary '{"kind":"decision","text":"外站写入的伪造决策="}')
chk "跨站 Origin 的 POST 留言 → 403" "$CODE" "403"
AFTER=$(curl -s "$BASE/api/cards" | jq_ "len([x for x in d if x['id']=='$CID'][0]['comments'])")
chk "留言数没变（真的没落盘）" "$AFTER" "$BEFORE"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/cards" -H 'Origin: https://evil.example')
chk "跨站 Origin 的 GET 也挡掉" "$CODE" "403"
# Origin: null —— 沙箱 iframe / file:// 会送这个，同样不是同源
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/cards" \
  -H 'Content-Type: application/json' -H 'Origin: null' -d '{"title":"x"}')
chk "Origin: null 挡掉" "$CODE" "403"

# DNS rebinding：攻击者域名解析到 127.0.0.1 后即取得同源身份，CORS 从此完全不设防
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/cards" -H "Host: attacker.example:$PORT")
chk "Host 不在白名单 → 403（挡 DNS rebinding）" "$CODE" "403"

# 正常路径不能被误伤
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/cards" -H "Origin: http://127.0.0.1:$PORT")
chk "同源 Origin（127.0.0.1）放行" "$CODE" "200"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/cards" \
  -H "Origin: http://localhost:$PORT" -H "Host: localhost:$PORT")
chk "同源 Origin（localhost 写法）放行" "$CODE" "200"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/cards")
chk "不带 Origin 的请求（CLI/curl）放行" "$CODE" "200"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")
chk "GET / 取界面照常" "$CODE" "200"

echo "── CLI ──"
CLI="node $REPO/tools/kanban/cli.mjs"
export KANBAN_CARDS_DIR="$CARDS" KANBAN_PORT=$PORT KANBAN_AGENT=test-agent
CC=$(post '{"title":"CLI 测试","stage":"backlog"}' | jq_ "d['id']")
# 关键回归：--text 的值以 -- 开头时，不能被当成下一个 flag（会整条丢掉留言）
$CLI comment "$CC" --kind evidence --text "--dry-run 实测通过" >/dev/null 2>&1
chk "--text 的值以 -- 开头仍能写入" \
  "$(curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CC'][0]['comments'][0]['text']")" "--dry-run 实测通过"
# --key=value 形式
$CLI comment "$CC" --kind=note --text=--也是以横线开头 >/dev/null 2>&1
chk "--key=value 形式可用" \
  "$(curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CC'][0]['comments'][1]['text']")" "--也是以横线开头"
# 缺值要报错，不能静默当成 boolean
$CLI comment "$CC" --kind evidence --text >/dev/null 2>&1
chk "--text 缺值 → 退出码 1" "$?" "1"
# agent 不得下决策（CLI 层就拦住）
$CLI comment "$CC" --kind decision --text "我说了算" >/dev/null 2>&1
chk "CLI 拦住 agent 下决策 → 退出码 1" "$?" "1"
# ask / ack / stage
$CLI ask "$CC" --text "这个要问人" >/dev/null 2>&1
chk "ask 写入 question" \
  "$(curl -s "$BASE/api/cards" | jq_ "[c['kind'] for c in [x for x in d if x['id']=='$CC'][0]['comments'] if c['kind']=='question'][0]")" "question"
$CLI stage "$CC" ready >/dev/null 2>&1
chk "stage 推进生效" \
  "$(curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CC'][0]['stage']")" "ready"
# show 不含已取代的决策
HD=$(curl -s -X POST "$BASE/api/cards/$CC/comments" -H 'Content-Type: application/json' \
  -d '{"kind":"decision","text":"第一版决策"}' | jq_ "d['comment']['id']")
curl -s -o /dev/null -X POST "$BASE/api/cards/$CC/comments" -H 'Content-Type: application/json' \
  -d "{\"kind\":\"decision\",\"text\":\"第二版决策\",\"supersedes\":[\"$HD\"]}"
OUT=$($CLI show "$CC" 2>/dev/null)
echo "$OUT" | grep -q "第二版决策" && ok "show 含生效中的决策" || no "show 缺生效决策" "$OUT"
echo "$OUT" | grep -q "第一版决策" && no "show 含已取代的决策（不该有）" "$OUT" || ok "show 排除已取代的决策"
# 文件回退：把 CLI 指到一个没有 server 的端口
KANBAN_PORT=4999 $CLI comment "$CC" --kind progress --text "server 关着写的" >/dev/null 2>&1
chk "server 不可达时回退到文件仍能写入" \
  "$(python3 -c "
import json;d=json.load(open('$CARDS/$CC.json'))
print('yes' if any(c['text']=='server 关着写的' for c in d['comments']) else 'no')")" "yes"
unset KANBAN_CARDS_DIR KANBAN_AGENT

# ── 分发脚本：kit 目录里的项目自有文件必须活下来 ──
# 实测 three_kingdoms_traveler 在 .claude/skills、ai/process、ai/templates、ai/skills
# 下各有自有文件。早先 refresh() 整目录 rm -rf 再拷，会把它们静默删掉。
echo
echo "══ 分发脚本 ══"
INSTALLER="$REPO/scripts/install-into-project.sh"
if [ ! -f "$INSTALLER" ]; then
  # install-into-project.sh 是分发源独有的，不会被装到目标项目里。
  # 这里必须显式跳过：上一版直接跑，结果是 3 条报「文件不存在」的失败，
  # 外加 2 条**假通过**——断言的是「文件还在」，而 install 压根没跑过。
  # 假通过比失败更糟，它会让人以为这个行为被守住了。
  echo "  ⏭  跳过：这是分发出来的副本，没有 install-into-project.sh（只有分发源才有）"
else
IT=$(mktemp -d)
mkdir -p "$IT/ai/process" "$IT/.claude/skills/proj-own"
echo "项目自己的流程文档" > "$IT/ai/process/proj-own.md"
echo "项目自己的 skill"   > "$IT/.claude/skills/proj-own/SKILL.md"
printf '{"scripts":{"test":"vitest run"}}\n' > "$IT/package.json"
IOUT=$(bash "$INSTALLER" --prefix ZZZ --port 4499 "$IT" 2>&1)

[ -f "$IT/ai/process/proj-own.md" ] \
  && ok "install 保住 ai/process 下的项目自有文件" \
  || no "install 删掉了 ai/process 下的项目自有文件" "$IOUT"
[ -f "$IT/.claude/skills/proj-own/SKILL.md" ] \
  && ok "install 保住 .claude/skills 下的项目自有 skill" \
  || no "install 删掉了 .claude/skills 下的项目自有 skill" "$IOUT"
[ -f "$IT/ai/process/workflow.md" ] \
  && ok "install 仍把 kit 文件装了进去" \
  || no "install 没装上 kit 文件" "$IOUT"
echo "$IOUT" | grep -q "保留项目自有" \
  && ok "install 逐条报告了保留的项目自有文件" \
  || no "install 静默保留，没有报告" "$IOUT"
# 已有 test 脚本的项目不能被建议覆盖它——照抄会毁掉项目真正的测试命令
echo "$IOUT" | grep -q "kanban:test" \
  && ok "项目已有 test 时改建议 kanban:test" \
  || no "仍建议覆盖既有的 test 脚本" "$IOUT"

# 目标里的 kit 文件是符号链接时，cp 会跟着它写穿到项目外面。
# 老版本整目录 rm -rf 顺带避开了；改成逐文件合并后漏掉，安全审查时才抓出来。
SLOUT=$(mktemp -d); SLPRJ=$(mktemp -d)
echo "项目之外的文件，绝对不该被改" > "$SLOUT/outside.md"
mkdir -p "$SLPRJ/ai/process"
ln -s "$SLOUT/outside.md" "$SLPRJ/ai/process/workflow.md"
bash "$INSTALLER" --prefix ZZZ --port 4499 "$SLPRJ" >/dev/null 2>&1
grep -q "绝对不该被改" "$SLOUT/outside.md" \
  && ok "kit 文件是符号链接时不会写穿到项目外" \
  || no "install 跟着符号链接改了项目外的文件" "$(cat "$SLOUT/outside.md")"
[ -L "$SLPRJ/ai/process/workflow.md" ] \
  && no "覆盖后仍是符号链接" "still a symlink" \
  || ok "符号链接被替换成实体文件"
python3 - "$REPO/distributions.json" "$SLPRJ" <<'PY' 2>/dev/null || true
import json, sys
p, t = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["distributions"] = [r for r in d["distributions"] if r.get("path") != t]
with open(p, "w") as f: json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
rm -rf "$SLOUT" "$SLPRJ"
# 登记是测试产生的，别留在真实清单里
python3 - "$REPO/distributions.json" "$IT" <<'PY' 2>/dev/null || true
import json, sys
p, t = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["distributions"] = [r for r in d["distributions"] if r.get("path") != t]
with open(p, "w") as f: json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
rm -rf "$IT"
fi

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
