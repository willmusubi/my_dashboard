# 工作流程（Workflow）

这套流程把模糊的需求转换成范围有界、可审查、可验证的 AI 工作。

全新项目、还没有 Epic/User Story 待办清单时，先跑 `project-kickoff` skill。
它会把项目拆成 Epic → User Story → Task，建进 `tools/kanban/epics.json` 与
`tools/kanban/cards/`。之后每张任务卡各自走一遍下面的阶段。

## Phase 0：收件（Intake）

先收下需求，不要实作。

输出：

- 问题陈述。
- 用户或业务目标。
- 已知限制。
- 未知事项。
- 是否涉及 UI、数据、认证、支付、基础设施或迁移。

关卡：

- 需求不是小而明确的，进入澄清阶段。

## Phase 1：情境探索（Context Discovery）

只搜索到足以理解项目相关部分的程度。

必要输出：

- 任务专属的情境包。
- 相关文件。
- 应遵循的既有模式。
- 风险区域。
- 验证命令。
- 情境预算备注：读了什么、跳过了什么、为什么。

用 `ai/process/context-protocol.md`。

## Phase 2：澄清（Clarification）

把模糊的意图转成产品层级的规格书。

必要输出：

- 功能规格书：以 `ai/templates/feature-spec.md` 为范本，产出到
  `ai/artifacts/<Epic>/feature-spec.md`（存放惯例见 `ai/artifacts/README.md`；范本只读，不得覆写）。
- 待厘清问题。
- 明确的非目标。
- 验收标准。

关卡：

- **进入架构规划前需要人工核准。**

## Phase 3：UI Mockup 关卡

涉及画面、视觉状态或交互流程时需要。

先读 `ai/context/design-system.md`。mockup 变体必须以其中已定案的 design token
与组件库组成，不得凭空发明新风格；缺的组件依 `ai/skills/ui-mockup-gate.md` 的
「查库 → 照风格补做 → 登记回库」规则处理。视觉品质套用 `ai/skills/design-craft.md`。

必要输出：

- 画面地图。
- 状态地图。
- **2-3 个 mockup 变体**（以既有 token／组件组成）。
- 重用的 token／组件清单，与需新做并登记的组件（如有）。
- 取舍比较表。
- 选定的变体。

关卡：

- **实作前需要人工选定。这是整套流程里最值钱的一关，不要省。**

## Phase 4：架构规划（Architecture Plan）

建立技术做法。

必要输出：

- 预期会变更的文件。
- 数据与 API 契约。
- 迁移备注（如有）。
- 安全与隐私备注。
- 测试策略。
- 高风险工作的回滚计划。

关卡：

- 高风险工作需要 architect、security 与 test 审查。

## Phase 5：任务卡（Task Cards）

把工作拆成 AI-ready 的卡片。每张卡都必须符合 `ai/process/definition-of-ready.md`。

建议的卡片大小：

- 一个画面状态。
- 一个 API endpoint。
- 一个组件行为。
- 一个 bug 的重现与修复。
- 一个测试缺口。

## Phase 6：实作（Implementation）

一次只实作一张已核准的任务卡。

规则：

- **开工前先读那张卡**：`cat tools/kanban/cards/<ID>.json`。
  卡片 `comments` 里人写的内容是指令，不是背景资料。
- 写新代码前，先确认是否已有现成的库或框架能解决这个问题，避免重造轮子。
- 若有 2-3 个可行的库或做法，**问用户要用哪一种并提出建议**。重大选择不要自己闷头选。
- 除非有新证据需要更新计划，否则只动允许范围内的文件。
- 遵循既有项目模式。
- UI 实作一律取用 `ai/context/design-system.md` 的 token 与组件库，不硬写一次性的
  色彩、间距或字级；新做的组件照既有 token 与风格制作，完成后登记回 inventory。
  全程遵循 `ai/skills/design-craft.md`，交付前对照 `ai/checklists/design-review-checklist.md`。
- 保持 diff 小。
- **每个增量都要让系统维持在可运行状态**，绝不能任务做到一半就停下、留下跑不起来的系统。
- 随着变更新增或更新测试。
- 进入验证阶段前自己先跑过测试，不要只凭「看起来是对的」。
- 写代码的当下就套用 `ai/checklists/security-checklist.md`，不是只有正式审查时才做。
  无论风险等级高低都适用（例如绝不以明文存储密钥或密码）。
- **范围改变时停下来询问。**
- 随进度推进看板卡片的阶段（见 `ai/process/kanban.md`）。
  卡片有 `rev` 字段做乐观锁：整卡 PUT 要带 `If-Match: <rev>`，收到 409 表示
  这张卡在你读到之后被人改过——重新读取后再改，不要硬覆盖。

## Phase 7：验证（Verification）

完成需要证据佐证。

- 单元测试。
- 集成测试。
- E2E 测试。
- 类型检查。
- Lint。
- Build。
- 安全扫描。
- UI 截图比对。

证据写进卡片的 `evidence` 字段，不要只写在聊天里。

## Phase 8：审查（Review）

执行相关的审查关卡：产品验收 / UX 审查 / 架构审查 / 安全审查 / 测试审查 / code review。

用 `ai/process/review-gates.md`。**代理输出本身不等于核准。**

## Phase 9：人工验收（Human Acceptance）

最终回复必须包含：

- 变更了什么。
- 证据。
- 残留风险。
- 后续任务。

**没有验证证据前，不得宣称已可上生产环境。**
