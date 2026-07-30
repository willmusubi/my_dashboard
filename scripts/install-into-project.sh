#!/usr/bin/env bash
# 把这套治理工作流装到另一个项目里。
#
#   scripts/install-into-project.sh [--dry-run] [--prefix TKT] [--port 4431] /path/to/project
#
# 上游的同名脚本对 ai/{process,templates,checklists,skills} 和 .claude/{skills,agents}
# 做无条件 cp -R 覆盖，无备份、无日志、无预演、无卸载——定制过的文件一跑就没。
# 这一版把它换成：先预演、覆盖前备份、逐行报告动了什么。
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
PREFIX=""
PORT=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --prefix)  PREFIX="${2:-}"; shift 2 ;;
    --port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "未知参数：$1"; exit 1 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || { echo "用法：$0 [--dry-run] [--prefix TKT] [--port 4431] /path/to/project"; exit 1; }
[[ -d "$TARGET" ]] || { echo "目标目录不存在：$TARGET"; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

# ── 安全阀 ──
[[ "$TARGET" == "$HOME" ]] && { echo "拒绝：不能把 \$HOME 当成目标项目。"; exit 1; }
[[ "$TARGET" == "/" ]]     && { echo "拒绝：不能把 / 当成目标项目。"; exit 1; }
[[ "$TARGET" == "$SRC" ]]  && { echo "拒绝：目标就是本仓库自己。"; exit 1; }
# cp -R 会跟随符号链接。若目标的 .claude 是指向 ~/.claude 的链接，写进去就污染全局配置。
if [[ -L "$TARGET/.claude" ]]; then
  echo "拒绝：$TARGET/.claude 是符号链接（指向 $(readlink "$TARGET/.claude")）。"
  echo "     cp -R 会跟随它，可能写进你的全局 ~/.claude。请先处理这个链接。"
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET/.kanban-backup-$STAMP"
declare -i N_NEW=0 N_OVER=0 N_SKIP=0

say() { printf '%s\n' "$1"; }
run() { [[ "$DRY" -eq 1 ]] || eval "$1"; }

backup_of() {   # $1 = 目标文件绝对路径
  local rel="${1#"$TARGET"/}"
  run "mkdir -p \"$BACKUP/$(dirname "$rel")\""
  run "cp -R \"$1\" \"$BACKUP/$rel\""
}

# kit-owned：每次安装都刷新到最新版；覆盖前一定备份。
refresh() {     # $1 = 相对路径
  local from="$SRC/$1" to="$TARGET/$1"
  [[ -e "$from" ]] || return 0
  if [[ -e "$to" ]]; then
    if diff -rq "$from" "$to" >/dev/null 2>&1; then
      say "  相同，跳过    $1"; N_SKIP+=1; return 0
    fi
    backup_of "$to"
    say "  覆盖（已备份）$1"; N_OVER+=1
    run "rm -rf \"$to\""
  else
    say "  新建          $1"; N_NEW+=1
  fi
  run "mkdir -p \"$(dirname "$to")\""
  run "cp -R \"$from\" \"$to\""
}

# project-owned：目标已有就永不碰。
keep() {        # $1 = 相对路径
  local from="$SRC/$1" to="$TARGET/$1"
  [[ -e "$from" ]] || return 0
  if [[ -e "$to" ]]; then
    say "  保留目标版本  $1"; N_SKIP+=1; return 0
  fi
  say "  新建          $1"; N_NEW+=1
  run "mkdir -p \"$(dirname "$to")\""
  run "cp -R \"$from\" \"$to\""
}

say "源：    $SRC"
say "目标：  $TARGET"
[[ "$DRY" -eq 1 ]] && say "模式：  预演（不会写任何东西）" || say "模式：  实际安装，覆盖前备份到 $BACKUP"
say ""

say "kit-owned（每次刷新到最新）："
for p in \
  ai/process ai/templates ai/checklists ai/skills \
  .claude/skills .claude/agents \
  tools/kanban/server.mjs tools/kanban/card-store.mjs tools/kanban/cli.mjs \
  tools/kanban/index.html tools/kanban/test.sh tools/kanban/test-store.mjs \
  tools/kanban/hooks tools/kanban/README.md \
  scripts/check-governance.sh \
  .github/pull_request_template.md .github/ISSUE_TEMPLATE/ai_task.yml
do refresh "$p"; done

say ""
say "project-owned（目标已有就不碰）："
for p in \
  CLAUDE.md AGENTS.md \
  ai/context ai/artifacts \
  tools/kanban/epics.json \
  .claude/settings.json
do keep "$p"; done

# 卡片目录只建骨架，绝不复制本仓库的卡片过去。
if [[ ! -d "$TARGET/tools/kanban/cards" ]]; then
  say "  新建          tools/kanban/cards/（空）"; N_NEW+=1
  run "mkdir -p \"$TARGET/tools/kanban/cards\" && touch \"$TARGET/tools/kanban/cards/.gitkeep\""
else
  say "  保留目标版本  tools/kanban/cards/（$(ls "$TARGET"/tools/kanban/cards/*.json 2>/dev/null | wc -l | tr -d ' ') 张卡）"; N_SKIP+=1
fi

# 卡片 id 前缀与端口：分发到别的项目时必须能改，否则两个项目的 id 会撞。
# 用环境变量注入，避免改代码——card-store.mjs 读 KANBAN_ID_PREFIX / KANBAN_PORT。
if [[ -n "$PREFIX" || -n "$PORT" ]]; then
  say ""
  say "写入 .env.kanban（card-store.mjs 与 server.mjs 会读这些变量）："
  ENVF="$TARGET/.env.kanban"
  [[ -e "$ENVF" ]] && backup_of "$ENVF"
  BODY="# 看板配置。用法：set -a; . ./.env.kanban; set +a; npm run kanban"
  [[ -n "$PREFIX" ]] && BODY="$BODY"$'\n'"KANBAN_ID_PREFIX=${PREFIX}"
  [[ -n "$PORT" ]]   && BODY="$BODY"$'\n'"KANBAN_PORT=${PORT}"
  printf '%s\n' "$BODY" | sed 's/^/  /'
  [[ "$DRY" -eq 1 ]] || printf '%s\n' "$BODY" > "$ENVF"
fi

say ""
say "── 汇总：新建 ${N_NEW}，覆盖 ${N_OVER}，跳过 ${N_SKIP} ──"
if [[ "$DRY" -eq 1 ]]; then
  say "这是预演。去掉 --dry-run 才会实际写入。"
else
  [[ "$N_OVER" -gt 0 ]] && say "被覆盖的文件已备份在：$BACKUP"
  say ""
  say "接下来："
  say "  1. 目标项目里跑 bash scripts/check-governance.sh 自检"
  say "  2. 目标项目里跑 npm test 确认看板可用（不会碰真实卡片）"
  say "  3. package.json 加脚本：\"kanban\": \"node tools/kanban/server.mjs\""
  [[ -n "$PREFIX" ]] && say "  4. 卡片 id 前缀是 $PREFIX —— **建第一张卡之前**确认好，之后改会让整块看板失效"
  if [[ -n "$PREFIX" || -n "$PORT" ]]; then
    say "  注意：.env.kanban 很可能被目标项目 .gitignore 的 .env* 规则忽略（个人用无妨；"
    say "        要让配置随仓库走，就把这两个变量写进 package.json 的 kanban 脚本里）"
  fi
  say "  卸载：删掉 ai/、tools/kanban/、.claude/{skills,agents,settings.json}、scripts/check-governance.sh"
fi
