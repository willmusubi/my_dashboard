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
PORT=${KANBAN_TEST_PORT:-4431}
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
curl -sf -X DELETE "$BASE/api/cards/DASH-002" >/dev/null   # 删中间那张
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
printf '{"id":"DASH-999","title":"坏档",,,}' > "$CARDS/DASH-999.json"
CODE=$(curl -s -o /tmp/after.json -w '%{http_code}' "$BASE/api/cards")
chk "有坏档时 GET /api/cards 仍是 200（不是 400）" "$CODE" "200"
chk "其余卡片全部还在" "$(jq_ "len(d)" </tmp/after.json)" "$BEFORE"
chk "/api/issues 指名道姓报出坏档" \
  "$(curl -s "$BASE/api/issues" | jq_ "d['broken'][0]['file']")" "DASH-999.json"
rm -f "$CARDS/DASH-999.json"

echo "── track=fullstack 不再让整批拒绝 ──"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/cards" \
  -H 'Content-Type: application/json' -d '{"title":"全栈卡","track":"fullstack"}')
chk "POST track=fullstack → 201" "$CODE" "201"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
