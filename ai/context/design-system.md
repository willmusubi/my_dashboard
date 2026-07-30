# 设计系统（Design System）

由 Epic 0「项目设置」的「UI 设计系统」User Story 按 S1–S5 的顺序（框架 → 风格 → design token → 组件库 → 版面）逐步填写；卡片粒度与是否合并由项目规模决定，见 `ai/skills/project-kickoff.md` 步骤 2a。**这份文件是后续所有功能 Epic 做 UI 时的单一事实来源**：任何前端任务开工前都要先读它，能用既有 token／组件就必须用；缺的组件要照既有风格补做并登记回这里（见 `ai/skills/project-kickoff.md` 步骤 6 与 `ai/skills/ui-mockup-gate.md`）。

状态：模板占位符（尚未展开设计）。

## S1 底层框架

- UI 框架：待补（例如 React / Vue / SvelteKit）
- 组件库策略：待补（采用现成 / 自建；若采用，列出来源如 shadcn/ui、MUI、Ant Design）
- 样式方案：待补（例如 Tailwind、CSS-in-JS、CSS Modules）
- 选定理由：待补
- 人工批准：待补（批准人／日期）

## S2 风格方向

- 选定的 style tile：待补（变体名称）
- 色彩情绪：待补
- 字体个性：待补
- 圆角／阴影倾向：待补
- 密度：待补（紧凑 / 舒适）
- 亮／暗模式：待补
- 参考产品：待补
- 人工批准：待补（批准人／日期）

## S3 Design Token 列表

### Primitive Token

| 类别 | Token | 值 | 备注 |
|---|---|---|---|
| 色彩 | 待补 | 待补 | 完整色票（含各阶明度） |
| 字级 | 待补 | 待补 | type scale |
| 字重／行高 | 待补 | 待补 | |
| 间距 | 待补 | 待补 | spacing scale |
| 圆角 | 待补 | 待补 | |
| 阴影 | 待补 | 待补 | |
| z-index | 待补 | 待补 | |
| 动效 | 待补 | 待补 | 时间与曲线 |

### Semantic Token

| Token | 对应 primitive | 用途 |
|---|---|---|
| color.primary | 待补 | 待补 |
| color.surface | 待补 | 待补 |
| color.danger | 待补 | 待补 |
| space.page | 待补 | 待补 |

### 实际 token 档位置

- 项目内真实 token 档路径：待补（例如 `src/styles/tokens.css`、`tailwind.config.ts` 主题、`theme.ts`）。若项目尚无可跑框架，可留空，仅以上表为准。
- 人工批准：待补（批准人／日期）

## S4 组件库 Inventory

每做一个核心组件就登记一列。后续 Epic 缺组件、照风格补做后也要回来补登。

| 组件 | 状态 | 涵盖状态 | 用到的 token | 文件位置 | 截图 | 来源阶段 |
|---|---|---|---|---|---|---|
| Button | 待补 | 默认/hover/focus/停用/载入 | 待补 | 待补 | 待补 | S4 |
| Input | 待补 | 默认/focus/停用/错误 | 待补 | 待补 | 待补 | S4 |
| Select | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Card | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Nav | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Modal/Dialog | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Table | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Form | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |
| Toast/Alert | 待补 | 待补 | 待补 | 待补 | 待补 | S4 |

（「来源阶段」记录这个组件是 S4 初建，还是后续某个功能 Epic 补做并回登的。）

## S5 各界面版面

| 界面／用户端 | 选定版型 | Mockup 决策纪录 | 人工批准 |
|---|---|---|---|
| 待补（例如 管理员后台） | 待补 | 连结到 `ai/artifacts/<Epic>/mockup-decision-<画面>.md` | 待补 |
| 待补（例如 顾客前台） | 待补 | 待补 | 待补 |
