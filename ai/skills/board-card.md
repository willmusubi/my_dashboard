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

## 遇到决策没涵盖的分歧

**不要自己挑一个做下去。**

```bash
node tools/kanban/cli.mjs ask <ID> --text "手机版要不要保留 drawer？"
```

然后停下来，把这个问题带给人。`ai/process/context-protocol.md` 的「停止条件」
列了必须停的情形：有多个可行方案、与既有架构冲突、缺少必要文件、
碰到密钥/认证/支付/迁移/基础设施、范围超出已批准的卡片。

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
