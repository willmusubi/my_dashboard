/**
 * 治理看板 — 零依赖本地 server。
 *
 * 启动：node tools/kanban/server.mjs（或 npm run kanban）
 * 数据层在 card-store.mjs —— server 与 cli.mjs 共用同一套 schema 与校验，
 * 所以「agent 走 CLI」和「人在浏览器里改」受同一批不变量约束。
 *
 * 环境变量：
 *   KANBAN_PORT        端口，默认 4430
 *   KANBAN_CARDS_DIR   数据目录，默认 ./cards（回归测试指向临时目录）
 *   KANBAN_ID_PREFIX   卡片 id 前缀，默认 DASH
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import * as store from "./card-store.mjs";

const HOST = "127.0.0.1";
// 可用 KANBAN_PORT 覆写：平行项目很多时，同时开两块看板不会撞端口。
const PORT = Number(process.env.KANBAN_PORT) || 4430;

const HERE = import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname);
const INDEX_HTML = path.join(HERE, "index.html");

fs.mkdirSync(store.CARDS_DIR, { recursive: true });

// 新卡 owner 与看板留言作者的默认值：取本机 git 身份（这个看板本来就以 git
// 为同步机制），没有 git 或没设 user.name 时留空（未指派）。
const DEFAULT_OWNER = (() => {
  try {
    return execSync("git config user.name", {
      cwd: HERE,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
})();

/* ── helpers ── */

function sendJson(res, code, obj, extraHeaders) {
  const body = JSON.stringify(obj);
  const headers = { "Content-Type": "application/json; charset=utf-8" };
  if (extraHeaders) Object.assign(headers, extraHeaders);
  res.writeHead(code, headers);
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

/**
 * 乐观锁。If-Match 带的是客户端手上那份的 rev；对不上，说明它读到之后有人
 * （多半是 agent）改过这张卡，直接覆盖就会静默丢掉那次改动。
 * 不带 If-Match 的请求放行，保持对旧客户端与手写 curl 的兼容。
 */
function checkPrecondition(req, current) {
  const raw = req.headers["if-match"];
  if (raw === undefined) return null;
  const want = parseInt(String(raw).replace(/"/g, ""), 10);
  if (want === current.rev) return null;
  return {
    error:
      current.id + " 已被改动（你手上是 rev " + want + "，磁盘上是 rev " +
      current.rev + "）。请重新载入后重做这次修改。",
    conflict: true,
    rev: current.rev,
  };
}

/** agent 身份来自 X-Kanban-Agent header（或 body.agent）。不是安全边界——
 *  单机没有对手——目的只有一个：不要把 agent 的留言记成人写的。 */
function actorOf(req, input) {
  const name = String(req.headers["x-kanban-agent"] || (input && input.agent) || "").trim();
  return store.resolveActor(name, DEFAULT_OWNER);
}

/* ── route handlers ── */

function handleList(res) {
  sendJson(res, 200, store.readAllCards());
}

function handleEpics(res) {
  const epics = store.readEpics();
  if (epics.error) return sendJson(res, 500, { error: "读取 epics.json 失败：" + epics.error });
  sendJson(res, 200, epics);
}

function handlePutOne(req, res, id, body) {
  const incoming = JSON.parse(body);
  if (!store.isPlainObject(incoming)) {
    return sendJson(res, 400, { error: "body 必须是完整 card object" });
  }
  if (incoming.id !== id) return sendJson(res, 400, { error: "body 的 id 与 URL 不一致" });

  const cardMap = new Map(store.readAllCards().map((x) => [x.id, x]));
  const current = cardMap.get(id);
  if (!current) return sendJson(res, 404, { error: id + " 不存在" });

  const conflict = checkPrecondition(req, current);
  if (conflict) return sendJson(res, 409, conflict);

  // rev / createdAt / comments 一律以磁盘版本为准，客户端说了不算。
  // comments 只能经 append-only 端点写入 —— 这样「人在浏览器拖卡」就不可能
  // 洗掉 agent 200ms 前贴的留言。
  const c = store.fillDefaults({
    ...incoming,
    rev: current.rev,
    createdAt: current.createdAt,
    comments: current.comments,
  });
  const err = store.validateCard(c);
  if (err) return sendJson(res, 400, { error: err });
  cardMap.set(c.id, c);
  const depErr = store.checkDependsOn(c, cardMap);
  if (depErr) return sendJson(res, 400, { error: depErr });
  store.bumpRev(c);
  store.writeCard(c);
  sendJson(res, 200, c, { ETag: String(c.rev) });
}

function handlePutBulk(res, body) {
  const list = JSON.parse(body);
  if (!Array.isArray(list)) return sendJson(res, 400, { error: "body 必须是 card 数组" });
  const cardMap = new Map(store.readAllCards().map((x) => [x.id, x]));

  // 先比对 rev，且必须在 fillDefaults 之前——fillDefaults 会给缺 rev 的卡补
  // rev=1，之后就分不清「客户端没带 rev」和「客户端带的是 1」。
  const stale = [];
  for (const c of list) {
    const cur = store.isPlainObject(c) ? cardMap.get(c.id) : null;
    if (cur && Number.isInteger(c.rev) && c.rev !== cur.rev) stale.push(c.id);
  }
  if (stale.length) {
    return sendJson(res, 409, {
      error: "这些卡片已被改动：" + stale.join("、") + "。请重新载入后重做这次拖拽。",
      conflict: true,
      stale,
    });
  }

  const prepared = [];
  for (const c of list) {
    const cur = store.isPlainObject(c) ? cardMap.get(c.id) : null;
    const merged = store.fillDefaults(
      cur ? { ...c, rev: cur.rev, createdAt: cur.createdAt, comments: cur.comments } : c
    );
    const err = store.validateCard(merged);
    if (err) return sendJson(res, 400, { error: (c && c.id ? c.id + ": " : "") + err });
    prepared.push(merged);
  }
  for (const c of prepared) cardMap.set(c.id, c);
  for (const c of prepared) {
    const depErr = store.checkDependsOn(c, cardMap);
    if (depErr) return sendJson(res, 400, { error: depErr });
  }
  for (const c of prepared) {
    store.bumpRev(c);
    store.writeCard(c);
  }
  sendJson(res, 200, { updated: prepared.length, cards: prepared });
}

function handlePost(res, body) {
  const input = JSON.parse(body);
  if (!store.isPlainObject(input)) return sendJson(res, 400, { error: "body 必须是 object" });
  const existing = store.readAllCards();
  const num = store.nextIdNumber(existing);
  const stage = store.STAGES.includes(input.stage) ? input.stage : "backlog";
  const inColumn = existing.filter((c) => c.stage === stage);
  const card = store.fillDefaults({
    id: store.formatId(num),
    title: typeof input.title === "string" ? input.title.trim() : "",
    content: typeof input.content === "string" ? input.content : "",
    stage,
    risk: store.RISKS.includes(input.risk) ? input.risk : "low",
    owner: typeof input.owner === "string" ? input.owner : DEFAULT_OWNER,
    agent: typeof input.agent === "string" ? input.agent : "",
    approvalRequired: !!input.approvalRequired,
    createdAt: store.todayStr(),
    epic: typeof input.epic === "string" ? input.epic : "",
    userStory: typeof input.userStory === "string" ? input.userStory : "",
    track: store.TRACKS.includes(input.track) ? input.track : "n/a",
    dependsOn: Array.isArray(input.dependsOn) ? input.dependsOn : [],
    // 不能用 inColumn.length + 1：删掉车道中间的卡后会撞号，排序退化到
    // id.localeCompare，顺序变随机且每次拖拽都重写文件制造 git 噪音。
    order: inColumn.reduce((m, c) => Math.max(m, c.order || 0), 0) + 1,
    readiness: input.readiness,
    gates: input.gates,
    links: input.links,
    refs: Array.isArray(input.refs) ? input.refs : [],
    evidence: input.evidence,
    comments: [],
  });
  const err = store.validateCard(card);
  if (err) return sendJson(res, 400, { error: err });
  const cardMap = new Map(existing.map((x) => [x.id, x]));
  cardMap.set(card.id, card);
  const depErr = store.checkDependsOn(card, cardMap);
  if (depErr) return sendJson(res, 400, { error: depErr });
  store.writeCard(card);
  store.writeSeq(num);
  sendJson(res, 201, card, { ETag: String(card.rev) });
}

/**
 * POST /api/cards/:id/comments —— 只追加。
 * 整卡 PUT 不再接受 comments，所以这是唯一的写入口。好处是「人在浏览器拖卡」
 * 和「agent 贴留言」不再竞争同一份数据：前者永远不碰 comments 数组。
 */
function handleAddComment(req, res, id, body) {
  const input = JSON.parse(body);
  if (!store.isPlainObject(input)) return sendJson(res, 400, { error: "body 必须是 object" });
  const card = store.readCard(id);
  if (!card) return sendJson(res, 404, { error: id + " 不存在" });

  const actor = actorOf(req, input);
  const r = store.appendComment(card, {
    kind: input.kind,
    text: input.text,
    actor,
    re: input.re,
    supersedes: input.supersedes,
  });
  // agent 试图下决策 → 403（不是 400）：这是权限问题，不是格式问题。
  if (r.error) {
    const code = /只能由人工|不得撰写/.test(r.error) ? 403 : 400;
    return sendJson(res, code, { error: r.error });
  }

  const err = store.validateCard(card);
  if (err) return sendJson(res, 400, { error: err });
  store.bumpRev(card);
  store.writeCard(card);
  sendJson(res, 201, { comment: r.comment, rev: card.rev }, { ETag: String(card.rev) });
}

/** PATCH /api/cards/:id/comments/:cid —— 只允许改 status，别的一概不动。
 *  留言文本不可变是并发处理变平凡的原因，别在这里开后门。 */
function handlePatchComment(req, res, id, cid, body) {
  const input = JSON.parse(body);
  if (!store.isPlainObject(input)) return sendJson(res, 400, { error: "body 必须是 object" });
  const extra = Object.keys(input).filter((k) => k !== "status" && k !== "agent");
  if (extra.length) {
    return sendJson(res, 400, {
      error: "只允许改 status，收到了：" + extra.join("、") + "（要修正内容请发一条新留言并用 supersedes）",
    });
  }
  const card = store.readCard(id);
  if (!card) return sendJson(res, 404, { error: id + " 不存在" });

  const actor = actorOf(req, input);
  const r = store.setCommentStatus(card, cid, input.status, actor.authorKind);
  if (r.error) {
    const code = /只能由/.test(r.error) ? 403 : 400;
    return sendJson(res, code, { error: r.error });
  }
  store.bumpRev(card);
  store.writeCard(card);
  sendJson(res, 200, { comment: r.comment, rev: card.rev }, { ETag: String(card.rev) });
}

/**
 * PATCH /api/cards/:id —— 稀疏更新。agent 只想推进一个 stage 时不必送整张卡，
 * 于是它无法覆盖它没打算改的字段。依赖门禁照常生效。
 */
function handlePatchCard(req, res, id, body) {
  const patch = JSON.parse(body);
  if (!store.isPlainObject(patch)) return sendJson(res, 400, { error: "body 必须是 object" });

  const cardMap = new Map(store.readAllCards().map((x) => [x.id, x]));
  const current = cardMap.get(id);
  if (!current) return sendJson(res, 404, { error: id + " 不存在" });

  const conflict = checkPrecondition(req, current);
  if (conflict) return sendJson(res, 409, conflict);

  // comments 只能经 append-only 端点写；id/rev/createdAt 不可改。
  const { comments, id: _i, rev: _r, createdAt: _c, agent: patchAgent, ...rest } = patch;
  const merged = store.fillDefaults({ ...current, ...rest });
  if (typeof patchAgent === "string" && "agent" in patch) merged.agent = patchAgent;

  const err = store.validateCard(merged);
  if (err) return sendJson(res, 400, { error: err });
  cardMap.set(merged.id, merged);
  const depErr = store.checkDependsOn(merged, cardMap);
  if (depErr) return sendJson(res, 400, { error: depErr });
  store.bumpRev(merged);
  store.writeCard(merged);
  sendJson(res, 200, merged, { ETag: String(merged.rev) });
}

function handleDelete(res, id) {
  if (!store.deleteCardFile(id)) return sendJson(res, 404, { error: id + " 不存在" });

  // 清掉其他卡对它的 dependsOn 引用。上游不做这件事，后果是连锁的：
  // checkDependsOn 硬拒任何引用不存在卡片的 PUT，modal 又没有 dependsOn
  // 编辑器，而拖拽走的是整批拒绝的 handlePutBulk —— 净效果是一个悬空引用
  // 让两条车道彻底拖不动，只能手改 JSON 才能救回来。
  const cleaned = [];
  for (const c of store.readAllCards()) {
    if (!c.dependsOn.includes(id)) continue;
    c.dependsOn = c.dependsOn.filter((d) => d !== id);
    store.bumpRev(c);
    store.writeCard(c);
    cleaned.push(c.id);
  }
  sendJson(res, 200, { deleted: id, dependsOnCleaned: cleaned });
}

/* ── server ── */

const server = http.createServer(async (req, res) => {
  const pathname = (req.url || "/").split("?")[0];
  try {
    if (req.method === "GET" && (pathname === "/" || pathname === "/index.html")) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(fs.readFileSync(INDEX_HTML));
      return;
    }

    if (pathname === "/api/config") {
      if (req.method === "GET") {
        return sendJson(res, 200, { owner: DEFAULT_OWNER, idPrefix: store.ID_PREFIX });
      }
      return sendJson(res, 405, { error: "method not allowed" });
    }

    if (pathname === "/api/epics") {
      if (req.method === "GET") return handleEpics(res);
      return sendJson(res, 405, { error: "method not allowed" });
    }

    // 解析失败的卡片文件。这些文件被刻意排除在 /api/cards 之外（塞进去会被
    // 拖拽静默覆盖掉），所以要有一个地方能看见它们，否则就是无声消失。
    if (pathname === "/api/issues") {
      if (req.method === "GET") {
        store.readAllCards();
        return sendJson(res, 200, { broken: store.getBrokenFiles() });
      }
      return sendJson(res, 405, { error: "method not allowed" });
    }

    if (pathname === "/api/cards") {
      if (req.method === "GET") return handleList(res);
      if (req.method === "PUT") return handlePutBulk(res, await readBody(req));
      if (req.method === "POST") return handlePost(res, await readBody(req));
      return sendJson(res, 405, { error: "method not allowed" });
    }

    // /api/cards/:id/comments/:cid —— 必须排在 /api/cards/:id 之前
    const cm = pathname.match(/^\/api\/cards\/([^/]+)\/comments\/([^/]+)$/);
    if (cm) {
      const id = decodeURIComponent(cm[1]);
      const cid = decodeURIComponent(cm[2]);
      if (!store.ID_RE.test(id)) {
        return sendJson(res, 400, { error: "id 必须符合 ^" + store.ID_PREFIX + "-\\d{3,}$" });
      }
      if (!store.COMMENT_ID_RE.test(cid)) {
        return sendJson(res, 400, { error: "留言 id 必须符合 " + store.COMMENT_ID_RE.source });
      }
      if (req.method === "PATCH") return handlePatchComment(req, res, id, cid, await readBody(req));
      return sendJson(res, 405, { error: "method not allowed" });
    }

    const cl = pathname.match(/^\/api\/cards\/([^/]+)\/comments$/);
    if (cl) {
      const id = decodeURIComponent(cl[1]);
      if (!store.ID_RE.test(id)) {
        return sendJson(res, 400, { error: "id 必须符合 ^" + store.ID_PREFIX + "-\\d{3,}$" });
      }
      if (req.method === "POST") return handleAddComment(req, res, id, await readBody(req));
      return sendJson(res, 405, { error: "method not allowed" });
    }

    const one = pathname.match(/^\/api\/cards\/([^/]+)$/);
    if (one) {
      const id = decodeURIComponent(one[1]);
      if (!store.ID_RE.test(id)) {
        return sendJson(res, 400, { error: "id 必须符合 ^" + store.ID_PREFIX + "-\\d{3,}$" });
      }
      if (req.method === "PUT") return handlePutOne(req, res, id, await readBody(req));
      if (req.method === "PATCH") return handlePatchCard(req, res, id, await readBody(req));
      if (req.method === "DELETE") return handleDelete(res, id);
      return sendJson(res, 405, { error: "method not allowed" });
    }

    sendJson(res, 404, { error: "not found" });
  } catch (err) {
    // 只有「有 body 的请求」才可能是 body 不合法。GET 走到这里必然是别的原因
    // （例如读文件失败），不能挂在 body 头上。
    if (err instanceof SyntaxError && req.method !== "GET") {
      sendJson(res, 400, { error: "body 不是合法 JSON：" + err.message });
    } else {
      sendJson(res, 500, { error: "写入失败：" + err.message });
    }
  }
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(
      `[kanban] port ${PORT} 已被占用。请先关掉占用的程序（lsof -i :${PORT}）再重新启动。`
    );
  } else {
    console.error("[kanban] server 启动失败：" + err.message);
  }
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`[kanban] 治理看板 → http://${HOST}:${PORT}`);
  console.log(`[kanban] 数据目录：${store.CARDS_DIR}`);
});
