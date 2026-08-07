# 治理看板 · my_dashboard

一个本地的、零依赖的 AI 协作治理看板。

**要解决的问题**：AI agent 从模糊需求就开始写代码、产出大而不可审查的 diff、没有证据就宣称"完成了"。

**核心机制**：看板不只是任务追踪，而是**人和 AI 之间的决策通道**——你在卡片上写下的决策，agent 下一次接手这张卡时一定会读到，并且必须在看板上留下"已确认"的痕迹。

## 跑起来

```bash
npm run kanban                     # → http://127.0.0.1:4430
KANBAN_PORT=4430 npm run kanban    # 换个端口
```

零依赖，无需 `npm install`。数据是 `tools/kanban/cards/*.json`，一卡一个文件，git 追踪。
没有保存按钮，改动即时落盘；要撤销就用 `git checkout`。

回归测试：`npm test`（90 项断言，跑在临时目录，**不会碰真实卡片**）
治理自检：`npm run check`

## 人 ↔ AI 决策通道

这是本 fork 相对上游最大的增量。上游有 `comments` 字段，但没有任何机制让 agent
读到它——`ai/process/`、`ai/skills/`、`AGENTS.md`、`CLAUDE.md` 里「留言/comment」
出现 **0 次**。

**你这边**：打开卡片，选【决策】写下你的决定。它会显示「待处理」，卡面出现
`💬 N 待处理`。agent 确认后变成「**已确认 · 14:02**」——你能直接看到它有没有读到。
改主意就点「取代这条决策」，旧的变「已取代」并划线（保留审计轨迹），
并且**结构性地不再进入 agent 的 context**。

**agent 那边**（`tools/kanban/cli.mjs`，8 个子命令）：

```bash
node tools/kanban/cli.mjs show <ID>          # 读卡，含生效中的人工决策
node tools/kanban/cli.mjs ack  <ID> <留言id>  # 确认，在看板上留下时间戳
node tools/kanban/cli.mjs comment <ID> --kind progress|evidence --text "..."
node tools/kanban/cli.mjs ask  <ID> --text "..."   # 提问后停下来等人
node tools/kanban/cli.mjs open               # 哪些卡在等人 / 等 agent
```

server 关着也能用（自动回退到直接读写文件）。

**三条载荷规则**：

1. **只有人能下决策。** agent 写 `kind=decision` 会被 403 拒绝——它只能提问然后停下。
   通道在信息上双向，在权威上单向。
2. **留言文本不可变**，只有状态可改。修正靠发新留言 + `supersedes`。
3. **不靠 agent 自觉**：`.claude/settings.json` 里的 UserPromptSubmit hook 会在你
   提到卡号时自动把生效中的决策注入 context。⚠️ 这是本项目唯一的可执行配置，
   每次 prompt 以你的完整权限跑一个本地脚本；它只 import `node:fs`/`node:path`，
   任何异常静默退出绝不挡你的输入，**删掉那个文件即停用**。

hook 只保证「送达」，不保证「遵守」。遵守靠它必须 `ack` 留下痕迹——于是不遵守
在看板上一眼可见。协议细节见 `ai/skills/board-card.md`。

## 分发到其他项目

新项目里一条命令：

```bash
cd /path/to/新项目
govkit --dry-run     # 先预演
govkit               # 实际装
```

`govkit` 是 `~/.zshrc` 里的一个函数，转发给下面这个脚本。没装函数就直接跑，效果一样：

```bash
scripts/install-into-project.sh [--dry-run] [--yes] [--no-verify] [--prefix TKT] [--port 4431] [/path/to/project]
```

**目标省略时用当前目录**，前缀和端口也都可以不传：

- **前缀**从目录名推首字母缩写（`medical_tourism` → `MT`、`three_kingdoms_traveler` → `TKT`），
  然后**停下来等你按回车确认**——回车接受，或直接输入别的。前缀建第一张卡之后就改不动了，
  这种不可逆的值不该由脚本自行拍板。推出来的前缀撞上已有项目就报错退出，不会静默换一个；
  没有终端可读时也拒绝执行，加 `--yes` 才算你认可推导值。
- **端口**从 `distributions.json` 挑下一个既没登记过、也没被实际监听的号。
- **`package.json`** 自动补 `kanban` 启动脚本；目标已有 `test` 脚本时看板测试挂到
  `kanban:test`，**绝不覆盖**（TKT 的 `test` 是 `vitest run`，覆盖掉就毁了它真正的测试命令）。
  没有 `package.json` 就跳过，不凭空创建。

**装完自动跑自检**（`check-governance.sh` 与看板测试，逐条报结果）。只在全新安装时跑：
重装和 `upgrade-all.sh` 会跳过，否则批量升级白等；`--no-verify` 可以关掉。自检没过时
脚本响亮报错并以非 0 退出，且会讲清「文件已经装好了，是自检没过」——这两件事必须分开，
否则人会跑去重装，而重装因为 `config.json` 已存在反倒会跳过自检，问题就此隐形。

于是装完只剩 3 件事要你做，都是脚本代劳不了的：

1. `npm run kanban` —— 长驻进程，不替你起（起了你也不知道它在跑）
2. 开一个**新的** Claude Code 会话，hook 才生效
3. 在那个会话里跑 `project-kickoff`，把想法拆成 Epic → Story → Task 建进看板

kit 文件每次刷新（覆盖前备份到 `.kanban-backup-<时间戳>/`），
而 `CLAUDE.md`、`ai/context/`、`ai/artifacts/`、`epics.json`、`cards/` 属于目标项目，
**存在就永不碰**。会拒绝 `$HOME`、拒绝本仓库自己、拒绝目标 `.claude` 是符号链接
（`cp -R` 会跟随它写进全局 `~/.claude`）。

一份 63 个文件、416K，其中约 332K 各项目完全相同。**每个项目装一份是对的**，
不是将就——卡片是那个项目的审计轨迹要随 git 走，hook 是项目级的
（`.claude/settings.json` 里写的是 `$CLAUDE_PROJECT_DIR/...`），而 clone 下来
就能跑是这套东西的核心属性（上游 README 明确反对
*hidden dependency on skills installed in someone's home directory*）。
共享最多省那 332K，代价是三条全破——不划算。

### 批量升级

安装成功后会往本仓库的 `distributions.json` 登记一条（`--dry-run` 不写）。
这边修了 bug 之后：

```bash
bash scripts/upgrade-all.sh --dry-run   # 逐个预演
bash scripts/upgrade-all.sh             # 实际推过去
```

不传 `--prefix`/`--port`——目标的 `config.json` 是 project-owned，各项目保留自己的
前缀和端口。目录不在了只报告「跳过」并继续，**不删记录**（可能只是外置盘没挂）。

> `distributions.json` 里是本机的绝对路径。本仓库将来若要公开，先看一眼这个文件。

### 装了之后，发布会带上这些文件吗

分两种情况，答案相反：

| 发布方式                          | 会带上吗   | 为什么                                                            |
| --------------------------------- | ---------- | ----------------------------------------------------------------- |
| 构建产物（`dist/`、打包好的 app） | **不会**   | 打包器只收 `src/` 里被 import 的东西，根本不认识 `ai/`、`tools/kanban/` |
| `git push` 到 GitHub              | **会**     | 它们在版本控制里                                                  |
| npm 包                            | 看配置     | 取决于 `package.json` 的 `files` / `.npmignore`；`private: true` 的项目不适用 |

所以「部署到 Vercel 之后访问网站的人看得到我的卡片吗」——**看不到**，部署的是
构建产物。但**仓库要是公开的，clone 的人看得到**。

取舍：私有仓库直接带着，没有任何问题；要开源就先扫一遍卡片（里面可能有还没公开
的计划、对第三方的评价、内部权衡）。

**不要用 `.gitignore` 排除卡片。** 那样它们脱离版本控制——没有历史、没有 diff、
换台机器就没了，等于扔掉这套东西最核心的追溯能力。真要隔离，宁可把卡片放进一个
单独的私有仓库。

### 哪些项目值得装

不是所有项目都该装。判据：

- **装** —— 会长期迭代、要反复跟 AI 协作、将来需要回答「当初为什么这么改」的项目
- **不装** —— 一次性脚本、探索性实验、玩具项目。这套流程的关卡对它们是纯开销

建议**先在 1-2 个项目上完整跑几张卡**，确认这个 ceremony 强度自己受得了，
再往外铺。铺开之后再想减负，每个项目都得改一遍。

## 流程

每个非小型变更走 `ai/process/workflow.md` 定义的这些阶段：

| 阶段                      | 产出                                           | 关卡                            |
| ------------------------- | ---------------------------------------------- | ------------------------------- |
| 0 收件                    | 问题陈述、目标、限制、未知事项                 | 需求模糊 → 进入澄清             |
| 1 情境探索                | 任务专属情境包：文件、模式、风险、验证命令     | —                               |
| 2 澄清                    | 功能规格书、非目标、验收标准                   | **人工批准**                    |
| 3 UI Mockup（涉及界面时） | 画面/状态地图、2-3 个变体、取舍表              | **人工选定变体**                |
| 4 架构规划                | 变更文件、数据/API 契约、回滚计划              | 高风险 → 架构 + 安全 + 测试审查 |
| 5 任务卡                  | 符合 `definition-of-ready.md` 的 AI-ready 卡片 | —                               |
| 6 实作                    | 一次一张已批准的卡，小 diff                    | 范围改变 → 停下询问             |
| 7 验证                    | 测试、typecheck、lint、build、安全扫描、截图   | —                               |
| 8 审查                    | 产品 / UX / 架构 / 安全 / 测试 / code review   | `review-gates.md`               |
| 9 人工验收                | 变更内容、证据、残留风险、后续任务             | **没有证据就不算完成**          |

代理输出本身**永远不等于批准**。

## 目录

| 路径                      | 内容                                                               |
| ------------------------- | ------------------------------------------------------------------ |
| `CLAUDE.md` / `AGENTS.md` | agent 入口与路由规则                                               |
| `ai/process/`             | 流程规则：工作流、就绪定义、完成定义、情境协议、审查关卡、看板政策 |
| `ai/templates/`           | 只读模板母本，**不得覆写**                                         |
| `ai/checklists/`          | 安全、测试、设计审查检查表                                         |
| `ai/context/`             | 本项目的架构地图、设计系统、决策记录                               |
| `ai/artifacts/`           | 填写完成的产出物，一个 Epic 一个目录                               |
| `ai/skills/`              | skill 正本内容；`.claude/skills/` 下是指向它的薄 stub              |
| `.claude/agents/`         | 5 个审查子代理（架构 / 安全 / 测试 / UX / 产品）                   |
| `tools/kanban/`           | 看板本体（`server.mjs` + `index.html`），schema 与 API 见其 README |

自检：`bash scripts/check-governance.sh`（从仓库根目录跑）

## 与上游的关系

fork 自 [Monstrare](https://github.com/pjwang2022/Monstrare)（MIT，见 `NOTICE.md` 与 `LICENSE`）。
上游 remote 保留为 `upstream` 且**禁止 push**，所以随时可以：

```bash
git diff upstream/main      # 看自己改了什么
git log upstream/main..HEAD # 自己的 changelog
git fetch upstream          # 拉上游修复
```

本 fork 相对上游的主要差异：

- 删除 Codex 支持、安装脚本、上游自己的看板设计史
- 修复若干**静默损坏数据**的 bug（悬空依赖锁死车道、ID 复用、order 冲突、坏 JSON 废掉整板、后写覆盖）
- 全文简体化
- 新增**人 ↔ AI 决策通道**：类型化留言（decision/question/note…）+ CLI + Claude Code hook
