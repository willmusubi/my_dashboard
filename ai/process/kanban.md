# AI 看板

这个看板追踪的是「**这项任务对 AI agent 来说是否可以安全执行**」，不只是任务状态。
它同时是人和 AI 之间的决策通道——卡片上人写的留言是指令，agent 写的是记录。

实作在 `tools/kanban/`（schema 与 API 见 `tools/kanban/README.md`）。

> 上游这份文件定义了 12 个栏位（column），而工具只有 6 条车道，两者从来没有对应关系，
> `tools/kanban/README.md` 也承认了这点。一份和工具矛盾的政策文档只会持续
> 误导 agent，所以本 fork 按工具的真实形态重写：**治理状态不靠看板的栏位表达，
> 靠卡片上的 `readiness`（7 项）和 `gates`（6 项）字段表达。** 这也解释了那两组
> 字段为什么存在——上游从没把这层说清楚。

## 六条车道

```text
backlog → ready → implementing → verify → done
   ↓
blocked（任何阶段都可能进来）
```

| 车道 | 含义 | 离场条件 |
|---|---|---|
| **backlog** | 想法或还没准备好的任务。规格、mockup、架构规划都在这个阶段发生 | `readiness` 7 项全勾 |
| **blocked** | 被前置任务、外部依赖或未答复的提问挡住 | 阻塞原因消失；卡片上人写的提问已被回答 |
| **ready** | 可以交给 agent 执行 | 已指定 agent owner；允许改的文件范围已明确；`dependsOn` 全部 `done` |
| **implementing** | agent 正在实作一张已批准的卡 | 有 diff；agent 已回报变更的文件并自己跑过验证 |
| **verify** | 实作已存在，正在补证据与过审查关卡 | `evidence` 已填；相关 `gates` 已勾 |
| **done** | 已验收且已验证。后续事项另立新卡 | — |

`done` 不设 WIP 上限（它本来就该一直堆），界面上按**完成时间倒序**显示、默认只展开
最近 8 张，其余折叠成「还有 N 张已完成 · 展开」。**折叠不是归档**：数据一张没动，
车道头的数字仍是总数，展开就全在。所以不需要任何人做「归档」这个动作。

`dependsOn` 的阻断由服务端强制执行：前置任务没全 `done`，卡片推不到
`ready` 之后（`tools/kanban/server.mjs` 的 `checkDependsOn`）。这是整套流程里
唯一有机械强制力的一条。

## Readiness：什么时候能进 ready

7 项对应上游那几个「待 XX」栏位，勾满才算 AI-ready（详见 `definition-of-ready.md`）：

| 卡片字段 | 含义 | 对应上游栏位 |
|---|---|---|
| `problem_clear` | 问题、用户、场景清楚 | 待澄清 |
| `non_goals_clear` | 非目标明确列出 | 待澄清 |
| `acceptance_testable` | 验收标准可测试 | 待产品批准 |
| `files_known` | 相关文件或搜索入口已列出 | 待架构规划 |
| `scope_defined` | 允许改的文件范围有界 | 待任务卡 |
| `verification_contract` | 验证方法已定 | 待任务卡 |
| `human_approval_recorded` | 人工批准状态已记录 | 待产品批准 |

UI 工作还要额外满足：已出 2-3 个 mockup 变体、**人工已选定一个**（见
`ai/skills/ui-mockup-gate.md`）。这一关不能省。

## Gates：什么时候能进 done

6 项对应上游的「待审查 / 待人工验收」（详见 `review-gates.md`）。

**和 readiness 不同，gates 不需要勾满**——「这张卡要过哪几关」由它的 `risk` 和
`track` 决定。所以界面上的分母是**这张卡的必需项数**，不是固定的 6：

**「谁出结论」和「谁拍板」是两件事**，别压成一件（曾经压过，结果界面要求人凭空
判断 OWASP Top 10）：

| gate | 对应关卡 | 谁出结论 | 谁拍板 | 何时必需 |
|---|---|---|---|---|
| `product` | 产品关卡 | —（人自己判断） | **人**（产品负责人） | 总是 |
| `ui` | UI Mockup 关卡 | —（人自己判断） | **人**（产品负责人或设计师） | `track` 是 `frontend` 或 `fullstack` |
| `architecture` | 架构关卡 | **架构 agent** | agent；**高风险时人** | `risk` 是 `high` |
| `security` | 安全性关卡 | **安全审查 agent** | agent；**高风险时人** | `risk` 是 `high` |
| `test` | 验证关卡 | 测试工程 agent | agent 或人 | 总是 |
| `code_review` | 合并关卡 | agent | agent | 总是 |

举例：`medium` + `frontend` 的卡需要 4 项（product / ui / test / code_review）；
`low` + `backend` 只需 3 项；`high` 的卡六项全需要。

**`product` 和 `ui` 是人自己的判断**（「这个问题值得解决吗」「符合产品意图吗」），
agent 不得自己勾，也不该代写结论。

**`architecture` 和 `security` 在高风险卡上是两步**：agent 先跑
`security-maintainability-review` 产出「发现的问题／影响／建议修法／**批准建议**」，
人读结论后决定采纳或打回。agent 给的是**建议**，不是批准——自己勾就等于把代理
输出当成批准，`CLAUDE.md` 明令禁止。**没有结论之前不该要求人拍板。**

每一关具体查什么，见 `review-gates.md`；看板界面上点关卡旁的 ⓘ 也能展开同一份内容。

这套判定实作在 `tools/kanban/card-store.mjs` 的 `requiredGates()` / `gateOwner()`，
界面与 `cli.mjs show` 共用同一份规则。

## 什么时候可以删卡

判据只有一条：**这张卡上有没有别处不存在的信息？**

- **可以删**：建错的空卡——重复建、手滑建、需求当场取消，且卡上没有任何
  `evidence`、没有留言，也没有被其他卡 `dependsOn` 引用。
- **不要删**：任何进过 `verify` 或 `done` 的卡。它们带着跑过的验证命令、过程中的
  发现、残留判断，以及人机决策留言——**这些只存在于卡上**。`residual` 里的
  「已判断不做」尤其如此：删了就等于没判断过，三个月后有人再问「这个为什么不处理」，
  没有答案。

删除本身是安全的：`handleDelete` 会清掉其他卡对它的 `dependsOn` 引用，不会像上游
那样锁死车道。但那条依赖关系的历史也就一并消失了。

**「git 里还有」不是理由。** 没有人会去 `git log --follow tools/kanban/cards/DASH-008.json`
翻一张卡——「数据还在」和「查得到」是两回事。

## WIP 上限

- `implementing`：1-3 张（看板上超过会标红）
- `verify`：最多 5 张

若 `verify` 满了，**停止建立新的 AI 工作**。积压在 verify 意味着证据在欠账，
再开新工作只会让欠账变多。
