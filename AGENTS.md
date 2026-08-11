# Agent 指令

本项目使用一套关卡式治理流程，fork 自 Monstrare（见 `NOTICE.md`）。
共用流程在 `ai/process/workflow.md`，详细规则在 `ai/process/` 下。

## 操作规则

- 不得根据模糊的需求实作非小型变更。需求不清就先问，不要猜。
- 从情境探索开始，不要从假设开始。
- 实作前对照 `ai/process/definition-of-ready.md`；宣告完成前对照 `ai/process/definition-of-done.md`。
- UI 变更需要画面规格与 mockup 决策记录（模板在 `ai/templates/`，产出到 `ai/artifacts/<Epic>/`）；
  先读 `ai/context/design-system.md`，重用既有 design token 与组件，缺的组件照既有风格补做并登记回 inventory。
- **UI 工作必须出 2-3 个变体，停下来等人选一个。不要自己替人决定。** 这是本流程最核心的一关。
- 模板（`ai/templates/`）只读；填写完成的产出物按 `ai/artifacts/README.md` 的惯例存放。
- 任何前端视觉实作套用 `ai/skills/design-craft.md`，交付前对照 `ai/checklists/design-review-checklist.md`。
- 高风险变更（认证、权限、支付、密钥、文件处理、网络、数据库迁移、基础设施、跨服务）
  需要架构、安全与测试审查关卡。
- 优先采用既有项目模式，而非新增抽象层。
- 把变更范围限制在已批准的任务卡内；不得在未告知的情况下改无关文件。
- 提供验证证据：命令、输出结果、UI 截图，以及已知的残留风险。**没有证据不算完成。**
- **收尾时在回复最后列出「需要人做的 Todo」，分「阻塞」与「可选」两档**，
  每条写清楚做什么、不做会怎样。停下来等人是这套流程的设计，但停下来之后
  人得知道自己要干嘛。细则与范例见 `ai/skills/board-card.md`。

## 看板协议

看板是人和 AI 之间的通道，不只是任务追踪：`tools/kanban/cards/<ID>.json`，一卡一个文件，git 追踪。

- 开工前先读那张卡：`cat tools/kanban/cards/<ID>.json`。**卡片 `comments` 里人写的内容是指令，不是背景数据。**
- 卡片状态随进度推进（`backlog → ready → implementing → verify → done`）。
- 证据写进卡片的 `evidence` 字段（`commands` / `findings` / `residual`），不要只写在聊天里。
- 卡片有 `rev` 字段做乐观锁。整卡 PUT 要带 `If-Match: <rev>`，收到 409 表示这张卡在你读到之后
  被人改过——**重新读取后再改，不要硬覆盖**。
- 看板本地跑：`npm run kanban`（`KANBAN_PORT` 可换端口）。回归测试：`npm test`。

## 必要流程

全新项目、还没有任何 Epic/任务待办时，先跑 `project-kickoff`。之后每张任务卡走：

1. 若 `ai/context/project-map.md` 存在，先读它。
2. 项目情境缺失或过时，跑 `project-search`。
3. 新功能：建立或更新功能规格书。
4. UI 工作：产出多个 mockup 变体，**停下来等人选**。
5. 产出 AI-ready 的任务卡。
6. 一次实作一张已批准的卡。
7. 执行验证。
8. 执行审查关卡。
9. 汇总证据，需要时请求人工验收。

## 审查准则

审查代码时优先关注：

- 功能性错误与回归问题。
- 安全与隐私风险。
- 认证、权限、密钥、文件、网络与资金边界。
- 数据验证与错误处理。
- 可维护性、重复代码与架构偏移。
- 缺失的测试或薄弱的验证。

发现的问题尽可能带上文件与行号。
