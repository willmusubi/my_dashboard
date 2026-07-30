# 治理看板

以 git 为同步机制的本地 Kanban 小工具，零依赖（只用 Node 内建模块），用来把 [`ai/process/kanban.md`](../../ai/process/kanban.md) 定义的 AI 协作治理流程视觉化：每张任务卡从 Backlog 一路推进到 Done 的过程中，会经过哪些字段、需要哪些 Readiness 检查与人工批准，都在这个看板上一目了然。

**看板分页**（水平车道，Backlog → Blocked → Ready → Implementing → Verify → Done）：

![看板分页截图](docs/board-screenshot.png)

**蓝图分页**（Epic → User Story → Task 的完成度总览，数据来自 [`epics.json`](epics.json)）：

![蓝图分页截图](docs/roadmap-screenshot.png)

## 这是什么、为什么需要它

治理包（Monstrare）要求每个非小型变更都要经过「规格 → 架构 → 任务卡 → 实作 → 验证 → 审查 → 人工验收」的关卡流程。光靠文件很难追踪「现在有哪些任务卡在哪个关卡、卡在谁手上、是不是超过 WIP 上限」，这个看板就是那个流程的即时视觉化 + 轻量数据库：每张卡是一个 git tracked 的 JSON 档，拖曳、勾选、留言都会即时写回文件，靠 `git commit` / `git push` 同步给团队或其他 agent，不需要额外的数据库或账号系统。

原本 1:1 对应 `ai/process/kanban.md` 的 12 个治理阶段，后改为 6 栏的精简流程：`backlog`（Backlog 待办）→ `blocked`（Blocked）→ `ready`（Ready 就绪）→ `implementing`（Implementing 进行中）→ `verify`（Verify 验证中）→ `done`（Done 完成）。`ai/process/kanban.md` 本身未变，仍是完整的 12 阶段治理政策；本工具是该政策的一种简化实作，不要求逐栏对应（`ai/process/kanban.md` 也明讲这一点）。

版面沿用 Mockup 阶段选定的 **Variant A（控制塔）** 风格：水平车道逐一对应每个阶段。另外两个候选版面（阶段分组、审计列表表格）保留在 [`mockups/index.html`](mockups/index.html) 供参考，详见 [`mockup-decision.md`](mockup-decision.md)（该文件与种子数据仍反映旧的 12 阶段命名，仅供追溯选型过程，不代表目前字段）。这些选型纪录只存在 Monstrare 原始 repo；`scripts/install-into-project.sh` 安装到其他项目时不会复制，所以在你的项目里看不到这几个文件是正常的。

页面右上角有两个分页：

- **看板**：6 车道控制塔（上述 Variant A）。
- **蓝图**：功能模块（Epic）→ 用户需求（User Story）→ 任务（Task）的阶层检视，每个 Epic／User Story 都会即时算出完成度（`stage === "done"` 的卡片数 / 总卡片数）。数据来自 [`epics.json`](epics.json)，任务卡透过 `epic` / `userStory` 两个字段对应回去；卡片若指定了 Epic 但没指定对应的 User Story，会落在该 Epic 底下的「（未分类任务）」桶，不会凭空消失。

`epics.json` 与 `cards/` 默认是空的模板状态。开始一个新项目时，走 `ai/skills/project-kickoff.md` 的流程：先确认技术栈，再逐层让人工勾选 Epic、User Story，最后把拆好的 Task 一张张写成 `cards/` 底下的 JSON 档（或透过本机 server 的 `POST /api/cards`）。

## 启动

```bash
node tools/kanban/server.mjs
# 或
npm run kanban
```

浏览器开 <http://127.0.0.1:4420>（server 只 bind 127.0.0.1，port 4420 被占用时会直接报错，不自动换 port；若启动失败，先用 `lsof -i :4420` 找出占用的程序）。

## 怎么操作

- **新增卡片**：点任一车道底部的「+ 新增卡片」，输入标题即可（id 由 server 自动配号）。
- **移动卡片**：直接把卡片拖到别的车道（跨栏即改变 `stage`），同栏内拖曳可调整 `order`。
- **编辑详情**：点卡片本体开启详情面板，可改 owner／risk／agent／Readiness 勾选／Review Gates 勾选／留言等所有字段。
- **看整体进度**：切到右上角「蓝图」分页，依 Epic → User Story 检视完成度（需先在 [`epics.json`](epics.json) 定义 Epic／User Story）。
- 所有操作都是即时写回 `cards/*.json`，没有「存储」按钮；要复原就用 `git checkout` 还原文件再重新整理页面。

## 数据与同步

- 数据来源就是 [`cards/`](cards/) 目录，**一张卡一个 JSON 档**，git tracked。
- 看板上的所有操作（拖曳、勾选 Readiness/Gates、编辑字段、新增、删除、留言）即时写回对应 JSON 档。
- 同步 = git：`git commit` / `git push` 就是存档与分享，多人协作靠 git 合并。
- 也可以直接改 JSON 档（或 `git checkout` 还原），重新整理页面即生效。
- 新卡片的默认 owner 与留言作者取自本机 `git config user.name`（server 启动时读一次，经 `GET /api/config` 提供给前端）；没设定时 owner 留空、留言作者显示「匿名」。

## WIP 上限

`implementing`（Implementing 进行中）上限 3、`verify`（Verify 验证中）上限 5，沿用 `ai/process/kanban.md` 对 Agent Working / Needs Review 的建议值。车道张数超过上限时，车道标头的计数 badge 会变红。上限只在 `index.html` 的 `WIP_CAPS` 里（纯前端视觉化，server 不做强制）。

## Card JSON schema

| 字段 | 型别 | 说明 |
| --- | --- | --- |
| `id` | string | 项目代码前缀 + 流水号（`server.mjs` 的 `ID_PREFIX`，默认是 `TASK-`，请依项目自订），新增时由 server 配号 |
| `title` | string | 标题（非空） |
| `content` | string | 补充说明（纯文字，不支援 markdown） |
| `stage` | string | `backlog` / `blocked` / `ready` / `implementing` / `verify` / `done` 之一 |
| `risk` | string | `low` / `medium` / `high` |
| `owner` | string | 人工负责人 |
| `agent` | string | 执行的 AI agent 名称，留空代表纯人工 |
| `approvalRequired` | boolean | 是否需要人工批准 |
| `createdAt` | string | 建立日期 `YYYY-MM-DD`，新增时由 server 填当天 |
| `epic` | string | 对应 `epics.json` 里某个 Epic 的 `name`，留空代表未分类 |
| `userStory` | string | 对应该 Epic 底下某个 User Story 的 `name`，留空代表未分类 |
| `dependsOn` | array | 前置任务卡片 id 数组（字符串），默认 `[]`；要推进到 `ready`／`implementing`／`verify`／`done` 前，数组里列出的卡片都必须是 `done`，见下方「dependsOn 硬防呆」 |
| `order` | number | 栏内排序，整数、栏内从 1 起 |
| `readiness` | object | 对应 `ai/templates/kanban-card.md` 的 7 项 Readiness，各为 boolean |
| `gates` | object | 6 个 Review Gates（product/ui/architecture/security/test/code_review），各为 boolean |
| `links` | object | 6 种关联文件路径（featureSpec/screenSpec/mockupDecision/taskCard/verificationReport/pr），字符串、可留空 |
| `refs` | array | repo 相对路径（string 数组，唯读显示） |
| `evidence` | object | `{ commands: string[], findings: string[], residual: string }` |
| `comments` | array | 留言 `{ name, time, text }` |

文件以 2 空格缩排 + 结尾换行写入，减少 git diff 噪音。

## API（server.mjs）

| Method | Path | 说明 |
| --- | --- | --- |
| `GET` | `/api/config` | 看板设定（目前只有 `owner`：本机 `git config user.name`，作为新卡 owner 与留言作者的默认值） |
| `GET` | `/api/epics` | 读取 [`epics.json`](epics.json)（Epic → User Story 定义，唯读，没有写入 API，要改就直接编辑文件） |
| `GET` | `/api/cards` | 全部卡片（数组） |
| `PUT` | `/api/cards/:id` | 覆写单卡（body 为完整 card） |
| `PUT` | `/api/cards` | bulk 覆写（body 为数组，拖曳排序用） |
| `POST` | `/api/cards` | 新增卡（server 配下一个流水号） |
| `DELETE` | `/api/cards/:id` | 删卡（删档） |

非法 id / stage / risk 格式一律回 400；PUT/POST body 缺少物件型字段时由 server 补默认值。

### dependsOn 硬防呆

`PUT /api/cards/:id`、`PUT /api/cards`（bulk）、`POST /api/cards` 对 `dependsOn` 一律做以下检查，违反时回 400、不写入文件：

- **格式**：必须是字符串数组，且每个元素要符合 id 格式 `^{ID_PREFIX}-\d{3,}$`。
- **自我依赖**：不可包含卡片自己的 id。
- **存在性**：数组里的每个 id 都必须是目前真的存在的卡片（含这次请求里一起送进来的其他卡）。
- **循环依赖**：以 `dependsOn` 建图做 DFS，侦测到循环（例如 `A -> B -> A`）就拒绝，错误消息会列出循环路径。
- **推进阻挡**：若这次要把 `stage` 改成 `ready`／`implementing`／`verify`／`done` 之一，`dependsOn` 列出的卡片必须全部是 `done`，否则回 400 并列出还没完成的卡片 id 与标题。移动到 `backlog`／`blocked` 不受此限制。

删除卡片不会自动清除其他卡对它的 `dependsOn` 参照；看板 UI 读到参照不存在的 id 时会显示警示，但不会挡任何操作。

## 已知限制（v1）

- 没有账号系统，身分只取自本机 git 设定，无法区分同名用户、也没有权限控管。
- `content` / 留言不支援 markdown 渲染，纯文字显示。
- 没有多人即时协作（没有 WebSocket），要靠重新整理页面看到别人 git pull 后的异动。
- 手机版尚未特别优化（多栏横向卷动在小屏幕会更明显），对应 `screen-spec.md` 的 Mobile 状态尚待处理。
