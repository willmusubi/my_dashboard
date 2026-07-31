#!/usr/bin/env bash
# 把本仓库的改进推到所有已装过的项目。
#
#   bash scripts/upgrade-all.sh [--dry-run]
#
# 读 distributions.json（由 install-into-project.sh 自动登记），逐个跑一次安装。
# 不传 --prefix/--port：目标的 tools/kanban/config.json 是 project-owned，本来就
# 不会被覆盖，各项目保留自己的前缀与端口。
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$SRC/distributions.json"
INSTALL="$SRC/scripts/install-into-project.sh"

DRY=""
case "${1:-}" in
  --dry-run) DRY="--dry-run" ;;
  -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "未知参数：$1"; exit 1 ;;
esac

if [[ ! -f "$REG" ]]; then
  echo "还没有分发记录（$REG）。"
  echo "先用 scripts/install-into-project.sh 装一个项目，它会自动登记。"
  exit 0
fi

declare -i OK=0 SKIP=0 FAIL=0

# bash 3.2 没有 mapfile，用进程替换 + while read。
while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  echo ""
  echo "═══════════════════════════════════════════════════════"
  if [[ ! -d "$target" ]]; then
    # 不从清单里删——可能只是外置盘没挂载，或临时移走了。
    echo "跳过（目录不存在）：$target"
    SKIP+=1
    continue
  fi
  echo "升级：$target"
  echo "═══════════════════════════════════════════════════════"
  if bash "$INSTALL" $DRY "$target"; then
    OK+=1
  else
    echo "❌ 失败：$target"
    FAIL+=1
  fi
done < <(python3 -c "
import json
for r in json.load(open('$REG')).get('distributions', []):
    print(r.get('path', ''))
")

echo ""
echo "═══ 全部完成：成功 ${OK}，跳过 ${SKIP}，失败 ${FAIL} ═══"
if [[ "$DRY" == "--dry-run" ]]; then
  echo "这是预演，没有写入任何东西。去掉 --dry-run 才会实际升级。"
fi
[[ "$FAIL" -eq 0 ]]
