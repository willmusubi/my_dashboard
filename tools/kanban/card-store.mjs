/**
 * 看板数据层 — schema、校验、读写。零依赖。
 *
 * server.mjs（HTTP）与 cli.mjs（agent 用）都 import 这里，所以校验逻辑只有一份。
 * 这也是「agent 永远不直接改 JSON」得以成立的前提：它调 CLI，CLI 走这里，
 * 和人在浏览器里改走的是同一套不变量。
 *
 * 数据：<CARDS_DIR>/*.json，一文件一卡，git 追踪。
 */
import fs from "node:fs";
import path from "node:path";

const HERE = import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname);

// 数据目录可注入：回归测试指向临时目录，从机制上碰不到真实卡片。
export const CARDS_DIR = process.env.KANBAN_CARDS_DIR
  ? path.resolve(process.env.KANBAN_CARDS_DIR)
  : path.join(HERE, "cards");
export const EPICS_JSON = path.join(HERE, "epics.json");
// 「曾经发出过的最大编号」。git 追踪，跨机器有效。没有它的话，删掉编号最大的
// 卡再建新卡会拿到同一个 id，别人的 dependsOn 就静默指向了一张无关的新卡。
export const SEQ_FILE = path.join(CARDS_DIR, ".seq");

// 分发到其他项目时改这个（或设 KANBAN_ID_PREFIX）。必须在建第一张卡之前定，
// 因为 ID_RE 会校验每个 id 和每个 dependsOn 元素。
export const ID_PREFIX = process.env.KANBAN_ID_PREFIX || "DASH";
export const ID_RE = new RegExp("^" + ID_PREFIX + "-\\d{3,}$");

export const STAGES = ["backlog", "blocked", "ready", "implementing", "verify", "done"];
export const ADVANCED_STAGES = ["ready", "implementing", "verify", "done"];
export const RISKS = ["low", "medium", "high"];
// 'fullstack' 是上游漏掉的合理值。枚举缺值的代价很高：非法值会让整批 PUT 拒绝，
// 于是一张坏卡就能让整条车道拖不动。
export const TRACKS = ["frontend", "backend", "integration", "fullstack", "n/a"];
export const READINESS_KEYS = [
  "problem_clear", "non_goals_clear", "acceptance_testable", "files_known",
  "scope_defined", "verification_contract", "human_approval_recorded",
];
export const GATE_KEYS = ["product", "ui", "architecture", "security", "test", "code_review"];
export const LINK_KEYS = [
  "featureSpec", "screenSpec", "mockupDecision", "taskCard", "verificationReport", "pr",
];

/* ══ 留言 schema ══
 * 人写的决策要能被 agent 分辨出来、并且能看出「AI 到底看没看见」。
 * 上游只有 {name, time, text}，time 还是 "07-03 13:58"（无年份无时区）。
 */
export const COMMENT_KINDS = [
  "decision",  // 人下的决策：必须遵守
  "question",  // 提问：等对方回答
  "answer",    // 回答某条 question
  "note",      // 随手记，不具约束力
  "blocker",   // 卡住了
  "progress",  // agent 报进度
  "evidence",  // agent 交证据
];
export const COMMENT_STATUSES = ["open", "acked", "done", "superseded"];
export const AUTHOR_KINDS = ["human", "agent"];
// 核心授权规则：只有人能下决策。agent 想推翻决策只能发 question 然后停下等人。
// 这让通道在信息上双向、在权威上单向。
export const HUMAN_ONLY_KINDS = ["decision"];
// 需要后续处理的类型默认 open；其余是纯信息，直接 done。
export const OPEN_BY_DEFAULT = ["decision", "question", "blocker"];
export const COMMENT_ID_RE = /^c-\d{8}T\d{6}-[0-9a-f]{4}$/;
export const COMMENT_KEYS = [
  "id", "at", "author", "authorKind", "kind", "status", "statusAt", "re", "supersedes", "text",
];

// writeCard 的字段顺序与 validateCard 的未知字段检查共用这一份清单。
export const CARD_KEYS = [
  "id", "title", "content", "stage", "risk", "owner", "agent", "approvalRequired",
  "createdAt", "updatedAt", "rev", "epic", "userStory", "track", "dependsOn", "order",
  "readiness", "gates", "links", "refs", "evidence", "comments",
];

/* ── 小工具 ── */

export function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

export function todayStr(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
}

/** ISO 8601 含时区偏移。上游的 "07-03 13:58" 没有年份也没有时区，无法比较先后。 */
export function isoNow(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  return (
    d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + "T" +
    p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds()) +
    sign + p(Math.floor(Math.abs(off) / 60)) + ":" + p(Math.abs(off) % 60)
  );
}

export function makeCommentId(d = new Date()) {
  const p = (n) => String(n).padStart(2, "0");
  const rand = Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
  return (
    "c-" + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "T" +
    p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()) + "-" + rand
  );
}

/** 每次写入递增，配合 If-Match 做乐观锁，防止「浏览器开着一小时后拖一下，
 *  把 agent 期间的改动整个还原掉」这种静默数据丢失。 */
export function bumpRev(c) {
  c.rev = (Number.isInteger(c.rev) ? c.rev : 0) + 1;
  c.updatedAt = isoNow();
  return c;
}

function defaultObj(keys, value) {
  const o = {};
  for (const k of keys) o[k] = value;
  return o;
}

/** 旧格式 "07-03 13:58"（无年份、无时区）→ ISO。年份取 createdAt；
 *  解析不出来就退回 createdAt 当天 + index 秒，保证顺序稳定与 id 唯一。 */
function legacyTimeToIso(time, createdAt, index) {
  const year = /^\d{4}/.test(createdAt || "") ? createdAt.slice(0, 4) : String(new Date().getFullYear());
  const m = String(time || "").match(/^(\d{2})-(\d{2})\s+(\d{2}):(\d{2})$/);
  let base;
  if (m) {
    base = new Date(Number(year), Number(m[1]) - 1, Number(m[2]), Number(m[3]), Number(m[4]), 0);
  } else {
    base = new Date((createdAt || year + "-01-01") + "T00:00:00");
    if (Number.isNaN(base.getTime())) base = new Date();
    base.setSeconds(index);
  }
  return isoNow(base);
}

/**
 * 旧格式 { name, time, text } → 新格式；新格式缺字段补默认值。
 * 旧留言一律当 note/done —— **不得回溯升格为 decision**。它们写的时候没有
 * 任何机制保证被读到，把它们当成生效中的指令是危险的。
 */
export function normalizeComment(raw, card, index) {
  if (!isPlainObject(raw)) return raw; // 交给 validateCard 报错
  const at =
    typeof raw.at === "string" && !Number.isNaN(Date.parse(raw.at))
      ? raw.at
      : legacyTimeToIso(raw.time, card && card.createdAt, index);
  const kind = COMMENT_KINDS.includes(raw.kind) ? raw.kind : "note";
  return {
    id: typeof raw.id === "string" && COMMENT_ID_RE.test(raw.id) ? raw.id : makeCommentId(new Date(at)),
    at,
    author: typeof raw.author === "string" ? raw.author : typeof raw.name === "string" ? raw.name : "",
    authorKind: AUTHOR_KINDS.includes(raw.authorKind) ? raw.authorKind : "human",
    kind,
    status: COMMENT_STATUSES.includes(raw.status)
      ? raw.status
      : OPEN_BY_DEFAULT.includes(kind) ? "open" : "done",
    statusAt:
      typeof raw.statusAt === "string" && !Number.isNaN(Date.parse(raw.statusAt)) ? raw.statusAt : at,
    re: typeof raw.re === "string" ? raw.re : null,
    supersedes: Array.isArray(raw.supersedes) ? raw.supersedes.filter((x) => typeof x === "string") : [],
    text: typeof raw.text === "string" ? raw.text : "",
  };
}

/** 旧数据 / 精简 client 兼容：缺少的字段补默认值（in-place）。 */
export function fillDefaults(c) {
  if (!isPlainObject(c)) return c;
  if (c.content === undefined) c.content = "";
  if (c.agent === undefined) c.agent = "";
  if (c.approvalRequired === undefined) c.approvalRequired = false;
  if (c.epic === undefined) c.epic = "";
  if (c.userStory === undefined) c.userStory = "";
  if (c.track === undefined) c.track = "n/a";
  if (!Array.isArray(c.dependsOn)) c.dependsOn = [];
  if (!isPlainObject(c.readiness)) c.readiness = defaultObj(READINESS_KEYS, false);
  else for (const k of READINESS_KEYS) if (c.readiness[k] === undefined) c.readiness[k] = false;
  if (!isPlainObject(c.gates)) c.gates = defaultObj(GATE_KEYS, false);
  else for (const k of GATE_KEYS) if (c.gates[k] === undefined) c.gates[k] = false;
  if (!isPlainObject(c.links)) c.links = defaultObj(LINK_KEYS, "");
  else for (const k of LINK_KEYS) if (c.links[k] === undefined) c.links[k] = "";
  if (!Array.isArray(c.refs)) c.refs = [];
  if (!isPlainObject(c.evidence)) c.evidence = { commands: [], findings: [], residual: "" };
  if (!Number.isInteger(c.rev) || c.rev < 1) c.rev = 1;
  if (typeof c.updatedAt !== "string") {
    const base = new Date((c.createdAt || todayStr()) + "T00:00:00");
    c.updatedAt = isoNow(Number.isNaN(base.getTime()) ? new Date() : base);
  }
  c.comments = Array.isArray(c.comments) ? c.comments.map((x, i) => normalizeComment(x, c, i)) : [];
  return c;
}

export function validateCard(c) {
  if (!isPlainObject(c)) return "card 必须是 object";
  if (typeof c.id !== "string" || !ID_RE.test(c.id)) return "id 必须符合 ^" + ID_PREFIX + "-\\d{3,}$";
  if (typeof c.title !== "string" || c.title.trim() === "") return "title 必须是非空字符串";
  if (typeof c.content !== "string") return "content 必须是字符串";
  if (!STAGES.includes(c.stage)) return "stage 只允许 " + STAGES.join("/");
  if (!RISKS.includes(c.risk)) return "risk 只允许 " + RISKS.join("/");
  if (typeof c.owner !== "string") return "owner 必须是字符串";
  if (typeof c.agent !== "string") return "agent 必须是字符串";
  if (typeof c.approvalRequired !== "boolean") return "approvalRequired 必须是 boolean";
  if (typeof c.createdAt !== "string") return "createdAt 必须是字符串";
  if (!Number.isInteger(c.rev) || c.rev < 1) return "rev 必须是 >= 1 的整数";
  if (typeof c.updatedAt !== "string") return "updatedAt 必须是字符串";
  if (!Number.isInteger(c.order) || c.order < 1) return "order 必须是 >= 1 的整数";
  if (typeof c.epic !== "string") return "epic 必须是字符串";
  if (typeof c.userStory !== "string") return "userStory 必须是字符串";
  if (!TRACKS.includes(c.track)) return "track 只允许 " + TRACKS.join("/");
  if (!Array.isArray(c.dependsOn) || c.dependsOn.some((x) => typeof x !== "string" || !ID_RE.test(x))) {
    return "dependsOn 必须是字符串数组，且每个元素需符合 id 格式 ^" + ID_PREFIX + "-\\d{3,}$";
  }
  if (c.dependsOn.includes(c.id)) return "dependsOn 不可包含自己的 id";

  if (!isPlainObject(c.readiness)) return "readiness 必须是 object";
  for (const k of READINESS_KEYS) {
    if (typeof c.readiness[k] !== "boolean") return "readiness." + k + " 必须是 boolean";
  }
  if (!isPlainObject(c.gates)) return "gates 必须是 object";
  for (const k of GATE_KEYS) {
    if (typeof c.gates[k] !== "boolean") return "gates." + k + " 必须是 boolean";
  }
  if (!isPlainObject(c.links)) return "links 必须是 object";
  for (const k of LINK_KEYS) {
    if (typeof c.links[k] !== "string") return "links." + k + " 必须是字符串";
  }
  if (!Array.isArray(c.refs) || c.refs.some((r) => typeof r !== "string")) {
    return "refs 必须是字符串数组";
  }
  if (!isPlainObject(c.evidence)) return "evidence 必须是 object";
  for (const k of ["commands", "findings"]) {
    if (!Array.isArray(c.evidence[k]) || c.evidence[k].some((x) => typeof x !== "string")) {
      return "evidence." + k + " 必须是字符串数组";
    }
  }
  if (typeof c.evidence.residual !== "string") return "evidence.residual 必须是字符串";

  const err = validateComments(c.comments);
  if (err) return err;

  // 未知字段一律报错，而不是被 writeCard 静默丢掉。
  // 静默删除才是真缺陷；一个会告诉你的白名单没问题。
  for (const k of Object.keys(c)) {
    if (!CARD_KEYS.includes(k)) {
      return "未知字段：" + k + "（要扩充 schema 请同时改 CARD_KEYS / validateCard / fillDefaults）";
    }
  }
  return null;
}

export function validateComments(list) {
  if (!Array.isArray(list)) return "comments 必须是数组";
  const ids = new Set();
  for (const it of list) {
    if (!isPlainObject(it)) return "comments 每项必须是 object";
    if (typeof it.id !== "string" || !COMMENT_ID_RE.test(it.id)) {
      return "comments[].id 必须符合 " + COMMENT_ID_RE.source;
    }
    if (ids.has(it.id)) return "comments[].id 重复：" + it.id;
    ids.add(it.id);
    if (typeof it.at !== "string" || Number.isNaN(Date.parse(it.at))) {
      return "comments[].at 必须是可解析的 ISO 时间";
    }
    if (typeof it.statusAt !== "string" || Number.isNaN(Date.parse(it.statusAt))) {
      return "comments[].statusAt 必须是可解析的 ISO 时间";
    }
    if (typeof it.author !== "string") return "comments[].author 必须是字符串";
    if (!AUTHOR_KINDS.includes(it.authorKind)) {
      return "comments[].authorKind 只允许 " + AUTHOR_KINDS.join("/");
    }
    if (!COMMENT_KINDS.includes(it.kind)) return "comments[].kind 只允许 " + COMMENT_KINDS.join("/");
    if (!COMMENT_STATUSES.includes(it.status)) {
      return "comments[].status 只允许 " + COMMENT_STATUSES.join("/");
    }
    if (it.re !== null && typeof it.re !== "string") return "comments[].re 必须是 null 或字符串";
    if (!Array.isArray(it.supersedes) || it.supersedes.some((x) => typeof x !== "string")) {
      return "comments[].supersedes 必须是字符串数组";
    }
    if (typeof it.text !== "string" || it.text.trim() === "") return "comments[].text 必须是非空字符串";
    // 核心授权规则
    if (it.authorKind === "agent" && HUMAN_ONLY_KINDS.includes(it.kind)) {
      return "comments[].kind=" + it.kind + " 只能由人工撰写（agent 请改用 kind=question 并停下等人回答）";
    }
    for (const k of Object.keys(it)) {
      if (!COMMENT_KEYS.includes(k)) return "comments[] 未知字段：" + k;
    }
  }
  // 引用完整性
  for (const it of list) {
    if (it.re !== null && !ids.has(it.re)) return "comments[].re 指向不存在的留言：" + it.re;
    for (const s of it.supersedes) {
      if (s === it.id) return "comments[].supersedes 不可包含自己";
      if (!ids.has(s)) return "comments[].supersedes 指向不存在的留言：" + s;
    }
  }
  return null;
}

/* ── 读写 ── */

/**
 * 固定 key 顺序写文件（顺序来自 CARD_KEYS / COMMENT_KEYS 单一清单），
 * 2 空格缩进 + 结尾换行，减少 git diff 噪音。
 * tmp + rename 让写入原子化：崩在中途也不会留下半截文件。
 */
export function writeCard(c) {
  const out = {};
  for (const k of CARD_KEYS) out[k] = c[k];
  out.comments = (c.comments || []).map((cm) => {
    const o = {};
    for (const k of COMMENT_KEYS) o[k] = cm[k];
    return o;
  });
  fs.mkdirSync(CARDS_DIR, { recursive: true }); // 目录可能被删掉过
  const file = path.join(CARDS_DIR, c.id + ".json");
  const tmp = file + ".tmp" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(out, null, 2) + "\n", "utf8");
  fs.renameSync(tmp, file); // 同一文件系统上的 rename 是原子的
  return out;
}

/** 解析失败的卡片文件。刻意「跳过」而不是「合成一张卡塞进列表」：合成卡一旦被
 *  拖拽写回，原始坏文件的内容就被静默覆盖了，而且它会混进整批 PUT 造成整批拒绝。 */
let BROKEN = [];
export function getBrokenFiles() {
  return BROKEN;
}

export function readAllCards() {
  fs.mkdirSync(CARDS_DIR, { recursive: true });
  const files = fs.readdirSync(CARDS_DIR).filter((f) => f.endsWith(".json"));
  const cards = [];
  const broken = [];
  for (const f of files) {
    try {
      cards.push(fillDefaults(JSON.parse(fs.readFileSync(path.join(CARDS_DIR, f), "utf8"))));
    } catch (err) {
      // 上游这里没有 try/catch：一个坏文件会让 SyntaxError 一路冒到顶层 handler，
      // 被误报成「body 不是合法 JSON」——对一个根本没有 body 的 GET 请求，
      // 而且整块看板会变空。
      console.error("[kanban] 解析失败：" + f + " — " + err.message);
      broken.push({ file: f, error: err.message });
    }
  }
  BROKEN = broken;
  cards.sort(
    (a, b) =>
      STAGES.indexOf(a.stage) - STAGES.indexOf(b.stage) ||
      a.order - b.order ||
      a.id.localeCompare(b.id)
  );
  return cards;
}

export function readCard(id) {
  const file = path.join(CARDS_DIR, id + ".json");
  if (!fs.existsSync(file)) return null;
  return fillDefaults(JSON.parse(fs.readFileSync(file, "utf8")));
}

export function deleteCardFile(id) {
  const file = path.join(CARDS_DIR, id + ".json");
  if (!fs.existsSync(file)) return false;
  fs.unlinkSync(file);
  return true;
}

export function readSeq() {
  try {
    return parseInt(fs.readFileSync(SEQ_FILE, "utf8").trim(), 10) || 0;
  } catch {
    return 0;
  }
}

export function writeSeq(n) {
  try {
    fs.mkdirSync(CARDS_DIR, { recursive: true });
    fs.writeFileSync(SEQ_FILE, String(n) + "\n", "utf8");
  } catch (err) {
    console.error("[kanban] 写入 .seq 失败：" + err.message);
  }
}

/** 取「磁盘上现存最大」与「曾经发出过的最大」的较大者。只看磁盘的话，删掉编号
 *  最大的卡再建新卡会复用同一个 id。 */
export function nextIdNumber(existing) {
  const fromDisk = existing.reduce(
    (m, c) => Math.max(m, parseInt(c.id.slice(ID_PREFIX.length + 1), 10) || 0),
    0
  );
  return Math.max(fromDisk, readSeq()) + 1;
}

export function formatId(n) {
  return ID_PREFIX + "-" + String(n).padStart(3, "0");
}

/* ── 依赖图 ── */

/** 从 startId 沿 dependsOn 做 DFS，找出第一个可达的循环。 */
export function detectCycle(startId, cardMap) {
  const trail = [];
  const onPath = new Set();
  function visit(id) {
    if (onPath.has(id)) return trail.slice(trail.indexOf(id)).concat(id);
    const card = cardMap.get(id);
    if (!card || !Array.isArray(card.dependsOn)) return null;
    trail.push(id);
    onPath.add(id);
    for (const dep of card.dependsOn) {
      const cycle = visit(dep);
      if (cycle) return cycle;
    }
    trail.pop();
    onPath.delete(id);
    return null;
  }
  return visit(startId);
}

/** 检查一张卡的 dependsOn：引用是否存在、是否成环、要推进到 ready 之后时前置是否都 done。
 *  cardMap 必须包含本次「即将写入」的最新版本。 */
export function checkDependsOn(card, cardMap) {
  const missing = card.dependsOn.filter((id) => !cardMap.has(id));
  if (missing.length) return card.id + "：dependsOn 引用到不存在的卡片：" + missing.join(", ");

  const cycle = detectCycle(card.id, cardMap);
  if (cycle) return card.id + "：检测到循环依赖：" + cycle.join(" -> ");

  if (ADVANCED_STAGES.includes(card.stage)) {
    const unmet = card.dependsOn.map((id) => cardMap.get(id)).filter((d) => d.stage !== "done");
    if (unmet.length) {
      return (
        card.id + "：前置任务尚未完成（" +
        unmet.map((d) => d.id + " " + d.title).join("、") +
        "），无法推进到 " + card.stage
      );
    }
  }
  return null;
}

/* ── 留言操作 ── */

/**
 * 身份判定。这里不是安全边界（单机、无账号系统），目的只有一个：
 * 不要把 agent 的留言记成人写的。
 */
export function resolveActor(agentName, defaultOwner) {
  const a = String(agentName || "").trim();
  if (a) return { author: a, authorKind: "agent" };
  return { author: defaultOwner || "匿名", authorKind: "human" };
}

/**
 * 追加一条留言（只追加，永不修改既有留言的文本）。
 * 返回 { comment } 或 { error }。
 */
export function appendComment(card, { kind, text, actor, re = null, supersedes = [] }) {
  const k = COMMENT_KINDS.includes(kind) ? kind : "note";
  if (actor.authorKind === "agent" && HUMAN_ONLY_KINDS.includes(k)) {
    return { error: "agent 不得撰写 " + k + "；请改用 kind=question 并停下等人回答" };
  }
  const body = typeof text === "string" ? text.trim() : "";
  if (!body) return { error: "text 必须是非空字符串" };

  const now = new Date();
  const at = isoNow(now);
  const taken = new Set(card.comments.map((x) => x.id));
  let id = makeCommentId(now);
  while (taken.has(id)) id = makeCommentId(now);

  const comment = {
    id,
    at,
    author: actor.author,
    authorKind: actor.authorKind,
    kind: k,
    status: OPEN_BY_DEFAULT.includes(k) ? "open" : "done",
    statusAt: at,
    re: typeof re === "string" ? re : null,
    supersedes: Array.isArray(supersedes) ? supersedes.filter((x) => typeof x === "string") : [],
  text: body,
  };
  card.comments.push(comment);

  // 取代旧决策：旧的翻成 superseded，于是它被 hook 的注入过滤结构性排除，
  // agent 不可能再执行已撤销的指令。
  for (const s of comment.supersedes) {
    const t = card.comments.find((x) => x.id === s);
    if (t) {
      t.status = "superseded";
      t.statusAt = at;
    }
  }
  // 回答就关掉对应的提问
  if (comment.kind === "answer" && comment.re) {
    const q = card.comments.find((x) => x.id === comment.re);
    if (q && q.kind === "question") {
      q.status = "done";
      q.statusAt = at;
    }
  }
  return { comment };
}

/** status 转换权限。acked 只有 agent 能设（人确认自己的决策没有意义）；
 *  open 只有人能重开；superseded 不可直接设置，只能是新留言 supersedes 的副作用。 */
export const STATUS_RULES = {
  acked: ["agent"],
  done: ["agent", "human"],
  open: ["human"],
};

export function setCommentStatus(card, commentId, status, actorKind) {
  const cm = card.comments.find((x) => x.id === commentId);
  if (!cm) return { error: "留言不存在：" + commentId };
  if (!Object.prototype.hasOwnProperty.call(STATUS_RULES, status)) {
    return { error: "status 只允许 " + Object.keys(STATUS_RULES).join("/") + "（superseded 只能由新留言的 supersedes 造成）" };
  }
  if (!STATUS_RULES[status].includes(actorKind)) {
    return { error: "status=" + status + " 只能由 " + STATUS_RULES[status].join("/") + " 设置" };
  }
  cm.status = status;
  cm.statusAt = isoNow();
  return { comment: cm };
}

/** hook 与 CLI 共用的「生效中的人工项」筛选：只有人写的、还没被取代或完成的。 */
export function liveHumanItems(card, kind) {
  return (card.comments || []).filter(
    (c) => c.kind === kind && c.authorKind === "human" && (c.status === "open" || c.status === "acked")
  );
}

export function readEpics() {
  try {
    return JSON.parse(fs.readFileSync(EPICS_JSON, "utf8"));
  } catch (err) {
    return { epics: [], error: err.message };
  }
}
