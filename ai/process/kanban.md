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

6 项对应上游的「待审查 / 待人工验收」（详见 `review-gates.md`）：
`product` / `ui` / `architecture` / `security` / `test` / `code_review`。

不是每张卡都要勾满——低风险的卡不需要架构和安全审查。但**高风险变更
（认证、权限、支付、密钥、文件处理、网络、数据库迁移、基础设施、跨服务）
必须勾 `architecture` + `security` + `test`**。

## WIP 上限

- `implementing`：1-3 张（看板上超过会标红）
- `verify`：最多 5 张

若 `verify` 满了，**停止建立新的 AI 工作**。积压在 verify 意味着证据在欠账，
再开新工作只会让欠账变多。
