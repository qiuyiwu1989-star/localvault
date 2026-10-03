'use strict';
/**
 * 判断记忆（条陈）的**读侧** —— 让 agent 看得见「你签过的判断」。
 *
 * ## 为什么需要它
 *
 * App 里那张「提炼」页能签判断（保留 / 待看 / 可归档 / 可清理），
 * 写进 `~/.localvault/claims.db`。但在这一步之前，**CLI 与 MCP 侧一行都没有** ——
 * 判断写得进、读不出来。于是 agent 永远不知道你已经说过「这个别删」，
 * 只能反复问，或者更糟：它以为自己知道。
 *
 * ## 表结构必须与 App 逐字一致
 *
 * 写这个文件的是 Swift（`app/Sources/LocalVault/ClaimStore.swift`），
 * 读它的是这里。两个语言、一个文件。所以下面这段 DDL 是**照抄**，
 * 不是「大致等价」—— 列名、NOT NULL、CHECK 都要一模一样。
 * `test/claims.js` 里有一条对拍：拿 Swift 的 DDL 原文与这里的逐字比对。
 *
 * ## 两个不变量，在这边也要是硬的
 *
 * - **I**：`signed_by` 与 `actor_type` 都 NOT NULL。人和机器一眼可分。
 *   **机器只能落 L0 待签**，越界直接拒。
 * - **II**：**只追加**。当前判断是事件流的投影（每个目标取最新一条）。
 *   撤回 = 追加一条 `撤回` 条陈，**不删行**。
 *   这边不只靠「我不写 UPDATE/DELETE」——那样只是自律。
 *   真正的保证是**数据库层的 TRIGGER**：谁写 UPDATE/DELETE 都失败。
 *
 * 「靠约定」和「靠约束」的区别，在没人遵守约定的那天才看得出来。
 */

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

/** 判断的四个词。与 Swift 的 `enum Verdict` 一致。 */
const VERDICTS = ['保留', '待看', '可归档', '可清理'];

/** 撤回**不是一个词**，是一个动作：追加一条 `撤回`，旧判断留在历史里。 */
const RETRACTED = '撤回';

const KINDS = ['event', 'material', 'fact', 'judgment', 'consequence'];
const TARGET_TYPES = ['file', 'dir', 'project'];
const ACTOR_TYPES = ['human', 'machine'];
const AUTHORITIES = ['L0', 'L1', 'L2'];

/** 机器写的东西必须挂在一个可追溯的策略名下，而不是假装是人。 */
const MACHINE_POLICY = 'policy:localvault-agent';

/**
 * 与 `ClaimStore.swift` 的 DDL **逐字一致**。
 * 改了这里就必须改那边 —— `test/claims.js` 会把两份原文对比，不一样就红。
 */
const CLAIMS_SCHEMA = `CREATE TABLE IF NOT EXISTS claims (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  kind         TEXT    NOT NULL,
  target_type  TEXT    NOT NULL,
  target       TEXT    NOT NULL,
  verdict      TEXT,
  note         TEXT    NOT NULL DEFAULT '',
  source_ref   TEXT    NOT NULL,
  holder       TEXT    NOT NULL,
  signed_by    TEXT    NOT NULL,
  actor_type   TEXT    NOT NULL CHECK(actor_type IN ('human','machine')),
  authority    TEXT    NOT NULL CHECK(authority IN ('L0','L1','L2')),
  ts           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_claims_target ON claims(target_type, target, ts);
CREATE INDEX IF NOT EXISTS idx_claims_kind   ON claims(kind, ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);`;

/**
 * 不变量 II 的**数据库层**实现。
 *
 * `RAISE(ABORT, …)` 让整条语句失败并回滚，不是静默忽略。
 * 注意：`meta` 表**不在**保护范围 —— 签字人本来就要能改（`ON CONFLICT DO UPDATE`）。
 * 受保护的是 `claims` 这张只该增长的账。
 */
const APPEND_ONLY_TRIGGERS = `CREATE TRIGGER IF NOT EXISTS claims_no_update BEFORE UPDATE ON claims
BEGIN
  SELECT RAISE(ABORT, '条陈只可追加：不允许 UPDATE（不变量 II）。撤回应追加一条「撤回」。');
END;
CREATE TRIGGER IF NOT EXISTS claims_no_delete BEFORE DELETE ON claims
BEGIN
  SELECT RAISE(ABORT, '条陈只可追加：不允许 DELETE（不变量 II）。没有任何删除路径是设计如此。');
END;`;

function claimsDbPath(cfg) {
  return path.join(cfg.dataDirAbs, 'claims.db');
}

/**
 * 判断记忆库在不在。
 *
 * **不主动创建。** 写这个库的是 App；CLI 凭空造一个空的，
 * 会让「App 还没写过任何判断」和「判断都被清空了」看起来一样。
 */
function claimsExists(cfg) {
  try {
    return fs.existsSync(claimsDbPath(cfg));
  } catch {
    return false;
  }
}

/**
 * 打开判断记忆库。
 *
 * **读不建、写可建**：
 * - 默认（读）：文件不在就明确说「还不存在」，**不造**。
 *   凭空造一个空的，会让「还没签过」和「判断被清空了」看起来一样。
 * - `{create: true}`（写路径）：要往里写东西了，这时候建是合理的。
 * - `{readOnly: true}`：任何时候都不建，而且连触发器都不装。
 *
 * @param {object} cfg
 * @param {{readOnly?: boolean, create?: boolean}} [opts]
 * @returns {{ok: true, db: object, dbPath: string} | {ok: false, reason: string}}
 */
function openClaims(cfg, opts = {}) {
  const dbPath = claimsDbPath(cfg);
  const exists = fs.existsSync(dbPath);
  if (!exists && !(opts.create && !opts.readOnly)) {
    return {
      ok: false,
      reason: `判断记忆库还不存在：${dbPath}\n` +
        `它由 App 的「提炼」页写入 —— 你还没在 App 里签过任何判断。`,
    };
  }

  let db;
  try {
    if (!exists) fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    db = new DatabaseSync(dbPath, opts.readOnly ? { readOnly: true } : {});
  } catch (e) {
    return { ok: false, reason: `打不开判断记忆库：${e.message}` };
  }

  // 顺序是硬要求：**先 busy_timeout，再碰别的**。
  // App 可能正开着这个库；而等待超时必须在第一次要锁之前就生效。
  try { db.exec('PRAGMA busy_timeout = 5000;'); } catch { /* 读-only 下也可能被拒，无所谓 */ }

  if (!opts.readOnly) {
    try {
      db.exec(CLAIMS_SCHEMA);
      db.exec(APPEND_ONLY_TRIGGERS);
    } catch (e) {
      try { db.close(); } catch { /* 关不掉也没别的办法 */ }
      return { ok: false, reason: `初始化判断记忆库失败：${e.message}` };
    }
  }
  return { ok: true, db, dbPath };
}

function rowToClaim(r) {
  return {
    id: Number(r.id),
    kind: r.kind,
    targetType: r.target_type,
    target: r.target,
    verdict: r.verdict === null || r.verdict === undefined ? null : r.verdict,
    note: r.note,
    sourceRef: r.source_ref,
    holder: r.holder,
    signedBy: r.signed_by,
    actorType: r.actor_type,
    authority: r.authority,
    ts: Number(r.ts),
    isMachine: r.actor_type === 'machine',
    at: new Date(Number(r.ts) * 1000).toISOString().replace('T', ' ').slice(0, 16),
  };
}

/**
 * 事件流：全部条陈，按时间倒序（与 Swift 的 `ORDER BY ts DESC, id DESC` 同序）。
 *
 * `ts` 只到秒，同一秒内多条是常态（点一下签一条，点得快就连着几条）。
 * 所以**必须**带 `id DESC` 兜底 —— 只按 ts 排，同一秒内的顺序是不确定的，
 * 于是「投影」会随机取到新旧其中一条。这是那种能过一百次、第一百零一次错的 bug。
 */
function listClaims(db, opts = {}) {
  const where = [];
  const params = [];
  if (opts.target) { where.push('target = ?'); params.push(opts.target); }
  if (opts.targetType) { where.push('target_type = ?'); params.push(opts.targetType); }
  if (opts.kind) { where.push('kind = ?'); params.push(opts.kind); }
  if (opts.actorType) { where.push('actor_type = ?'); params.push(opts.actorType); }
  if (opts.signedBy) { where.push('signed_by = ?'); params.push(opts.signedBy); }
  if (opts.sinceMs) { where.push('ts >= ?'); params.push(Math.floor(opts.sinceMs / 1000)); }

  const limit = Number.isFinite(opts.limit) && opts.limit > 0 ? Math.min(opts.limit, 5000) : 500;
  const sql = `SELECT id,kind,target_type,target,verdict,note,source_ref,holder,
                      signed_by,actor_type,authority,ts
               FROM claims ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
               ORDER BY ts DESC, id DESC LIMIT ?`;
  const rows = db.prepare(sql).all(...params, limit);

  const totalSql = `SELECT count(*) c FROM claims ${where.length ? 'WHERE ' + where.join(' AND ') : ''}`;
  const total = Number(db.prepare(totalSql).get(...params).c);

  return { rows: rows.map(rowToClaim), total, shown: rows.length };
}

/**
 * 当前状态 = 事件流的投影：每个目标取最新一条，撤回的不在内。
 *
 * `seen` 那一步**不是多余的**。少了它，撤回过的目标会从结果里消失，
 * 于是**更旧的那条判断被重新填回来** —— 撤回就白撤了。
 * Swift 那边有一模一样的注释；两边都得对。
 */
function projectCurrent(rows) {
  const proj = new Map();
  const seen = new Set();
  for (const c of rows) {
    if (seen.has(c.target)) continue;
    seen.add(c.target);
    if (c.verdict === RETRACTED) continue;
    proj.set(c.target, c);
  }
  return proj;
}

function summary(db) {
  const all = listClaims(db, { limit: 1 });
  const every = db.prepare(
    `SELECT id,kind,target_type,target,verdict,note,source_ref,holder,
            signed_by,actor_type,authority,ts
     FROM claims ORDER BY ts DESC, id DESC`
  ).all().map(rowToClaim);

  const current = projectCurrent(every);
  const byVerdict = {};
  for (const v of VERDICTS) byVerdict[v] = 0;
  let unjudged = 0;
  for (const c of current.values()) {
    if (c.verdict === null) { unjudged++; continue; }
    if (byVerdict[c.verdict] === undefined) byVerdict[c.verdict] = 0;
    byVerdict[c.verdict]++;
  }

  return {
    eventCount: all.total,
    currentTargets: current.size,
    byVerdict,
    machineNotes: every.filter((c) => c.isMachine).length,
    humanClaims: every.filter((c) => !c.isMachine).length,
    retractedTargets: [...new Set(every.filter((c) => c.verdict === RETRACTED).map((c) => c.target))].length,
    unjudgedCurrent: unjudged,
    signer: (() => {
      try {
        const r = db.prepare("SELECT value FROM meta WHERE key='signer'").get();
        return r ? r.value : null;
      } catch { return null; }
    })(),
  };
}

/**
 * 追加一条条陈。**这是这个模块里唯一的写操作，而且它只增不改。**
 *
 * 与 Swift 的 `append()` 同一套校验，逐条：
 * - 四个必填字段不能是空串（`NOT NULL` 挡不住空字符串）；
 * - 机器只能写 L0 —— 越界直接拒，不写进去再报错。
 *
 * **这个函数不提供人类判断的写法。** agent 不签人的判断；
 * 它只能 `annotate`（L0 待签），等人在 App 里批。
 */
function appendClaim(db, c) {
  const need = ['kind', 'targetType', 'target', 'sourceRef', 'holder', 'signedBy', 'actorType', 'authority'];
  for (const k of need) {
    if (typeof c[k] !== 'string' || c[k].trim() === '') {
      return { ok: false, reason: `条陈缺少必填字段：${k}（不可为空）` };
    }
  }
  if (!KINDS.includes(c.kind)) return { ok: false, reason: `kind 不认识：${c.kind}（只接受 ${KINDS.join('/')}）` };
  if (!TARGET_TYPES.includes(c.targetType)) return { ok: false, reason: `targetType 不认识：${c.targetType}` };
  if (!ACTOR_TYPES.includes(c.actorType)) return { ok: false, reason: `actorType 不认识：${c.actorType}` };
  if (!AUTHORITIES.includes(c.authority)) return { ok: false, reason: `authority 不认识：${c.authority}` };

  // 不变量 I 的硬边：机器不准写 L1/L2。
  if (c.actorType === 'machine' && c.authority !== 'L0') {
    return { ok: false, reason: '机器只能写 L0 待签条陈（不变量 I）—— 已批的判断只能由人签。' };
  }
  // 有 verdict 就是一条判断；判断必须是人签的。
  if (c.verdict && c.actorType !== 'human') {
    return { ok: false, reason: '判断（verdict）只能由人签 —— 机器只能写备注。' };
  }
  if (c.verdict && !VERDICTS.includes(c.verdict)) {
    return { ok: false, reason: `verdict 不认识：${c.verdict}（只接受 ${VERDICTS.join('/')}）` };
  }

  const ts = Number.isFinite(c.ts) ? Math.floor(c.ts) : Math.floor(Date.now() / 1000);
  try {
    db.prepare(
      `INSERT INTO claims
         (kind,target_type,target,verdict,note,source_ref,holder,signed_by,actor_type,authority,ts)
       VALUES (?,?,?,?,?,?,?,?,?,?,?)`
    ).run(c.kind, c.targetType, c.target, c.verdict ?? null, c.note ?? '',
          c.sourceRef, c.holder, c.signedBy, c.actorType, c.authority, ts);
  } catch (e) {
    return { ok: false, reason: `追加失败：${e.message}` };
  }
  const id = Number(db.prepare('SELECT last_insert_rowid() id').get().id);
  return { ok: true, id };
}

/** 机器备注的便利写法：固定挂 `policy:localvault-agent`、固定 L0。 */
function annotate(db, { target, targetType = 'file', note, kind = 'material', holder = MACHINE_POLICY }) {
  return appendClaim(db, {
    kind, targetType, target,
    verdict: null, note,
    sourceRef: `vault://file/${target}`,
    holder, signedBy: MACHINE_POLICY,
    actorType: 'machine', authority: 'L0',
  });
}

// ── 给人看的渲染 ────────────────────────────────────────────────────

function renderCurrentMarkdown(proj, opts = {}) {
  const L = [];
  const entries = [...proj.values()].sort((a, b) => b.ts - a.ts);
  L.push(`# 你签过的判断（当前 ${entries.length} 个目标）`);
  L.push('');
  if (opts.signer) L.push(`签字人：**${opts.signer}**`);
  L.push('');
  if (!entries.length) {
    L.push('（还没有任何判断。App 的「提炼」页里签一条就会出现在这里。）');
    return L.join('\n');
  }
  L.push('| 判断 | 目标 | 时间 | 备注 |');
  L.push('| --- | --- | --- | --- |');
  for (const c of entries.slice(0, opts.limit || 200)) {
    L.push(`| ${c.verdict ?? '（机器备注）'} | \`${c.target}\` | ${c.at} | ${(c.note || '').replace(/\|/g, '\\|')} |`);
  }
  if (entries.length > (opts.limit || 200)) {
    L.push('');
    L.push(`> 只列了最近 ${opts.limit || 200} 条，共 ${entries.length} 条。`);
  }
  return L.join('\n');
}

function renderHistoryMarkdown(rows, total, shown) {
  const L = [`# 判断记忆的事件流（共 ${total} 条，列出 ${shown} 条）`, ''];
  L.push('**只追加，不修改，不删除。** 撤回也是一条新记录。');
  L.push('');
  L.push('| 时间 | 类型 | 目标 | 判断 | 谁写的 | 权威级 |');
  L.push('| --- | --- | --- | --- | --- | --- |');
  for (const c of rows) {
    L.push(`| ${c.at} | ${c.kind} | \`${c.target}\` | ${c.verdict ?? '—'} | ${c.signedBy}（${c.actorType === 'machine' ? '机器' : '人'}） | ${c.authority} |`);
  }
  return L.join('\n');
}

module.exports = {
  VERDICTS, RETRACTED, KINDS, TARGET_TYPES, ACTOR_TYPES, AUTHORITIES, MACHINE_POLICY,
  CLAIMS_SCHEMA, APPEND_ONLY_TRIGGERS,
  claimsDbPath, claimsExists, openClaims,
  listClaims, projectCurrent, summary,
  appendClaim, annotate,
  renderCurrentMarkdown, renderHistoryMarkdown,
};
