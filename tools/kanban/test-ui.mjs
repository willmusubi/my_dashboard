/**
 * 看板前端的行为级测试（Playwright，真浏览器）。
 *
 *   node tools/kanban/test-ui.mjs
 *
 * 为什么单独一个文件、而且是**可选**的：
 * 这个 kit 的承诺是「零依赖（只用 Node 内建模块）」——install-into-project.sh 不跑
 * npm install，装进任何项目都不带 node_modules。所以 playwright 只进
 * devDependencies，test.sh 检测不到就跳过这一段并响亮说明（决策见 DASH-051）。
 *
 * 它补的是结构断言补不了的那一半。DASH-048 那个「送出后草稿又冒出来」的 bug
 * 就是人工点浏览器抓到的，当时结构断言全绿——正则看得见代码在不在，看不见
 * 点下去之后 DOM 变成什么样。
 *
 * 自带 server 与独立的 cards 目录：绝不碰真实卡片。
 */
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.KANBAN_UI_TEST_PORT) || 4498;
const BASE = "http://127.0.0.1:" + PORT;

let pass = 0, fail = 0;
const ok = (m) => { console.log("  ✅ " + m); pass++; };
const no = (m, got) => { console.log("  ❌ " + m + "\n     got: " + JSON.stringify(got)); fail++; };
const eq = (m, a, b) => (JSON.stringify(a) === JSON.stringify(b) ? ok(m) : no(m, a));
const truthy = (m, v) => (v ? ok(m) : no(m, v));

const CARDS = fs.mkdtempSync(path.join(os.tmpdir(), "kanban-ui-"));
const api = (p, init) => fetch(BASE + p, init).then((r) => r.json());
const post = (body) =>
  api("/api/cards", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
const comment = (id, body) =>
  api("/api/cards/" + id + "/comments", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(body.agent ? { "x-kanban-agent": body.agent } : {}) },
    body: JSON.stringify(body),
  });
const readCard = (id) => JSON.parse(fs.readFileSync(path.join(CARDS, id + ".json"), "utf8"));

/** 打开某张卡的详情面板。看板车道里的卡片是 .ticket-card[data-id]。 */
async function openCard(page, id) {
  await page.locator('.ticket-card[data-id="' + id + '"]').click();
  await page.waitForSelector("#new-comment", { state: "visible" });
}
const closeModal = async (page) => {
  await page.keyboard.press("Escape");
  await page.waitForSelector("#new-comment", { state: "hidden" });
};

const server = spawn("node", [path.join(HERE, "server.mjs")], {
  env: { ...process.env, KANBAN_CARDS_DIR: CARDS, KANBAN_PORT: String(PORT) },
  stdio: "ignore",
});
const cleanup = () => {
  server.kill();
  fs.rmSync(CARDS, { recursive: true, force: true });
};
process.on("exit", cleanup);

// 等 server 起来。轮询而不是 sleep 一个定数——CI 上慢起来能等，本机快就不白等。
for (let i = 0; i < 50; i++) {
  try { await api("/api/config"); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
}

const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(BASE);

try {
  /* ── DASH-040：人在界面上回答 agent 的提问 ── */
  console.log("── 回答按钮：人答完，那条提问要关掉 ──");
  {
    const a = await post({ title: "UI 测试：回答按钮", stage: "backlog" });
    const q = await comment(a.id, { kind: "question", text: "要用方案 A 还是 B？", agent: "test-agent" });
    await page.reload();
    await openCard(page, a.id);

    const btn = page.locator('[data-answer="' + q.comment.id + '"]');
    eq("agent 的 open 提问下出现「回答」按钮", await btn.count(), 1);
    await btn.click();
    truthy("进入回答模式（kind 按钮换成「回答提问 …」）",
      await page.locator(".answering").isVisible());

    await page.fill("#new-comment", "用方案 B。");
    await page.click("#add-comment");
    await page.waitForFunction(
      (id) => fetch("/api/cards").then((r) => r.json()).then((d) =>
        d.find((c) => c.id === id).comments.some((x) => x.kind === "answer")), a.id);

    const card = readCard(a.id);
    const answer = card.comments.find((c) => c.kind === "answer");
    eq("送出的是 answer 且 re 指向那条提问", [answer.kind, answer.re], ["answer", q.comment.id]);
    eq("人写的 answer 默认 open（等 agent 读）", answer.status, "open");
    eq("那条提问被关掉", card.comments.find((c) => c.id === q.comment.id).status, "done");
    await closeModal(page);
  }

  /* ── DASH-044：模式状态不得跨卡泄漏 ── */
  console.log("── 取代模式：点了不送出就关掉，不能跟到下一张卡 ──");
  {
    const A = await post({ title: "UI 测试：A 卡", stage: "backlog" });
    const B = await post({ title: "UI 测试：B 卡", stage: "backlog" });
    const d = await comment(A.id, { kind: "decision", text: "A 卡上的一条决策" });
    await page.reload();

    await openCard(page, A.id);
    await page.locator('[data-supersede="' + d.comment.id + '"]').click();
    truthy("A 卡进入取代模式", await page.locator(".superseding").isVisible());
    await closeModal(page);                       // 关键：不送出，直接关掉

    await openCard(page, B.id);
    eq("B 卡没有残留的取代标记", await page.locator(".superseding").count(), 0);
    await page.fill("#new-comment", "我选的是「留言」");
    await page.click("#add-comment");
    await page.waitForFunction(
      (id) => fetch("/api/cards").then((r) => r.json()).then((d2) =>
        d2.find((c) => c.id === id).comments.length > 0), B.id);

    /* 断言要能在失败时活着走完，不能崩——崩了会掩盖后面所有测试。
       泄漏时这里存的其实是「什么都没有」：kind 被改成 decision 且带一个 B 卡上
       不存在的 supersedes id，validateCard 的引用完整性检查会整条拒掉（400），
       人看到的是送出失败。所以失败信息要能区分「存错了」和「根本没存进去」。 */
    const bcs = readCard(B.id).comments;
    eq("B 卡存的是 note，supersedes 为空",
      bcs.length ? [bcs[0].kind, bcs[0].supersedes] : "整条被服务端拒绝，什么都没存",
      ["note", []]);
    const acs = readCard(A.id).comments;
    eq("A 卡那条决策没被取代", acs.length ? acs[0].status : "A 卡没有留言", "open");
    await closeModal(page);
  }

  /* ── DASH-048：留言草稿 ── */
  console.log("── 留言草稿：重绘、切卡、关卡都不能把字弄丢 ──");
  {
    const X = await post({ title: "UI 测试：草稿 X", stage: "backlog" });
    const Y = await post({ title: "UI 测试：草稿 Y", stage: "backlog" });
    await page.reload();
    const DRAFT = "这段字不能消失";

    await openCard(page, X.id);
    await page.fill("#new-comment", DRAFT);
    // 勾一个 readiness → 走 reopenModal 重绘，textarea 是重新生成的
    await page.locator('input[data-field="readiness.problem_clear"]').click();
    await page.waitForFunction(() => {
      const el = document.querySelector('input[data-field="readiness.problem_clear"]');
      return el && el.checked;
    });
    eq("勾字段重绘后草稿还在", await page.inputValue("#new-comment"), DRAFT);

    await closeModal(page);
    await openCard(page, Y.id);
    eq("切到另一张卡是空的（草稿不跨卡）", await page.inputValue("#new-comment"), "");
    await closeModal(page);

    await openCard(page, X.id);
    eq("切回来草稿还在", await page.inputValue("#new-comment"), DRAFT);
    // 只恢复文本、不恢复模式，才不会把上一次的 supersedes/re 带进来
    eq("恢复的是纯文本，kind 回到默认「留言」",
      await page.locator(".kind-pick .is-picked").getAttribute("data-kind"), "note");

    await page.click("#add-comment");
    await page.waitForFunction(
      (id) => fetch("/api/cards").then((r) => r.json()).then((d) =>
        d.find((c) => c.id === id).comments.length > 0), X.id);
    await closeModal(page);
    await openCard(page, X.id);
    // 只 delete drafts 而不清 DOM 的话，紧接着的 reopenModal 会把它原样存回去
    eq("送出后草稿清掉了，重开是空的", await page.inputValue("#new-comment"), "");
    await closeModal(page);
  }

  /* ── DASH-047：Epic 序号 ── */
  console.log("── 蓝图：Epic 序号等于它在 epics.json 里的位置 ──");
  {
    const epics = (await api("/api/epics")).epics || [];
    if (!epics.length) {
      console.log("  ⏭  跳过：epics.json 里没有 Epic");
    } else {
      await page.reload();
      await page.locator('[data-view="roadmap"]').click();
      await page.waitForSelector(".epic-card");
      const nums = await page.locator(".epic-num").allTextContents();
      eq("每个 Epic 都有序号，且等于数组下标",
        nums, epics.map(function (_, i) { return String(i); }));
    }
  }
} finally {
  await browser.close();
}

console.log("\n前端行为测试：通过 " + pass + "，失败 " + fail);
cleanup();
process.exit(fail ? 1 : 0);
