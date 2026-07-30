@AGENTS.md

# Claude Code 指令

本文件是 Claude Code 专属的路由层，补充 `AGENTS.md` 定义的作业规则。
保持简短——可复用的工作流程放在 `.claude/skills/`，详细规则放在 `ai/process/`。

## Skill 路由（本项目优先于全局 skill）

本机装有 140+ 个全局 skill，其中不少和本项目的 skill 功能重叠。做以下事情时，
**用本项目的，不要用全局的**：

| 要做的事 | 用这个 | 不要用 |
|---|---|---|
| 全新项目拆 Epic/Story/Task | `project-kickoff` | — |
| 找代码、建情境包 | `project-search` | `investigate` / `systematic-debugging` |
| 需求澄清、写规格书 | `spec-interrogation` | `spec` / `brainstorming` / `writing-plans` |
| UI 方案选型与画面状态 | `ui-mockup-gate` | `design-shotgun` / `design-consultation` |
| UI 视觉质量与设计工艺 | `design-craft` | `frontend-design` / `design-review` |
| 技术规划与任务卡 | `implementation-plan` | `writing-plans` / `executing-plans` |
| 安全性与可维护性审查 | `security-maintainability-review` | `review` / `requesting-code-review` |
| 测试与验证证据 | `test-verification` | `qa` / `verification-before-completion` |

理由：全局 skill 的描述更多也更触发导向，在描述匹配上通常会赢；但它们不认识
本项目的关卡、产出物惯例和看板协议。

## 本项目禁用

- **`ship` / `land-and-deploy` / `autoplan`** —— 这几个 gstack skill 的设计目标是
  快速自动决策（`autoplan` 明写「with auto-decisions」）。那是本项目治理模型的
  精确反面：在这里跑它们会静默绕过全部人工关卡。要发布就手动走 `workflow.md` 的
  Phase 7-9。

## 子代理路由

- 产品面模糊性：`product-planner`
- UI 与互动质量：`ux-reviewer`
- 架构或跨切面变更：`architect`
- 安全性敏感变更：`security-reviewer`
- 测试策略与回归风险：`test-engineer`

## 最重要的一条

**不得把代理输出当成批准。** 人工批准是 `ai/process/review-gates.md` 每一道关卡的
必要条件。代理可以给出判断、证据和建议，但「通过」只能由人说。

同理：卡片上人写的 `comments` 是指令，agent 写的是记录。要推翻人的决策，
先问人，不要自己改。
