/**
 * 治理看板 — 零依賴本地 server
 *
 * 啟動：node tools/kanban/server.mjs（或 npm run kanban）
 * 資料：tools/kanban/cards/*.json（一檔一卡，git tracked）
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const HOST = '127.0.0.1';
// 可用 KANBAN_PORT 覆写：平行专案很多时，同时开两块看板不会撞埠。
const PORT = Number(process.env.KANBAN_PORT) || 4420;

const ROOT = import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname);
const CARDS_DIR = path.join(ROOT, 'cards');
const INDEX_HTML = path.join(ROOT, 'index.html');
const EPICS_JSON = path.join(ROOT, 'epics.json');
// 「曾经发出过的最大编号」。git 追踪，跨机器有效。没有它的话，删掉编号最大的
// 卡再建新卡会拿到同一个 id，别人的 dependsOn 就静默指向了一张无关的新卡。
const SEQ_FILE = path.join(CARDS_DIR, '.seq');

fs.mkdirSync(CARDS_DIR, { recursive: true });

// Customize this per project (e.g. team or product initials). Card IDs are
// generated as `${ID_PREFIX}-001`, `${ID_PREFIX}-002`, ...
const ID_PREFIX = 'DASH';

// 新卡片 owner 與看板留言作者的預設值：取本機 git 身分（這個看板本來就以
// git 為同步機制），沒有 git 或沒設 user.name 時留空字串（未指派）。
const DEFAULT_OWNER = (() => {
  try {
    return execSync('git config user.name', { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
})();
const ID_RE = new RegExp('^' + ID_PREFIX + '-\\d{3,}$');
const STAGES = ['backlog', 'blocked', 'ready', 'implementing', 'verify', 'done'];
const ADVANCED_STAGES = ['ready', 'implementing', 'verify', 'done'];
const RISKS = ['low', 'medium', 'high'];
// 'fullstack' 是上游漏掉的合理值。枚举缺值的代价很高：非法值会让 handlePutBulk
// 整批拒绝，于是一张坏卡就能让整条车道拖不动（见 readAllCards 的坏卡处理）。
const TRACKS = ['frontend', 'backend', 'integration', 'fullstack', 'n/a'];
const READINESS_KEYS = [
  'problem_clear', 'non_goals_clear', 'acceptance_testable', 'files_known',
  'scope_defined', 'verification_contract', 'human_approval_recorded'
];
const GATE_KEYS = ['product', 'ui', 'architecture', 'security', 'test', 'code_review'];
const LINK_KEYS = ['featureSpec', 'screenSpec', 'mockupDecision', 'taskCard', 'verificationReport', 'pr'];

/* ── helpers ── */

function sendJson(res, code, obj, extraHeaders) {
  const body = JSON.stringify(obj);
  const headers = { 'Content-Type': 'application/json; charset=utf-8' };
  if (extraHeaders) Object.assign(headers, extraHeaders);
  res.writeHead(code, headers);
  res.end(body);
}

/**
 * 乐观锁。If-Match 带的是客户端手上那份的 rev；对不上，说明它读到之后有人
 * （多半是 agent）改过这张卡，直接覆盖就会静默丢掉那次改动。
 * 不带 If-Match 的请求放行，保持对旧客户端与手写 curl 的兼容。
 */
function checkPrecondition(req, current) {
  const raw = req.headers['if-match'];
  if (raw === undefined) return null;
  const want = parseInt(String(raw).replace(/"/g, ''), 10);
  if (want === current.rev) return null;
  return {
    error: current.id + ' 已被改动（你手上是 rev ' + want + '，磁盘上是 rev ' +
      current.rev + '）。请重新载入后重做这次修改。',
    conflict: true,
    rev: current.rev
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function validateCard(c) {
  if (!isPlainObject(c)) return 'card 必須是 object';
  if (typeof c.id !== 'string' || !ID_RE.test(c.id)) return 'id 必須符合 ^' + ID_PREFIX + '-\\d{3,}$';
  if (typeof c.title !== 'string' || c.title.trim() === '') return 'title 必須是非空字串';
  if (typeof c.content !== 'string') return 'content 必須是字串';
  if (!STAGES.includes(c.stage)) return 'stage 只允許 ' + STAGES.join('/');
  if (!RISKS.includes(c.risk)) return 'risk 只允許 ' + RISKS.join('/');
  if (typeof c.owner !== 'string') return 'owner 必須是字串';
  if (typeof c.agent !== 'string') return 'agent 必須是字串';
  if (typeof c.approvalRequired !== 'boolean') return 'approvalRequired 必須是 boolean';
  if (typeof c.createdAt !== 'string') return 'createdAt 必須是字串';
  if (!Number.isInteger(c.rev) || c.rev < 1) return 'rev 必須是 >= 1 的整數';
  if (typeof c.updatedAt !== 'string') return 'updatedAt 必須是字串';
  if (!Number.isInteger(c.order) || c.order < 1) return 'order 必須是 >= 1 的整數';
  if (typeof c.epic !== 'string') return 'epic 必須是字串';
  if (typeof c.userStory !== 'string') return 'userStory 必須是字串';
  if (!TRACKS.includes(c.track)) return 'track 只允許 ' + TRACKS.join('/');
  if (!Array.isArray(c.dependsOn) || c.dependsOn.some((x) => typeof x !== 'string' || !ID_RE.test(x))) {
    return 'dependsOn 必須是字串陣列，且每個元素需符合 id 格式 ^' + ID_PREFIX + '-\\d{3,}$';
  }
  if (c.dependsOn.includes(c.id)) return 'dependsOn 不可包含自己的 id';

  if (!isPlainObject(c.readiness)) return 'readiness 必須是 object';
  for (const k of READINESS_KEYS) {
    if (typeof c.readiness[k] !== 'boolean') return 'readiness.' + k + ' 必須是 boolean';
  }
  if (!isPlainObject(c.gates)) return 'gates 必須是 object';
  for (const k of GATE_KEYS) {
    if (typeof c.gates[k] !== 'boolean') return 'gates.' + k + ' 必須是 boolean';
  }
  if (!isPlainObject(c.links)) return 'links 必須是 object';
  for (const k of LINK_KEYS) {
    if (typeof c.links[k] !== 'string') return 'links.' + k + ' 必須是字串';
  }
  if (!Array.isArray(c.refs) || c.refs.some((r) => typeof r !== 'string')) {
    return 'refs 必須是字串陣列';
  }
  if (!isPlainObject(c.evidence)) return 'evidence 必須是 object';
  if (!Array.isArray(c.evidence.commands) || c.evidence.commands.some((x) => typeof x !== 'string')) {
    return 'evidence.commands 必須是字串陣列';
  }
  if (!Array.isArray(c.evidence.findings) || c.evidence.findings.some((x) => typeof x !== 'string')) {
    return 'evidence.findings 必須是字串陣列';
  }
  if (typeof c.evidence.residual !== 'string') return 'evidence.residual 必須是字串';
  if (!Array.isArray(c.comments)) return 'comments 必須是陣列';
  for (const item of c.comments) {
    if (!isPlainObject(item)) return 'comments 每項必須是 { name, time, text } object';
    if (typeof item.name !== 'string') return 'comments[].name 必須是字串';
    if (typeof item.time !== 'string') return 'comments[].time 必須是字串';
    if (typeof item.text !== 'string') return 'comments[].text 必須是字串';
  }
  return null;
}

function defaultObj(keys, value) {
  const o = {};
  for (const k of keys) o[k] = value;
  return o;
}

/** 舊資料 / 精簡 client 相容：缺少的欄位補預設值（in-place） */
function fillDefaults(c) {
  if (!isPlainObject(c)) return c;
  if (c.content === undefined) c.content = '';
  if (c.agent === undefined) c.agent = '';
  if (c.approvalRequired === undefined) c.approvalRequired = false;
  if (c.epic === undefined) c.epic = '';
  if (c.userStory === undefined) c.userStory = '';
  if (c.track === undefined) c.track = 'n/a';
  if (!Array.isArray(c.dependsOn)) c.dependsOn = [];
  if (!isPlainObject(c.readiness)) c.readiness = defaultObj(READINESS_KEYS, false);
  else for (const k of READINESS_KEYS) if (c.readiness[k] === undefined) c.readiness[k] = false;
  if (!isPlainObject(c.gates)) c.gates = defaultObj(GATE_KEYS, false);
  else for (const k of GATE_KEYS) if (c.gates[k] === undefined) c.gates[k] = false;
  if (!isPlainObject(c.links)) c.links = defaultObj(LINK_KEYS, '');
  else for (const k of LINK_KEYS) if (c.links[k] === undefined) c.links[k] = '';
  if (!Array.isArray(c.refs)) c.refs = [];
  if (!isPlainObject(c.evidence)) c.evidence = { commands: [], findings: [], residual: '' };
  if (!Array.isArray(c.comments)) c.comments = [];
  if (!Number.isInteger(c.rev) || c.rev < 1) c.rev = 1;
  if (typeof c.updatedAt !== 'string') {
    const base = new Date((c.createdAt || todayStr()) + 'T00:00:00');
    c.updatedAt = isoNow(Number.isNaN(base.getTime()) ? new Date() : base);
  }
  return c;
}

/** 固定 key 順序寫檔，2 空格縮排 + 結尾換行，減少 git diff 噪音 */
function writeCard(c) {
  const normalized = {
    id: c.id,
    title: c.title,
    content: c.content,
    stage: c.stage,
    risk: c.risk,
    owner: c.owner,
    agent: c.agent,
    approvalRequired: c.approvalRequired,
    createdAt: c.createdAt,
    updatedAt: c.updatedAt,
    rev: c.rev,
    epic: c.epic,
    userStory: c.userStory,
    track: c.track,
    dependsOn: c.dependsOn,
    order: c.order,
    readiness: c.readiness,
    gates: c.gates,
    links: c.links,
    refs: c.refs,
    evidence: c.evidence,
    comments: c.comments
  };
  const file = path.join(CARDS_DIR, c.id + '.json');
  fs.writeFileSync(file, JSON.stringify(normalized, null, 2) + '\n', 'utf8');
}

/**
 * 解析失败的卡片档，供 GET /api/issues 用。
 * 刻意「跳过」而不是「合成一张卡塞进列表」：合成卡一旦被拖拽写回，原始坏档
 * 的内容就被静默覆盖掉了；而且它会混进 handlePutBulk 的批次里造成整批拒绝。
 * 跳过 + 单独上报，才既救回其余卡片、又不损坏坏档本身。
 */
let BROKEN_FILES = [];

function readAllCards() {
  const files = fs.readdirSync(CARDS_DIR).filter((f) => f.endsWith('.json'));
  const cards = [];
  const broken = [];
  for (const f of files) {
    try {
      cards.push(fillDefaults(JSON.parse(fs.readFileSync(path.join(CARDS_DIR, f), 'utf8'))));
    } catch (err) {
      // 上游这里没有 try/catch：一个坏档会让 SyntaxError 一路冒到顶层 handler，
      // 被误报成「body 不是合法 JSON」——对一个根本没有 body 的 GET 请求，
      // 而且整块看板会变空。
      console.error('[kanban] 解析失败：' + f + ' — ' + err.message);
      broken.push({ file: f, error: err.message });
    }
  }
  BROKEN_FILES = broken;
  cards.sort((a, b) =>
    STAGES.indexOf(a.stage) - STAGES.indexOf(b.stage) ||
    a.order - b.order ||
    a.id.localeCompare(b.id)
  );
  return cards;
}

/**
 * 從 startId 沿 dependsOn 邊做 DFS，找出第一個可達的循環。
 * cardMap 必須包含這次請求裡「即將寫入」的最新版本（覆蓋掉舊檔內容）。
 * 回傳循環路徑（含重複的起點，方便顯示 "A -> B -> A"），沒有循環回傳 null。
 */
function detectCycle(startId, cardMap) {
  const path = [];
  const onPath = new Set();
  function visit(id) {
    if (onPath.has(id)) return path.slice(path.indexOf(id)).concat(id);
    const card = cardMap.get(id);
    if (!card || !Array.isArray(card.dependsOn)) return null;
    path.push(id);
    onPath.add(id);
    for (const dep of card.dependsOn) {
      const cycle = visit(dep);
      if (cycle) return cycle;
    }
    path.pop();
    onPath.delete(id);
    return null;
  }
  return visit(startId);
}

/**
 * 檢查一張卡的 dependsOn：參照是否存在、是否形成循環、
 * 若要推進到 ready/implementing/verify/done，前置任務是否皆已 done。
 * cardMap 必須包含這次請求裡「即將寫入」的最新版本。回傳錯誤字串，沒有問題回傳 null。
 */
function checkDependsOn(card, cardMap) {
  const missing = card.dependsOn.filter((depId) => !cardMap.has(depId));
  if (missing.length) return card.id + ': dependsOn 參照到不存在的卡片：' + missing.join(', ');

  const cycle = detectCycle(card.id, cardMap);
  if (cycle) return card.id + ': 偵測到循環依賴：' + cycle.join(' -> ');

  if (ADVANCED_STAGES.includes(card.stage)) {
    const unmet = card.dependsOn.map((depId) => cardMap.get(depId)).filter((dep) => dep.stage !== 'done');
    if (unmet.length) {
      return (
        card.id + ': 前置任務尚未完成（' +
        unmet.map((d) => d.id + ' ' + d.title).join('、') +
        '），無法推進到 ' + card.stage
      );
    }
  }
  return null;
}

function todayStr() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

/** ISO 8601 含时区偏移。原本的 "07-03 13:58" 没有年份也没有时区，无法比较先后。 */
function isoNow(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' +
    p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) +
    sign + p(Math.floor(Math.abs(off) / 60)) + ':' + p(Math.abs(off) % 60);
}

/** 每次写入递增，配合 If-Match 做乐观锁，防止「浏览器开着一小时后拖一下，
 *  把 agent 期间的改动整个还原掉」这种静默数据丢失。 */
function bumpRev(c) {
  c.rev = (Number.isInteger(c.rev) ? c.rev : 0) + 1;
  c.updatedAt = isoNow();
  return c;
}

function readSeq() {
  try {
    return parseInt(fs.readFileSync(SEQ_FILE, 'utf8').trim(), 10) || 0;
  } catch {
    return 0;
  }
}

function writeSeq(n) {
  try {
    fs.writeFileSync(SEQ_FILE, String(n) + '\n', 'utf8');
  } catch (err) {
    console.error('[kanban] 写入 .seq 失败：' + err.message);
  }
}

/* ── route handlers ── */

function handleList(res) {
  sendJson(res, 200, readAllCards());
}

function handleEpics(res) {
  try {
    const epics = JSON.parse(fs.readFileSync(EPICS_JSON, 'utf8'));
    sendJson(res, 200, epics);
  } catch (err) {
    sendJson(res, 500, { error: '讀取 epics.json 失敗：' + err.message });
  }
}

function handlePutOne(req, res, id, body) {
  const incoming = JSON.parse(body);
  if (!isPlainObject(incoming)) return sendJson(res, 400, { error: 'body 必須是完整 card object' });
  if (incoming.id !== id) return sendJson(res, 400, { error: 'body 的 id 與 URL 不一致' });

  const cardMap = new Map(readAllCards().map((x) => [x.id, x]));
  const current = cardMap.get(id);
  if (!current) return sendJson(res, 404, { error: id + ' 不存在' });

  const conflict = checkPrecondition(req, current);
  if (conflict) return sendJson(res, 409, conflict);

  // rev 与 createdAt 一律以磁盘版本为准，客户端说了不算。
  const c = fillDefaults({ ...incoming, rev: current.rev, createdAt: current.createdAt });
  const err = validateCard(c);
  if (err) return sendJson(res, 400, { error: err });
  cardMap.set(c.id, c);
  const depErr = checkDependsOn(c, cardMap);
  if (depErr) return sendJson(res, 400, { error: depErr });
  bumpRev(c);
  writeCard(c);
  sendJson(res, 200, c, { ETag: String(c.rev) });
}

function handlePutBulk(res, body) {
  const list = JSON.parse(body);
  if (!Array.isArray(list)) return sendJson(res, 400, { error: 'body 必須是 card 陣列' });
  const cardMap = new Map(readAllCards().map((x) => [x.id, x]));

  // 先比对 rev，且必须在 fillDefaults 之前——fillDefaults 会给缺 rev 的卡补
  // rev=1，之后就分不清「客户端没带 rev」和「客户端带的是 1」。
  // 拖拽送来的是浏览器内存里那份；开着页面一小时再拖一下，就会把 agent 期间
  // 的改动整个还原掉，而且无声无息。
  const stale = [];
  for (const c of list) {
    const cur = isPlainObject(c) ? cardMap.get(c.id) : null;
    if (cur && Number.isInteger(c.rev) && c.rev !== cur.rev) stale.push(c.id);
  }
  if (stale.length) {
    return sendJson(res, 409, {
      error: '这些卡片已被改动：' + stale.join('、') + '。请重新载入后重做这次拖拽。',
      conflict: true,
      stale
    });
  }

  const prepared = [];
  for (const c of list) {
    const cur = isPlainObject(c) ? cardMap.get(c.id) : null;
    const merged = fillDefaults(cur ? { ...c, rev: cur.rev, createdAt: cur.createdAt } : c);
    const err = validateCard(merged);
    if (err) return sendJson(res, 400, { error: (c && c.id ? c.id + ': ' : '') + err });
    prepared.push(merged);
  }
  for (const c of prepared) cardMap.set(c.id, c);
  for (const c of prepared) {
    const depErr = checkDependsOn(c, cardMap);
    if (depErr) return sendJson(res, 400, { error: depErr });
  }
  for (const c of prepared) {
    bumpRev(c);
    writeCard(c);
  }
  sendJson(res, 200, { updated: prepared.length, cards: prepared });
}

function handlePost(res, body) {
  const input = JSON.parse(body);
  if (!isPlainObject(input)) return sendJson(res, 400, { error: 'body 必須是 object' });
  const existing = readAllCards();
  // 取「磁盘上现存最大」与「曾经发出过的最大」的较大者。只看磁盘的话，删掉
  // 编号最大的卡再建新卡会复用同一个 id，其他卡的 dependsOn 就静默指向了
  // 一张毫不相干的新卡。
  const maxNum = Math.max(
    existing.reduce((m, c) => Math.max(m, parseInt(c.id.slice(ID_PREFIX.length + 1), 10) || 0), 0),
    readSeq()
  );
  const stage = STAGES.includes(input.stage) ? input.stage : 'backlog';
  const inColumn = existing.filter((c) => c.stage === stage);
  const card = fillDefaults({
    id: ID_PREFIX + '-' + String(maxNum + 1).padStart(3, '0'),
    title: typeof input.title === 'string' ? input.title.trim() : '',
    content: typeof input.content === 'string' ? input.content : '',
    stage,
    risk: RISKS.includes(input.risk) ? input.risk : 'low',
    owner: typeof input.owner === 'string' ? input.owner : DEFAULT_OWNER,
    agent: typeof input.agent === 'string' ? input.agent : '',
    approvalRequired: !!input.approvalRequired,
    createdAt: todayStr(),
    epic: typeof input.epic === 'string' ? input.epic : '',
    userStory: typeof input.userStory === 'string' ? input.userStory : '',
    track: TRACKS.includes(input.track) ? input.track : 'n/a',
    dependsOn: Array.isArray(input.dependsOn) ? input.dependsOn : [],
    // 不能用 inColumn.length + 1：删掉车道中间的卡后会撞号，排序退化到
    // id.localeCompare，顺序变随机且每次拖拽都重写文件制造 git 噪音。
    order: inColumn.reduce((m, c) => Math.max(m, c.order || 0), 0) + 1,
    readiness: input.readiness,
    gates: input.gates,
    links: input.links,
    refs: Array.isArray(input.refs) ? input.refs : [],
    evidence: input.evidence,
    comments: []
  });
  const err = validateCard(card);
  if (err) return sendJson(res, 400, { error: err });
  const cardMap = new Map(existing.map((x) => [x.id, x]));
  cardMap.set(card.id, card);
  const depErr = checkDependsOn(card, cardMap);
  if (depErr) return sendJson(res, 400, { error: depErr });
  writeCard(card);
  writeSeq(maxNum + 1);
  sendJson(res, 201, card, { ETag: String(card.rev) });
}

function handleDelete(res, id) {
  const file = path.join(CARDS_DIR, id + '.json');
  if (!fs.existsSync(file)) return sendJson(res, 404, { error: id + ' 不存在' });
  fs.unlinkSync(file);

  // 清掉其他卡对它的 dependsOn 引用。上游不做这件事，后果是连锁的：
  // checkDependsOn 硬拒任何引用不存在卡片的 PUT，modal 又没有 dependsOn
  // 编辑器，而拖拽走的是整批拒绝的 handlePutBulk —— 净效果是一个悬空引用
  // 让两条车道彻底拖不动，只能手改 JSON 才能救回来。
  const cleaned = [];
  for (const c of readAllCards()) {
    if (!c.dependsOn.includes(id)) continue;
    c.dependsOn = c.dependsOn.filter((d) => d !== id);
    bumpRev(c);
    writeCard(c);
    cleaned.push(c.id);
  }
  sendJson(res, 200, { deleted: id, dependsOnCleaned: cleaned });
}

/* ── server ── */

const server = http.createServer(async (req, res) => {
  const pathname = (req.url || '/').split('?')[0];
  try {
    if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(fs.readFileSync(INDEX_HTML));
      return;
    }

    if (pathname === '/api/config') {
      if (req.method === 'GET') return sendJson(res, 200, { owner: DEFAULT_OWNER, idPrefix: ID_PREFIX });
      return sendJson(res, 405, { error: 'method not allowed' });
    }

    if (pathname === '/api/epics') {
      if (req.method === 'GET') return handleEpics(res);
      return sendJson(res, 405, { error: 'method not allowed' });
    }

    // 解析失败的卡片档。这些档被刻意排除在 /api/cards 之外（塞进去会被拖拽
    // 静默覆盖掉），所以要有一个地方能看见它们，否则就变成无声消失。
    if (pathname === '/api/issues') {
      if (req.method === 'GET') {
        readAllCards();
        return sendJson(res, 200, { broken: BROKEN_FILES });
      }
      return sendJson(res, 405, { error: 'method not allowed' });
    }

    if (pathname === '/api/cards') {
      if (req.method === 'GET') return handleList(res);
      if (req.method === 'PUT') return handlePutBulk(res, await readBody(req));
      if (req.method === 'POST') return handlePost(res, await readBody(req));
      return sendJson(res, 405, { error: 'method not allowed' });
    }

    const match = pathname.match(/^\/api\/cards\/([^/]+)$/);
    if (match) {
      const id = decodeURIComponent(match[1]);
      if (!ID_RE.test(id)) return sendJson(res, 400, { error: 'id 必須符合 ^' + ID_PREFIX + '-\\d{3,}$' });
      if (req.method === 'PUT') return handlePutOne(req, res, id, await readBody(req));
      if (req.method === 'DELETE') return handleDelete(res, id);
      return sendJson(res, 405, { error: 'method not allowed' });
    }

    sendJson(res, 404, { error: 'not found' });
  } catch (err) {
    // 只有「有 body 的请求」才可能是 body 不合法。GET 走到这里必然是别的原因
    // （例如读档失败），不能挂在 body 头上。
    if (err instanceof SyntaxError && req.method !== 'GET') {
      sendJson(res, 400, { error: 'body 不是合法 JSON：' + err.message });
    } else {
      sendJson(res, 500, { error: '寫入失敗：' + err.message });
    }
  }
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[kanban] port ${PORT} 已被占用。請先關掉占用的程序（lsof -i :${PORT}）再重新啟動。`);
  } else {
    console.error('[kanban] server 啟動失敗：' + err.message);
  }
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`[kanban] 治理看板 → http://${HOST}:${PORT}`);
  console.log(`[kanban] 資料目錄：${CARDS_DIR}`);
});
