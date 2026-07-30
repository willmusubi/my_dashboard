# 产出物目录（Artifacts）

填写完成的流程产出物（功能规格书、画面规格、mockup、任务卡、验证报告）都存在这里，**一个 Epic 一个文件夹**。

`ai/templates/` 底下的文件是**唯读的模板母本，不得覆写**——产出时一律「以模板为底，另存到本目录」。看板卡片的 `links` 字段（featureSpec / screenSpec / mockupDecision / taskCard / verificationReport）也填这里的路径。

## 结构

```text
ai/artifacts/<Epic 名称>/
  feature-spec.md               # 以 ai/templates/feature-spec.md 为模板
  screen-spec-<画面>.md         # 以 ai/templates/screen-spec.md 为模板，一画面一份
  mockups/                      # mockup 变体（HTML 或图档），档名含画面与变体，如 dashboard-variant-a.html
  mockup-decision-<画面>.md     # 以 ai/templates/mockup-decision.md 为模板
  task-cards/<卡片id>.md        # 以 ai/templates/task-card.md 为模板，一卡一份
  verification/<卡片id>.md      # 以 ai/templates/verification-report.md 为模板
```

Epic 文件夹名称与 `tools/kanban/epics.json` 的 Epic `name` 一致（例如 `ai/artifacts/项目设置/`、`ai/artifacts/预约管理/`）。

## 规则

- 产出物跟代码一样走 git：commit 就是批准纪录的一部分。
- 不确定该放哪时，回来读这份 README，不要就地发明新位置。
- 模板更新不回溯：已产出的文件维持产出当下的结构即可。
