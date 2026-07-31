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

# 卡片 id 前缀与端口。**必须写成文件而不是环境变量**：hook 由 Claude Code 启动，
# 环境里不会有 KANBAN_*，也不会去 source 任何 .env。只放环境变量的话，分发出去后
# hook 的正则仍是源项目的前缀，自动注入静默失效——看起来一切正常，实际通道断了。
# 而且这个文件**无条件写**：不写的话目标项目会沿用默认 DASH/4430，直接和源项目撞端口。
CFGF="$TARGET/tools/kanban/config.json"
CUR_PREFIX="${PREFIX:-DASH}"
CUR_PORT="${PORT:-4430}"
say ""
if [[ -e "$CFGF" ]]; then
  say "保留目标版本  tools/kanban/config.json（已存在，不覆盖）"
  say "  当前内容：$(tr -d '\n ' < "$CFGF")"
else
  say "写入 tools/kanban/config.json（server / cli / hook 共读这一份）："
  BODY="{
  \"idPrefix\": \"${CUR_PREFIX}\",
  \"port\": ${CUR_PORT}
}"
  printf '%s\n' "$BODY" | sed 's/^/  /'
  [[ "$DRY" -eq 1 ]] || { mkdir -p "$(dirname "$CFGF")"; printf '%s\n' "$BODY" > "$CFGF"; }
  if [[ -z "$PREFIX" ]]; then
    say "  ⚠️  没指定 --prefix，用了默认 DASH。**建第一张卡之前**改掉它，"
    say "      否则和其他项目的卡片 id 混在一起；建卡之后再改会让整块看板失效。"
  fi
  if [[ -z "$PORT" ]]; then
    say "  ⚠️  没指定 --port，用了默认 4430。若该端口已被其他项目的看板占用，"
    say "      server 会直接退出（lsof -i :4430 可查）。"
  fi
fi

say ""
say "── 汇总：新建 ${N_NEW}，覆盖 ${N_OVER}，跳过 ${N_SKIP} ──"
if [[ "$DRY" -eq 1 ]]; then
  say "这是预演。去掉 --dry-run 才会实际写入。"
else
  [[ "$N_OVER" -gt 0 ]] && say "被覆盖的文件已备份在：$BACKUP"
  say ""
  say "接下来（在目标项目里）："
  say "  1. 确认 tools/kanban/config.json 的 idPrefix 是 ${CUR_PREFIX}、port 是 ${CUR_PORT}"
  say "     —— 前缀**建第一张卡之前**定好，之后再改会让整块看板失效"
  say "  2. package.json 加脚本： \"kanban\": \"node tools/kanban/server.mjs\","
  say "                          \"test\": \"bash tools/kanban/test.sh\""
  say "  3. bash scripts/check-governance.sh   自检"
  say "  4. npm test                           确认看板可用（跑在临时目录，不碰真实卡片）"
  say "  5. npm run kanban                     打开 http://127.0.0.1:${CUR_PORT}"
  say "  6. hook 要开一个**新的 Claude Code 会话**才生效（本次会话启动时"
  say "     目标项目还没有 .claude/settings.json，配置 watcher 没在监视它）"
  say ""
  say "  卸载：删掉 ai/、tools/kanban/、.claude/{skills,agents,settings.json}、scripts/check-governance.sh"
fi
