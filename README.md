# 治理看板 · my_dashboard

一个本地的、零依赖的 AI 协作治理看板。

**要解决的问题**：AI agent 从模糊需求就开始写代码、产出大而不可审查的 diff、没有证据就宣称"完成了"。

**核心机制**：看板不只是任务追踪，而是**人和 AI 之间的决策通道**——你在卡片上写下的决策，agent 下一次接手这张卡时一定会读到，并且必须在看板上留下"已确认"的痕迹。

## 跑起来

```bash
npm run kanban                     # → http://127.0.0.1:4430
KANBAN_PORT=4430 npm run kanban    # 换个端口
```

零依赖，无需 `npm install`。数据是 `tools/kanban/cards/*.json`，一卡一个文件，git 追踪。
没有保存按钮，改动即时落盘；要撤销就用 `git checkout`。

## 流程

每个非小型变更走 `ai/process/workflow.md` 定义的这些阶段：

| 阶段                      | 产出                                           | 关卡                            |
| ------------------------- | ---------------------------------------------- | ------------------------------- |
| 0 收件                    | 问题陈述、目标、限制、未知事项                 | 需求模糊 → 进入澄清             |
| 1 情境探索                | 任务专属情境包：文件、模式、风险、验证命令     | —                               |
| 2 澄清                    | 功能规格书、非目标、验收标准                   | **人工核准**                    |
| 3 UI Mockup（涉及界面时） | 画面/状态地图、2-3 个变体、取舍表              | **人工选定变体**                |
| 4 架构规划                | 变更文件、数据/API 契约、回滚计划              | 高风险 → 架构 + 安全 + 测试审查 |
| 5 任务卡                  | 符合 `definition-of-ready.md` 的 AI-ready 卡片 | —                               |
| 6 实作                    | 一次一张已核准的卡，小 diff                    | 范围改变 → 停下询问             |
| 7 验证                    | 测试、typecheck、lint、build、安全扫描、截图   | —                               |
| 8 审查                    | 产品 / UX / 架构 / 安全 / 测试 / code review   | `review-gates.md`               |
| 9 人工验收                | 变更内容、证据、残留风险、后续任务             | **没有证据就不算完成**          |

代理输出本身**永远不等于核准**。

## 目录

| 路径                      | 内容                                                               |
| ------------------------- | ------------------------------------------------------------------ |
| `CLAUDE.md` / `AGENTS.md` | agent 入口与路由规则                                               |
| `ai/process/`             | 流程规则：工作流、就绪定义、完成定义、情境协议、审查关卡、看板政策 |
| `ai/templates/`           | 只读范本母本，**不得覆写**                                         |
| `ai/checklists/`          | 安全、测试、设计审查检查表                                         |
| `ai/context/`             | 本项目的架构地图、设计系统、决策记录                               |
| `ai/artifacts/`           | 填写完成的产出物，一个 Epic 一个目录                               |
| `ai/skills/`              | skill 正本内容；`.claude/skills/` 下是指向它的薄 stub              |
| `.claude/agents/`         | 5 个审查子代理（架构 / 安全 / 测试 / UX / 产品）                   |
| `tools/kanban/`           | 看板本体（`server.mjs` + `index.html`），schema 与 API 见其 README |

自检：`bash scripts/check-governance.sh`（从仓库根目录跑）

## 与上游的关系

fork 自 [Monstrare](https://github.com/pjwang2022/Monstrare)（MIT，见 `NOTICE.md` 与 `LICENSE`）。
上游 remote 保留为 `upstream` 且**禁止 push**，所以随时可以：

```bash
git diff upstream/main      # 看自己改了什么
git log upstream/main..HEAD # 自己的 changelog
git fetch upstream          # 拉上游修复
```

本 fork 相对上游的主要差异：

- 删除 Codex 支持、安装脚本、上游自己的看板设计史
- 修复若干**静默损坏数据**的 bug（悬空依赖锁死车道、ID 复用、order 冲突、坏 JSON 废掉整板、后写覆盖）
- 全文简体化
- 新增**人 ↔ AI 决策通道**：类型化留言（decision/question/note…）+ CLI + Claude Code hook
