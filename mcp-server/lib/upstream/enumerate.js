'use strict';

/**
 * 来件建议的两个本地能力：
 *
 *   1. **枚举变化** —— 自上次游标以来，哪些资料新增 / 改了 / 消失了
 *   2. **读取指定版本资料** —— 按 stableId 取回**磁盘上的全文**
 *
 * 都建在现有 `files` 表上，**不改 schema、不建新表**。
 *
 * ## 游标就是 `scan_id`
 *
 * `indexer.js` 里 `scanId = Date.now()`，每次扫描单调递增；
 * 被这次扫描触及的行写上新 scanId，没触及的行被 `markGoneOlderThan` 标 `gone=1`
 * （**行不删** —— 留着才看得见「它曾经存在」）。
 *
 * 所以：
 *   - 新增/改动 = `WHERE scan_id > :cursor`
 *   - 消失      = `WHERE scan_id > :cursor AND gone = 1`
 *
 * 不需要 `updated_at` 列、不需要触发器、不需要 changelog 表。
 *
 * ## 「读版本」为什么不复用 `files.body`
 *
 * `maxStoredBodyChars = 400000`，当前真实库里 **22 行 `truncated = 1`**。
 * 复用索引正文 = 长文档在无声中短一截，而且 `truncated` 标记一旦没看就被忽略。
 * 所以这里**一律回磁盘读**，并且读出来的字节数要与 `files.size` 对得上；
 * 对不上就报错，不提交 —— 宁可这一份这次不发，也不要发一份短的。
 */

const fs = require('fs');
const path = require('path');

/** 路径 → stableId 用的规范化 rel（斜杠统一，去前导 ./）。 */
function normalizeRel(rel) {
  return String(rel).replace(/\\/g, '/').replace(/^\.\//, '');
}

/**
 * **只读**打开 vault.db。
 *
 * 刻意不用 `store.openDatabase()`：那个会 `PRAGMA journal_mode = WAL` 并建表 ——
 * 桥接端是**读取方**，不该对用户的索引库有任何写入行为
 * （写 WAL 头会改动文件、可能和 App / CLI 抢锁）。
 */
function openVaultReadOnly(dbPath) {
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(dbPath, { readOnly: true });
  db.exec('PRAGMA busy_timeout = 5000;');
  return db;
}

/**
 * 枚举变化。
 *
 * @param {object} db           vault.db 连接（只读使用）
 * @param {number} cursor       上次的 scan_id
 * @param {object} [opts]
 * @param {Map<string,object>} [opts.allow]  白名单（key = `${root}\u0000${rel}`）；传了就只回允许的
 * @returns {{cursor:number, nextCursor:number, changed:Array, removed:Array}}
 */
function enumerateChanges(db, cursor, opts = {}) {
  const allow = opts.allow || null;

  const changed = db.prepare(`
    SELECT id, root, path, rel, name, ext, kind, size, mtime, is_text, is_binary,
           denied, truncated, gone, scan_id
      FROM files
     WHERE scan_id > ?
     ORDER BY scan_id, root, rel
  `).all(cursor);

  let nextCursor = cursor;
  for (const r of changed) if (Number(r.scan_id) > nextCursor) nextCursor = Number(r.scan_id);

  const isAllowed = (r) => !allow || allow.has(`${r.root}\u0000${normalizeRel(r.rel)}`);

  const live = [];
  const removed = [];
  for (const r of changed) {
    if (!isAllowed(r)) continue;
    if (r.gone) removed.push(r); else live.push(r);
  }

  return { cursor, nextCursor, changed: live, removed };
}

/**
 * 读指定版本资料：**从磁盘读全文**。
 *
 * @returns {{ok:true, text:string, bytes:number, rel:string, abs:string}
 *          | {ok:false, reason:string, kind:string}}
 */
function readVersion(row) {
  const abs = row.path;
  let st;
  try {
    st = fs.statSync(abs);
  } catch (e) {
    return { ok: false, kind: 'missing', reason: `读不到了：${e.code || e.message}`, abs };
  }
  if (!st.isFile()) return { ok: false, kind: 'not-file', reason: '不是普通文件', abs };

  if (row.size && st.size !== Number(row.size)) {
    // 索引与磁盘不一致：说明索引刚过期。**照实说**，不猜哪个对。
    return {
      ok: false,
      kind: 'size-mismatch',
      reason: `索引记 ${row.size} 字节，磁盘是 ${st.size} 字节 —— 索引已过期，先重跑索引`,
      abs,
    };
  }

  let text;
  try {
    text = fs.readFileSync(abs, 'utf8');
  } catch (e) {
    return { ok: false, kind: 'read-failed', reason: `读失败：${e.code || e.message}`, abs };
  }

  if (text.includes('\u0000')) {
    // 二进制文件被当成文本读了。不提交 —— 提交出去就是一堆乱码。
    return { ok: false, kind: 'binary', reason: '正文里有 NUL，看起来是二进制文件', abs };
  }

  return { ok: true, text, bytes: Buffer.byteLength(text, 'utf8'), rel: normalizeRel(row.rel), abs };
}

/** 按 stableId 反查（补偿回放时要能凭账本里的 ID 找回原文）。 */
function findByIdentity(db, stableId, versionHash) {
  const rows = db.prepare('SELECT id, root, rel, path, size, mtime FROM files').all();
  const { stableId: sid } = require('./versions');
  for (const r of rows) {
    if (sid(r.root, normalizeRel(r.rel)) === stableId) return r;
  }
  return null;
}

module.exports = { enumerateChanges, readVersion, normalizeRel, findByIdentity, openVaultReadOnly };
