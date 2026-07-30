# 设计审查检查清单

UI 变更交付前、mockup 关卡审查时，或用户抱怨「丑」时逐项打勾。**不要凭感觉**，每一项都对着实际画面与代码确认。原则出处见 `ai/skills/design-craft.md`。

## 一、字体与文字

- [ ] HTML `lang` 与内容语言一致（本项目：`zh-CN`），不是 `en` 跑中文。
- [ ] 字体 stack 含对应语系的中文 fallback。简中：`'PingFang SC', 'Microsoft YaHei', '微软雅黑'`；繁中：`'PingFang TC', 'Microsoft JhengHei'`。
- [ ] 字级全部来自 type scale（`11 / 12 / 13 / 14 / 16 / 18 / 20 / 24 / 30 / 36 / 48`），没有 15px、17px、19px 这种奇怪字级。
- [ ] 字重至少用到 3 种（400 / 500 / 700），不是全 500。
- [ ] 行高：标题 1.2–1.3、内文 1.5–1.7；中文 letter-spacing 为 0 或 < 0.02em。

## 二、颜色

- [ ] 没有孤立 hex 散落各文件；全部来自 `ai/context/design-system.md` 的 design token。
- [ ] 主色有完整 9-10 阶；hover / active / disabled 用同色系不同阶。
- [ ] 灰阶系统至少 5 阶。
- [ ] 文字对背景对比达 WCAG AA（4.5:1）。
- [ ] 同一语意（如「警告」）全站只用一个颜色变量；accent 色不超过 2 个。
- [ ] 颜色不是唯一的信息载体（配 icon 或 label，色盲也看得懂）。

## 三、间距

- [ ] 所有间距是 4 的倍数（`4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48 / 64`）。
- [ ] Card 内 padding 至少 16px 起手；section 间至少 32px。
- [ ] 没有为了塞东西硬缩的 margin / padding。

## 四、视觉层次

- [ ] 主要／次要／三级信息一眼分得出来；三级信息主动弱化（小字＋灰色＋细体）。
- [ ] 标题与内文字级差至少 4px。
- [ ] 主按钮跟次按钮一眼分得出（颜色＋字重＋边框至少一项明显不同）。

## 五、深度

- [ ] 边框、阴影、背景色**三选一**，没有同时叠用。
- [ ] 阴影方向统一（y-offset > 0、blur > y-offset）。
- [ ] 边框颜色不超过 2 种；背景色不超过 3 种。

## 六、互动五态

每个互动元素（button、link、input、可点击的 card）都要有：

- [ ] Default、Hover、Focus（focus ring，无障碍必备）、Disabled（明显弱化＋ `not-allowed`）、Loading（> 200ms 的动作有 spinner / skeleton）。

## 七、零内容状态

每个会显示数据的区块（list、table、card grid）都要有：

- [ ] Loading（skeleton / spinner，不能空白）。
- [ ] Empty（「目前无数据」＋行动 CTA）。
- [ ] Error（明确消息＋重试）。
- [ ] 无权限（友善说明，不要裸 403）。

## 八、Mockup 对齐（如有 mockup）

- [ ] 字级、颜色、间距、圆角、边框逐项对齐选定的 mockup（用浏览器 inspect 对）。
- [ ] 不要自己「顺手改善」mockup——先实作一致版本，改善另提。

## 九、响应式

- [ ] Mobile（< 640px）／Tablet／Desktop 排版皆正常；文字不截断、不溢出。
- [ ] 表格在窄画面有横向卷动或重排策略。
- [ ] 触控目标至少 44×44px。

## 十、最终检查

- [ ] 眯起眼看，视觉重心对吗？
- [ ] 跟 `ai/skills/design-craft.md` 参考清单里最像的 production 产品并排比，差在哪？
- [ ] 给人看 5 秒，能说出「这页是做什么的」吗？

还是不对劲时：找最像的参考项目并排截图比对；**最后手段**是放弃目前排版、照参考从零重排一次——常常比东补西补快。
