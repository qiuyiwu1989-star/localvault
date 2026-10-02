'use strict';

/**
 * SQLite 存储层（node:sqlite，零外部依赖）。
 * 表结构刻意保持扁平：一次查询即可完成过滤 + 评分 + 排序。
 */

const fs = require('node:fs');
const path = require('node:path');
const { ensureDir } = require('./util');

const SCHEMA_VERSION = 1;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS files (
  id          INTEGER PRIMARY KEY,
  root        TEXT NOT NULL,
  path        TEXT NOT NULL UNIQUE,
  rel         TEXT NOT NULL,
  name        TEXT NOT NULL,
  ext         TEXT DEFAULT '',
  kind        TEXT DEFAULT 'other',
  size        INTEGER DEFAULT 0,
  mtime       INTEGER DEFAULT 0,
  birthtime   INTEGER DEFAULT 0,
  is_text     INTEGER DEFAULT 0,
  is_symlink  INTEGER DEFAULT 0,
  denied      INTEGER DEFAULT 0,
  is_binary   INTEGER DEFAULT 0,
  title       TEXT DEFAULT '',
  headings    TEXT DEFAULT '',
  body        TEXT DEFAULT '',
  truncated   INTEGER DEFAULT 0,
  scan_id     INTEGER DEFAULT 0,
  gone        INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_files_root   ON files(root);
CREATE INDEX IF NOT EXISTS idx_files_mtime  ON files(mtime);
CREATE INDEX IF NOT EXISTS idx_files_size   ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_name   ON files(name);
CREATE INDEX IF NOT EXISTS idx_files_kind   ON files(kind);
CREATE INDEX IF NOT EXISTS idx_files_gone   ON files(gone);

CREATE TABLE IF NOT EXISTS scan_runs (
  id          INTEGER PRIMARY KEY,
  started_at  INTEGER,
  finished_at INTEGER,
  root        TEXT,
  files_seen  INTEGER DEFAULT 0,
  files_added INTEGER DEFAULT 0,
  files_updated INTEGER DEFAULT 0,
  files_removed INTEGER DEFAULT 0,
  dirs_seen   INTEGER DEFAULT 0,
  skipped_dirs INTEGER DEFAULT 0,
  errors      INTEGER DEFAULT 0,
  elapsed_ms  INTEGER DEFAULT 0,
  ok          INTEGER DEFAULT 1,
  detail      TEXT
);
`;

function openDatabase(dbPath) {
  const { DatabaseSync } = require('node:sqlite');
  ensureDir(path.dirname(dbPath));
  const db = new DatabaseSync(dbPath);
  // ⚠️ 顺序要紧：**先设 busy_timeout，再切 WAL。**
  //
  // 反了没用 —— 实测过。按「先 WAL 后 timeout」写，3 个并发 `cli.js index`
  // 仍有一个崩在 `PRAGMA journal_mode = WAL` 上：那一句自己也要拿锁，
  // 而它跑在超时生效**之前**，所以是立刻失败（原始崩溃栈就指向这一行）。
  //
  // 为什么要有 timeout：实测 3 个并发 index，2 个以 `database is locked` 栈回溯退出。
  // 而 App 侧**一直有这个设置**（`VaultIndexer.swift:158`，
  // 那里的注释还写着「busy_timeout 是这里加的」）—— 也就是这是已知的，
  // 只是没补到 CLI 上。同一个库、两个入口，一个会等、一个会崩。
  //
  // 5000ms 与 App 侧一致：两边取值必须一样，否则「改用 App」和「改用 CLI」
  // 会得到不同的行为。
  db.exec('PRAGMA busy_timeout = 5000;');
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec('PRAGMA synchronous = NORMAL;');
  db.exec('PRAGMA temp_store = MEMORY;');
  db.exec(SCHEMA);
  const current = getMeta(db, 'schema_version');
  if (current == null) setMeta(db, 'schema_version', String(SCHEMA_VERSION));
  return db;
}

function getMeta(db, key) {
  try {
    const row = db.prepare('SELECT value FROM meta WHERE key = ?').get(key);
    return row ? row.value : null;
  } catch (_e) {
    return null;
  }
}

function setMeta(db, key, value) {
  db.prepare('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(
    key,
    value == null ? null : String(value),
  );
}

function getMetaJson(db, key) {
  const raw = getMeta(db, key);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (_e) {
    return null;
  }
}

function setMetaJson(db, key, value) {
  setMeta(db, key, JSON.stringify(value));
}

/** 批量写入器：一次扫描一个事务，显著快于逐条提交。 */
class BatchWriter {
  constructor(db) {
    this.db = db;
    this.stmt = db.prepare(`
      INSERT INTO files (root, path, rel, name, ext, kind, size, mtime, birthtime,
                         is_text, is_symlink, denied, is_binary, title, headings, body,
                         truncated, scan_id, gone)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
      ON CONFLICT(path) DO UPDATE SET
        root = excluded.root, rel = excluded.rel, name = excluded.name, ext = excluded.ext,
        kind = excluded.kind, size = excluded.size, mtime = excluded.mtime,
        birthtime = excluded.birthtime, is_text = excluded.is_text,
        is_symlink = excluded.is_symlink, denied = excluded.denied,
        is_binary = excluded.is_binary, title = excluded.title,
        headings = excluded.headings, body = excluded.body,
        truncated = excluded.truncated, scan_id = excluded.scan_id, gone = 0
    `);
    // 未变化的文件只更新元数据列，避免把正文重写一遍（省 IO、省时间）。
    this.touchStmt = db.prepare(`
      UPDATE files SET root = ?, rel = ?, name = ?, ext = ?, kind = ?,
                       size = ?, mtime = ?, scan_id = ?, gone = 0, denied = ?
      WHERE path = ?
    `);
    this.count = 0;
    this.inTx = false;
  }

  begin() {
    if (!this.inTx) {
      this.db.exec('BEGIN');
      this.inTx = true;
    }
  }

  put(rec) {
    this.begin();
    this.stmt.run(
      rec.root,
      rec.path,
      rec.rel,
      rec.name,
      rec.ext || '',
      rec.kind || 'other',
      rec.size || 0,
      rec.mtime || 0,
      rec.birthtime || 0,
      rec.isText ? 1 : 0,
      rec.isSymlink ? 1 : 0,
      rec.denied ? 1 : 0,
      rec.isBinary ? 1 : 0,
      rec.title || '',
      rec.headings || '',
      rec.body || '',
      rec.truncated ? 1 : 0,
      rec.scanId || 0,
    );
    this.count += 1;
    if (this.count % 2000 === 0) {
      // 定期提交，避免单个大事务内存膨胀
      this.db.exec('COMMIT');
      this.db.exec('BEGIN');
    }
  }

  /** 只刷新元数据，保留既有正文。返回 false 表示行不存在，需要改用 put()。 */
  touch(rec) {
    this.begin();
    const res = this.touchStmt.run(
      rec.root,
      rec.rel,
      rec.name,
      rec.ext || '',
      rec.kind || 'other',
      rec.size || 0,
      rec.mtime || 0,
      rec.scanId || 0,
      rec.denied ? 1 : 0,
      rec.path,
    );
    this.count += 1;
    if (this.count % 5000 === 0) {
      this.db.exec('COMMIT');
      this.db.exec('BEGIN');
    }
    return (res.changes || 0) > 0;
  }

  commit() {
    if (this.inTx) {
      this.db.exec('COMMIT');
      this.inTx = false;
    }
  }
}

/** 把本次扫描未出现的记录标记为 gone。 */
/**
 * 把「本次扫描没见过」的行标成 `gone = 1`。
 *
 * **`scan_id` 也要一起更新**（2026-10-02 修）。
 *
 * 原来只写 `gone = 1`，`scan_id` 保持旧值。后果：
 * 「按 `scan_id` 增量枚举变化」**永远看不见删除** ——
 * 因为被删的行 scan_id 还是上一次的，`WHERE scan_id > cursor` 筛不出来。
 * 筛不出来的东西不会报错，只是那一段代码永远不执行。
 *
 * 语义上也该更新：`scan_id` 是「最后一次触及这一行的扫描」，
 * 而把它标成 gone，就是这次扫描触及了它。
 */
function markGoneOlderThan(db, root, scanId) {
  const res = db.prepare('UPDATE files SET gone = 1, scan_id = ? WHERE root = ? AND scan_id <> ? AND gone = 0')
    .run(scanId, root, scanId);
  return res.changes || 0;
}

function countFiles(db, where, params) {
  const sql = `SELECT COUNT(*) AS c FROM files WHERE gone = 0 ${where ? 'AND ' + where : ''}`;
  const row = db.prepare(sql).get(...(params || []));
  return row ? Number(row.c) : 0;
}

function recordScanRun(db, run) {
  db.prepare(`
    INSERT INTO scan_runs (started_at, finished_at, root, files_seen, files_added, files_updated,
                           files_removed, dirs_seen, skipped_dirs, errors, elapsed_ms, ok, detail)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
  `).run(
    run.startedAt || 0,
    run.finishedAt || 0,
    run.root || '',
    run.filesSeen || 0,
    run.filesAdded || 0,
    run.filesUpdated || 0,
    run.filesRemoved || 0,
    run.dirsSeen || 0,
    run.skippedDirs || 0,
    run.errors || 0,
    run.elapsedMs || 0,
    run.ok === false ? 0 : 1,
    run.detail || '',
  );
}

function recentScanRuns(db, limit) {
  return db
    .prepare('SELECT * FROM scan_runs ORDER BY id DESC LIMIT ?')
    .all(limit || 10);
}

module.exports = {
  SCHEMA_VERSION,
  openDatabase,
  getMeta,
  setMeta,
  getMetaJson,
  setMetaJson,
  BatchWriter,
  markGoneOlderThan,
  countFiles,
  recordScanRun,
  recentScanRuns,
};
