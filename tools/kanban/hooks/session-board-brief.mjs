#!/usr/bin/env node
/**
 * Claude Code SessionStart hook。
 *
 * 会话开始时报告人在看板上做了什么。matcher 必须含 clear 与 compact：
 * 那两种情形下 agent 的上下文被清空，而看板状态一个字都没跟着重来。
 *
 * 渲染与 UserPromptSubmit 的回退简报共用 renderBoardBrief，措辞才不会各说各话。
 * 看板干净时**不输出任何东西**，所以安静时的 token 成本真的是零。
 * 任何异常都静默 exit 0。
 */
import * as store from "../card-store.mjs";

try {
  process.stdout.write(store.renderBoardBrief(store.boardBrief()));
} catch {
  /* 静默 */
}
process.exit(0);
