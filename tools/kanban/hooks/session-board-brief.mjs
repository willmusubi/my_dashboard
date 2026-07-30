#!/usr/bin/env node
/**
 * Claude Code SessionStart hook。
 *
 * 会话开始时报告哪些卡在等人、哪些在等 agent。这是「用户说『继续』而没提卡号」
 * 那个漏洞的部分弥补——UserPromptSubmit hook 靠正则抓 ID，抓不到就什么也不注入。
 *
 * 看板干净时**不输出任何东西**，所以安静时的 token 成本真的是零。
 * 任何异常都静默 exit 0。
 */
import * as store from "../card-store.mjs";

try {
  const rows = store.boardPending();
  if (rows.length) {
    const lines = rows.map((r) => {
      const bits = [];
      if (r.waitingOnAgent) bits.push(r.waitingOnAgent + " 条人工决策/提问待你确认");
      if (r.waitingOnHuman) bits.push(r.waitingOnHuman + " 条你的提问等人回答");
      return "  " + r.card.id + "（" + r.card.stage + "）" + bits.join("；") + " — " + r.card.title;
    });
    process.stdout.write(
      "<kanban-brief>\n看板上有 " + rows.length + " 张卡有待处理的人工项：\n" +
        lines.join("\n") +
        "\n处理任何一张卡之前，先执行 `node tools/kanban/cli.mjs show <ID>`。\n" +
        "</kanban-brief>\n"
    );
  }
} catch {
  /* 静默 */
}
process.exit(0);
