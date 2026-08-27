#!/usr/bin/env bash
# 看板卡片的提交前校验：手写坏的卡片进不了 commit。**kit 文件，每次升级都会刷新。**
#
# 这一段刻意不直接叫 pre-commit：项目往往已经有自己的 pre-commit（实测
# medical_tourism 的那份是 MT-002 的密钥泄漏防线），kit 整份覆盖过去会静默毁掉它。
# 所以逻辑放这里由 kit 维护，调用点留给项目自己的 pre-commit：
#
#   bash "$(git rev-parse --show-toplevel)/.githooks/kanban-cards.sh" || exit 1
#
# 只校验**这次要提交的**卡片，不是整个 cards/。连坐在这套流程里是刻意避开的
# （见 DASH-037）：别人手写坏的一张卡，不该让一个碰都没碰它的人提交不了东西。
set -uo pipefail

REPO="$(git rev-parse --show-toplevel)" || exit 0
CLI="$REPO/tools/kanban/cli.mjs"
[ -f "$CLI" ] || exit 0   # 不是装了看板的项目，什么都不做

staged=()
while IFS= read -r f; do
  [ -n "$f" ] && staged+=("$f")
done < <(git diff --cached --name-only --diff-filter=ACM -- 'tools/kanban/cards/*.json')
[ ${#staged[@]} -eq 0 ] && exit 0

if ! command -v node >/dev/null 2>&1; then
  echo "pre-commit：找不到 node，卡片校验跳不过去。" >&2
  echo "  这次提交带了 ${#staged[@]} 个卡片文件，没校验就放行等于没装这道关卡。" >&2
  echo "  从装了 node 的终端提交，或明确跳过：git commit --no-verify" >&2
  exit 1
fi

# 校验的是 **index 里的内容**，不是工作树里的。`git add -p` 只暂存了一半时，
# 工作树那份可能是好的而要提交的那份是坏的——校验工作树就会放它过去。
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kanban-precommit.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
files=()
for f in "${staged[@]}"; do
  # 文件名要保住：cli.mjs validate 会拿它和卡片里的 id 对一遍。
  out="$TMP/$(basename "$f")"
  git show ":$f" > "$out" || exit 1
  files+=("$out")
done

if ! node "$CLI" validate "${files[@]}"; then
  echo "" >&2
  echo "提交已中止。修好上面这几个文件再提交；真要跳过：git commit --no-verify" >&2
  exit 1
fi
