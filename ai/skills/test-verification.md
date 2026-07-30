# 测试验证

在宣告任务完成前使用此流程。

## 步骤

1. 阅读任务卡中的验证契约。
2. 确定范围最小但仍有效的检查项目。
3. 先执行针对性的测试。
4. 于必要时执行 lint／型别检查（typecheck）／构建。
5. 对于 UI 变更，若工具允许，撷取桌面版与行动装置版的屏幕截图。
6. 对照 `ai/checklists/testing-checklist.md` 逐项确认（测试是否会在没修复前失败、边界案例与权限/错误路径是否覆盖等）；UI 变更另对照 `ai/checklists/design-review-checklist.md`。
7. 以 `ai/templates/verification-report.md` 为模板记录证据，产出到 `ai/artifacts/<Epic>/verification/<卡片id>.md`（见 `ai/artifacts/README.md`）。

## 输出

- 已执行的指令。
- 通过／失败摘要。
- 屏幕截图备注。
- 涵盖范围缺口。
- 残留风险。
- 任务是否符合完成定义（definition of done）。
