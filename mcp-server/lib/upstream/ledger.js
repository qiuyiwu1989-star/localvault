'use strict';

/**
 * 同步账本。
 *
 * 来件：「桥接账本建议按实例、资料ID、版本、分段记录：payload digest、目标scope、
 * 返回source_id/job_id、重试次数、最后错误及阶段状态。只有当前版本所有分段
 * 取得收据后，才能标记已归档；归档与索引状态分开，用memory_import_status检查。
 * 已归档不等于已提炼或已确认。」
 *
 * ## 阶段状态是分开的三件事，不是一根进度条
 *
 * ```
 *   submitted  已提交（拿到 source_id / job_id，但还没确认归档）
 *   receipted  已归档（当前版本的**所有**分段都拿到收据）
 *   indexed    已索引（服务端说索引完了）
 *   extracted  已提炼  ← 首版**永远不写这个值**
 *   confirmed  已确认  ← 首版**永远不写这个值**
 * ```
 *
 * 把它们压成一个「完成」布尔值是同一个病的另一种形态：之后没人分得清
 * 「送进去了」和「提炼过了」。来件专门点了这一条，所以这里用显式状态机。
 *
 * ## 幂等的依据是 source_key，不是自增 id
 *
 * `UNIQUE(instance, source_key)`：同一个 source_key 重复提交**只更新已有行**，
 * 不新建。网络超时后重试用完全相同的 source_key 和 payload，服务端也能因此去重。
 */

const fs = require('fs');
const path = require('path');

const SCHEMA_VERSION = 1;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS ledger_meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS submissions (
  id             INTEGER PRIMARY KEY,
  instance       TEXT NOT NULL,
  stable_id      TEXT NOT NULL,
  version_hash   TEXT NOT NULL,
  source_key     TEXT NOT NULL,
  part_index     INTEGER NOT NULL,
  part_total     INTEGER NOT NULL,
  locator        TEXT,
  payload_digest TEXT NOT NULL,
  scope          TEXT NOT NULL,
  source_type    TEXT NOT NULL,
  role           TEXT NOT NULL,
  payload_json   TEXT NOT NULL,
  stage          TEXT NOT NULL DEFAULT 'pending',
  source_id      TEXT,
  job_id         TEXT,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT,
  last_error_kind TEXT,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  UNIQUE(instance, source_key)
);

CREATE INDEX IF NOT EXISTS idx_sub_stable  ON submissions(instance, stable_id, version_hash);
CREATE INDEX IF NOT EXISTS idx_sub_stage   ON submissions(instance, stage);

CREATE TABLE IF NOT EXISTS cursors (
  instance   TEXT PRIMARY KEY,
  scan_id    INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tombstones (
  id         INTEGER PRIMARY KEY,
  instance   TEXT NOT NULL,
  stable_id  TEXT NOT NULL,
  source_key TEXT,
  reason     TEXT,
  state      TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  UNIQUE(instance, stable_id, source_key)
);

/* 同步账本自己的日志：只记数量/hash/错误类型，**不记正文**。 */
CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY,
  instance   TEXT NOT NULL,
  at         INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  detail     TEXT
);
`;

function openLedger(file) {
  const { DatabaseSync } = require('node:sqlite');
  const dir = path.dirname(file);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const db = new DatabaseSync(file);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA busy_timeout = 5000;');
  db.exec(SCHEMA);
  const cur = db.prepare('SELECT value FROM ledger_meta WHERE key = ?').get('schema_version');
  if (!cur) {
    db.prepare('INSERT INTO ledger_meta(key, value) VALUES (?, ?)').run('schema_version', String(SCHEMA_VERSION));
  } else if (Number(cur.value) !== SCHEMA_VERSION) {
    throw new Error(`同步账本 schema 版本不匹配：文件是 ${cur.value}，程序要 ${SCHEMA_VERSION}`);
  }
  return db;
}

/** 记一条：已存在则**不新建**（幂等）。返回 {id, isNew}。 */
function upsertSubmission(db, row) {
  const now = Date.now();
  const existing = db.prepare(
    'SELECT id, payload_digest, stage FROM submissions WHERE instance = ? AND source_key = ?'
  ).get(row.instance, row.sourceKey);

  if (existing) {
    if (existing.payload_digest !== row.payloadDigest) {
      // 同一个 source_key 配不同的 payload = source_key 撞了，绝不能覆盖已有的收据
      throw new Error(
        `source_key 冲突：${row.sourceKey}\n` +
        `  账本里已有 payload digest ${existing.payload_digest}，这次是 ${row.payloadDigest}。\n` +
        '  同一个 key 必须是同一份内容；出现这种情况说明版本 hash 覆盖不足，请先查清楚再提交。'
      );
    }
    return { id: existing.id, isNew: false };
  }

  const info = db.prepare(`
    INSERT INTO submissions
      (instance, stable_id, version_hash, source_key, part_index, part_total, locator,
       payload_digest, scope, source_type, role, payload_json,
       stage, attempts, created_at, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?, 'pending', 0, ?, ?)
  `).run(
    row.instance, row.stableId, row.versionHash, row.sourceKey,
    row.partIndex, row.partTotal, row.locator || null,
    row.payloadDigest, row.scope, row.sourceType, row.role,
    JSON.stringify(row.payload), now, now
  );
  return { id: Number(info.lastInsertRowid), isNew: true };
}

function markSubmitted(db, sourceKey, { sourceId, jobId }) {
  db.prepare(`
    UPDATE submissions
       SET stage = 'submitted', source_id = COALESCE(?, source_id), job_id = COALESCE(?, job_id),
           attempts = attempts + 1, last_error = NULL, last_error_kind = NULL, updated_at = ?
     WHERE source_key = ?
  `).run(sourceId || null, jobId || null, Date.now(), sourceKey);
}

function markReceipted(db, sourceKey) {
  db.prepare(`UPDATE submissions SET stage = 'receipted', updated_at = ? WHERE source_key = ?`)
    .run(Date.now(), sourceKey);
}

function markIndexed(db, sourceKey) {
  db.prepare(`UPDATE submissions SET stage = 'indexed', updated_at = ? WHERE source_key = ?`)
    .run(Date.now(), sourceKey);
}

function markFailed(db, sourceKey, kind, message) {
  db.prepare(`
    UPDATE submissions
       SET stage = CASE WHEN stage = 'receipted' THEN stage ELSE 'failed' END,
           attempts = attempts + 1, last_error = ?, last_error_kind = ?, updated_at = ?
     WHERE source_key = ?
  `).run(String(message || '').slice(0, 500), kind || 'unknown', Date.now(), sourceKey);
}

/** 涨一次 attempts（用于「结果不明」的重试：状态不变，只记次数）。 */
function bumpAttempt(db, sourceKey, kind, message) {
  db.prepare(`
    UPDATE submissions SET attempts = attempts + 1, last_error = ?, last_error_kind = ?, updated_at = ?
     WHERE source_key = ?
  `).run(String(message || '').slice(0, 500), kind || 'unknown', Date.now(), sourceKey);
}

/** 某个版本是不是**所有分段**都拿到收据了。 */
function versionComplete(db, instance, stableId, versionHash) {
  const r = db.prepare(`
    SELECT COUNT(*) AS total,
           SUM(CASE WHEN stage IN ('receipted','indexed') THEN 1 ELSE 0 END) AS done
      FROM submissions
     WHERE instance = ? AND stable_id = ? AND version_hash = ?
  `).get(instance, stableId, versionHash);
  const total = Number(r.total || 0);
  const done = Number(r.done || 0);
  return { total, done, complete: total > 0 && total === done };
}

/** 有待重试的分段（补偿回放的输入）。 */
function pendingParts(db, instance) {
  return db.prepare(`
    SELECT * FROM submissions
     WHERE instance = ? AND stage IN ('pending','failed','submitted')
     ORDER BY stable_id, part_index
  `).all(instance);
}

/** 重试次数用光的分段（需要人来处理，不要无限重试）。 */
function exhaustedParts(db, instance, maxAttempts) {
  return db.prepare(`
    SELECT * FROM submissions
     WHERE instance = ? AND stage IN ('pending','failed') AND attempts >= ?
     ORDER BY attempts DESC, stable_id
  `).all(instance, maxAttempts);
}

function getCursor(db, instance) {
  const r = db.prepare('SELECT scan_id FROM cursors WHERE instance = ?').get(instance);
  return r ? Number(r.scan_id) : 0;
}

function setCursor(db, instance, scanId) {
  db.prepare(`
    INSERT INTO cursors(instance, scan_id, updated_at) VALUES (?,?,?)
    ON CONFLICT(instance) DO UPDATE SET scan_id = excluded.scan_id, updated_at = excluded.updated_at
  `).run(instance, scanId, Date.now());
}

/**
 * 推进游标 —— **但绝不超过未持久记录的失败项**。
 *
 * 来件：「增量游标不得越过未持久记录的失败项；可持久记录失败后继续其他项，
 * 但必须能补偿回放。」
 *
 * 这里靠的是「先写账本、再动游标」的调用顺序（见 bridge.js），
 * 以及本函数的 `blocked` 参数：有未完成项时调用方必须传 false。
 */
function advanceCursor(db, instance, scanId, { blocked }) {
  if (blocked) return { advanced: false, scanId: getCursor(db, instance) };
  setCursor(db, instance, scanId);
  return { advanced: true, scanId };
}

function addTombstone(db, { instance, stableId, sourceKey, reason }) {
  const now = Date.now();
  const r = db.prepare(`
    INSERT INTO tombstones(instance, stable_id, source_key, reason, state, created_at)
    VALUES (?,?,?,?, 'pending', ?)
    ON CONFLICT(instance, stable_id, source_key) DO NOTHING
  `).run(instance, stableId, sourceKey || '', reason || '', now);
  return Number(r.changes) > 0;
}

function tombstoneCount(db, instance) {
  return Number(db.prepare('SELECT COUNT(*) AS n FROM tombstones WHERE instance = ?').get(instance).n);
}

function logEvent(db, instance, kind, detail) {
  db.prepare('INSERT INTO events(instance, at, kind, detail) VALUES (?,?,?,?)')
    .run(instance, Date.now(), kind, detail == null ? null : String(detail).slice(0, 500));
}

module.exports = {
  SCHEMA_VERSION,
  openLedger,
  upsertSubmission,
  markSubmitted,
  markReceipted,
  markIndexed,
  markFailed,
  bumpAttempt,
  versionComplete,
  pendingParts,
  exhaustedParts,
  getCursor,
  setCursor,
  advanceCursor,
  addTombstone,
  tombstoneCount,
  logEvent,
};
