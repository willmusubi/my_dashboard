# 设计工艺（Design Craft）

任何产出 UI mockup 或前端视觉实作的任务都适用。`ui-mockup-gate` 管的是**流程**（几个变体、哪些状态、谁批准）；这份 skill 管的是**质量**——没有它，流程走完也可能产出丑的东西。原则整理自《Refactoring UI》（Adam Wathan & Steve Schoger）。

## 何时使用

- Epic 0 的五阶段设计流程（`ai/skills/project-kickoff.md` 步骤 2a 的 S2–S5）全程。
- `ui-mockup-gate` 产出任何 mockup 变体之前。
- 任何前端任务的实作过程中。
- Design review、或用户抱怨「丑」「看起来怪」「不对齐」时。

## 十大核心纪律

1. **从 features 出发，不从 layout 出发**：先列出这一页的 1-3 个主要动作，把它们做大做明显；不要先画 sidebar/header 再想中间塞什么。
2. **层次靠对比建立**：size、weight、color 三个工具择一加强；次要信息主动弱化（小字＋灰色＋细体）。反例：所有文字都同字级同字重同颜色。
3. **留白起手就用过量**：card 内 padding 从 24px（`p-6`）起手，觉得太空再缩；不要从 8px 开始加。挤＝廉价，空＝精致。
4. **间距只用 4 的倍数**：`4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64`。7px、13px、19px 会让画面「说不出哪里怪」。
5. **字级从 type scale 取、字重活用**：字级只用 `11 / 12 / 13 / 14 / 16 / 18 / 20 / 24 / 30 / 36 / 48`；字重至少用到 400（body）／500（emphasis）／600（subheading）／700（heading、主按钮）三种以上，不要全用 500。中文项目：字体 stack 必含对应语系的 fallback（简中 `'PingFang SC', 'Microsoft YaHei'`，繁中 `'PingFang TC', 'Microsoft JhengHei'`），HTML `lang` 与内容语言一致（本项目 `zh-CN`）；标题行高 1.2–1.3、内文 1.5–1.7；中文 letter-spacing 为 0。
6. **色彩是 system，不是单一 hex**：grey scale（最重要）＋ primary scale ＋ semantic 色（success/warning/danger/info），每色 9-10 阶。hover/active/disabled 用同色系不同阶。**先用 grayscale 把整个版面排好，最后才上色**——灰阶版层次对了，加色就是锦上添花。
7. **边框是新手最常见的视觉噪音**：区隔优先序＝ spacing → 背景色 → 阴影 → 最后才是边框（表格列、input 这类需要硬边界的才用）。
8. **Depth 三选一**：浮起用 shadow、平面区块用背景色、硬边界用 border，**不要叠用**。阴影模拟上方光源：y-offset > x-offset、blur > y-offset。
9. **五态完整才算做完**：每个互动元素要有 default / hover / focus / disabled / loading；每个数据区块要有 loading / empty / error / 无权限。只做 default 是半成品。
10. **Polish 自问**：做完逐项对照 `ai/checklists/design-review-checklist.md`，每个 ❌ 都是修的机会。

## 实作前先比对高质量开源参考

**不要凭记忆设计。** 启动视觉任务时先问三题：

1. 这个 feature 最像哪一类？（calendar / dashboard / form / list / detail / setting）
2. 下面哪个参考最像？打开它，找对应页面。
3. 该页面的字级、间距、配色、互动，依次抄；不确定的数值就抄参考，不要瞎猜。

| 类型 | 参考 | 学什么 |
| --- | --- | --- |
| Admin dashboard | [shadcn-admin](https://github.com/satnaing/shadcn-admin)、[TailAdmin](https://github.com/TailAdmin/free-nextjs-admin-dashboard) | 版型配置、light/dark、表格／filter／pagination 模式 |
| 预约／排程 | [Cal.com](https://github.com/calcom/cal.com)、[open-salon](https://github.com/clawnify/open-salon) | booking 视觉语言、availability picker、日历字段 |
| SaaS 全套 | [ixartz/SaaS-Boilerplate](https://github.com/ixartz/SaaS-Boilerplate) | auth flow、multi-tenancy、landing/pricing/dashboard 三段风格 |
| 组件范例 | [shadcn/ui examples](https://ui.shadcn.com/examples)、[Tremor](https://github.com/tremorlabs/tremor)、[Radix primitives](https://www.radix-ui.com/primitives)、[Mantine UI](https://ui.mantine.dev/) | 直接照抄结构；data viz；a11y 互动细节 |
| 设计灵感（非程序） | [Mobbin](https://mobbin.com/)、[Dribbble](https://dribbble.com/) | 真实 production app 截图；配色／字体／排版方向 |

## 实作中的固定处理顺序

**不要跳过顺序**，每一阶段完成才进下一阶段：

1. **Hierarchy**：定出主要／次要／三级信息，三级要明显比次要弱。
2. **Layout & Spacing**：间距全部取自 4 的倍数 scale。
3. **Typography**：字级从 type scale 取、字重活用、中文 fallback 与 lang 设好。
4. **Color**：先 grayscale 排好版面，再从 design token 上色。
5. **Depth**：边框／阴影／背景三选一。
6. **Polish**：补齐互动五态与 empty/loading/error 画面。

## 与治理流程的整合

- 所有色彩、字级、间距、圆角、阴影数值一律来自 `ai/context/design-system.md` 的 design token，不写孤立 hex 或 inline 一次性数值；Epic 0 的 S3 阶段就是用这份 skill 的 scale 纪律去定 token。
- mockup 关卡（`ai/skills/ui-mockup-gate.md`）产出的每个变体都要先过上面的十大纪律。
- 交付前与 design review 时，逐项对照 `ai/checklists/design-review-checklist.md`。

## 常见急救修法（用户抱怨丑时）

- 字体 stack 没中文 fallback → 加对应语系的（简中 PingFang SC／微软雅黑）；`lang` 与内容语言不符 → 改成对的（本项目 `zh-CN`）。
- hex 散落各文件 → 集中回 design token。
- 字重全 500 → 主要 700、次要 500、提示 400。
- 间距 7/13/19px → 改 8/12/16/20。
- 边框＋阴影＋背景三叠 → 砍掉两个。
- 没有 empty／loading state → 补上。

## 不要做的事

- 不要凭记忆猜 hex、间距、字级。
- 不要看到 mockup 就直接写 inline style 而不对齐到 design token。
- 不要在没看过任何参考的情况下「自己设计」一个新版型。
- 不要等用户抱怨丑才做 review——交付前就对照检查清单。
