#!/usr/bin/env node
/**
 * Claude Code UserPromptSubmit hook。
 *
 * 用户消息里出现 <PREFIX>-### 时，把那张卡「生效中的人工决策 / 待回答提问」注入
 * 本轮 context；抓不到卡号时退回一份简报（见 renderBoardBrief）。
 * stdout 会被 Claude Code 并进这一轮的输入。
 *
 * 为什么需要它：只在 CLAUDE.md 里写一条「记得读卡片」等于上游已经做的事，
 * 实测零强制力（上游整个仓库里「留言/comment」在 ai/process、ai/skills、
 * AGENTS.md、CLAUDE.md 中出现 0 次）。hook 是唯一不依赖模型自觉的机制。
 *
 * 设计原则，按优先级：
 *   1. 绝不阻塞用户输入 —— 任何异常都静默 exit 0
 *   2. 不依赖 server —— 直接读文件，看板没开也能工作
 *   3. 有界的 token 成本 —— 最多 3 张卡，每类最多 8 条
 *
 * 它只保证「送达」，不保证「遵守」。遵守靠的是：注入文本是命令式的，且要求
 * agent 用 cli.mjs ack 留下痕迹——于是不遵守在看板上一眼可见。
 */
import * as store from "../card-store.mjs";

const MAX_CARDS = 3;

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  try {
    const payload = JSON.parse(raw || "{}");
    const prompt = String(payload.prompt || "");
    const re = new RegExp("\\b" + store.ID_PREFIX + "-\\d{3,}\\b", "g");
    const ids = [...new Set(prompt.match(re) || [])].slice(0, MAX_CARDS);
    // 抓不到卡号就退回简报。这不是可有可无的补充——人在看板上勾完关卡、留完言
    // 之后，回到对话说的正是「继续」「可以了」这类不含卡号的话。原先这里直接
    // exit 0，于是人做的每一个动作都掉在地上。
    if (!ids.length) {
      process.stdout.write(store.renderBoardBrief(store.boardBrief()));
      return void process.exit(0);
    }

    const blocks = [];
    for (const id of ids) {
      try {
        const card = store.readCard(id);
        if (card) blocks.push(store.renderCardForAgent(card));
      } catch {
        /* 单张卡坏了就跳过，不影响其余 */
      }
    }
    if (blocks.length) process.stdout.write(blocks.join("\n"));
  } catch {
    /* 静默：hook 出错绝不能挡住用户的话 */
  }
  process.exit(0);
});
