#!/usr/bin/env node
/**
 * 看板 CLI —— agent 的读写入口。
 *
 * 这是「agent 永远不直接改 JSON」得以成立的那一环：读路径是预渲染的纯文本，
 * 写路径是命令动词，所以 agent 从不需要解析或拼装卡片结构，也就不会写出
 * server 会拒绝的东西（比如上游那张 track='fullstack' 的卡）。
 *
 * 用法：
 *   node tools/kanban/cli.mjs show   <ID> [--json]
 *   node tools/kanban/cli.mjs open                       列出在等人 / 等 agent 的卡
 *   node tools/kanban/cli.mjs ack     <ID> <留言id>       确认一条人写的决策
 *   node tools/kanban/cli.mjs resolve <ID> <留言id>       标记为已完成
 *   node tools/kanban/cli.mjs comment <ID> --kind progress|evidence|note|blocker --text "..."
 *   node tools/kanban/cli.mjs ask     <ID> --text "..."   提问，把卡推进 blocked 并停下来等人
 *   node tools/kanban/cli.mjs answer  <ID> --re <留言id> --text "..."
 *   node tools/kanban/cli.mjs stage   <ID> <backlog|blocked|ready|implementing|verify|done>
 *
 * server 没开也能用：走 HTTP 失败就回退到直接读写文件。人不会一直开着看板，
 * 而 agent 撞 ECONNREFUSED 之后要么放弃、要么开始手改 JSON——那正是要消灭的失败模式。
 */
import * as store from "./card-store.mjs";

// 端口与 id 前缀都来自 card-store 的统一配置（config.json），
// 这样 server / cli / hook 三个入口不可能各说各话。
const BASE = "http://127.0.0.1:" + store.PORT;

// agent 身份。解析不出来就报错退出，绝不静默以人的身份发言——那会让人的决策和
// agent 的记录混在一起，而整套设计的前提就是这两者必须分得开。
const AGENT =
  process.env.KANBAN_AGENT || (process.env.CLAUDECODE ? "claude-code" : "");

function die(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

// 这些 flag 一定带值。必须显式列出——否则 `--text "--dry-run 实测…"` 里的值
// 因为以 `--` 开头，会被当成下一个 flag，留言内容整条丢掉（真踩过）。
const VALUE_FLAGS = new Set(["kind", "text", "re", "agent"]);
// 对称的另一半：这些 flag 一定不带值。不列出来的话 `show DASH-001 --json` 没问题，
// 但 `--json DASH-001` 会把卡号当成 --json 的值吃掉，然后报「用法」——
// 错在参数顺序，报出来的却是用法错误，很难看懂。
const BOOL_FLAGS = new Set(["json", "no-block"]);

function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      positional.push(a);
      continue;
    }
    // 支持 --key=value，值里可以随便带 -- 开头的内容
    const eq = a.indexOf("=");
    if (eq > 2) {
      flags[a.slice(2, eq)] = a.slice(eq + 1);
      continue;
    }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (VALUE_FLAGS.has(key)) {
      if (next === undefined) die("--" + key + " 需要一个值");
      flags[key] = next;
      i++;
    } else if (BOOL_FLAGS.has(key)) {
      flags[key] = true;
    } else if (next === undefined || next.startsWith("--")) {
      flags[key] = true;
    } else {
      flags[key] = next;
      i++;
    }
  }
  return { positional, flags };
}

/** 先试 HTTP（这样看板开着时能立刻看到变化），失败就直接操作文件。 */
async function viaHttp(path, opts) {
  const res = await fetch(BASE + path, {
    ...opts,
    headers: { "Content-Type": "application/json", "X-Kanban-Agent": AGENT, ...(opts && opts.headers) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(body.error || res.statusText);
    e.status = res.status;
    e.httpHandled = true; // 服务端明确拒绝了，不要再回退去文件里硬写
    throw e;
  }
  return body;
}

async function withFallback(httpFn, fileFn) {
  try {
    return await httpFn();
  } catch (err) {
    if (err && err.httpHandled) throw err; // 业务拒绝：403/400/409 等，照实报
    return fileFn(); // 连不上（server 没开）→ 直接读写文件
  }
}

function requireCard(id) {
  const c = store.readCard(id);
  if (!c) die("卡片不存在：" + id);
  return c;
}

function saveLocal(card) {
  const err = store.validateCard(card);
  if (err) die("校验失败：" + err);
  store.bumpRev(card);
  store.writeCard(card);
  return card;
}

/* ── 子命令 ── */

const CMDS = {
  async show({ positional, flags }) {
    const id = positional[0];
    if (!id) die("用法：cli.mjs show <ID> [--json]");
    const card = requireCard(id);
    if (flags.json) console.log(JSON.stringify(card, null, 2));
    else process.stdout.write(store.renderCardForAgent(card));
  },

  async open() {
    const rows = store.boardPending();
    if (!rows.length) {
      console.log("看板上没有待处理的人工决策或提问。");
      return;
    }
    console.log("有待处理项的卡片：");
    for (const r of rows) {
      const bits = [];
      if (r.waitingOnAgent) bits.push(r.waitingOnAgent + " 项等你处理");
      if (r.waitingOnHuman) bits.push(r.waitingOnHuman + " 项等人回答");
      console.log("  " + r.card.id + "（" + r.card.stage + "）" + bits.join("，") + " — " + r.card.title);
    }
    console.log("\n处理任何一张之前先跑：node tools/kanban/cli.mjs show <ID>");
  },

  async ack({ positional }) {
    const [id, cid] = positional;
    if (!id || !cid) die("用法：cli.mjs ack <ID> <留言id>");
    if (!AGENT) die("没有 agent 身份：请设 KANBAN_AGENT，否则会被记成人写的留言");
    const out = await withFallback(
      () => viaHttp("/api/cards/" + id + "/comments/" + cid, { method: "PATCH", body: JSON.stringify({ status: "acked" }) }),
      () => {
        const card = requireCard(id);
        const r = store.setCommentStatus(card, cid, "acked", "agent");
        if (r.error) die(r.error);
        saveLocal(card);
        return { comment: r.comment };
      }
    );
    console.log("已确认 " + cid + "（" + out.comment.statusAt + "）");
  },

  async resolve({ positional }) {
    const [id, cid] = positional;
    if (!id || !cid) die("用法：cli.mjs resolve <ID> <留言id>");
    const kind = AGENT ? "agent" : "human";
    const out = await withFallback(
      () => viaHttp("/api/cards/" + id + "/comments/" + cid, { method: "PATCH", body: JSON.stringify({ status: "done" }) }),
      () => {
        const card = requireCard(id);
        const r = store.setCommentStatus(card, cid, "done", kind);
        if (r.error) die(r.error);
        saveLocal(card);
        return { comment: r.comment };
      }
    );
    console.log("已标记完成 " + cid + "（" + out.comment.statusAt + "）");
  },

  async comment({ positional, flags }) {
    const id = positional[0];
    const kind = typeof flags.kind === "string" ? flags.kind : "note";
    const text = typeof flags.text === "string" ? flags.text : "";
    if (!id || !text) die('用法：cli.mjs comment <ID> --kind progress|evidence|note|blocker --text "..."');
    if (kind === "decision") {
      die("agent 不得下决策。请改用 `ask` 提问并停下来等人回答——这是本项目的核心规则。");
    }
    return addComment(id, kind, text);
  },

  async ask({ positional, flags }) {
    const id = positional[0];
    const text = typeof flags.text === "string" ? flags.text : "";
    if (!id || !text) die('用法：cli.mjs ask <ID> --text "..." [--no-block]');
    const out = await addComment(id, "question", text);
    console.log("已提问。**现在停下来，把这个问题带给人，不要自己假设答案。**");

    // 提问 = 停下来等人，所以卡片要跟着进 blocked。不推的话它继续停在
    // implementing：占着 WIP 名额（上限 3）、在看板上看起来像在做，实际在等人。
    // `cli.mjs open` 本来就分得清「等人 / 等 agent」，但人看的是车道，不是 CLI。
    if (flags["no-block"]) {
      console.log("（--no-block：stage 保持不动）");
      return out;
    }
    const cur = requireCard(id).stage;
    if (cur === "blocked") {
      console.log("stage 保持 blocked（已经在等人了）");
      return out;
    }
    if (cur === "done") {
      // 已完成的卡上提问是「事后追问」，不该把它拖回未完成的状态
      console.log("stage 保持 done（已完成的卡不因提问回退，问题仍在卡上等人回答）");
      return out;
    }
    const moved = await setStage(id, "blocked");
    console.log(id + " " + cur + " → blocked（rev " + moved.rev + "）：这张卡在等人回答，不再占着 " + cur + " 的名额");
    return out;
  },

  async answer({ positional, flags }) {
    const id = positional[0];
    const re = typeof flags.re === "string" ? flags.re : "";
    const text = typeof flags.text === "string" ? flags.text : "";
    if (!id || !re || !text) die('用法：cli.mjs answer <ID> --re <留言id> --text "..."');
    return addComment(id, "answer", text, { re });
  },

  async stage({ positional }) {
    const [id, next] = positional;
    if (!id || !next) die("用法：cli.mjs stage <ID> <" + store.STAGES.join("|") + ">");
    if (!store.STAGES.includes(next)) die("stage 只允许 " + store.STAGES.join("/"));
    const out = await setStage(id, next);
    console.log(id + " → " + out.stage + "（rev " + out.rev + "）");
  },
};

/** 推进 stage。抽出来是因为 `ask` 也要用——提问之后卡片得跟着进 blocked。 */
async function setStage(id, next) {
  return withFallback(
    () => viaHttp("/api/cards/" + id, { method: "PATCH", body: JSON.stringify({ stage: next }) }),
    () => {
      const cards = store.readAllCards();
      const map = new Map(cards.map((x) => [x.id, x]));
      const card = map.get(id);
      if (!card) die("卡片不存在：" + id);
      const prev = { ...card };   // card 是原地改的，旧 stage 得先留一份
      card.stage = next;
      const depErr = store.checkDependsOn(card, map, prev);
      if (depErr) die(depErr);
      return saveLocal(card);
    }
  );
}

async function addComment(id, kind, text, extra = {}) {
  const out = await withFallback(
    () => viaHttp("/api/cards/" + id + "/comments", { method: "POST", body: JSON.stringify({ kind, text, ...extra }) }),
    () => {
      const card = requireCard(id);
      const actor = store.resolveActor(AGENT, "");
      if (actor.authorKind === "human" && !AGENT) {
        die("没有 agent 身份：请设 KANBAN_AGENT，否则这条留言会被记成人写的");
      }
      const r = store.appendComment(card, { kind, text, actor, ...extra });
      if (r.error) die(r.error);
      saveLocal(card);
      return { comment: r.comment, rev: card.rev };
    }
  );
  console.log("已写入 " + out.comment.kind + " " + out.comment.id);
  return out;
}

/* ── 入口 ── */

const [cmd, ...rest] = process.argv.slice(2);
if (!cmd || cmd === "-h" || cmd === "--help" || !CMDS[cmd]) {
  console.log(
    [
      "看板 CLI —— agent 的读写入口",
      "",
      "  show    <ID> [--json]                     读卡（含生效中的人工决策）",
      "  open                                      列出在等人 / 等 agent 的卡",
      "  ack     <ID> <留言id>                      确认一条人写的决策",
      "  resolve <ID> <留言id>                      标记为已完成",
      '  comment <ID> --kind progress|evidence|note|blocker --text "..."',
      '  ask     <ID> --text "..." [--no-block]    提问 → 卡片进 blocked → 停下来等人',
      '  answer  <ID> --re <留言id> --text "..."',
      "  stage   <ID> <" + store.STAGES.join("|") + ">",
      "",
      "身份：KANBAN_AGENT（Claude Code 下自动为 claude-code）",
      "端口：KANBAN_PORT（默认 4430）；server 没开时自动回退到直接读写文件",
    ].join("\n")
  );
  process.exit(cmd && !CMDS[cmd] ? 1 : 0);
}

CMDS[cmd](parseArgs(rest)).catch((err) => {
  die(err && err.message ? err.message : String(err));
});
