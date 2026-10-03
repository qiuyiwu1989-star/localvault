'use strict';

/**
 * 检索层。
 *
 * 设计取舍：中文语料下分词不可靠，因此不做分词，直接用 SQL LIKE 子串匹配。
 * 本机语料量级（正文十几 MB）下全表 LIKE 扫描在 10~50ms 之间，换来的是
 * 「任意 2 字以上中文子串都能命中」这一确定性行为 —— 这比 FTS5 的
 * unicode61/trigram 分词器在中文上的表现更符合预期。
 * 排序在 SQL 内完成（字段权重 + 时间），摘要与微调在 JS 侧完成。
 */

const path = require('node:path');
const { toPosix, formatBytes, formatDate, squeeze, truncate, parseSince } = require('./util');

const FIELD_WEIGHTS = {
  name: 40,
  rel: 18,
  title: 16,
  headings: 10,
  body: 5,
};

const SCOPE_FIELDS = {
  all: ['name', 'rel', 'title', 'headings', 'body'],
  name: ['name', 'rel'],
  content: ['title', 'headings', 'body'],
};

function escapeLike(s) {
  return String(s).replace(/[\\%_]/g, (m) => '\\' + m);
}

function normalizeExt(ext) {
  if (!ext) return null;
  const list = String(ext)
    .split(/[,\s]+/)
    .filter(Boolean)
    .map((e) => (e.startsWith('.') ? e : '.' + e).toLowerCase());
  return list.length ? list : null;
}

function normalizeKind(kind) {
  if (!kind || kind === 'any' || kind === 'all') return null;
  const list = String(kind)
    .split(/[,\s]+/)
    .filter(Boolean)
    .map((k) => k.toLowerCase());
  return list.length ? list : null;
}

/**
 * @param {object} db
 * @param {object} cfg
 * @param {object} opts 见 README
 */
function searchFiles(db, cfg, opts) {
  const started = Date.now();
  const o = opts || {};
  const limit = Math.min(Math.max(Number(o.limit) || 20, 1), 200);
  const fetchLimit = Math.min(limit * 3 + 1, 600);
  const scope = SCOPE_FIELDS[o.scope] || SCOPE_FIELDS.all;
  const sort = o.sort || (o.query ? 'relevance' : 'recent');
  const includeDenied = Boolean(o.includeDenied);

  const terms = String(o.query || '')
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean)
    .slice(0, 6);

  const scoreParts = [];
  const scoreParams = [];
  const whereParts = [];
  const whereParams = [];

  for (const term of terms) {
    const like = '%' + escapeLike(term) + '%';
    const w = [];
    if (scope.includes('name')) w.push(`(name LIKE ? ESCAPE '\\' OR rel LIKE ? ESCAPE '\\')`);
    if (scope.includes('title')) w.push(`title LIKE ? ESCAPE '\\'`);
    if (scope.includes('headings')) w.push(`headings LIKE ? ESCAPE '\\'`);
    if (scope.includes('body')) w.push(`body LIKE ? ESCAPE '\\'`);
    whereParts.push('(' + w.join(' OR ') + ')');
    if (scope.includes('name')) whereParams.push(like, like);
    if (scope.includes('title')) whereParams.push(like);
    if (scope.includes('headings')) whereParams.push(like);
    if (scope.includes('body')) whereParams.push(like);

    // 评分：同一次查询里给出字段权重，避免额外扫描
    const s = [];
    if (scope.includes('name')) s.push(`(CASE WHEN name LIKE ? ESCAPE '\\' THEN ${FIELD_WEIGHTS.name} ELSE 0 END + CASE WHEN rel LIKE ? ESCAPE '\\' THEN ${FIELD_WEIGHTS.rel} ELSE 0 END)`);
    if (scope.includes('title')) s.push(`(CASE WHEN title LIKE ? ESCAPE '\\' THEN ${FIELD_WEIGHTS.title} ELSE 0 END)`);
    if (scope.includes('headings')) s.push(`(CASE WHEN headings LIKE ? ESCAPE '\\' THEN ${FIELD_WEIGHTS.headings} ELSE 0 END)`);
    if (scope.includes('body')) s.push(`(CASE WHEN body LIKE ? ESCAPE '\\' THEN ${FIELD_WEIGHTS.body} ELSE 0 END)`);
    scoreParts.push('(' + s.join(' + ') + ')');
    if (scope.includes('name')) scoreParams.push(like, like);
    if (scope.includes('title')) scoreParams.push(like);
    if (scope.includes('headings')) scoreParams.push(like);
    if (scope.includes('body')) scoreParams.push(like);
  }

  const scoreExpr = scoreParts.length ? scoreParts.join(' + ') : '0';

  if (o.root) {
    const roots = Array.isArray(o.root) ? o.root : [o.root];
    whereParts.push('(' + roots.map(() => 'root = ?').join(' OR ') + ')');
    for (const r of roots) whereParams.push(r);
  }
  if (o.pathPrefix) {
    const p = toPosix(o.pathPrefix).replace(/\/+$/, '');
    whereParts.push('(rel LIKE ? ESCAPE \'\\\' OR path LIKE ? ESCAPE \'\\\')');
    whereParams.push(escapeLike(p) + '/%', escapeLike(p) + '/%');
  }
  const kinds = normalizeKind(o.kind);
  if (kinds) {
    whereParts.push('kind IN (' + kinds.map(() => '?').join(',') + ')');
    whereParams.push(...kinds);
  }
  const exts = normalizeExt(o.ext);
  if (exts) {
    whereParts.push('ext IN (' + exts.map(() => '?').join(',') + ')');
    whereParams.push(...exts);
  }
  const since = opts.sinceMs != null ? opts.sinceMs : parseSince(o.since);
  if (since != null) {
    whereParts.push('mtime >= ?');
    whereParams.push(since);
  }
  const before = opts.beforeMs != null ? opts.beforeMs : parseSince(o.before);
  if (before != null) {
    whereParts.push('mtime <= ?');
    whereParams.push(before);
  }
  if (Number.isFinite(o.minSize)) {
    whereParts.push('size >= ?');
    whereParams.push(Number(o.minSize));
  }
  if (Number.isFinite(o.maxSize)) {
    whereParts.push('size <= ?');
    whereParams.push(Number(o.maxSize));
  }
  if (!includeDenied) whereParts.push('denied = 0');

  const whereSql = ['gone = 0', ...whereParts].join(' AND ');

  let orderSql;
  if (sort === 'recent') orderSql = 'mtime DESC, score DESC';
  else if (sort === 'oldest') orderSql = 'mtime ASC';
  else if (sort === 'size') orderSql = 'size DESC';
  else if (sort === 'name') orderSql = 'name COLLATE NOCASE ASC';
  else orderSql = 'score DESC, mtime DESC';

  const sql = `
    SELECT id, root, path, rel, name, ext, kind, size, mtime, is_text, is_binary, denied,
           title, headings, body,
           (${scoreExpr}) AS score
    FROM files
    WHERE ${whereSql}
    ORDER BY ${orderSql}
    LIMIT ?
  `;

  const params = [...scoreParams, ...whereParams, fetchLimit];
  let rows;
  try {
    rows = db.prepare(sql).all(...params);
  } catch (e) {
    return {
      ok: false,
      error: `检索失败：${e.message}`,
      query: o.query || '',
      hits: [],
      tookMs: Date.now() - started,
    };
  }

  // 「一共命中多少」要单独数一次。
  //
  // `fetchLimit` 是 LIMIT，把它的结果当成总数，就是把**上限**写成了**统计值**。
  // 那种数字看起来完全像个事实，所以比不给更坏 —— `recent_changes` 已经踩过这个坑
  // （limit=40 就报「命中 40 条」，真值 4,805）。这里不给它机会复发。
  let total = null;
  try {
    total = Number(db.prepare(`SELECT count(*) AS c FROM files WHERE ${whereSql}`).get(...whereParams).c);
  } catch (_e) {
    total = null;   // 数不出来就给 null，绝不拿 returned 冒充
  }

  const hasMore = rows.length > limit;
  const used = rows.slice(0, limit);

  const hits = used.map((r) => {
    const matchedIn = [];
    const lowerTerms = terms.map((t) => t.toLowerCase());
    const nameL = String(r.name).toLowerCase();
    const relL = String(r.rel).toLowerCase();
    const titleL = String(r.title || '').toLowerCase();
    const headL = String(r.headings || '').toLowerCase();
    const bodyL = String(r.body || '').toLowerCase();
    for (const t of lowerTerms) {
      if (nameL.includes(t)) { if (!matchedIn.includes('name')) matchedIn.push('name'); }
      else if (relL.includes(t)) { if (!matchedIn.includes('path')) matchedIn.push('path'); }
      else if (titleL.includes(t)) { if (!matchedIn.includes('title')) matchedIn.push('title'); }
      else if (headL.includes(t)) { if (!matchedIn.includes('heading')) matchedIn.push('heading'); }
      else if (bodyL.includes(t)) { if (!matchedIn.includes('body')) matchedIn.push('body'); }
    }
    return {
      path: toPosix(r.path),
      rel: toPosix(r.rel),
      root: toPosix(r.root),
      name: r.name,
      kind: r.kind,
      ext: r.ext,
      size: Number(r.size),
      sizeText: formatBytes(Number(r.size)),
      mtime: Number(r.mtime),
      date: formatDate(Number(r.mtime)),
      title: squeeze(r.title),
      score: Number(r.score) + recencyBoost(Number(r.mtime), cfg),
      matchedIn,
      snippet: buildSnippet(r, terms),
      isText: Boolean(Number(r.is_text)),
    };
  });

  if (sort === 'relevance') hits.sort((a, b) => b.score - a.score || b.mtime - a.mtime);

  return {
    ok: true,
    query: o.query || '',
    scope: o.scope || 'all',
    sort,
    tookMs: Date.now() - started,
    returned: hits.length,
    total,
    hasMore,
    hits,
  };
}

function recencyBoost(mtime, cfg) {
  const days = (Date.now() - mtime) / 86400000;
  const recentDays = (cfg && cfg.policy && cfg.policy.recentDays) || 7;
  if (days <= recentDays) return 6;
  if (days <= 30) return 3;
  if (days <= 90) return 1;
  return 0;
}

function buildSnippet(row, terms) {
  const body = String(row.body || '');
  const lower = body.toLowerCase();
  for (const t of terms) {
    const idx = lower.indexOf(t.toLowerCase());
    if (idx >= 0) {
      const start = Math.max(0, idx - 60);
      const end = Math.min(body.length, idx + t.length + 90);
      const prefix = start > 0 ? '…' : '';
      const suffix = end < body.length ? '…' : '';
      return prefix + squeeze(body.slice(start, end)) + suffix;
    }
  }
  const head = squeeze(row.headings || '');
  if (head) return truncate(head, 150);
  const title = squeeze(row.title || '');
  if (title) return truncate(title, 150);
  if (body) return truncate(squeeze(body), 150);
  return '';
}

/** 供列表 / 最近改动复用。 */
function listFiles(db, opts) {
  const o = opts || {};
  const limit = Math.min(Math.max(Number(o.limit) || 50, 1), 500);
  const where = ['gone = 0'];
  const params = [];
  if (o.root) {
    where.push('root = ?');
    params.push(o.root);
  }
  if (o.pathPrefix) {
    where.push("(rel LIKE ? ESCAPE '\\' OR rel = ?)");
    const p = toPosix(o.pathPrefix).replace(/\/+$/, '');
    params.push(escapeLike(p) + '/%', p);
  }
  const since = o.sinceMs != null ? o.sinceMs : parseSince(o.since);
  if (since != null) {
    where.push('mtime >= ?');
    params.push(since);
  }
  if (o.maxDepth != null) {
    where.push('(length(rel) - length(replace(rel, "/", ""))) <= ?');
    params.push(Number(o.maxDepth));
  }
  if (o.filesOnly !== false) where.push('is_symlink = 0');
  const whereSql = where.join(' AND ');

  // 调用方要「一共有多少」时，用**同一套 WHERE** 再数一次。
  //
  // 为什么必须有：`recent_changes` 原来把 `LIMIT` 出来的行数写成「命中 N 条」——
  // 40 行就报「命中 40 条」，而真实是 4,805 条。一个上限被当成了总数，
  // 而且它看起来完全是个统计值。**这比不给数字更坏**，因为它会被当成事实引用。
  //
  // 挂在数组上（而不是改返回类型）是为了不动现有调用方：
  // 不传 `withTotal` 的调用方拿到的东西和以前一模一样。
  if (o.withTotal) {
    const total = db.prepare(`SELECT count(*) AS c FROM files WHERE ${whereSql}`).get(...params).c;
    const sql = `SELECT root, path, rel, name, ext, kind, size, mtime, is_text, denied, title
                 FROM files WHERE ${whereSql}
                 ORDER BY mtime DESC LIMIT ?`;
    const rows = db.prepare(sql).all(...params, limit);
    const out = rows.map((r) => ({
      path: toPosix(r.path),
      rel: toPosix(r.rel),
      root: toPosix(r.root),
      name: r.name,
      kind: r.kind,
      ext: r.ext,
      size: Number(r.size),
      sizeText: formatBytes(Number(r.size)),
      mtime: Number(r.mtime),
      date: formatDate(Number(r.mtime)),
      title: squeeze(r.title),
    }));
    out.total = Number(total);
    out.hasMore = Number(total) > out.length;
    return out;
  }

  const sql = `SELECT root, path, rel, name, ext, kind, size, mtime, is_text, denied, title
               FROM files WHERE ${whereSql}
               ORDER BY mtime DESC LIMIT ?`;
  params.push(limit);
  return db.prepare(sql).all(...params).map((r) => ({
    path: toPosix(r.path),
    rel: toPosix(r.rel),
    root: toPosix(r.root),
    name: r.name,
    kind: r.kind,
    ext: r.ext,
    size: Number(r.size),
    sizeText: formatBytes(Number(r.size)),
    mtime: Number(r.mtime),
    date: formatDate(Number(r.mtime)),
    title: squeeze(r.title),
  }));
}

/** 目录列表（治理与导航用）。 */
/**
 * 列一个目录。
 *
 * **这是一次真正的目录列表，不是「路径前缀下的所有文件」。**
 *
 * 原来它做的是 `path LIKE '目录/%'` —— 于是列一个顶层目录会把它下面
 * **全部子孙文件**平铺成一张长表。而「这个目录里有什么」问的是**直接子项**。
 * 两者在浅目录上看起来一模一样，在深目录上差几千行 —— 那种差别不会报错，
 * 只会让人以为「这个目录里有 4000 个文件」。
 *
 * `depth` 控制展开几层：
 * - `depth: 1`（默认）= 直接子目录 + 直接子文件，像 `ls`；
 * - `depth: n` = 展开到第 n 层，中间层以目录聚合出现。
 *
 * 子目录带 `fileCount` / `bytes`（该目录**整棵子树**的合计），
 * 这样「哪个目录占地方」不用再猜。
 */
function listDirectory(db, dirAbsPosix, opts) {
  const o = opts || {};
  const limit = Math.min(Math.max(Number(o.limit) || 200, 1), 1000);
  const depth = Math.min(Math.max(Number(o.depth) || 1, 1), 6);
  const prefix = String(dirAbsPosix).replace(/\/+$/, '');
  const base = prefix + '/';

  // 一次取回前缀下的全部行，再在内存里按层级切。
  //
  // 为什么不用 SQL 数斜杠：`length(rel) - length(replace(rel,'/',''))` 这类算式
  // 一长，读的人就只能靠猜，而算错一位不会报错 —— 只会少给或多给几行。
  // 这里行数本来就有界（一个目录的子孙），内存切分更看得懂。
  const rows = db
    .prepare(
      `SELECT path, rel, name, ext, kind, size, mtime, title FROM files
       WHERE gone = 0 AND is_symlink = 0 AND path LIKE ? ESCAPE '\\'
       ORDER BY path ASC`,
    )
    .all(escapeLike(prefix) + '/%');

  const mkItem = (r) => ({
    rel: toPosix(r.rel),
    name: r.name,
    kind: r.kind,
    size: Number(r.size),
    sizeText: formatBytes(Number(r.size)),
    mtime: Number(r.mtime),
    date: formatDate(Number(r.mtime)),
    title: squeeze(r.title),
  });

  const dirs = new Map();   // 直接/浅层子目录 → 聚合
  const files = [];
  let totalFiles = 0;       // 前缀下**全部**子孙文件数（用于「还有多少没列」）
  let capped = false;       // 文件条数到了 limit

  for (const r of rows) {
    const full = toPosix(r.path);
    if (!full.startsWith(base)) continue;
    const rest = full.slice(base.length);
    if (!rest) continue;
    totalFiles += 1;

    const parts = rest.split('/');
    if (parts.length > 1) {
      // 落在子目录里：把前 depth-1 层的目录名都登记上
      // 展开到 depth 层：depth=1 时也要看得出「有个子目录」，
      // 否则 ls 一个目录会连子目录都看不到 —— 那正是最该看见的东西。
      const upto = Math.min(parts.length - 1, depth);
      for (let i = 1; i <= upto; i += 1) {
        const relDir = base + parts.slice(0, i).join('/');
        let e = dirs.get(relDir);
        if (!e) {
          // `relDir` 是**相对被列目录**的路径。
          // 只给 `name` 的话，depth≥2 时会出现一堆裸名字（`里`、`src`），
          // 根本看不出它是谁的下级 —— 那等于没列。
          e = {
            rel: relDir,
            name: parts[i - 1],
            relDir: parts.slice(0, i).join('/'),
            level: i,
            fileCount: 0,
            bytes: 0,
          };
          dirs.set(relDir, e);
        }
        e.fileCount += 1;
        e.bytes += Number(r.size);
      }
    }

    // 只有层级 ≤ depth 的文件才算「列出来了」。
    // depth=1 时这一条对子目录里的文件永远不成立 —— 正是我们要的。
    if (parts.length - 1 < depth && !o.dirsOnly) {
      if (files.length < limit) files.push(mkItem(r));
      else capped = true;
    }
  }

  for (const e of dirs.values()) {
    e.bytesText = formatBytes(e.bytes);
  }

  const dirList = [...dirs.values()].filter((d) => d.level <= depth)
    .sort((a, b) => b.bytes - a.bytes);
  files.sort((a, b) => b.mtime - a.mtime);

  return {
    dir: prefix,
    depth,
    // 直接子目录数（像 ls 里那几个名字）
    returnedDirs: dirList.length,
    returnedFiles: files.length,
    // 前缀下**全部**子孙文件，不受 limit 影响 —— 用来回答「这个目录一共多大」
    totalDescendantFiles: totalFiles,
    hasMore: capped,
    dirs: dirList,
    files,
    // 兼容旧调用方：原来是「前缀下前 limit 个文件」
    items: files,
    returned: files.length,
    hasMoreFiles: capped,
  };
}

/**
 * 数一下有多少文件被 `denyRead` 挡住 —— 也就是**正文从未入库、检索永远查不到**的那些。
 *
 * 为什么单独有这个函数：`find_files` 返回「没有命中」时，调用方无从分辨
 * 「真的没有这个文件」和「有这个文件，但被策略排除、我故意不给你看」。
 * 实测过：`shilu-studio/.env` 明明在索引里（`list_directory` 列得出来），
 * 但搜 `.env` 返回 0 条，且没有任何提示 —— 同一份数据，列目录说「有」，搜索说「没有」。
 *
 * 被排除是有意的（见 隐私.md），但**沉默的排除和不存在的排除必须能区分开**。
 */
function countDenied(db, opts) {
  const o = opts || {};
  const where = ['gone = 0', 'denied = 1'];
  const params = [];
  if (o.root) {
    const roots = Array.isArray(o.root) ? o.root : [o.root];
    where.push('(' + roots.map(() => 'root = ?').join(' OR ') + ')');
    params.push(...roots);
  }
  if (o.pathPrefix) {
    const p = toPosix(o.pathPrefix).replace(/\/+$/, '');
    where.push("(rel LIKE ? ESCAPE '\\' OR rel = ?)");
    params.push(escapeLike(p) + '/%', p);
  }
  // 按名字/相对路径做子串匹配，用来回答一个具体问题：
  // 「我搜 `.env` 返回 0 条 —— 是真的没有，还是你不给我看？」
  if (o.nameLike) {
    const like = '%' + escapeLike(String(o.nameLike).toLowerCase()) + '%';
    where.push('(lower(name) LIKE ? ESCAPE \'\\\' OR lower(rel) LIKE ? ESCAPE \'\\\')');
    params.push(like, like);
  }
  return Number(db.prepare(`SELECT count(*) AS c FROM files WHERE ${where.join(' AND ')}`).get(...params).c);
}

module.exports = { searchFiles, listFiles, listDirectory, countDenied, escapeLike, buildSnippet };
