'use strict';

/**
 * 自动发现：从磁盘上的**实际内容**推断工作区约定。
 *
 * 存在的理由：一个装在别人电脑上的软件，没有资格假定
 * 「入口文档叫 00-从这里开始.md」「收集目录叫 待整理」「台账在 项目管理/」。
 * 这些都必须从磁盘推出来，或者由用户在 config.json 里显式覆盖。
 *
 * 所有推断结果都带 source（推断依据的文件路径），
 * 因为它们可能猜错 —— 猜错时必须让人看得出是怎么猜的。
 */

const path = require('node:path');
const { toPosix, squeeze, readJsonSafe } = require('./util');

/** 入口文档的名字强度。分越高越像"从这里开始读"。 */
const NAV_PATTERNS = [
  { re: /^00[-_\s.]/, score: 100 },
  { re: /^0[-_\s.]/, score: 90 },
  { re: /^readme([-_.].*)?$/i, score: 85 },
  { re: /^(index|overview|start|home)([-_.].*)?$/i, score: 80 },
  { re: /^(agents?|claude|cursor|gemini|copilot)\.md$/i, score: 75 },
  { re: /(从这里开始|开始阅读|快速开始|入口|导航|总览|索引)/, score: 70 },
  { re: /^(maps?|toc|contents?|guide|handbook)([-_.].*)?$/i, score: 55 },
];

/** 台账候选的名字模式。 */
const LEDGER_PATTERNS = [
  { re: /台账|清册|总表|汇总表/, score: 90 },
  { re: /(^|[-_.])(ledger|registry|inventory|manifest|projects?|catalog)([-_.]|$)/i, score: 80 },
];

/** 规则/约定文档的名字模式。 */
const RULES_PATTERNS = [
  { re: /文件管理规则|管理规则|整理规则|命名规则/, score: 95 },
  { re: /(^|[-_.])(rules?|conventions?|guidelines?|styleguide|contributing|standards?)([-_.]|$)/i, score: 85 },
  { re: /(^|[-_.])(规范|约定|规约|章程|制度)([-_.]|$)/, score: 80 },
];

function matchScore(name, patterns) {
  for (const p of patterns) if (p.re.test(name)) return p.score;
  return 0;
}

function depthOf(rel) {
  return String(rel).split('/').length - 1;
}

/**
 * 入口文档：根目录及浅层的导航类文档，按名字强度 + 层级排序。
 * @returns {{rel:string,name:string,title:string,score:number}[]}
 */
function discoverCanonicalDocs(db, cfg, opts) {
  const o = opts || {};
  const root = o.root || cfg.primaryRoot;
  const max = Number.isFinite(o.max) ? o.max : 12;
  const maxDepth = Number.isFinite(o.maxDepth) ? o.maxDepth : 2;

  let rows = [];
  try {
    rows = db
      .prepare(
        `SELECT rel, name, ext, kind, size, title FROM files
         WHERE gone = 0 AND is_symlink = 0 AND root = ?
           AND kind IN ('doc','web','data') AND length(coalesce(body,'')) > 0`,
      )
      .all(root);
  } catch (_e) {
    return [];
  }

  const out = [];
  for (const r of rows) {
    const rel = toPosix(r.rel);
    const depth = depthOf(rel);
    if (depth > maxDepth) continue;
    const base = matchScore(r.name, NAV_PATTERNS);
    if (base <= 0) continue;
    // 层级每深一层扣分：根目录的 README 比 深/深/README 更像总入口
    const score = base - depth * 15;
    out.push({ rel, name: r.name, title: squeeze(r.title || ''), score, depth });
  }
  out.sort((a, b) => b.score - a.score || a.rel.length - b.rel.length);
  return out.slice(0, max);
}

/**
 * 目录用途：优先取该目录里的 README / 00-* / index，用其标题当用途。
 * @returns {{[seg:string]: {note:string, source:string}}}
 */
function discoverDirNotes(db, cfg, opts) {
  const o = opts || {};
  const root = o.root || cfg.primaryRoot;
  const maxDirs = Number.isFinite(o.maxDirs) ? o.maxDirs : 60;

  let segs = [];
  try {
    segs = db
      .prepare(
        `SELECT DISTINCT substr(rel, 1, instr(rel, '/') - 1) AS seg FROM files
         WHERE gone = 0 AND is_symlink = 0 AND root = ? AND instr(rel, '/') > 0`,
      )
      .all(root)
      .map((r) => r.seg)
      .filter(Boolean)
      .slice(0, maxDirs);
  } catch (_e) {
    return {};
  }

  const notes = {};
  for (const seg of segs) {
    const hit = noteFromDir(db, root, seg);
    if (hit) notes[seg] = hit;
  }
  return notes;
}

function noteFromDir(db, root, seg) {
  const PATTERNS = [
    { re: /^readme(\.[a-z]+)?$/i, score: 0 },
    { re: /^00[-_\s.]/, score: 1 },
    { re: /^(index|overview|about)(\.[a-z]+)?$/i, score: 2 },
  ];
  let rows = [];
  try {
    const { escapeLike } = require('./search');
    rows = db
      .prepare(
        `SELECT rel, title, name FROM files
         WHERE gone = 0 AND root = ? AND rel LIKE ? ESCAPE '\\'
           AND ext IN ('.md', '.txt', '.markdown')
           AND length(coalesce(body,'')) > 0
         LIMIT 40`,
      )
      .all(root, escapeLike(String(seg)) + '/%');
  } catch (_e) {
    return null;
  }

  const ranked = [];
  for (const r of rows) {
    const rel = toPosix(r.rel);
    // 只看该目录直接子文件，不看更深的
    if (depthOf(rel) !== 1) continue;
    const s = matchScore(r.name, PATTERNS);
    if (s > 0 || /^(readme|index|00)/i.test(r.name)) {
      ranked.push({ rel, name: r.name, title: squeeze(r.title || ''), score: s });
    }
  }
  ranked.sort((a, b) => a.score - b.score || a.rel.length - b.rel.length);

  for (const r of ranked) {
    const title = r.title;
    if (title.length >= 2 && title.length <= 70) return { note: title, source: r.rel };
  }
  return null;
}

/**
 * 台账：找到一个"把项目映射到位置"的机器可读清单。
 * 只做启发式，找不到就返回 null —— 调用方必须能优雅降级。
 * @returns {{rel:string,count:number,shape:string}|null}
 */
function discoverLedger(db, cfg, opts) {
  const o = opts || {};
  const root = o.root || cfg.primaryRoot;
  const absRoot = root;

  let rows = [];
  try {
    rows = db
      .prepare(
        `SELECT rel, name, ext, size FROM files
         WHERE gone = 0 AND is_symlink = 0 AND root = ?
           AND ext IN ('.json','.csv') AND size > 2 AND size < 4000000`,
      )
      .all(root);
  } catch (_e) {
    return null;
  }

  const cands = [];
  for (const r of rows) {
    const rel = toPosix(r.rel);
    const depth = depthOf(rel);
    if (depth > 2) continue;
    const base = matchScore(r.name, LEDGER_PATTERNS);
    if (base <= 0) continue;
    cands.push({ rel, name: r.name, ext: r.ext, score: base - depth * 15 });
  }
  cands.sort((a, b) => b.score - a.score);

  for (const c of cands.slice(0, 5)) {
    const shape = inspectLedgerShape(path.join(absRoot, c.rel), c.ext);
    if (shape) return { rel: c.rel, count: shape.count, shape: shape.shape };
  }
  return null;
}

/** 验证候选台账确实"像一份清单"。 */
function inspectLedgerShape(abs, ext) {
  try {
    if (ext === '.csv') {
      const text = require('node:fs').readFileSync(abs, 'utf8');
      const lines = text.split('\n').filter((l) => l.trim());
      if (lines.length < 3) return null;
      return { shape: 'csv', count: lines.length - 1 };
    }
    const data = readJsonSafe(abs);
    if (!data || typeof data !== 'object') return null;
    for (const key of ['projects', 'items', 'entries', 'list', 'rows', 'data']) {
      if (Array.isArray(data[key])) return { shape: 'object.' + key, count: data[key].length };
    }
    if (Array.isArray(data)) return { shape: 'array', count: data.length };
    const keys = Object.keys(data);
    // 对象但键很多，且值多为对象 → 也算清单
    if (keys.length >= 3 && keys.filter((k) => data[k] && typeof data[k] === 'object').length >= keys.length / 2) {
      return { shape: 'map', count: keys.length };
    }
    return null;
  } catch (_e) {
    return null;
  }
}

/**
 * 规则文档：找到用户自己的整理/命名约定。
 * @returns {string|null} 相对路径
 */
function discoverRules(db, cfg, opts) {
  const o = opts || {};
  const root = o.root || cfg.primaryRoot;
  let rows = [];
  try {
    rows = db
      .prepare(
        `SELECT rel, name FROM files
         WHERE gone = 0 AND is_symlink = 0 AND root = ?
           AND ext IN ('.md','.txt','.markdown') AND length(coalesce(body,'')) > 0`,
      )
      .all(root);
  } catch (_e) {
    return null;
  }
  const cands = [];
  for (const r of rows) {
    const rel = toPosix(r.rel);
    const depth = depthOf(rel);
    if (depth > 2) continue;
    const s = matchScore(r.name, RULES_PATTERNS);
    if (s <= 0) continue;
    cands.push({ rel, score: s - depth * 15 });
  }
  cands.sort((a, b) => b.score - a.score || a.rel.length - b.rel.length);
  return cands.length ? cands[0].rel : null;
}

/**
 * 汇总一次自动发现。显式配置优先，发现结果只填空。
 * @returns {{canonicalDocs:object[], dirNotes:object, ledger:object|null, rules:string|null, sources:object}}
 */
function runDiscovery(db, cfg, opts) {
  const o = opts || {};
  const root = o.root || cfg.primaryRoot;
  const on = cfg.discover || {};
  const result = { canonicalDocs: [], dirNotes: {}, ledger: null, rules: null, sources: {} };

  if (on.canonicalDocs !== false) {
    result.canonicalDocs = discoverCanonicalDocs(db, cfg, { root });
    result.sources.canonicalDocs = 'auto';
  }
  if (on.dirNotes !== false) {
    result.dirNotes = discoverDirNotes(db, cfg, { root });
    result.sources.dirNotes = 'auto';
  }
  if (on.ledger !== false) {
    result.ledger = discoverLedger(db, cfg, { root });
    result.sources.ledger = result.ledger ? 'auto' : 'none';
  }
  if (on.rules !== false) {
    result.rules = discoverRules(db, cfg, { root });
    result.sources.rules = result.rules ? 'auto' : 'none';
  }
  return result;
}

module.exports = {
  discoverCanonicalDocs,
  discoverDirNotes,
  discoverLedger,
  discoverRules,
  noteFromDir,
  runDiscovery,
  inspectLedgerShape,
  NAV_PATTERNS,
  LEDGER_PATTERNS,
  RULES_PATTERNS,
};
