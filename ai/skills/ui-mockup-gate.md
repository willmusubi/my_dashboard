# UI Mockup 关卡

当任务涉及变更画面、组件、互动流程或视觉状态时，皆须使用此流程。

这个关卡管流程；视觉质量由 `ai/skills/design-craft.md` 把关——**产出任何变体之前先读它**，套用其中的十大纪律（type scale、4 的倍数间距、色彩系统、depth 三选一、五态完整）与「先比对高质量参考项目」的做法。

## 先对照设计系统（强制，不可省略）

除了 Epic 0 尚未定案设计系统的阶段外，跑这个关卡前**一律先读 `ai/context/design-system.md`**：

- mockup **必须用 `design-system.md` 已定案的 design token 与组件库拼出来**，不得凭空发明新色彩、新间距或新组件风格。变体之间的差异应该来自版型、信息架构与组件组合方式，而不是各自另立一套视觉。
- 若这个画面需要的组件在组件库 inventory 里还没有：**强制走「查库→照风格补做→登记回库」**——依既有 token 与风格新做该组件（涵盖必要状态），完成后登记回 `design-system.md` 的组件库 inventory，再继续。不得就地捏一个不入库的一次性组件。
- 若既有 token／组件确实不敷使用、需要扩充设计系统本身，停下来向人工确认，不要自行扩张风格。

## 步骤

1. 读 `ai/context/design-system.md`，列出这个画面会用到的既有 token 与组件；盘点是否有缺的组件需照上方规则补做。
2. 以 `ai/templates/screen-spec.md` 为模板，建立或更新 `ai/artifacts/<Epic>/screen-spec-<画面>.md`（模板唯读，不得覆写；见 `ai/artifacts/README.md`）。
3. 列出所有必要状态：默认、载入中、空状态、错误、停用、权限不足、行动装置版。
4. 产出 2-3 个 mockup 变体（皆以既有 token／组件组成），存到 `ai/artifacts/<Epic>/mockups/`，档名含画面与变体（例如 `dashboard-variant-a.html`）。
5. 依清晰度、信息密度、实作复杂度与风险比较各变体。
6. 以 `ai/templates/mockup-decision.md` 为模板，将决策记录于 `ai/artifacts/<Epic>/mockup-decision-<画面>.md`。
7. 在人工选择变体之前，停止进行实作。

## Style tile 变体（Epic 0 步骤 2a 的 S2 阶段专用）

在 Epic 0 决定「视觉风格方向」时，本关卡产出的不是完整版面，而是 2-3 个 **style tile**：每个变体呈现色彩情绪、字体个性、圆角与阴影倾向、密度、亮／暗模式与参考产品，让人工比较整体气质。这是唯一「还没有既有 token 可对照」的例外——此阶段的目的正是要产生风格方向，供后续 S3 提炼出 design token。选定方向后写进 `design-system.md` 的「风格方向」。

## 输出

- 画面规格书。
- 用到的既有 token／组件列表，以及本次新做并已登记回 inventory 的组件（如有）。
- 变体比较表。
- 建议采用的变体。
- 待澄清问题。
- 人工批准请求。
