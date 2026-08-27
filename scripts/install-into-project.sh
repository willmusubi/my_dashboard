#!/usr/bin/env bash
# 把这套治理工作流装到另一个项目里。
#
#   scripts/install-into-project.sh [选项] [/path/to/project]
#
#   目标省略时用**当前目录**——所以在新项目里 `cd 进去 && govkit` 就装完了。
#   --prefix 省略时从目录名推首字母缩写（medical_tourism → MT），并**停下来等你确认**。
#            前缀建第一张卡之后就改不动了，这种不可逆的值不该由脚本自行拍板。
#   --port   省略时读 distributions.json 挑下一个既没登记过、也没被实际占用的端口。
#   --yes    跳过那次确认（非交互场景用）。
#   --dry-run 只预演，不写任何东西。
#   --no-verify 装完不自动跑自检（默认全新安装会跑 check-governance 与看板测试）。
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
ASSUME_YES=0
NO_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --prefix)  PREFIX="${2:-}"; shift 2 ;;
    --port)    PORT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "未知参数：$1"; exit 1 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

# 目标省略 = 当前目录。下面「拒绝本仓库自己」那道阀仍然管得住在源仓库里手滑直接跑。
[[ -n "$TARGET" ]] || TARGET="$PWD"
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
declare -i N_NEW=0 N_OVER=0 N_SKIP=0 N_KEEP=0

say() { printf '%s\n' "$1"; }
run() { [[ "$DRY" -eq 1 ]] || eval "$1"; }

backup_of() {   # $1 = 目标文件绝对路径
  local rel="${1#"$TARGET"/}"
  run "mkdir -p \"$BACKUP/$(dirname "$rel")\""
  run "cp -R \"$1\" \"$BACKUP/$rel\""
}

# kit-owned：每次安装都刷新到最新版；覆盖前一定备份。
# $2 = "quiet" 时不打印「相同」那一行（目录逐文件刷新时用，否则输出会淹没有用信息）
refresh_file() {   # $1 = 相对路径（文件）
  local from="$SRC/$1" to="$TARGET/$1"
  if [[ -e "$to" ]]; then
    if cmp -s "$from" "$to"; then
      N_SKIP+=1
      [[ "${2:-}" == "quiet" ]] || say "  相同，跳过    $1"
      return 0
    fi
    backup_of "$to"
    if [[ -L "$to" ]]; then
      # 目标是符号链接：必须先删链接本身，否则 cp 会**跟着它写穿到项目外面**
      # （实测能改掉 ~/ 下的文件）。老版本整目录 rm -rf 顺带解决了这个问题，
      # 改成逐文件合并后就漏了——外层那道「拒绝 .claude 是符号链接」的安全阀
      # 只管到目录，管不到 kit 目录里面的单个文件。
      say "  覆盖（原为符号链接 → $(readlink "$to")，已备份并改为实体文件）$1"
    else
      say "  覆盖（已备份）$1"
    fi
    N_OVER+=1
  else
    say "  新建          $1"; N_NEW+=1
  fi
  run "mkdir -p \"$(dirname "$to")\""
  run "rm -f \"$to\""          # 只删这一个 kit 文件，不碰目录里其他东西
  run "cp \"$from\" \"$to\""
}

# 目录**逐文件合并**，绝不整目录 rm -rf 再拷。
# 原因：项目会往 kit 目录里加自己的东西（实测 three_kingdoms_traveler 在
# .claude/skills、ai/process、ai/templates、ai/skills 下各有自有文件）。
# 整目录替换会把它们从工作树里静默删掉——备份救得回来，但没人会去看备份。
refresh() {     # $1 = 相对路径，文件或目录
  local from="$SRC/$1" to="$TARGET/$1"
  [[ -e "$from" ]] || return 0
  if [[ -f "$from" ]]; then refresh_file "$1"; return 0; fi

  local b_new=$N_NEW b_over=$N_OVER b_skip=$N_SKIP b_keep=$N_KEEP
  local f rel t trel
  while IFS= read -r f; do
    rel="${f#"$SRC"/}"
    refresh_file "$rel" quiet
  done < <(find "$from" -type f ! -name '.DS_Store' | sort)

  # kit 里没有的，原样留下并且**说出来**——静默保留和静默删除一样糟
  if [[ -d "$to" ]]; then
    while IFS= read -r t; do
      trel="${t#"$TARGET"/}"
      if [[ ! -e "$SRC/$trel" ]]; then
        say "  保留项目自有  $trel"; N_KEEP+=1
      fi
    done < <(find "$to" -type f ! -name '.DS_Store' | sort)
  fi

  say "  $1/  新建 $((N_NEW-b_new))，覆盖 $((N_OVER-b_over))，相同 $((N_SKIP-b_skip))，保留项目自有 $((N_KEEP-b_keep))"
}

# project-owned：目标已有就永不碰。
#
# 这份名单里其实混着两类东西，需要的行为相反——分清楚才不会犯下面两种相反的错：
#
#   ① 内容是 kit 的，项目可能在上面追加
#      （CLAUDE.md / AGENTS.md / .claude/settings.json）
#      kit 这边有真内容要给。不覆盖是对的（人可能加了自己的规则），但光是不覆盖
#      还不够：kit 更新了规则，目标**永远拿不到而且无声无息**。所以要 `keep <p> drift`
#      ——照旧不碰一个字节，但把「kit 有、你没有」的行报出来让人自己判断。
#
#   ② 内容天生属于项目，kit 只该给空骨架或模板
#      （ai/context / ai/artifacts / epics.json / cards/ / config.json）
#      这一类**不能**报漂移——目标的内容跟 kit 的本来就该不一样，报了全是噪音。
#
# 两类混为一谈的后果实测过：epics.json 属②却被当①（复制了分发源的 4 个 Epic 过去），
# AGENTS.md 属①却被当②（碰都不碰也不报告，DASH-031 加的规则就这么丢了）。
keep() {        # $1 = 相对路径；$2 = "drift" 时对已存在的文件报告 kit 版多出来的行
  local from="$SRC/$1" to="$TARGET/$1"
  [[ -e "$from" ]] || return 0
  if [[ -e "$to" ]]; then
    say "  保留目标版本  $1"; N_SKIP+=1
    [[ "${2:-}" == "drift" ]] && report_drift "$1"
    return 0
  fi
  say "  新建          $1"; N_NEW+=1
  run "mkdir -p \"$(dirname "$to")\""
  run "cp -R \"$from\" \"$to\""
}

# 报告「kit 版有、目标版没有」的行。**只读，不改任何东西。**
# 只报这一个方向：目标自己加进去的行是它的权利，不是漂移，报出来只会淹没真信号。
report_drift() {  # $1 = 相对路径（文件）
  local from="$SRC/$1" to="$TARGET/$1"
  [[ -f "$from" && -f "$to" ]] || return 0
  cmp -s "$from" "$to" && return 0

  # diff A B：`>` 是「只在 B 里有」。这里 B 是 kit 版，所以 `>` 就是目标缺的那些行。
  local missing n
  missing="$(diff "$to" "$from" | sed -n 's/^> //p' | sed '/^[[:space:]]*$/d')"
  n="$(printf '%s\n' "$missing" | grep -c . || true)"
  [[ "$n" -gt 0 ]] || return 0

  say "     ⚠️  kit 版有 ${n} 行是目标版没有的——**不会自动合并，要不要采用由你决定**："
  if [[ "$n" -le 8 ]]; then
    printf '%s\n' "$missing" | sed 's/^/          /'
  else
    printf '%s\n' "$missing" | head -6 | sed 's/^/          /'
    say "          …还有 $((n - 6)) 行"
  fi
  say "     完整差异：diff \"$to\" \"$from\""
  say "     注：目标可能是**刻意**改写过的（例如把 npm test 改成 kanban:test），照抄前先看清楚。"
}

derive_prefix() {   # $1 = 目录名 → 首字母缩写。推不出来时输出空串。
  python3 - "$1" <<'PY'
import re, sys
words = [w for w in re.split(r"[^A-Za-z0-9]+", sys.argv[1]) if w]
parts = []
for w in words:                       # 再拆 camelCase：myDashboard 也要能拆成 my + Dashboard
    parts += [p for p in re.split(r"(?<=[a-z0-9])(?=[A-Z])", w) if p]
if not parts:
    print(""); raise SystemExit
out = parts[0][:3].upper() if len(parts) == 1 else "".join(p[0] for p in parts).upper()[:5]
out = re.sub(r"[^A-Z0-9]", "", out)
while out and not out[0].isalpha():   # 必须字母开头，否则 id 里的数字段会和卡号连在一起有歧义
    out = out[1:]
print(out)
PY
}

taken_prefixes() {  # 已被别的项目（含分发源自己）占用的前缀，一行一个
  python3 - "$SRC/distributions.json" "$SRC/tools/kanban/config.json" "$TARGET" <<'PY'
import json, sys
reg, own, target = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
try:
    for r in json.load(open(reg)).get("distributions", []):
        if r.get("path") != target and r.get("prefix"):
            out.append(r["prefix"])
except Exception:
    pass
try:
    p = json.load(open(own)).get("idPrefix")
    if p: out.append(p)
except Exception:
    pass
for p in sorted(set(out)): print(p)
PY
}

port_free() {       # $1 = 端口号；能 bind 上就算空闲
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
}

pick_port() {       # 既没在 distributions.json 登记过、也没被实际占用的最小端口
  python3 - "$SRC/distributions.json" "$SRC/tools/kanban/config.json" "$TARGET" <<'PY'
import json, socket, sys
reg, own, target = sys.argv[1], sys.argv[2], sys.argv[3]
used = set()
try:
    for r in json.load(open(reg)).get("distributions", []):
        if r.get("path") != target and isinstance(r.get("port"), int):
            used.add(r["port"])
except Exception:
    pass
try:
    p = json.load(open(own)).get("port")
    if isinstance(p, int): used.add(p)
except Exception:
    pass

def free(p):
    s = socket.socket()
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", p)); return True
    except OSError:
        return False
    finally:
        s.close()

for p in range(4430, 4600):
    if p not in used and free(p):
        print(p); raise SystemExit
print("")
PY
}

# ── 前缀与端口：在**动任何文件之前**定好 ──
# 顺序是刻意的。确认提示要是出现在 63 个文件拷完之后，人一旦 Ctrl-C 就留下一个
# 装了一半的项目——而这个脚本没有卸载命令。
CFGF="$TARGET/tools/kanban/config.json"
CFG_EXISTS=0; [[ -e "$CFGF" ]] && CFG_EXISTS=1
PREFIX_DERIVED=0
PREFIX_NOTE=""; PORT_NOTE=""

if [[ "$CFG_EXISTS" -eq 1 ]]; then
  # 重装 / upgrade-all 的情形。config.json 是 project-owned，本来就不会被覆盖，
  # 这时既不推导也不提示——批量升级不能被一个交互式提问卡住。
  # 路径走 argv，不要插进 python 源码字符串——目录名里一个单引号就能把它拆了
  CUR_PREFIX="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("idPrefix",""))' "$CFGF" 2>/dev/null)"
  CUR_PORT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("port",""))' "$CFGF" 2>/dev/null)"
  PREFIX_NOTE="目标已有 config.json，沿用"
  PORT_NOTE="目标已有 config.json，沿用"
else
  if [[ -n "$PREFIX" ]]; then
    CUR_PREFIX="$PREFIX"; PREFIX_NOTE="--prefix 指定"
  else
    CUR_PREFIX="$(derive_prefix "$(basename "$TARGET")")"
    PREFIX_DERIVED=1
    PREFIX_NOTE="从目录名 $(basename "$TARGET") 推导"
    [[ -n "$CUR_PREFIX" ]] || {
      echo "从目录名「$(basename "$TARGET")」推不出可用的前缀（要求字母开头）。"
      echo "请显式指定：--prefix XXX"; exit 1; }
  fi

  [[ "$CUR_PREFIX" =~ ^[A-Z][A-Z0-9]{0,5}$ ]] || {
    echo "前缀「${CUR_PREFIX}」不合法：要求大写字母开头、只含大写字母与数字、最多 6 位。"; exit 1; }

  if taken_prefixes | grep -qx "$CUR_PREFIX"; then
    if [[ "$PREFIX_DERIVED" -eq 1 ]]; then
      # 推导撞车必须硬停：静默换一个名字，等于脚本替人做了不可逆决定。
      echo "推导出的前缀「${CUR_PREFIX}」已被占用："
      taken_prefixes | sed 's/^/  /'
      echo "卡号前缀撞车会让两个项目的卡片 id 混在一起。请显式指定：--prefix XXX"
      exit 1
    fi
    PREFIX_NOTE="$PREFIX_NOTE ⚠️ 该前缀已被其他项目占用"
  fi

  if [[ -n "$PORT" ]]; then
    CUR_PORT="$PORT"; PORT_NOTE="--port 指定"
    port_free "$CUR_PORT" || PORT_NOTE="$PORT_NOTE ⚠️ 该端口当前已被占用，server 会起不来"
  else
    CUR_PORT="$(pick_port)"
    PORT_NOTE="自动选取，避开已登记与监听中的端口"
    [[ -n "$CUR_PORT" ]] || { echo "4430-4599 之间找不到空闲端口。请显式指定：--port NNNN"; exit 1; }
  fi
fi

say "源：    $SRC"
say "目标：  $TARGET"
[[ "$DRY" -eq 1 ]] && say "模式：  预演（不会写任何东西）" || say "模式：  实际安装，覆盖前备份到 $BACKUP"
say "前缀：  ${CUR_PREFIX}（${PREFIX_NOTE}）"
say "端口：  ${CUR_PORT}（${PORT_NOTE}）"
say ""

# 只在前缀是**推导**出来的时候停下来确认。显式传了 --prefix 就是人已经决定过了；
# config.json 已存在就更不用问。这样 upgrade-all.sh 与既有测试都不会被卡住。
if [[ "$PREFIX_DERIVED" -eq 1 && "$ASSUME_YES" -eq 0 ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo "没有可用的终端，无法确认推导出的前缀。请显式传 --prefix，或加 --yes 接受推导值。"
    exit 1
  fi
  say "⚠️  卡片前缀是**不可逆**的：建第一张卡之后再改，会让整块看板失效。"
  printf '    回车接受 %s，或直接输入要用的前缀（Ctrl-C 放弃）： ' "$CUR_PREFIX"
  # read 的**返回码**必须查。写成 `read ... || ANS=""` 的话，非交互环境下 read 立刻
  # 失败、ANS 为空，代码就当成「人按了回车」——等于静默替人接受了一个不可逆的前缀。
  # 这正是这次确认要防的事。读不到就停，不要猜。
  if ! IFS= read -r ANS < /dev/tty; then
    say ""
    echo "读不到终端输入（非交互环境），无法确认推导出的前缀。"
    echo "请显式传 --prefix XXX，或加 --yes 表示接受推导值 ${CUR_PREFIX}。"
    exit 1
  fi
  ANS="$(printf '%s' "$ANS" | tr -d '[:space:]')"
  if [[ -n "$ANS" ]]; then
    CUR_PREFIX="$(printf '%s' "$ANS" | tr '[:lower:]' '[:upper:]')"
    [[ "$CUR_PREFIX" =~ ^[A-Z][A-Z0-9]{0,5}$ ]] || {
      echo "前缀「${CUR_PREFIX}」不合法：要求大写字母开头、只含大写字母与数字、最多 6 位。"; exit 1; }
    if taken_prefixes | grep -qx "$CUR_PREFIX"; then
      echo "前缀「${CUR_PREFIX}」已被其他项目占用，换一个。"; exit 1
    fi
    say "    改用前缀 ${CUR_PREFIX}"
  fi
  say ""
fi

say "kit-owned（每次刷新到最新）："
for p in \
  ai/process ai/templates ai/checklists ai/skills \
  .claude/skills .claude/agents \
  tools/kanban/server.mjs tools/kanban/card-store.mjs tools/kanban/cli.mjs \
  tools/kanban/index.html tools/kanban/test.sh tools/kanban/test-store.mjs \
  tools/kanban/hooks tools/kanban/README.md \
  .githooks/kanban-cards.sh \
  scripts/check-governance.sh \
  .github/pull_request_template.md .github/ISSUE_TEMPLATE/ai_task.yml
do refresh "$p"; done

say ""
say "project-owned（目标已有就不碰）："
# ① kit 有正本、项目可能追加 → 不覆盖，但报告 kit 版多出来的行
for p in CLAUDE.md AGENTS.md .claude/settings.json .githooks/pre-commit
do keep "$p" drift; done
# ② 内容天生属于项目 → 不覆盖，也不报漂移（内容本来就该不一样）
# 注意 ai/context 与 ai/artifacts 是**模板占位符**（「状态：模板占位符」＋写法说明），
# 所以 cp 过去给的是空表格而不是内容，这才符合上面②的定义。
for p in ai/context ai/artifacts
do keep "$p"; done

# 卡片目录只建骨架，绝不复制本仓库的卡片过去。
if [[ ! -d "$TARGET/tools/kanban/cards" ]]; then
  say "  新建          tools/kanban/cards/（空）"; N_NEW+=1
  run "mkdir -p \"$TARGET/tools/kanban/cards\" && touch \"$TARGET/tools/kanban/cards/.gitkeep\""
else
  say "  保留目标版本  tools/kanban/cards/（$(ls "$TARGET"/tools/kanban/cards/*.json 2>/dev/null | wc -l | tr -d ' ') 张卡）"; N_SKIP+=1
fi

# epics.json 同理：它是那个项目的 Epic 结构，和 cards/ 一样属于②，kit 不该有内容。
# 早先它在 keep 名单里，于是 cp 过去的是**分发源自己的 Epic**——real_rpg 装完就带着
# my_dashboard 的「看板可用性 / 人机决策通道 / 简体化与文档 / 分发能力」四个 Epic，
# 蓝图分页和完成度全是错的。侥幸没留下后果，只因为它 kickoff 时整个替换掉了；
# project-kickoff 步骤 3 只说「写进 epics[]」，agent 用追加的话污染就永久留下。
EPICSF="$TARGET/tools/kanban/epics.json"
if [[ ! -e "$EPICSF" ]]; then
  say "  新建          tools/kanban/epics.json（空）"; N_NEW+=1
  run "mkdir -p \"$(dirname "$EPICSF")\" && printf '%s\\n' '{ \"epics\": [] }' > \"$EPICSF\""
else
  say "  保留目标版本  tools/kanban/epics.json（$(python3 -c "
import json,sys
try: print(len(json.load(open(sys.argv[1])).get('epics', [])))
except Exception: print('?')
" "$EPICSF" 2>/dev/null) 个 Epic）"; N_SKIP+=1
fi

# 卡片 id 前缀与端口。**必须写成文件而不是环境变量**：hook 由 Claude Code 启动，
# 环境里不会有 KANBAN_*，也不会去 source 任何 .env。只放环境变量的话，分发出去后
# hook 的正则仍是源项目的前缀，自动注入静默失效——看起来一切正常，实际通道断了。
# 而且这个文件**无条件写**：不写的话目标项目会沿用默认 DASH/4430，直接和源项目撞端口。
say ""
if [[ "$CFG_EXISTS" -eq 1 ]]; then
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
fi

# ── git hooks：坏卡片进不了 commit ──
# core.hooksPath 存在 .git/config 里，git 不追踪，所以 cp 完文件还得接这一下，
# 否则 .githooks/pre-commit 只是一个躺着的文件，一次都不会被执行。
#
# **已经被占用就不碰。** 目标可能在用 husky / lefthook，覆盖掉等于把人家整套
# 提交前检查静默换掉——比不装严重得多。
say ""
# 必须是**仓库根**才接。装进 monorepo 的某个子目录时，rev-parse 给的是外层仓库，
# 在那里设 core.hooksPath=.githooks 会指向 <monorepo>/.githooks —— 一个没有这个
# 钩子的目录，等于把外层仓库原有的钩子也一起停掉。
#
# 用 --show-prefix（在根目录时输出空串）判断，不拿 --show-toplevel 和 $TARGET
# 比字符串：macOS 的 /var、/tmp 都是符号链接，git 给的是解析后的 /private/var，
# `cd && pwd` 给的是 /var，两边永远对不上——实测就是这么错的。
IS_REPO=0; AT_ROOT=0
if GIT_PREFIX="$(git -C "$TARGET" rev-parse --show-prefix 2>/dev/null)"; then
  IS_REPO=1
  [[ -z "$GIT_PREFIX" ]] && AT_ROOT=1
fi
CUR_HOOKS="$(git -C "$TARGET" config --local core.hooksPath 2>/dev/null || true)"
# 项目自有的 pre-commit 没被覆盖是对的，但光是不覆盖还不够：它没调用 kit 的校验时，
# kanban-cards.sh 只是一个躺着的文件，一次都不会被执行——「装了但不生效」正是这张卡要消灭的。
PCF="$TARGET/.githooks/pre-commit"
if [[ -f "$PCF" ]] && ! grep -q "kanban-cards.sh" "$PCF"; then
  say "  ⚠️  目标的 .githooks/pre-commit 是项目自有的（没被覆盖，这是对的），但它**没有调用**卡片校验。"
  say "     把这一行加进去，否则 kanban-cards.sh 装了也不会跑："
  say "       bash \"\$(git rev-parse --show-toplevel)/.githooks/kanban-cards.sh\" || exit 1"
fi
if [[ "$IS_REPO" -eq 0 ]]; then
  say "git hooks：跳过——目标不是 git 仓库（.githooks/pre-commit 已装好，之后 git init 了再跑一次这个脚本）"
elif [[ "$AT_ROOT" -eq 0 ]]; then
  say "  ⚠️  目标是某个 git 仓库里的子目录（${GIT_PREFIX%/}）——**不动 core.hooksPath**（设了会指到外层仓库去）。"
  say "     要启用卡片校验，在外层仓库的钩子里加一行：bash \"${TARGET}/.githooks/pre-commit\""
elif [[ -z "$CUR_HOOKS" ]]; then
  say "git hooks：core.hooksPath → .githooks（坏卡片进不了 commit）"
  [[ "$DRY" -eq 1 ]] || git -C "$TARGET" config --local core.hooksPath .githooks
elif [[ "$CUR_HOOKS" == ".githooks" ]]; then
  say "git hooks：已指向 .githooks，不动"
else
  say "  ⚠️  core.hooksPath 已经是「${CUR_HOOKS}」（husky？lefthook？）——**不覆盖**。"
  say "     .githooks/pre-commit 已装好但不会被执行。要启用，把它接进你现有的钩子，或："
  say "     git config core.hooksPath .githooks   # 会停用 ${CUR_HOOKS} 那一套，想清楚再跑"
fi

# ── package.json：把看板脚本挂上去 ──
# 只加不改：目标已有的 test 脚本绝不覆盖（实测 three_kingdoms_traveler 的 test 是
# `vitest run`，覆盖掉就毁了它真正的测试命令），这时看板测试挂到 kanban:test。
say ""
PKGF="$TARGET/package.json"
if [[ ! -f "$PKGF" ]]; then
  say "package.json 不存在 —— 跳过。手动跑看板：node tools/kanban/server.mjs"
else
  say "package.json（只加不改，已有的脚本一律保留）："
  # 备份交给 python 在**确定要写**的那一刻做。无条件先备份的话，批量升级时
  # 每个项目都会多出一个只装着没改动的 package.json 的备份目录。
  python3 - "$PKGF" "$DRY" "$BACKUP/package.json" <<'PY'
import json, os, re, shutil, sys
path, dry, backup = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
raw = open(path).read()
try:
    data = json.loads(raw)
except Exception as e:
    print("  package.json 解析失败，未改动：%s" % e); raise SystemExit
if not isinstance(data, dict):
    print("  package.json 顶层不是 object，未改动"); raise SystemExit

# 沿用原文件的缩进，别把人家的 package.json 整个重排出一坨 git 噪音
m = re.search(r'\n(\s+)"', raw)
indent = m.group(1) if m else "  "
indent = "\t" if indent.startswith("\t") else len(indent.replace("\t", "  "))

scripts = data.setdefault("scripts", {})
if not isinstance(scripts, dict):
    print("  package.json 的 scripts 不是 object，未改动"); raise SystemExit
changed = []
KANBAN = "node tools/kanban/server.mjs"
TESTCMD = "bash tools/kanban/test.sh"

if scripts.get("kanban") == KANBAN:
    print('  已有        "kanban"')
elif "kanban" in scripts:
    print('  保留目标版本 "kanban": %s（与 kit 的不同，不覆盖）' % json.dumps(scripts["kanban"], ensure_ascii=False))
else:
    scripts["kanban"] = KANBAN; changed.append("kanban")

if "test" not in scripts:
    key = "test"
elif scripts["test"] == TESTCMD:
    key = None; print('  已有        "test"')
else:
    key = "kanban:test"
    print('  保留目标版本 "test": %s —— 看板测试改挂 kanban:test' % json.dumps(scripts["test"], ensure_ascii=False))
if key:
    if scripts.get(key) == TESTCMD:
        print('  已有        "%s"' % key)
    elif key in scripts:
        print('  保留目标版本 "%s": %s（不覆盖）' % (key, json.dumps(scripts[key], ensure_ascii=False)))
    else:
        scripts[key] = TESTCMD; changed.append(key)

for k in changed:
    print('  %s      "%s": "%s"' % ("将新增" if dry else "新增  ", k, scripts[k]))
if not changed:
    print("  package.json 无需改动")
    raise SystemExit(0)
if not dry:
    os.makedirs(os.path.dirname(backup), exist_ok=True)
    shutil.copy2(path, backup)
    out = json.dumps(data, ensure_ascii=False, indent=indent)
    open(path, "w").write(out + ("\n" if raw.endswith("\n") else ""))
raise SystemExit(10)          # 10 = 确实改了，让外层把它算进「覆盖」并提示备份位置
PY
  [[ "$?" -eq 10 ]] && N_OVER+=1
fi

say ""
say "── 汇总：新建 ${N_NEW}，覆盖 ${N_OVER}，相同 ${N_SKIP}，保留项目自有 ${N_KEEP} ──"
if [[ "$DRY" -eq 1 ]]; then
  say "这是预演。去掉 --dry-run 才会实际写入。"
else
  [[ "$N_OVER" -gt 0 ]] && say "被覆盖的文件已备份在：$BACKUP"

  # 登记到分发清单，供 scripts/upgrade-all.sh 用。装完不留痕迹的话，过几周
  # 这边修了 bug 想推过去，就得自己回忆装过哪些项目了。
  python3 - "$SRC/distributions.json" "$TARGET" "$CFGF" <<'PY'
import json, sys, datetime
reg_path, target, cfg_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(cfg_path))          # 以目标实际生效的配置为准，
except Exception:                            # 而不是命令行参数（config.json 可能是目标已有的）
    cfg = {}
today = datetime.date.today().isoformat()
try:
    reg = json.load(open(reg_path))
except Exception:
    reg = {"distributions": []}
rows = reg.get("distributions", [])
for r in rows:
    if r.get("path") == target:
        r["lastUpgradedAt"] = today
        r["prefix"] = cfg.get("idPrefix", r.get("prefix"))
        r["port"] = cfg.get("port", r.get("port"))
        break
else:
    rows.append({"path": target, "prefix": cfg.get("idPrefix"), "port": cfg.get("port"),
                 "installedAt": today, "lastUpgradedAt": today})
reg["distributions"] = sorted(rows, key=lambda r: r["path"])
with open(reg_path, "w") as f:
    json.dump(reg, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("  已登记到 distributions.json（共 %d 个项目）" % len(rows))
PY

  # 看板测试挂在哪个 key 上，取决于目标原本有没有自己的 test 脚本
  # （实测 tkt 的是 vitest run，被覆盖掉就毁了它真正的测试命令）。
  # 读**改完之后**的实际值，不要凭安装前的状态猜。
  KTEST="$(python3 -c '
import json, sys
try: s = json.load(open(sys.argv[1])).get("scripts", {})
except Exception: s = {}
print("kanban:test" if s.get("kanban:test") else ("test" if s.get("test") else ""))
' "$PKGF" 2>/dev/null)"
  [[ -n "$KTEST" ]] && KTESTCMD="npm run $KTEST" || KTESTCMD="bash tools/kanban/test.sh"
  [[ -f "$PKGF" ]]  && KRUNCMD="npm run kanban"  || KRUNCMD="node tools/kanban/server.mjs"

  # ── 自检：能自动跑的就别留给人手动跑 ──
  # 只在**全新安装**时跑。重装 / upgrade-all 的路径上 kit 刚在分发源跑过完整测试，
  # 每个项目再跑十几秒没有新信息，只会让批量升级变慢。
  VERIFY_FAILED=0
  say ""
  if [[ "$NO_VERIFY" -eq 1 ]]; then
    say "自检：已用 --no-verify 跳过。想跑：bash scripts/check-governance.sh && ${KTESTCMD}"
  elif [[ "$CFG_EXISTS" -eq 1 ]]; then
    say "自检：跳过——目标不是全新安装，kit 已在分发源验证过。想跑：${KTESTCMD}"
  else
    say "自检（在目标项目里跑，看板测试用临时目录，不碰真实卡片）："
    verify_step() {   # $1 = 显示名，其余 = 要跑的命令
      local label="$1"; shift
      local out rc
      out="$(cd "$TARGET" && "$@" 2>&1)"; rc=$?
      if [[ "$rc" -eq 0 ]]; then
        say "  ✅ $label"
        printf '%s\n' "$out" | grep -E '^通过|passed' | sed 's/^/       /' \
          || printf '%s\n' "$out" | tail -1 | sed 's/^/       /'
      else
        say "  ❌ ${label}（退出码 ${rc}）"
        printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
        VERIFY_FAILED=1
      fi
    }
    verify_step "scripts/check-governance.sh" bash scripts/check-governance.sh
    verify_step "tools/kanban/test.sh"        bash tools/kanban/test.sh
  fi

  say ""
  say "接下来（在目标项目里）——只剩这 3 步，都是脚本代劳不了的："
  say "  1. ${KRUNCMD}   →  http://127.0.0.1:${CUR_PORT}"
  say "     （长驻进程，所以不替你起——起了你也不知道它在跑）"
  say "  2. 开一个**新的** Claude Code 会话，hook 才生效（本次会话启动时"
  say "     目标项目还没有 .claude/settings.json，配置 watcher 没在监视它）"
  say "  3. 在那个会话里跑 project-kickoff，把想法拆成 Epic → Story → Task 建进看板"
  say ""
  say "  看板配置：idPrefix=${CUR_PREFIX}、port=${CUR_PORT}"
  say "  —— 前缀已定案，**建第一张卡之后不要再改**，改了整块看板会失效。"
  say ""
  say "  这些文件会随 git push 一起走，但不会进构建产物（dist/）。"
  say "  要开源该项目的话，先读 README「装了之后，发布会带上这些文件吗」一节。"
  say "  本仓库有改进后，用 scripts/upgrade-all.sh 一次推给所有装过的项目。"
  say ""
  say "  卸载：删掉 ai/、tools/kanban/、.claude/{skills,agents,settings.json}、scripts/check-governance.sh"

  # 自检没过要以非 0 退出，否则淹在 40 行收尾提示里没人看得见。
  # 措辞必须把「文件装好了」和「自检没过」分开——不然人会以为安装本身失败了，
  # 跑去重装，而重装因为 config.json 已存在反倒会跳过自检，问题就此隐形。
  if [[ "$VERIFY_FAILED" -eq 1 ]]; then
    say ""
    say "⚠️  文件已经装好了（上面的汇总是真的），但**自检没过**——原因在上面 ❌ 那几行。"
    say "    先修掉再开工：装一套自己都跑不过的治理流程，比不装更糟。"
    say "    修完重跑自检用 ${KTESTCMD}，不要重装——重装会因为 config.json 已存在而跳过自检。"
    exit 1
  fi
fi
