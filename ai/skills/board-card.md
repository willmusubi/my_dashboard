# 看板卡片协议（Board Card）

看板不只是任务追踪，它是**人和你之间的决策通道**。这份文档说明这条通道怎么用。

## 最重要的三条

1. **卡片上人写的 `decision` 是指令，不是背景资料。** 必须遵守。要推翻它，
   先发一条 `question` 然后**停下来问人**，不得自行改变。
2. **你不能下决策。** `authorKind=agent` + `kind=decision` 会被服务端 403 拒绝。
   这不是技术限制的副作用，是刻意的：通道在信息上双向，在权威上单向。
3. **没有证据不算完成。** 证据写进卡片的 `evidence` 字段，不要只留在聊天里
   ——聊天会被关掉，卡片不会。

## 开工前

```bash
node tools/kanban/cli.mjs show <ID>
```

输出里会有「生效中的人工决策」和「尚未回答的提问」。逐条确认：

```bash
node tools/kanban/cli.mjs ack <ID> <留言id>
```

`ack` 会在看板上留下「已确认 · 时间」——**这是人验证你真的读到了的唯一方式**。
不确认就开工，等于让人无法判断你有没有看见他的决定。

已经被 `superseded`（取代）或 `done` 的决策不会出现在输出里，所以你看到的
一定是当前生效的那一版。不要去翻历史留言找旧决策。

## 干活中

有进展就写回看板，不要攒到最后：

```bash
node tools/kanban/cli.mjs comment <ID> --kind progress  --text "..."
node tools/kanban/cli.mjs comment <ID> --kind evidence  --text "npm test → 15/15"
node tools/kanban/cli.mjs comment <ID> --kind blocker   --text "..."
```

推进阶段：

```bash
node tools/kanban/cli.mjs stage <ID> implementing   # 再 verify，再 done
```

**`gates` 分三种归属**，`cli.mjs show` 的输出会直接告诉你这张卡的情况：

- **你要过**：`test` / `code_review`，以及低风险卡的 `architecture` / `security`。审完自己勾。
- **你先审出结论、再交给人拍板**：高风险卡的 `architecture` / `security`。
  跑 `security-maintainability-review`，产出「发现的问题／影响／建议修法／**批准建议**」，
  写进卡片，然后**停下来等人**。你给的是建议，不是批准，**不要自己勾**。
- **等人判断（不要自己勾，也不要代写结论）**：`product` / `ui`。
  「这个问题值得解决吗」「符合产品意图吗」是人的领域。

`gates` 也**不需要勾满 6 项**：要过哪几关由卡片的 `risk` 和 `track` 决定
（规则见 `ai/process/kanban.md`）。别看到「3/6」就以为还差 3 项。

### 人工关卡：勾了就必须留下授权来源

上面那两类「不要自己勾」是默认规则。**人可以就某张卡明确授权你代勾**——这是人的
权利，不是你能自行推定的。一旦获得授权，勾选的同时**必须发一条 comment 写明授权
来自哪里**：原话、时间或对话中的哪句指示。

适用范围：`product` / `ui`、高风险卡的 `architecture` / `security`，
以及 `readiness.human_approval_recorded`。

```bash
node tools/kanban/cli.mjs comment <ID> --kind progress --text \
  "授权留痕：用户 2026-08-03 指示「开卡然后实际操作掉就好」，据此勾 product 与 human_approval_recorded。授权范围仅限本卡。"
```

**为什么非留不可**：服务端对这几项**没有任何强制力**——agent 一个 PATCH 就能勾满
全部关卡并推 done，而 `gates` 只是布尔值，不记录谁勾的、什么时候勾的。于是卡片只
留下了「结果」，没留下「条件」。而授权本身是有条件的（「**得到许可之后**才自签」），
条件不可见就等于没有：几周后回头看，没人能分辨这一关是人批的还是 agent 自己勾的。

这不是形式主义。DASH-025 的安全审查就是从「MT-001 上 `gates.product` 与
`human_approval_recorded` 都是 true，卡上却找不到任何人写的痕迹」查起的。

范例见 DASH-025 与 DASH-027 的 `progress` 留言。

授权是**按卡**给的，不会自动延续到下一张卡。拿不准就当作没有授权，按默认规则停下来问。

**填 `evidence.residual` 时，每一条都要让人立刻答得出「现在要不要有人跟」**
（详见 `ai/process/definition-of-done.md`）：

- **要有人跟** → 写卡号或明确的时机。
- **不用跟** → 写理由，以及将来重新评估的触发条件（如果有）。这类沉在卡里备查
  是对的，**不要**为它建卡。

不要写「未在本卡范围内处理」——那既不给判断也不给归宿，读的人无法据此行动。
也不要为「不用跟」的事建 backlog 卡：backlog 里堆着永远不做的卡，
会让「积压」这个信号失效。

`dependsOn` 没全部 `done` 的卡推不到 `ready` 之后——这是服务端硬拦的，
不是建议。撞到了就说明前置任务真的没做完，去做前置，不要绕过。

## 收尾：把球明确地传回给人

**每一轮回复的最后，列出需要人做的 Todo，分两档：**

- **阻塞** —— 不做就走不下去。典型来源：`product` / `ui` 关卡；高风险卡的
  `architecture` / `security`（你出结论、人拍板）；你发出的、还没被回答的 `question`；
  `evidence.residual` 里判为「要有人跟」的条目；以及有多个可行方案要人二选一。
- **可选** —— 做不做都能继续。典型：要不要提交、要不要顺手升级其他项目、
  与本卡无关但顺手发现的小问题。

每条都要写清楚**做什么**和**不做会怎样**。只写个标题（「确认一下 X」）等于把判断
成本又推回给人——人得先读懂才知道要不要理，这份清单就没省下任何东西。

**没有需要人做的事时，一句话说「没有」就够了，不要硬凑。** 每轮硬凑两三条
无关紧要的待办，人很快会开始跳过整份清单，真正阻塞的那条也一起被跳过。

**为什么非列不可**：这套流程有意在很多地方停下来等人（`ai/process/review-gates.md`）。
停是对的，但**停下来之后人不知道要干嘛，就从「等」变成了「堵」**。待人决策的事项
散在长回复正文里时，不要紧的事和真正要紧的事会花掉人一样多的注意力。
「代理输出不等于批准」（见 `CLAUDE.md`）是这套东西的底线——那么让人能**低成本地
做出批准或否决**，就是让这条底线可持续的配套，不是可有可无的礼貌。

形状（照抄即可）：

```text
## 需要你处理的 Todo

**🔴 阻塞**
1. DASH-042 是高风险卡，architecture / security 两关等你拍板。结论与批准建议
   已写在卡片 evidence.residual 第一段。不勾这两关，这张卡推不到 done。

**🟡 可选**
2. 本轮改动还没提交。要提交说一声；不提交的话下一张卡的 diff 会和这次的混在一起。
```

## 不要删卡

**进过 `verify` 或 `done` 的卡，你一张都不要删。** 它们带着验证命令、过程发现、
残留判断与人机决策留言，这些只存在于卡上。要作废一张卡，就说明理由并交给人决定。

只有「建错的空卡」（重复、手滑，且没有任何 evidence 和留言）可以删。
判据与理由见 `ai/process/kanban.md` 的「什么时候可以删卡」。

## 遇到决策没涵盖的分歧

**不要自己挑一个做下去。**

```bash
node tools/kanban/cli.mjs ask <ID> --text "手机版要不要保留 drawer？"
```

然后停下来，把这个问题带给人。`ai/process/context-protocol.md` 的「停止条件」
列了必须停的情形：有多个可行方案、与既有架构冲突、缺少必要文件、
碰到密钥/认证/支付/迁移/基础设施、范围超出已批准的卡片。

### blocked 车道：等人的卡要看得出来在等人

`ask` 会**自动把卡片推进 `blocked`**，不用你另外跑 `stage`。

为什么必须换车道：提问之后那张卡就不动了。它要是继续停在 `implementing`，就会
占着 WIP 名额（上限 3）、在看板上**看起来像在做，实际在等人**。人看的是车道，
不是 `cli.mjs open` 的输出——车道没反映出来，等于没说。

- **进**：`ask` 自动推。卡已经是 `blocked` 就不重复推；已经 `done` 也不推
  （在完成的卡上追问，不该把它拖回未完成状态）。
- **出**：人回答之后，**你自己**推回原来的车道：

  ```bash
  node tools/kanban/cli.mjs ack <ID> <留言id>          # 先确认你读到了
  node tools/kanban/cli.mjs stage <ID> implementing    # 再推回去继续做
  ```

- **例外**：只是想记一笔「这里有个坎」但活还能继续，用
  `comment --kind blocker`（不换车道）；或 `ask ... --no-block`。
  两者的区别是**你会不会停下来**——会停就该进 blocked。

`dependsOn` 造成的阻塞不走这条路：那个由服务端硬拦（前置没 `done` 就推不到
`ready` 之后），撞到了说明前置真的没做完，去做前置。

## 留言类型

| kind | 谁能写 | 含义 | 默认状态 |
|---|---|---|---|
| `decision` | **只有人** | 必须遵守的决定 | `open` |
| `question` | 人 / agent | 等对方回答 | `open` |
| `blocker` | 人 / agent | 卡住了 | `open` |
| `answer` | 人 / agent | 回答某条 question（带 `--re`） | `done` |
| `progress` | 人 / agent | 进度记录 | `done` |
| `evidence` | 人 / agent | 验证证据 | `done` |
| `note` | 人 / agent | 随手记，不具约束力 | `done` |

状态流转：`open` →（agent 确认）`acked` →（做完）`done`；
或被新决策取代 → `superseded`。留言文本**不可变**，修正靠发新留言 + `supersedes`。

## 卡片的整卡写入

改 stage、risk、readiness、gates 这些结构化字段用 `stage` 子命令或 PATCH，
**不要**整卡 PUT——整卡写入会忽略你送的 `comments`（那是为了防止覆盖别人的留言），
而且要带 `If-Match: <rev>`，撞 409 说明这张卡在你读到之后被改过，
**重新读取后再改，不要硬覆盖**。

## server 没开也能用

CLI 连不上 4430 时会自动回退到直接读写文件。所以不要因为「看板没启动」
就跳过这套流程，也不要因此去手改 JSON。

## 身份

CLI 在 Claude Code 下自动用 `claude-code` 作为身份（`KANBAN_AGENT`）。
解析不出身份时 CLI 会报错退出，不会静默以人的名义发言——因为人的决策和
你的记录必须分得开，这是整套设计的前提。
