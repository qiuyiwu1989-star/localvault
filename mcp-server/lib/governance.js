'use strict';

/**
 * 文件治理体检。**全部只读** —— 只产出报告与建议，不移动、不重命名、不删除。
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { toPosix, formatBytes, formatDate, daysAgo, squeeze, truncate } = require('./util');
const { extractLocalLinks } = require('./extract');
const { globToRegExp } = require('./config');

/** 这些文件名到处都是，不参与「同名重复」告警。 */
const UBIQUITOUS_NAMES = new Set([
  'package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'tsconfig.json',
  'jsconfig.json', 'index.js', 'index.ts', 'index.html', 'main.js', 'app.js', 'app.json',
  'readme.md', '.gitignore', '.gitattributes', '.editorconfig', '.npmrc', '.prettierrc',
  'dockerfile', 'makefile', 'license', 'license.md', 'changelog.md', '__init__.py',
  '.env.example', 'requirements.txt', 'vite.config.js', 'vite.config.ts', 'next.config.js',
  'gradle.properties', 'settings.gradle', 'settings.gradle.kts', 'build.gradle',
  'proguard-rules.pro', 'androidmanifest.xml', 'info.plist', '.ds_store',
]);

function hashFileSync(file, maxBytes) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
  } catch (_e) {
    return null;
  }
  try {
    const h = crypto.createHash('sha1');
    const buf = Buffer.allocUnsafe(1 << 20);
    let pos = 0;
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      h.update(buf.subarray(0, n));
      pos += n;
      if (pos >= maxBytes) break;
    }
    return h.digest('hex');
  } catch (_e) {
    return null;
  } finally {
    try {
      fs.closeSync(fd);
    } catch (_e) {
      /* ignore */
    }
  }
}

/* ------------------------------------------------------------------ *
 * 1. 重复文件
 * ------------------------------------------------------------------ */

function checkDuplicates(db, cfg, opts) {
  const o = opts || {};
  const maxBytes = cfg.policy.duplicateMaxFileBytes;
  const budget = cfg.policy.duplicateMaxTotalBytes;
  const limitGroups = Math.min(Math.max(Number(o.limit) || 20, 1), 200);
  const rootFilter = o.root ? ' AND root = ?' : '';
  const params = o.root ? [o.root] : [];

  const sizeGroups = db
    .prepare(
      `SELECT size, count(*) AS c, coalesce(sum(size),0) AS s FROM files
       WHERE gone = 0 AND is_symlink = 0 AND size > 0 AND size <= ${Number(maxBytes)} AND denied = 0 ${rootFilter}
       GROUP BY size HAVING c > 1 ORDER BY s DESC LIMIT 400`,
    )
    .all(...params);

  const byHash = new Map();
  let hashed = 0;
  let truncated = false;

  for (const g of sizeGroups) {
    const size = Number(g.size);
    if (hashed + size * Number(g.c) > budget) {
      truncated = true;
      break;
    }
    const rows = db
      .prepare(`SELECT path, rel, name, mtime, size FROM files WHERE gone = 0 AND is_symlink = 0 AND size = ? ${rootFilter}`)
      .all(size, ...params);
    hashed += size * rows.length;
    for (const r of rows) {
      const h = hashFileSync(r.path, maxBytes);
      if (!h) continue;
      const key = size + ':' + h;
      if (!byHash.has(key)) byHash.set(key, []);
      byHash.get(key).push(r);
    }
  }

  const exact = [...byHash.values()]
    .filter((g) => g.length > 1)
    .map((g) => ({
      kind: 'exact',
      size: Number(g[0].size),
      sizeText: formatBytes(Number(g[0].size)),
      count: g.length,
      wastedBytes: Number(g[0].size) * (g.length - 1),
      files: g
        .map((r) => ({ path: toPosix(r.path), rel: toPosix(r.rel), mtime: Number(r.mtime), date: formatDate(Number(r.mtime)) }))
        .sort((a, b) => b.mtime - a.mtime),
    }))
    .sort((a, b) => b.wastedBytes - a.wastedBytes);

  // 同名簇（不同目录里散落的同名文件）
  // ── 同名簇：这里原来把「取了多少个」当成了「一共有多少个」 ─────────────
  //
  // 原写法是 `LIMIT 200` 一次查询 + 循环到 `limitGroups` 就 `break`，
  // 然后把 `sameName.length` 当作 `summary.sameNameGroups` 报出去。
  // 于是 limit=25 报 25、limit=1 报 1、默认报 20 —— 它是 `min(候选数, limit)`，
  // **是个上限，不是计数**。而它旁边紧挨着的 `exactGroups:350` 是真计数，
  // 两者并排放在同一个 summary 里，读的人分不出哪个是哪个。
  // 实测本机真实同名簇 ≥1713，而报告说 20 —— 差两个数量级。
  //
  // 修法：GROUP BY 的结果本来就只是一行一个名字，全取回来很便宜（本机约千行），
  // 取全之后**计数是真的**，「只列前 N 个」才是那个被 limit 影响的东西。
  const nameRowsAll = db
    .prepare(
      `SELECT name, count(*) AS c, coalesce(sum(size),0) AS s FROM files
       WHERE gone = 0 AND is_symlink = 0 AND size >= 1024 ${rootFilter}
       GROUP BY lower(name) HAVING c > 1 ORDER BY s DESC`,
    )
    .all(...params);
  // 常见名（LICENSE、README 之类）不算「散落的同名」，和循环里的跳过保持一致。
  const nameRows = nameRowsAll.filter((nr) => !UBIQUITOUS_NAMES.has(String(nr.name).toLowerCase()));
  const sameNameGroupsTotal = nameRows.length;

  const sameName = [];
  for (const nr of nameRows) {
    if (UBIQUITOUS_NAMES.has(String(nr.name).toLowerCase())) continue;
    const rows = db
      .prepare(`SELECT path, rel, mtime, size FROM files WHERE gone = 0 AND is_symlink = 0 AND lower(name) = lower(?) ${rootFilter} LIMIT 30`)
      .all(nr.name, ...params);
    if (rows.length < 2) continue;
    sameName.push({
      kind: 'same-name',
      name: nr.name,
      count: rows.length,
      totalBytes: Number(nr.s),
      totalBytesText: formatBytes(Number(nr.s)),
      files: rows.map((r) => ({ path: toPosix(r.path), rel: toPosix(r.rel), mtime: Number(r.mtime), date: formatDate(Number(r.mtime)) })),
    });
    if (sameName.length >= limitGroups) break;
  }

  const wasted = exact.reduce((a, g) => a + g.wastedBytes, 0);

  /**
   * 超过 `duplicateMaxFileBytes` 的文件**根本不进比对** —— 而这件事原本一声不吭。
   *
   * 实测（2026-10-02，本机工作区）：上限 8MiB 时只有 9,553 个文件 / 0.54 GB 参与，
   * 另有 **164 个文件 / 22.82 GB 被静默排除** —— 也就是说「可回收 104MB」
   * 是在 2.3% 的字节上算出来的，却被读成了总数。被排除的包括 3 个 2.48GB 的
   * 视频和 3 个 1.11GB 的 preview.mp4，正是最该查重的那一类。
   *
   * 所以这里必须把「没参与的部分」明说出来。数字可以小，但不能假装完整。
   */
  const skipped = db
    .prepare(
      `SELECT count(*) AS c, coalesce(sum(size),0) AS s FROM files
       WHERE gone = 0 AND is_symlink = 0 AND size > ${Number(maxBytes)} AND denied = 0 ${rootFilter}`,
    )
    .get(...params);

  const md = [];
  md.push('# 重复文件体检');
  md.push('');
  md.push(`可回收空间（完全重复）：**${formatBytes(wasted)}**；完全重复组 ${exact.length} 个，同名簇 ${sameNameGroupsTotal} 个${sameNameGroupsTotal > sameName.length ? `（下面列前 ${sameName.length} 个）` : ''}。`);
  if (truncated) md.push(`\n> 哈希预算已用尽，结果可能不完整（已扫描约 ${formatBytes(hashed)}）。`);
  if (skipped.c > 0) {
    md.push(
      `\n> **${skipped.c} 个文件（${formatBytes(Number(skipped.s))}）没有参与比对** —— ` +
        `它们单个超过上限 ${formatBytes(Number(maxBytes))}。上面的可回收空间**只覆盖其余文件**，不是全部。`,
    );
  }
  md.push('');
  if (exact.length) {
    md.push('## 完全重复（内容哈希一致）');
    md.push('');
    for (const g of exact.slice(0, limitGroups)) {
      md.push(`### ${formatBytes(g.size)} × ${g.count} 份（可回收 ${formatBytes(g.wastedBytes)}）`);
      for (const f of g.files) md.push(`- \`${f.rel}\`　${f.date}`);
      md.push('');
    }
  } else {
    md.push('没有发现内容完全相同的文件。');
    md.push('');
  }
  if (sameNameGroupsTotal) {
    md.push('## 同名文件散落在多处');
    md.push('');
    for (const g of sameName.slice(0, limitGroups)) {
      md.push(`### ${g.name}（${g.count} 处，合计 ${g.totalBytesText}）`);
      for (const f of g.files) md.push(`- \`${f.rel}\`　${f.date}`);
      md.push('');
    }
  }
  return { check: 'duplicates', summary: { exactGroups: exact.length, sameNameGroups: sameNameGroupsTotal, sameNameShown: sameName.length, sameNameCapped: sameNameGroupsTotal > sameName.length, reclaimableBytes: wasted, truncated, skippedTooLarge: Number(skipped.c), skippedTooLargeBytes: Number(skipped.s) }, exact, sameName, markdown: md.join('\n') };
}

/* ------------------------------------------------------------------ *
 * 2. 陈旧文件
 * ------------------------------------------------------------------ */

function checkStale(db, cfg, opts) {
  const o = opts || {};
  const days = Number(o.days) || cfg.policy.staleDays;
  const cutoff = Date.now() - days * 86400000;
  const limit = Math.min(Math.max(Number(o.limit) || 30, 1), 200);
  const rootFilter = o.root ? ' AND root = ?' : '';
  const params = o.root ? [o.root] : [];

  const total = db
    .prepare(`SELECT count(*) AS c, coalesce(sum(size),0) AS s FROM files WHERE gone = 0 AND is_symlink = 0 AND mtime > 0 AND mtime < ? ${rootFilter}`)
    .get(cutoff, ...params);

  const byDir = db
    .prepare(
      `SELECT CASE WHEN instr(rel,'/') > 0 THEN substr(rel,1,instr(rel,'/')-1) ELSE '(根目录)' END AS seg,
              count(*) AS c, coalesce(sum(size),0) AS s, max(mtime) AS m
       FROM files WHERE gone = 0 AND is_symlink = 0 AND mtime > 0 AND mtime < ? ${rootFilter}
       GROUP BY seg ORDER BY c DESC LIMIT ?`,
    )
    .all(cutoff, ...params, limit);

  const biggest = db
    .prepare(
      `SELECT path, rel, name, size, mtime FROM files
       WHERE gone = 0 AND is_symlink = 0 AND mtime > 0 AND mtime < ? ${rootFilter}
       ORDER BY size DESC LIMIT ?`,
    )
    .all(cutoff, ...params, limit);

  const md = [];
  md.push(`# 陈旧文件（超过 ${days} 天未改动）`);
  md.push('');
  md.push(`共 **${Number(total.c)}** 个文件 / ${formatBytes(Number(total.s))}，截止日期 ${formatDate(cutoff)}。`);
  md.push('');
  md.push('## 按顶层目录分布');
  md.push('');
  md.push('| 目录 | 文件数 | 体量 | 最近一次改动 |');
  md.push('| --- | ---: | ---: | --- |');
  for (const r of byDir) {
    md.push(`| \`${r.seg}\` | ${Number(r.c)} | ${formatBytes(Number(r.s))} | ${formatDate(Number(r.m))} |`);
  }
  md.push('');
  md.push('## 体积最大的陈旧文件');
  md.push('');
  for (const r of biggest) {
    md.push(`- \`${toPosix(r.rel)}\`　${formatBytes(Number(r.size))}　最后改动 ${formatDate(Number(r.mtime))}（${daysAgo(Number(r.mtime))} 天前）`);
  }
  md.push('');
  md.push('> 陈旧不等于可删。这里只提示「很久没动过」，是否归档由你判断。');
  return {
    check: 'stale',
    summary: { days, cutoff, files: Number(total.c), bytes: Number(total.s) },
    byDir: byDir.map((r) => ({ seg: r.seg, files: Number(r.c), bytes: Number(r.s), mtime: Number(r.m) })),
    biggest: biggest.map((r) => ({ rel: toPosix(r.rel), path: toPosix(r.path), size: Number(r.size), mtime: Number(r.mtime) })),
    markdown: md.join('\n'),
  };
}

/* ------------------------------------------------------------------ *
 * 3. 命名违规（版本化后缀 / 副本名）
 * ------------------------------------------------------------------ */

/**
 * 第三方运行时 / 构建产物里的文件名不是用户的命名习惯，不参与命名体检。
 * 这些目录里 `NEWS2x`、`PatternGrammar3.12.14.final.0.pickle`、`folder.gif`
 * 会被裸子串匹配误判成「版本化命名」。
 */
const NAMING_VENDOR_MARKERS = [
  '/node_modules/',
  '/site-packages/',
  '/lib/python',
  '/lib2to3/',
  '/idlelib/',
  '/__pycache__/',
  '/.git/',
  '/dist/',
  '/build/',
  '/vendor/',
  '/third_party/',
  '/Contents/Resources/',
  '/Contents/Frameworks/',
];

function isVendoredForNaming(rel) {
  const p = `/${toPosix(rel)}/`;
  return NAMING_VENDOR_MARKERS.some((m) => p.includes(m));
}

/**
 * 版本化词表由 policy.versionNamePatterns 驱动 —— 通用软件不能把
 * 「最终版」这种中文习惯写死在代码里，别的语言用户应该能换自己的词。
 * 中文词按「出现在词干任意位置」匹配；纯 ASCII 词按「落在词干末尾」匹配，
 * 这样 `report-final.md` 命中，而 `new-keystore.sh`（新建）不命中。
 */
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function buildNamingMatchers(cfg) {
  const words = ((cfg && cfg.policy && cfg.policy.versionNamePatterns) || []).filter(
    (w) => typeof w === 'string' && w.trim(),
  );
  const cjk = words.filter((w) => /[\u3400-\u9fff]/.test(w));
  const en = words.filter((w) => !/[\u3400-\u9fff]/.test(w) && /^[a-z0-9][a-z0-9._-]*$/i.test(w));
  return {
    cjk: cjk.length ? new RegExp('(' + cjk.map(escapeRe).join('|') + ')') : null,
    enSuffix: en.length
      ? new RegExp('(?:^|[^a-z])(' + en.map(escapeRe).join('|') + ')(\\d*)$', 'i')
      : null,
  };
}

/** macOS / Windows 的自动副本后缀：`报告 (1).md`、`方案 - 副本.md`、`稿子 2.md`。 */
const NAMING_DUP_SUFFIX = /(?:\s*\(\d+\)|\s*-\s*(?:副本|拷贝|复件)\s*\d*|\s+第?\d+\s*版)\s*$/;

/** 取文件名词干（去掉最后一个扩展名）。 */
function namingStem(name) {
  const i = name.lastIndexOf('.');
  return i > 0 ? name.slice(0, i) : name;
}

/** 是否属于「版本化 / 副本命名」。返回命中的理由，未命中返回 null。 */
function namingReason(name, matchers, detectCopySuffix) {
  const stem = namingStem(name);
  if (detectCopySuffix !== false && NAMING_DUP_SUFFIX.test(stem)) return '副本后缀';
  const m = matchers || {};
  if (m.cjk && m.cjk.test(stem)) return '版本化词';
  if (m.enSuffix && m.enSuffix.test(stem)) return '版本化词';
  return null;
}

/**
 * 内容寻址 / 机器生成的命名（sha256、uuid、纯十六进制）。
 * 「文件名过长」不该把这些算成用户的命名习惯——它们不是人写的。
 */
function looksMachineNamed(name) {
  const stem = namingStem(name);
  if (/^[0-9a-f]{32,}$/i.test(stem)) return true;
  if (/[0-9a-f]{32,}/i.test(stem)) return true;
  if (/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(stem)) return true;
  return false;
}

function checkNaming(db, cfg, opts) {
  const o = opts || {};
  const matchers = buildNamingMatchers(cfg);
  const detectCopySuffix = !cfg.policy || cfg.policy.detectCopySuffix !== false;
  const limit = Math.min(Math.max(Number(o.limit) || 40, 1), 200);
  const rootFilter = o.root ? ' AND root = ?' : '';
  const params = o.root ? [o.root] : [];

  const all = db
    .prepare(
      `SELECT path, rel, name, kind, size, mtime FROM files
       WHERE gone = 0 AND is_symlink = 0 ${rootFilter}`,
    )
    .all(...params);

  const rows = [];
  for (const r of all) {
    if (r.kind === 'bundle') continue;
    if (isVendoredForNaming(r.rel)) continue;
    const reason = namingReason(r.name, matchers, detectCopySuffix);
    if (reason) rows.push({ ...r, reason });
  }
  rows.sort((a, b) => Number(b.mtime) - Number(a.mtime));

  const longNames = all
    .filter(
      (r) =>
        r.kind !== 'bundle' &&
        !isVendoredForNaming(r.rel) &&
        !looksMachineNamed(r.name) &&
        String(r.name).length > 60,
    )
    .map((r) => ({ path: r.path, rel: r.rel, n: String(r.name).length }))
    .sort((a, b) => b.n - a.n)
    .slice(0, 20);

  const shown = rows.slice(0, limit);

  const md = [];
  md.push('# 命名体检（版本化后缀与副本名）');
  md.push('');
  md.push('命中的是**你配置的词表**（`policy.versionNamePatterns`）里的词，不是通行规范。');
  md.push('换一份词表，命中的文件就变了 —— 所以这项只做提示，不判定对错。');
  md.push('想调词表：改配置里的 `policy.versionNamePatterns`。');
  md.push('');
  md.push(`命中 **${rows.length}** 个文件${rows.length > limit ? `（下面只列最近改动的 ${limit} 个）` : ''}。`);
  md.push('');
  if (rows.length) {
    md.push('| 文件 | 命中类型 | 体量 | 最后改动 |');
    md.push('| --- | --- | ---: | --- |');
    for (const r of shown) {
      md.push(`| \`${toPosix(r.rel)}\` | ${r.reason} | ${formatBytes(Number(r.size))} | ${formatDate(Number(r.mtime))} |`);
    }
    md.push('');
    md.push('> 只在文件名**词元边界**上判定：「News2x」「folder.gif」「PatternGrammar3.12.14.final.0.pickle」这类不再算命中。');
    md.push('> `node_modules`、`site-packages`、`dist`、`.app` 内部等第三方运行时已排除。');
    md.push('');
  }
  if (longNames.length) {
    md.push('## 文件名过长（>60 字符）');
    md.push('');
    for (const r of longNames) md.push(`- (${r.n}) \`${toPosix(r.rel)}\``);
    md.push('');
  }
  return {
    check: 'naming',
    summary: { matched: rows.length, longNames: longNames.length },
    matches: shown.map((r) => ({
      rel: toPosix(r.rel),
      path: toPosix(r.path),
      size: Number(r.size),
      mtime: Number(r.mtime),
      reason: r.reason,
    })),
    markdown: md.join('\n'),
  };
}

/* ------------------------------------------------------------------ *
 * 4. 待整理积压
 * ------------------------------------------------------------------ */

/**
 * 待整理积压。
 *
 * 「待整理」是**特定工作流的约定，不是普遍需求** —— 目录名来自
 * policy.inboxDir，默认 null 表示不做这项检查。
 * 通用软件不该假定每个人都有一个叫「待整理」的目录。
 */
function checkInbox(db, cfg, opts) {
  const o = opts || {};
  const staleDays = Number(o.days) || cfg.policy.inboxStaleDays;
  const inboxRel = cfg.policy.inboxDir;
  const root = cfg.primaryRoot;

  if (!inboxRel) {
    return {
      check: 'inbox',
      configured: false,
      summary: { files: 0, staleFiles: 0, bytes: 0, staleDays },
      items: [],
      markdown: [
        '# 待整理积压',
        '',
        '**未配置，已跳过。** 这项检查针对「有一个固定收集目录、定期归位」的工作流。',
        '',
        '要启用，在配置里指定目录名：',
        '',
        '```json',
        '{ "policy": { "inboxDir": "待整理" } }',
        '```',
        '',
        '不配置就不检查 —— 大多数人不需要它。',
      ].join('\n'),
    };
  }

  const prefixAbs = path.join(root, inboxRel);
  const rows = db
    .prepare('SELECT path, rel, name, size, kind, mtime FROM files WHERE gone = 0 AND is_symlink = 0 AND path LIKE ? ORDER BY mtime ASC')
    .all(prefixAbs + path.sep + '%');

  const stale = rows.filter((r) => daysAgo(Number(r.mtime)) > staleDays);
  const totalBytes = rows.reduce((a, r) => a + Number(r.size), 0);

  const md = [];
  md.push('# 待整理积压');
  md.push('');
  md.push(`\`${inboxRel}/\` 共 ${rows.length} 个文件 / ${formatBytes(totalBytes)}；其中 **${stale.length}** 个超过 ${staleDays} 天未归位。`);
  md.push('');
  if (rows.length) {
    md.push('| 文件 | 体量 | 停留天数 |');
    md.push('| --- | ---: | ---: |');
    for (const r of rows.slice(0, 100)) {
      md.push(`| \`${toPosix(r.rel)}\` | ${formatBytes(Number(r.size))} | ${daysAgo(Number(r.mtime))} |`);
    }
  } else {
    md.push(`\`${inboxRel}/\` 是空的 —— 当前没有积压。`);
  }
  md.push('');
  return {
    check: 'inbox',
    configured: true,
    summary: { files: rows.length, staleFiles: stale.length, bytes: totalBytes, staleDays },
    items: rows.map((r) => ({ rel: toPosix(r.rel), path: toPosix(r.path), size: Number(r.size), mtime: Number(r.mtime), days: daysAgo(Number(r.mtime)) })),
    markdown: md.join('\n'),
  };
}

/* ------------------------------------------------------------------ *
 * 5. 根目录堆积
 * ------------------------------------------------------------------ */

/**
 * 根目录堆积。
 *
 * 这里刻意**不判定「散文件是不是问题」** —— 那是用户的标准，不是软件的。
 * 软件只做一件事：数清楚根目录有几个文件、几个目录。
 * 「哪些算导航文件、可以不算散落」由 policy.rootNavPatterns 定义，
 * 默认给一组通用名字（README / index / 00-* / AGENTS.md），
 * 用户可以设成 [] 表示「根目录一切文件都要报给我」。
 */
function checkRootClutter(db, cfg) {
  const root = cfg.primaryRoot;
  const patterns = (cfg.policy && cfg.policy.rootNavPatterns) || [];
  const navRes = patterns.map((g) => globToRegExp(g));
  const declaredRootDocs = new Set((cfg.canonicalDocs || []).filter((d) => !d.includes('/')));
  const isNav = (name) => declaredRootDocs.has(name) || navRes.some((re) => re.test(name));
  const allowed = new Set();
  const rows = db
    .prepare("SELECT path, rel, name, size, kind, mtime FROM files WHERE gone = 0 AND is_symlink = 0 AND root = ? AND instr(rel,'/') = 0 ORDER BY mtime DESC")
    .all(root)
    .filter((r) => {
      if (isNav(r.name)) {
        allowed.add(r.name);
        return false;
      }
      return true;
    });
  const dirs = db
    .prepare("SELECT DISTINCT substr(rel,1,instr(rel,'/')-1) AS seg FROM files WHERE gone = 0 AND root = ? AND instr(rel,'/') > 0")
    .all(root)
    .map((r) => r.seg);

  const md = [];
  md.push('# 根目录体检');
  md.push('');
  md.push(`\`${root}\` 根目录下有 **${rows.length}** 个未识别为导航的散文件、${dirs.length} 个子目录。`);
  if (allowed.size) md.push(`（已排除导航文件（按 policy.rootNavPatterns 判定）：${[...allowed].join('、')}。）`);
  md.push('');
  md.push('> 本检查只陈述事实：根目录有多少文件、多少目录。**它不判定这些文件该不该在根目录** —— 那是你的标准。');
  md.push('> 想调整哪些算「导航文件」，改 `policy.rootNavPatterns`；设成 `[]` 则根目录一切文件都会列出来。');
  md.push('');
  if (rows.length) {
    md.push('| 文件 | 体量 | 最后改动 |');
    md.push('| --- | ---: | --- |');
    for (const r of rows) md.push(`| \`${r.name}\` | ${formatBytes(Number(r.size))} | ${formatDate(Number(r.mtime))} |`);
  }
  md.push('');
  md.push('## 现有分类目录');
  md.push('');
  md.push(dirs.map((d) => `\`${d}/\``).join('　'));
  md.push('');
  return {
    check: 'root_clutter',
    summary: { files: rows.length, dirs: dirs.length },
    files: rows.map((r) => ({ name: r.name, rel: toPosix(r.rel), size: Number(r.size), mtime: Number(r.mtime) })),
    dirs,
    markdown: md.join('\n'),
  };
}

/* ------------------------------------------------------------------ *
 * 6. 断链检查（markdown 内的本地链接）
 * ------------------------------------------------------------------ */

/**
 * 链接是否可解析。markdown 里 `[x](npm-outdated)` 这类省略扩展名、
 * 或指向目录的链接很常见，因此依次尝试若干常见补全，避免误报。
 */
function linkResolves(target) {
  const candidates = [
    target,
    target + '.md',
    target + '.markdown',
    target + '.html',
    path.join(target, 'index.md'),
    path.join(target, 'README.md'),
    path.join(target, 'readme.md'),
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return true;
    } catch (_e) {
      /* 继续尝试 */
    }
  }
  return false;
}

function checkLinks(db, cfg, opts) {
  const o = opts || {};
  const limit = Math.min(Math.max(Number(o.limit) || 60, 1), 300);
  const rootFilter = o.root ? ' AND root = ?' : '';
  const params = o.root ? [o.root] : [];
  const rows = db
    .prepare(`SELECT path, rel, body FROM files WHERE gone = 0 AND ext IN ('.md','.markdown','.mdx') AND body <> '' ${rootFilter}`)
    .all(...params);

  const broken = [];
  let checkedLinks = 0;
  let checkedFiles = 0;

  for (const r of rows) {
    checkedFiles += 1;
    const links = extractLocalLinks(String(r.body || ''));
    const dir = path.dirname(r.path);
    const seen = new Set();
    for (const raw of links) {
      if (seen.has(raw)) continue;
      seen.add(raw);
      let target;
      if (raw.startsWith('/')) target = raw;
      else if (raw.startsWith('~')) target = path.join(require('./util').HOME, raw.slice(1));
      else target = path.resolve(dir, raw);
      // 只检查在索引根内的链接，外部路径（如 /etc、服务器路径）跳过
      const inside = cfg.roots.some((rt) => target === rt.path || target.startsWith(rt.path + path.sep));
      if (!inside) continue;
      checkedLinks += 1;
      if (!linkResolves(target)) {
        broken.push({ file: toPosix(r.rel), filePath: toPosix(r.path), link: raw, resolved: toPosix(target) });
        if (broken.length >= 500) break;
      }
    }
    if (broken.length >= 500) break;
  }

  const md = [];
  md.push('# 本地链接体检');
  md.push('');
  md.push(`检查了 ${checkedFiles} 个 Markdown 文件、${checkedLinks} 条指向索引根内的本地链接，发现 **${broken.length}** 条断链。`);
  md.push('');
  if (broken.length) {
    md.push('| 所在文件 | 失效链接 | 解析到的路径 |');
    md.push('| --- | --- | --- |');
    for (const b of broken.slice(0, limit)) md.push(`| \`${b.file}\` | \`${b.link}\` | \`${b.resolved}\` |`);
    if (broken.length > limit) md.push(`\n（共 ${broken.length} 条，只列前 ${limit} 条。）`);
  } else {
    md.push('没有发现断链。');
  }
  md.push('');
  md.push('> 只检查指向索引根内的路径；指向服务器（如 `/var/www`）或系统路径的链接按设计跳过。');
  return { check: 'links', summary: { checkedFiles, checkedLinks, broken: broken.length }, broken: broken.slice(0, limit), markdown: md.join('\n') };
}

/* ------------------------------------------------------------------ *
 * 调度
 * ------------------------------------------------------------------ */

const CHECKS = {
  duplicates: { title: '重复文件', run: checkDuplicates },
  stale: { title: '陈旧文件', run: checkStale },
  naming: { title: '命名违规', run: checkNaming },
  inbox: { title: '待整理积压', run: checkInbox },
  root_clutter: { title: '根目录堆积', run: checkRootClutter },
  links: { title: '本地断链', run: checkLinks },
};

function audit(db, cfg, opts) {
  const o = opts || {};
  const requested = String(o.checks || o.check || 'all')
    .split(/[,\s]+/)
    .filter(Boolean);
  const names = requested.includes('all') || requested.length === 0 ? Object.keys(CHECKS) : requested.filter((n) => CHECKS[n]);
  const unknown = requested.filter((n) => n !== 'all' && !CHECKS[n]);
  const results = [];
  for (const name of names) {
    try {
      results.push(CHECKS[name].run(db, cfg, o));
    } catch (e) {
      results.push({ check: name, error: String(e.message || e), markdown: `# ${name}\n\n检查失败：${e.message}` });
    }
  }
  const header = [
    '# 文件治理体检报告',
    '',
    `生成时间：${new Date().toLocaleString('zh-CN')}`,
    `检查项：${results.map((r) => CHECKS[r.check] ? CHECKS[r.check].title : r.check).join('、')}`,
    '',
    '> 本报告**只读**：没有移动、重命名或删除任何文件。要执行整理，请让 Agent 按建议逐条与你确认。',
    '',
    '## 结论速览',
    '',
    '| 检查项 | 关键数字 |',
    '| --- | --- |',
  ];
  for (const r of results) {
    let key = '';
    if (r.check === 'duplicates') key = `${r.summary.exactGroups} 组完全重复，可回收 ${formatBytes(r.summary.reclaimableBytes)}；${r.summary.sameNameGroups} 组同名`;
    else if (r.check === 'stale') key = `${r.summary.files} 个文件 / ${formatBytes(r.summary.bytes)} 超过 ${r.summary.days} 天未动`;
    else if (r.check === 'naming') key = `${r.summary.matched} 个命中自定义词表`;
    // 未配置的检查必须显示「未检查」，不能显示 0 ——
    // 0 和「没检查」是两回事，写成 0 就是静默的谎。
    else if (r.check === 'inbox') {
      key = r.configured === false
        ? '**未配置，未检查**'
        : `${r.summary.files} 个在收集目录（${r.summary.staleFiles} 个超期）`;
    }
    else if (r.check === 'root_clutter') key = `${r.summary.files} 个未识别为导航的散文件、${r.summary.dirs} 个子目录`;
    else if (r.check === 'links') key = `${r.summary.broken} 条断链 / 检查 ${r.summary.checkedLinks} 条`;
    else if (r.error) key = `失败：${r.error}`;
    header.push(`| ${CHECKS[r.check] ? CHECKS[r.check].title : r.check} | ${key} |`);
  }
  header.push('');
  header.push('---');
  header.push('');
  const body = results.map((r) => r.markdown || '').join('\n\n---\n\n');
  return {
    ok: true,
    unknown,
    checks: results.map((r) => ({ check: r.check, summary: r.summary || null, error: r.error || null })),
    results,
    markdown: header.join('\n') + body,
  };
}

/* ------------------------------------------------------------------ *
 * 整理方案（dry-run）
 * ------------------------------------------------------------------ */

function proposeOrganize(db, cfg, opts) {
  const o = opts || {};
  const limitPerKind = Math.min(Math.max(Number(o.limit) || 25, 1), 200);
  const root = o.root || cfg.primaryRoot;
  const now = new Date();
  const year = now.getFullYear();
  const month = `${year}-${String(now.getMonth() + 1).padStart(2, '0')}`;

  const clutter = checkRootClutter(db, { ...cfg, primaryRoot: root });
  const inbox = checkInbox(db, cfg, opts);
  const naming = checkNaming(db, cfg, { ...opts, root });
  const dups = checkDuplicates(db, cfg, { ...opts, root, limit: 10 });
  const stale = checkStale(db, cfg, { ...opts, root, limit: 15 });

  const proposals = [];

  // 收集目录未配置时不给「移到哪」的目标 —— 通用软件不该替用户决定归档到哪。
  const inboxRel = (cfg.policy && cfg.policy.inboxDir) || null;

  for (const f of clutter.files.slice(0, limitPerKind)) {
    proposals.push({
      action: inboxRel ? 'move' : 'triage',
      from: f.rel,
      to: inboxRel ? `${inboxRel}/${month}/${f.name}` : null,
      reason: inboxRel
        ? '根目录散文件（判定依据：policy.rootNavPatterns 未把它算作导航文件）'
        : '根目录散文件（判定依据：policy.rootNavPatterns 未把它算作导航文件）。未配置 policy.inboxDir，所以只列出、不指定去处。',
      risk: inboxRel ? 'low' : 'manual',
      category: '根目录散文件',
    });
  }

  for (const item of inbox.items.filter((i) => i.days > inbox.summary.staleDays).slice(0, limitPerKind)) {
    proposals.push({
      action: 'triage',
      from: item.rel,
      to: null,
      reason: `\`${inboxRel}\` 停留 ${item.days} 天未归位，需要判断归属`,
      risk: 'manual',
      category: `${inboxRel} 积压`,
    });
  }

  for (const g of dups.exact.slice(0, 10)) {
    const [keep, ...rest] = g.files;
    for (const f of rest) {
      proposals.push({
        action: 'archive',
        from: f.rel,
        to: `归档/${year}/重复副本/${path.basename(f.rel)}`,
        reason: `与 \`${keep.rel}\` 内容完全相同（${g.sizeText}），保留较新的那一份`,
        risk: 'medium',
        category: '重复文件',
      });
    }
  }

  for (const m of naming.matches.slice(0, limitPerKind)) {
    proposals.push({
      action: 'review',
      from: m.rel,
      to: null,
      reason: '文件管理规则第 5 条：版本化命名（最终版/副本/最新），建议合并为固定名称',
      risk: 'manual',
      category: '版本化命名',
    });
  }

  for (const s of stale.biggest.slice(0, limitPerKind)) {
    proposals.push({
      action: 'review',
      from: s.rel,
      to: `归档/${year}/（待定）/`,
      reason: `超过 ${stale.summary.days} 天未改动且体积较大（${formatBytes(s.size)}），候选归档`,
      risk: 'manual',
      category: '陈旧大文件',
    });
  }

  const byCategory = new Map();
  for (const p of proposals) {
    if (!byCategory.has(p.category)) byCategory.set(p.category, []);
    byCategory.get(p.category).push(p);
  }

  const md = [];
  md.push('# 文件整理方案（dry-run）');
  md.push('');
  md.push(`根目录：\`${root}\`　生成时间：${now.toLocaleString('zh-CN')}`);
  md.push('');
  md.push('> **这是一份建议，没有执行任何改动。** 每条动作都需要你确认；本工具永远不移动、重命名或删除文件。');
  md.push('');
  md.push(`共 ${proposals.length} 条建议：`);
  md.push('');
  md.push('| 类别 | 条数 | 风险 |');
  md.push('| --- | ---: | --- |');
  for (const [cat, list] of byCategory) {
    const risks = [...new Set(list.map((p) => p.risk))].join('/');
    md.push(`| ${cat} | ${list.length} | ${risks} |`);
  }
  md.push('');
  for (const [cat, list] of byCategory) {
    md.push(`## ${cat}`);
    md.push('');
    md.push('| 动作 | 从 | 到 | 理由 |');
    md.push('| --- | --- | --- | --- |');
    for (const p of list.slice(0, limitPerKind)) {
      md.push(`| ${p.action} | \`${p.from}\` | ${p.to ? '`' + p.to + '`' : '—'} | ${p.reason} |`);
    }
    if (list.length > limitPerKind) md.push(`\n（该类共 ${list.length} 条，只列前 ${limitPerKind} 条。）`);
    md.push('');
  }
  md.push('## 执行建议顺序');
  md.push('');
  md.push('1. 先清 \`待整理/\`：这是唯一「没有归属」的缓冲，先归位再谈归档。');
  md.push('2. 再处理版本化命名：合并成一份主要版本，把旧的移入 \`归档/年份/事项/\` 并注明新入口。');
  md.push('3. 最后处理完全重复文件：确认保留哪一份（一般留最新改动时间），其余的归档而非直接删除。');
  md.push('4. 每一步都先给用户看清单再动手；\`归档/\` 内部允许直接操作，其他位置一律先确认。');
  md.push('');
  return {
    ok: true,
    executed: false,
    root: toPosix(root),
    totalProposals: proposals.length,
    byCategory: [...byCategory.entries()].map(([cat, list]) => ({ category: cat, count: list.length, risk: [...new Set(list.map((p) => p.risk))].join('/') })),
    proposals,
    markdown: md.join('\n'),
  };
}

module.exports = {
  CHECKS,
  audit,
  checkDuplicates,
  checkStale,
  checkNaming,
  checkInbox,
  checkRootClutter,
  checkLinks,
  proposeOrganize,
  hashFileSync,
};
