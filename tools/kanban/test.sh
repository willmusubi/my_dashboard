#!/usr/bin/env bash
# 看板回归测试：每个修掉的 bug 都要能复现出「已修好」。
#
#   bash tools/kanban/test.sh        （或 npm test）
#
# 测试跑在一个临时目录里（KANBAN_CARDS_DIR），**绝不碰真实的 cards/**。
# 上一版直接 rm 真实 cards/，真删掉过 12 张卡——那种测试比没有测试更糟。
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# cd && pwd 归一化：$TMPDIR 在 macOS 上带尾斜杠，mktemp 模板会产出 `…/T//kanban-test.X`。
# 安装脚本对目标做的正是 cd && pwd（单斜杠），两边字符串对不上，按路径清理登记就成了空操作
# ——残留的前缀会让**下一次**跑测试撞车失败，而现场完全看不出是上一次留下的。
TMPROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/kanban-test.XXXXXX")" && pwd)"
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
  "$REPO"/*) echo "拒绝运行：测试数据目录落在仓库内（${CARDS}）"; exit 1 ;;
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

# 测试里的真实安装会往 distributions.json 登记。**跑挂了也必须清掉**，否则残留的
# 前缀会让下一次跑测试撞车。所以按「路径在 TMPROOT 底下」整批扫，而不是逐个记帐——
# 逐个记帐要求每条路径都被记得，而失败路径恰恰是最容易漏的。
purge_registry() {
  python3 - "$REPO/distributions.json" "$TMPROOT" <<'PY' 2>/dev/null || true
import json, sys
reg, root = sys.argv[1], sys.argv[2].rstrip("/") + "/"
try:
    d = json.load(open(reg))
except Exception:
    raise SystemExit
rows = d.get("distributions", [])
kept = [r for r in rows if not str(r.get("path", "")).startswith(root)]
if len(kept) == len(rows):
    raise SystemExit
d["distributions"] = kept
with open(reg, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
}

KANBAN_PORT=$PORT KANBAN_CARDS_DIR="$CARDS" node "$REPO/tools/kanban/server.mjs" >/tmp/t1.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; purge_registry; rm -rf "$TMPROOT"' EXIT
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

echo "── U10：依赖门禁只挡本次推进，不连坐也不冻结 ──"
# 复刻 real_rpg 的现场：RR-025/026/027 一路依赖，却全都停在 verify。
# 这种状态只能由「直接写卡片文件」产生（RR-027 第一次进 git 就是 verify/rev 1），
# 但产生之后必须还能被修好——否则那两条车道只剩手改 JSON 一条路。
D1=$(post '{"title":"前置","stage":"backlog"}' | jq_ "d['id']")
D2=$(post "{\"title\":\"中间\",\"stage\":\"backlog\",\"dependsOn\":[\"$D1\"]}" | jq_ "d['id']")
D3=$(post "{\"title\":\"下游\",\"stage\":\"backlog\",\"dependsOn\":[\"$D2\"]}" | jq_ "d['id']")
python3 - "$CARDS" "$D1" "$D2" "$D3" <<'PY'
import json, sys
cards = sys.argv[1]
for cid in sys.argv[2:]:
    p = cards + "/" + cid + ".json"
    d = json.load(open(p)); d["stage"] = "verify"
    with open(p, "w") as f:
        json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
getcard(){ curl -s "$BASE/api/cards" | python3 -c "
import sys,json;d=json.load(sys.stdin);print(json.dumps([c for c in d if c['id']=='$1'][0]))"; }

# ① 勾一个 gate：stage 一动没动，不该被当成推进
GATED=$(getcard "$D2" | python3 -c "
import sys,json;c=json.load(sys.stdin);c['gates']['product']=True;print(json.dumps(c))")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/cards/$D2" \
  -H 'Content-Type: application/json' -H "If-Match: $(getcard "$D2" | jq_ "d['rev']")" -d "$GATED")
chk "依赖未完成的卡仍能勾 gate（stage 没动）" "$CODE" "200"

# ② 真正的推进照旧拦住
TODONE=$(getcard "$D2" | python3 -c "
import sys,json;c=json.load(sys.stdin);c['stage']='done';print(json.dumps(c))")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/cards/$D2" \
  -H 'Content-Type: application/json' -H "If-Match: $(getcard "$D2" | jq_ "d['rev']")" -d "$TODONE")
chk "依赖未完成时 verify → done 仍被拦住" "$CODE" "400"

# ③ 拖 D1 进 done：同栏的 D2/D3 序号前移，会一起进 payload。
#    它们早就违规，但这次只改了 order——不该连坐否决整批（拖 A 报 C 的错）。
DRAG=$(curl -s "$BASE/api/cards" | python3 -c "
import sys,json;d=json.load(sys.stdin);m={c['id']:c for c in d}
a=m['$D1']; a['stage']='done'; a['order']=99
b=m['$D2']; b['order']=1
c=m['$D3']; c['order']=2
print(json.dumps([a,b,c]))")
CODE=$(curl -s -o /tmp/dragbulk.json -w '%{http_code}' -X PUT "$BASE/api/cards" \
  -H 'Content-Type: application/json' -d "$DRAG")
chk "拖前置卡进 done 不被同批旁观者的旧违规否决" "$CODE" "200"
chk "前置卡确实落盘成 done" "$(getcard "$D1" | jq_ "d['stage']")" "done"

# ④ 前置完成后，下游自然解开——链条一节一节松，不需要手改 JSON
NOWOK=$(getcard "$D2" | python3 -c "
import sys,json;c=json.load(sys.stdin);c['stage']='done';print(json.dumps(c))")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/cards/$D2" \
  -H 'Content-Type: application/json' -H "If-Match: $(getcard "$D2" | jq_ "d['rev']")" -d "$NOWOK")
chk "前置 done 之后下游可以推进" "$CODE" "200"

echo "── U11：人在看板上做的事要推到 agent 眼前 ──"
# 真的跑 hook 进程。这一关只能这样测：函数单测过了不代表 hook 会输出，
# 而「hook 什么都没吐」正是人勾了关卡、AI 却还在问要不要勾的那个 bug。
HOOK="$REPO/tools/kanban/hooks/inject-card-context.mjs"
hook(){ echo "{\"prompt\":\"$1\"}" | KANBAN_CARDS_DIR="$CARDS" node "$HOOK"; }

HK=$(post '{"title":"人写了决策的卡","stage":"backlog"}' | jq_ "d['id']")
# 不带 X-Kanban-Agent → 服务端记成人写的
curl -sf -X POST "$BASE/api/cards/$HK/comments" -H 'Content-Type: application/json' \
  -d '{"kind":"decision","text":"这条是人写的决策，agent 必须遵守"}' >/dev/null
OUT=$(hook "继续")
case "$OUT" in
  *"kanban-brief"*"$HK"*) ok "prompt 不带卡号时退回简报，并点名了 $HK" ;;
  *) no "prompt 不带卡号时应注入简报" "${OUT:-（空输出）}" ;;
esac

OUT=$(hook "继续做 $HK")
case "$OUT" in
  *"kanban-card"*"生效中的人工决策"*) ok "带卡号时仍注入整张卡（原行为没被改坏）" ;;
  *) no "带卡号时应注入整张卡" "${OUT:-（空输出）}" ;;
esac
case "$OUT" in
  *"kanban-brief"*) no "带卡号时不该再叠一份简报" "$OUT" ;;
  *) ok "带卡号时不叠简报" ;;
esac

# 人只勾关卡、一条留言都不写：这一类原本连 SessionStart 都不会提
GK=$(post '{"title":"人只勾了关卡的卡","stage":"backlog"}' | jq_ "d['id']")
curl -sf -X PATCH "$BASE/api/cards/$GK" -H 'Content-Type: application/json' \
  -d '{"stage":"verify","gates":{"product":true,"ui":false,"architecture":false,"security":false,"test":false,"code_review":false}}' >/dev/null
OUT=$(hook "可以了")
case "$OUT" in
  *"$GK"*"不要再问要不要勾"*) ok "人只勾关卡不留言，简报也报得出来" ;;
  *) no "人勾了 product 之后简报应点名 $GK" "${OUT:-（空输出）}" ;;
esac

# SessionStart 那个 hook 与它共用渲染，措辞必须一致
BRIEF=$(KANBAN_CARDS_DIR="$CARDS" node "$REPO/tools/kanban/hooks/session-board-brief.mjs")
chk "两个 hook 的简报输出逐字一致" "$BRIEF" "$OUT"

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

# 提问 = 停下来等人，卡片必须跟着换车道。不换的话它继续占着 implementing 的
# WIP 名额、看起来像在做，实际在等人——而人看的是车道，不是 cli.mjs open。
stage_of(){ curl -s "$BASE/api/cards" | jq_ "[x for x in d if x['id']=='$CC'][0]['stage']"; }
chk "ask 把卡片推进 blocked" "$(stage_of)" "blocked"
$CLI ask "$CC" --text "再问一句" >/dev/null 2>&1
chk "已在 blocked 时再 ask 不报错（退出码 0）" "$?" "0"
chk "已在 blocked 时再 ask 不乱动 stage" "$(stage_of)" "blocked"
# --no-block：只想记一笔、活还能继续
$CLI stage "$CC" implementing >/dev/null 2>&1
$CLI ask "$CC" --text "顺口一问，活还能继续" --no-block >/dev/null 2>&1
chk "--no-block 时 stage 保持不动" "$(stage_of)" "implementing"
# 在已完成的卡上追问，不该把它拖回未完成状态
$CLI stage "$CC" done >/dev/null 2>&1
$CLI ask "$CC" --text "事后追问" >/dev/null 2>&1
chk "done 的卡上 ask 不回退 stage" "$(stage_of)" "done"
$CLI stage "$CC" backlog >/dev/null 2>&1

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
# 人不会一直开着看板，所以 ask 推 blocked 在文件回退路径上也必须成立
KANBAN_PORT=4999 $CLI stage "$CC" implementing >/dev/null 2>&1
KANBAN_PORT=4999 $CLI ask "$CC" --text "server 关着时提的问" >/dev/null 2>&1
chk "server 不可达时 ask 也把卡推进 blocked" \
  "$(python3 -c "import json;print(json.load(open('$CARDS/$CC.json'))['stage'])")" "blocked"
unset KANBAN_CARDS_DIR KANBAN_AGENT

# ── 分发脚本：kit 目录里的项目自有文件必须活下来 ──
# 实测 three_kingdoms_traveler 在 .claude/skills、ai/process、ai/templates、ai/skills
# 下各有自有文件。早先 refresh() 整目录 rm -rf 再拷，会把它们静默删掉。
echo
echo "══ shell 脚本静态检查 ══"
# bash 会把多字节字符当成变量名的一部分：`$label` 后面紧跟全角括号时会被当成变量名 label（ 的一部分，
# 在 set -u 下直接 unbound variable 崩掉。这个坑一天之内咬了三次
# （install-into-project.sh 两次、upgrade-all.sh 一次），而且全在**错误路径**上
# ——平时跑不到，一跑到就崩在最不该崩的地方。所以做成断言而不是靠记性。
BADVARS=$(grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' \
  "$REPO"/scripts/*.sh "$REPO"/tools/kanban/*.sh 2>/dev/null)
[ -z "$BADVARS" ] \
  && ok "没有「变量后紧跟全角字符」的写法（这种写法在 set -u 下会崩）" \
  || no "有变量后紧跟全角字符，应改成 \${VAR}" "$BADVARS"

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
IT="$TMPROOT/inst"; mkdir -p "$IT"
mkdir -p "$IT/ai/process" "$IT/.claude/skills/proj-own"
echo "项目自己的流程文档" > "$IT/ai/process/proj-own.md"
echo "项目自己的 skill"   > "$IT/.claude/skills/proj-own/SKILL.md"
printf '{"scripts":{"test":"vitest run"}}\n' > "$IT/package.json"
# --no-verify：这两次安装验的是「文件放对了没」。不关掉的话安装脚本会在目标里
# 再跑一整套 test.sh（就是本文件），而它默认绑 4531 —— 和外层这个 server 同一个
# 端口，嵌套那套断言会转而打到外层 server 上。自动自检本身另有专门的用例在下面测。
IOUT=$(bash "$INSTALLER" --no-verify --prefix ZZZ --port 4499 "$IT" 2>&1)

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
SLOUT="$TMPROOT/outside"; SLPRJ="$TMPROOT/slink"; mkdir -p "$SLOUT" "$SLPRJ"
echo "项目之外的文件，绝对不该被改" > "$SLOUT/outside.md"
mkdir -p "$SLPRJ/ai/process"
ln -s "$SLOUT/outside.md" "$SLPRJ/ai/process/workflow.md"
bash "$INSTALLER" --no-verify --prefix ZZZ --port 4499 "$SLPRJ" >/dev/null 2>&1
grep -q "绝对不该被改" "$SLOUT/outside.md" \
  && ok "kit 文件是符号链接时不会写穿到项目外" \
  || no "install 跟着符号链接改了项目外的文件" "$(cat "$SLOUT/outside.md")"
[ -L "$SLPRJ/ai/process/workflow.md" ] \
  && no "覆盖后仍是符号链接" "still a symlink" \
  || ok "符号链接被替换成实体文件"

# ── 一条命令装到新项目：前缀推导 / 端口自动选 / package.json ──
# package.json 的断言打在上面那两次**真实**安装的产物上，不另外再装一遍
# （每多一次真实安装就多一条要清理的 distributions.json 登记）。
PKGQ="import json,sys;print(json.load(open(sys.argv[1]))['scripts'].get(sys.argv[2],''))"
chk "目标已有的 test 脚本原样保留" \
  "$(python3 -c "$PKGQ" "$IT/package.json" test)" "vitest run"
chk "已有 test 时看板测试改挂 kanban:test" \
  "$(python3 -c "$PKGQ" "$IT/package.json" kanban:test)" "bash tools/kanban/test.sh"
chk "kanban 启动脚本已自动补上" \
  "$(python3 -c "$PKGQ" "$IT/package.json" kanban)" "node tools/kanban/server.mjs"
[ ! -f "$SLPRJ/package.json" ] \
  && ok "目标没有 package.json 时跳过，不凭空创建" \
  || no "给没有 package.json 的项目凭空造了一个" "$(cat "$SLPRJ/package.json")"

# epics.json 属「内容天生属于项目」那一类，kit 只该给空骨架——和 cards/ 一样。
# 早先它在 keep 名单里，于是新项目装完带着**分发源自己的 Epic**（real_rpg 实测中招）。
chk "全新安装的 epics.json 是空数组" \
  "$(python3 -c "import json;print(json.load(open('$IT/tools/kanban/epics.json'))['epics'])")" "[]"
# 光看「是空的」不够：要确认里面没有分发源的任何一个 Epic 名字
SRC_EPICS=$(python3 -c "
import json;print('|'.join(e['name'] for e in json.load(open('$REPO/tools/kanban/epics.json'))['epics']))")
if [ -n "$SRC_EPICS" ] && grep -qE "$SRC_EPICS" "$IT/tools/kanban/epics.json"; then
  no "新项目的 epics.json 里混进了分发源的 Epic" "$(cat "$IT/tools/kanban/epics.json")"
else
  ok "新项目的 epics.json 不含分发源的任何 Epic"
fi

DT="$TMPROOT/dist"

# 省略目标 = 当前目录；前缀按目录名推首字母缩写
mkdir -p "$DT/alpha_beta_gamma"
DOUT=$(cd "$DT/alpha_beta_gamma" && bash "$INSTALLER" --dry-run --yes 2>&1)
echo "$DOUT" | grep -q "^前缀：  ABG" \
  && ok "省略目标时用当前目录，前缀按目录名推导（alpha_beta_gamma → ABG）" \
  || no "目标缺省或前缀推导不对" "$(echo "$DOUT" | head -6)"

# 推导撞车必须硬停。用 d_a_s_h：它推出 DASH，而 DASH 是分发源自己的前缀，
# 跟 distributions.json 里当下登记了谁无关——这条断言在任何机器上都成立。
mkdir -p "$DT/d_a_s_h"
COUT=$(bash "$INSTALLER" --dry-run --yes "$DT/d_a_s_h" 2>&1); CRC=$?
{ [ "$CRC" -ne 0 ] && echo "$COUT" | grep -q "已被占用"; } \
  && ok "推导出的前缀撞车时硬停，不静默改名" \
  || no "前缀撞车没拦住" "rc=$CRC $(echo "$COUT" | tail -3)"

# 前缀不可逆，非交互环境下不能把「读不到输入」当成「人按了回车」。
# 这个坑真踩过：read 写成 `|| ANS=""`，无 tty 时静默接受了推导值。
mkdir -p "$DT/quiet_probe"
QOUT=$(bash "$INSTALLER" --dry-run "$DT/quiet_probe" < /dev/null 2>&1); QRC=$?
{ [ "$QRC" -ne 0 ] && echo "$QOUT" | grep -q "读不到终端输入"; } \
  && ok "非交互环境不静默接受推导出的前缀" \
  || no "非交互时静默接受了推导前缀" "rc=$QRC $(echo "$QOUT" | tail -3)"

# 交互确认那三条路径。这是本项目「不可逆的值由人拍板」在代码里的落点，
# 回归掉了就等于脚本自己替人定了前缀，所以值得测。
# expect 不是硬依赖，没有就**说出来**再跳过——静默跳过和假通过没区别。
if command -v expect >/dev/null 2>&1; then
  mkdir -p "$DT/interactive_probe"
  cat > "$TMPROOT/ask.exp" <<'EXP'
log_user 0
set timeout 30
spawn bash [lindex $argv 0] --dry-run [lindex $argv 1]
expect {
  "Ctrl-C" {}
  timeout { puts "没等到确认提示（超时）"; exit 1 }
  eof     { puts "没等到确认提示就结束了"; exit 1 }
}
send "[lindex $argv 2]\r"
log_user 1
expect eof
EXP
  ask(){ expect "$TMPROOT/ask.exp" "$INSTALLER" "$DT/interactive_probe" "$1" 2>&1; }

  AOUT=$(ask "")
  echo "$AOUT" | grep -q '"idPrefix": "IP"' \
    && ok "交互确认：回车接受推导值（interactive_probe → IP）" \
    || no "回车没有接受推导值" "$(echo "$AOUT" | tail -3)"

  AOUT=$(ask "xyz")
  { echo "$AOUT" | grep -q "改用前缀 XYZ" && echo "$AOUT" | grep -q '"idPrefix": "XYZ"'; } \
    && ok "交互确认：输入别的前缀会覆盖推导值并转大写" \
    || no "输入的前缀没有生效" "$(echo "$AOUT" | tail -3)"

  AOUT=$(ask "dash")
  echo "$AOUT" | grep -q "已被其他项目占用" \
    && ok "交互确认：输入已被占用的前缀会被拒绝" \
    || no "输入已占用的前缀没被拦住" "$(echo "$AOUT" | tail -3)"
else
  echo "  ⏭  跳过交互确认的 3 条断言：本机没有 expect"
fi

# 自动选的端口不能和已登记的、或分发源自己的撞
mkdir -p "$DT/port_probe"
PPORT=$(bash "$INSTALLER" --dry-run --yes "$DT/port_probe" 2>&1 \
        | sed -n 's/^端口：  \([0-9]*\).*/\1/p')
python3 - "$REPO/distributions.json" "$REPO/tools/kanban/config.json" "${PPORT:-0}" <<'PY'
import json, sys
reg, own, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
used = {r.get("port") for r in json.load(open(reg)).get("distributions", [])}
used.add(json.load(open(own)).get("port"))
raise SystemExit(0 if port and port not in used else 1)
PY
[ $? -eq 0 ] \
  && ok "自动选取的端口避开了已登记端口（选到 ${PPORT:-空}）" \
  || no "自动选的端口和已登记的撞了" "${PPORT:-空}"

# ── project-owned 文档漂移检测（只报告，绝不覆盖）──
# keep 名单里混着两类：① kit 有正本、项目可能追加（AGENTS/CLAUDE/settings.json）——
# 要报漂移；② 内容天生属于项目（epics.json / ai/context）——报了全是噪音。
DR="$DT/drift_probe"; mkdir -p "$DR/tools/kanban"
python3 - "$REPO/AGENTS.md" "$DR/AGENTS.md" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
out = [l for l in lines if "从情境探索开始" not in l]   # 比 kit 少一行
out.append("- 这是项目自己加的规则，kit 里没有。")       # 比 kit 多一行
open(sys.argv[2], "w").write("\n".join(out))
PY
cp "$REPO/CLAUDE.md" "$DR/CLAUDE.md"                    # 与 kit 完全一致 → 不该有噪音
printf '{"epics":[{"name":"项目自己的 Epic","definition":"x","stories":[]}]}\n' \
  > "$DR/tools/kanban/epics.json"
SUM_A=$(shasum "$DR/AGENTS.md" | cut -d' ' -f1)
SUM_C=$(shasum "$DR/CLAUDE.md" | cut -d' ' -f1)
DROUT=$(bash "$INSTALLER" --no-verify --yes "$DR" 2>&1)

echo "$DROUT" | grep -q "从情境探索开始" \
  && ok "漂移检测报出「kit 有、目标没有」的行" \
  || no "没报出目标缺的那行" "$(echo "$DROUT" | grep -A8 'AGENTS.md' | head -10)"
echo "$DROUT" | grep -q "这是项目自己加的规则" \
  && no "把目标自己加的行也报成漂移了" "只该报 kit → 目标 一个方向" \
  || ok "目标自己加的行不报告（只报一个方向）"
# CLAUDE.md 与 kit 一致、epics.json 属第二类，两者都不该出现在漂移报告里
chk "只有真漂了的第一类文档才报（应恰好 1 处）" "$(echo "$DROUT" | grep -c 'kit 版有')" "1"
# 最要紧的一条：报告归报告，一个字节都不许动
chk "AGENTS.md 未被改动" "$(shasum "$DR/AGENTS.md" | cut -d' ' -f1)" "$SUM_A"
chk "CLAUDE.md 未被改动" "$(shasum "$DR/CLAUDE.md" | cut -d' ' -f1)" "$SUM_C"
chk "第二类的 epics.json 保持目标版本" \
  "$(python3 -c "import json;print(json.load(open('$DR/tools/kanban/epics.json'))['epics'][0]['name'])")" \
  "项目自己的 Epic"

# ── 装完自动跑自检 ──
# 三条「不该跑」的路径先测，它们都不触发嵌套的 test.sh，很快。
mkdir -p "$DT/verify_dry"
bash "$INSTALLER" --dry-run --yes "$DT/verify_dry" 2>&1 | grep -q "^自检" \
  && no "dry-run 也跑了自检" "dry-run 不该有自检那一段" \
  || ok "dry-run 不跑自检"

# 先捕获再匹配，**不要** `installer | grep -q`：grep -q 一匹配就退出并关掉管道，
# 安装脚本收到 SIGPIPE 死掉，pipefail 于是把整条管道判为失败——断言明明该过却报红。
mkdir -p "$DT/verify_skipped"
SOUT=$(bash "$INSTALLER" --no-verify --yes "$DT/verify_skipped" 2>&1)
echo "$SOUT" | grep -q "已用 --no-verify 跳过" \
  && ok "--no-verify 能关掉自检" \
  || no "--no-verify 没关掉自检" "$(echo "$SOUT" | grep '^自检')"

# 第二次装同一个目标 = config.json 已存在，走 upgrade-all 的那条路径
ROUT=$(bash "$INSTALLER" --yes "$DT/verify_skipped" 2>&1)
echo "$ROUT" | grep -q "自检：跳过——目标不是全新安装" \
  && ok "重装（config.json 已存在）不跑自检，批量升级不会变慢" \
  || no "重装仍跑了自检" "$(echo "$ROUT" | grep '^自检')"

# 真的跑一次自检。嵌套的 test.sh 必须换端口，否则它连上外层这个 server，
# 整套断言就打到别人身上去了（见 249 行那段注释）。
mkdir -p "$DT/verify_auto"
VOUT=$(KANBAN_TEST_PORT=$((PORT + 1)) bash "$INSTALLER" --yes "$DT/verify_auto" 2>&1); VRC=$?
{ [ "$VRC" -eq 0 ] \
  && echo "$VOUT" | grep -q "✅ scripts/check-governance.sh" \
  && echo "$VOUT" | grep -q "✅ tools/kanban/test.sh"; } \
  && ok "全新安装后自动跑完两项自检并全绿" \
  || no "自动自检没跑或没过" "rc=$VRC $(echo "$VOUT" | sed -n '/^自检/,/^$/p')"

# 收尾待办里不该再有「确认 config.json」——前缀在安装时已经确认过了
echo "$VOUT" | grep -q "确认 tools/kanban/config.json" \
  && no "收尾仍要求人手动确认 config.json" "这一步在安装时已经做过了" \
  || ok "收尾待办不再包含「确认 config.json」"

# 自检失败要响亮且退出码非 0。用真实场景制造失败：目标已有 ai/context/ 时
# 整个目录走 keep 分支被跳过，check-governance 要的 design-system.md 就缺了。
mkdir -p "$DT/verify_broken/ai/context"
echo "项目自己的情境笔记" > "$DT/verify_broken/ai/context/notes.md"
FOUT=$(KANBAN_TEST_PORT=$((PORT + 2)) bash "$INSTALLER" --yes "$DT/verify_broken" 2>&1); FRC=$?
{ [ "$FRC" -ne 0 ] \
  && echo "$FOUT" | grep -q "❌ scripts/check-governance.sh" \
  && echo "$FOUT" | grep -q "文件已经装好了"; } \
  && ok "自检失败时响亮报错、退出码非 0，且区分「已装好」与「没过」" \
  || no "自检失败没被报出来" "rc=$FRC $(echo "$FOUT" | tail -5)"


fi

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
