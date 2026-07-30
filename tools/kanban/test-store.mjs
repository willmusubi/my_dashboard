/**
 * card-store.mjs 的单元测试（不经 HTTP）。
 *
 *   KANBAN_CARDS_DIR=$(mktemp -d) node tools/kanban/test-store.mjs
 *
 * 必须注入 KANBAN_CARDS_DIR，否则会写到真实 cards/。开头有断言挡着。
 */
import fs from "node:fs";
import path from "node:path";
import * as store from "./card-store.mjs";

if (!process.env.KANBAN_CARDS_DIR) {
  console.error("必须设 KANBAN_CARDS_DIR，否则会写到真实卡片目录");
  process.exit(1);
}

let pass = 0,
  fail = 0;
const ok = (m) => {
  console.log("  ✅ " + m);
  pass++;
};
const no = (m, got) => {
  console.log("  ❌ " + m + "\n     got: " + JSON.stringify(got));
  fail++;
};
const eq = (m, a, b) => (JSON.stringify(a) === JSON.stringify(b) ? ok(m) : no(m, a));
const truthy = (m, v) => (v ? ok(m) : no(m, v));

function blank(id = store.formatId(1)) {
  return store.fillDefaults({
    id,
    title: "测试卡",
    stage: "backlog",
    risk: "low",
    owner: "liutong",
    createdAt: store.todayStr(),
    order: 1,
  });
}
const HUMAN = { author: "liutong", authorKind: "human" };
const AGENT = { author: "claude-code", authorKind: "agent" };

console.log("── comment schema ──");
{
  const c = blank();
  const { comment } = store.appendComment(c, {
    kind: "decision",
    text: "侧边栏改成可收合，不要用 drawer。",
    actor: HUMAN,
  });
  truthy("id 符合 c-YYYYMMDDTHHMMSS-xxxx", store.COMMENT_ID_RE.test(comment.id));
  truthy("at 是可解析的 ISO 且带时区", /[+-]\d{2}:\d{2}$/.test(comment.at));
  eq("人写的 decision 默认 status=open", comment.status, "open");
  eq("authorKind=human", comment.authorKind, "human");
  eq("字段集合与 COMMENT_KEYS 一致", Object.keys(comment).sort(), [...store.COMMENT_KEYS].sort());
  eq("schema 校验通过", store.validateCard(c), null);
}

console.log("── 核心授权规则：agent 不得下决策 ──");
{
  const c = blank();
  const r = store.appendComment(c, { kind: "decision", text: "我说了算", actor: AGENT });
  truthy("appendComment 拒绝 agent 写 decision", !!r.error);
  eq("卡上没有留下任何留言", c.comments.length, 0);

  // 就算绕过 appendComment 手塞进去，validateCard 也要兜住
  c.comments.push({
    id: "c-20260730T120000-aaaa",
    at: store.isoNow(),
    author: "claude-code",
    authorKind: "agent",
    kind: "decision",
    status: "open",
    statusAt: store.isoNow(),
    re: null,
    supersedes: [],
    text: "手塞的",
  });
  truthy("validateCard 兜底拒绝 agent 的 decision", !!store.validateCard(c));
}

console.log("── agent 能写的类型 ──");
{
  const c = blank();
  for (const k of ["progress", "evidence", "question", "note", "blocker"]) {
    const r = store.appendComment(c, { kind: k, text: "x " + k, actor: AGENT });
    truthy("agent 可写 kind=" + k, !!r.comment);
  }
  const byKind = Object.fromEntries(c.comments.map((x) => [x.kind, x.status]));
  eq("question 默认 open（需后续处理）", byKind.question, "open");
  eq("blocker 默认 open", byKind.blocker, "open");
  eq("progress 默认 done（纯信息）", byKind.progress, "done");
  eq("evidence 默认 done", byKind.evidence, "done");
  eq("note 默认 done", byKind.note, "done");
}

console.log("── supersedes：新决策让旧决策失效 ──");
{
  const c = blank();
  const a = store.appendComment(c, { kind: "decision", text: "用 modal", actor: HUMAN }).comment;
  const b = store.appendComment(c, {
    kind: "decision",
    text: "改用 drawer",
    actor: HUMAN,
    supersedes: [a.id],
  }).comment;
  eq("旧决策变 superseded", c.comments.find((x) => x.id === a.id).status, "superseded");
  eq("新决策是 open", b.status, "open");
  const live = store.liveHumanItems(c, "decision");
  eq("生效中的决策只剩 1 条", live.length, 1);
  eq("且是新那条", live[0].id, b.id);
  eq("schema 仍合法", store.validateCard(c), null);
}

console.log("── answer 关闭 question ──");
{
  const c = blank();
  const q = store.appendComment(c, { kind: "question", text: "手机版要不要保留 drawer？", actor: AGENT }).comment;
  eq("提问初始 open", q.status, "open");
  store.appendComment(c, { kind: "answer", text: "保留", actor: HUMAN, re: q.id });
  eq("被回答后变 done", c.comments.find((x) => x.id === q.id).status, "done");
}

console.log("── status 转换权限 ──");
{
  const c = blank();
  const d = store.appendComment(c, { kind: "decision", text: "决策", actor: HUMAN }).comment;
  truthy("人不能把自己的决策标成 acked（没有意义）", !!store.setCommentStatus(c, d.id, "acked", "human").error);
  truthy("agent 可以 acked", !!store.setCommentStatus(c, d.id, "acked", "agent").comment);
  eq("acked 后仍属于生效中（agent 已确认但事情没完）", store.liveHumanItems(c, "decision").length, 1);
  truthy("agent 不能把 status 重开为 open", !!store.setCommentStatus(c, d.id, "open", "agent").error);
  truthy("人可以重开", !!store.setCommentStatus(c, d.id, "open", "human").comment);
  truthy("superseded 不可直接设置", !!store.setCommentStatus(c, d.id, "superseded", "human").error);
  truthy("statusAt 跟着更新", /[+-]\d{2}:\d{2}$/.test(c.comments.find((x) => x.id === d.id).statusAt));
}

console.log("── 引用完整性 ──");
{
  const c = blank();
  const d = store.appendComment(c, { kind: "decision", text: "x", actor: HUMAN }).comment;
  d.supersedes = ["c-20260730T120000-ffff"];
  truthy("supersedes 指向不存在的留言 → 拒绝", !!store.validateCard(c));
  d.supersedes = [d.id];
  truthy("supersedes 包含自己 → 拒绝", !!store.validateCard(c));
  d.supersedes = [];
  d.re = "c-20260730T120000-eeee";
  truthy("re 指向不存在的留言 → 拒绝", !!store.validateCard(c));
}

console.log("── 旧格式迁移 ──");
{
  const raw = {
    id: store.formatId(2),
    title: "旧卡",
    stage: "backlog",
    risk: "low",
    owner: "liutong",
    createdAt: "2026-07-03",
    order: 1,
    comments: [
      { name: "claude", time: "07-03 13:58", text: "三案已由用户拍板，实装完毕。" },
      { name: "claude", time: "乱码时间", text: "第二条" },
    ],
  };
  const c = store.fillDefaults(raw);
  eq("旧留言一律降为 note", c.comments.map((x) => x.kind), ["note", "note"]);
  eq("且 status=done —— 不得回溯升格为生效中的决策", c.comments.map((x) => x.status), ["done", "done"]);
  truthy("time 被转成带时区的 ISO", /^2026-07-03T13:58:00[+-]\d{2}:\d{2}$/.test(c.comments[0].at));
  truthy("解析不出的时间也能得到合法 ISO", !Number.isNaN(Date.parse(c.comments[1].at)));
  truthy("补出的 id 合法且不重复", c.comments[0].id !== c.comments[1].id);
  eq("迁移后 schema 合法", store.validateCard(c), null);
  eq("生效中的人工决策为 0（旧留言不算）", store.liveHumanItems(c, "decision").length, 0);
}

console.log("── 未知字段：报错而不是静默丢弃 ──");
{
  const c = blank();
  c.someNewField = "手加的";
  const err = store.validateCard(c);
  truthy("卡片未知字段 → 400 级错误", err && err.includes("未知字段"));
  delete c.someNewField;
  store.appendComment(c, { kind: "note", text: "x", actor: HUMAN });
  c.comments[0].extra = 1;
  truthy("留言未知字段 → 报错", !!store.validateCard(c));
}

console.log("── 必需关卡的判定（gates 分母不是固定的 6）──");
{
  const mk = (risk, track) => store.fillDefaults({
    id: store.formatId(3), title: "x", stage: "backlog", risk, track,
    owner: "liutong", createdAt: store.todayStr(), order: 1,
  });

  eq("低风险后端卡 → 只需 product/test/code_review",
    store.requiredGates(mk("low", "backend")), ["product", "test", "code_review"]);
  eq("低风险前端卡 → 加上 ui",
    store.requiredGates(mk("low", "frontend")), ["product", "ui", "test", "code_review"]);
  eq("fullstack 视为含前端",
    store.requiredGates(mk("low", "fullstack")), ["product", "ui", "test", "code_review"]);
  eq("高风险 → 加上 architecture/security",
    store.requiredGates(mk("high", "backend")),
    ["product", "architecture", "security", "test", "code_review"]);
  eq("高风险前端 → 六项全需要",
    store.requiredGates(mk("high", "frontend")), [...store.GATE_KEYS]);
  eq("返回顺序与 GATE_KEYS 一致（界面按固定顺序渲染）",
    store.requiredGates(mk("high", "frontend")), [...store.GATE_KEYS]);

  eq("product 只有人能批", store.gateOwner(mk("low", "backend"), "product"), "human");
  eq("ui 只有人能批", store.gateOwner(mk("low", "frontend"), "ui"), "human");
  eq("低风险的 architecture 归 agent", store.gateOwner(mk("low", "backend"), "architecture"), "agent");
  eq("高风险的 architecture 需要人", store.gateOwner(mk("high", "backend"), "architecture"), "human");
  eq("高风险的 security 需要人", store.gateOwner(mk("high", "backend"), "security"), "human");
  eq("test 始终归 agent", store.gateOwner(mk("high", "backend"), "test"), "agent");

  // 复现用户看到的那张卡：medium + frontend，已勾 ui/test/code_review
  const c = mk("medium", "frontend");
  c.gates.ui = true; c.gates.test = true; c.gates.code_review = true;
  const gp = store.gateProgress(c);
  eq("DASH-002 那种卡：分母是 4 不是 6", gp.required.length, 4);
  eq("已过 3 项", gp.done.length, 3);
  eq("差的是 product（而且只有人能批）", gp.missing, ["product"]);
  eq("差的那项归属人", store.gateOwner(c, gp.missing[0]), "human");

  // 勾了不必需的关卡不该让分母变大
  c.gates.security = true;
  eq("额外勾了非必需的 security，分母仍是 4", store.gateProgress(c).required.length, 4);
  eq("分子也不受影响", store.gateProgress(c).done.length, 3);

  // agent 看到的文本要说清楚谁该做什么
  const txt = store.renderCardForAgent(c);
  truthy("renderCardForAgent 显示 3/4", txt.includes("审查关卡 3/4"));
  truthy("并提示 product 要等人批、不要自己勾", /等人批（不要自己勾）：product/.test(txt));
}

console.log("── 原子写 ──");
{
  const c = blank(store.formatId(9));
  store.appendComment(c, { kind: "decision", text: "落盘测试", actor: HUMAN });
  store.writeCard(c);
  const file = path.join(store.CARDS_DIR, c.id + ".json");
  truthy("卡片文件已生成", fs.existsSync(file));
  eq("没有残留 .tmp 文件", fs.readdirSync(store.CARDS_DIR).filter((f) => f.includes(".tmp")), []);
  const onDisk = JSON.parse(fs.readFileSync(file, "utf8"));
  eq("字段顺序由 CARD_KEYS 固定（git diff 友好）", Object.keys(onDisk), [...store.CARD_KEYS]);
  eq("留言字段顺序由 COMMENT_KEYS 固定", Object.keys(onDisk.comments[0]), [...store.COMMENT_KEYS]);
  truthy("文件以换行结尾", fs.readFileSync(file, "utf8").endsWith("\n"));
  eq("回读后 schema 合法", store.validateCard(store.readCard(c.id)), null);
}

console.log("\n通过 " + pass + "，失败 " + fail);
process.exit(fail === 0 ? 0 : 1);
