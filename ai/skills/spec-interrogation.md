# 规格书质询（Spec Interrogation）

在实作前使用此流程。适用范围是单一功能模块（Epic）。若是全新项目、还没有 Epic 列表，先用 `project-kickoff` 流程建立并让人工勾选 Epic，再对每个 Epic 个别跑这个流程。

## 步骤

1. 将需求重述为「问题」而非「解法」。
2. 确定用户、目标、非目标与风险。
3. 只询问阻挡性（blocking）问题。若某假设合理且安全，则直接记录下来。
4. 以 `ai/templates/feature-spec.md` 为模板，产出 `ai/artifacts/<Epic>/feature-spec.md`（模板本身唯读，不得覆写；见 `ai/artifacts/README.md`）。
5. 使用可测试的需求语言撰写。
6. 在进入架构规划前，停下来等待人工批准。

## 必要章节

- 问题。
- 用户。
- 目标。
- 非目标。
- 用户故事列表（User Stories，每条可独立验收，之后会逐条拆成任务卡）。
- 用户旅程。
- 功能需求。
- 若涉及 UI，列出相关画面。
- 数据与 API 假设。
- 安全性与隐私备注。
- 验收标准。
- 验证计画。
