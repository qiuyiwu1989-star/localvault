'use strict';

/**
 * 两张「默认规则表」必须逐字一致。
 *
 * ## 为什么需要这个测试
 *
 * `ignoredDirs` / `denyRead` / `ignoredDirSuffixes` 在**两个语言里各存了一份**，
 * 而且**两份都真的在用**：
 * - CLI 走 `mcp-server/lib/config.js`；
 * - App 在 `config.json` **没有** `ignoredDirs` 时走
 *   `app/Sources/LocalVault/VaultIndexer.swift` 里那张 —— 向导自己建的配置就是这种情况。
 *
 * 所以它们分叉时，同一台机器的 CLI 和 App 会给出**两种扫描口径**，
 * 而且是静默的：没有报错，只是某些目录一边扫一边不扫。
 *
 * 曾经的注释写着「往 config.js 加，两边同时生效」—— 那是错的，
 * 于是表里少了 `.build`，实测把 SwiftPM 的 `.build/` 索引了 220 行 / 161MB。
 * 结论：这种事不能靠注释提醒，得靠一条会红的断言。
 *
 * 跑法：node test/ignore-lists.js
 */

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const JS = path.join(ROOT, 'lib', 'config.js');
const SWIFT = path.join(ROOT, '..', 'app', 'Sources', 'LocalVault', 'VaultIndexer.swift');

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}${detail ? ' —— ' + detail : ''}`); }
}

/** 从 JS 源码里抽出一个 `const NAME = [ ... ];` 的字符串字面量。 */
function jsList(src, name) {
  const m = src.match(new RegExp(`const\\s+${name}\\s*=\\s*\\[([\\s\\S]*?)\\]`, 'm'));
  if (!m) throw new Error(`在 config.js 里找不到 ${name}`);
  return [...m[1].matchAll(/'([^']*)'|"([^"]*)"/g)].map((x) => x[1] ?? x[2]);
}

/** 从 Swift 源码里抽出一个 `static let NAME = [ ... ]` 的字符串字面量。 */
function swiftList(src, name) {
  const m = src.match(new RegExp(`static\\s+let\\s+${name}\\s*=\\s*\\[([\\s\\S]*?)\\n\\s*\\]`, 'm'));
  if (!m) throw new Error(`在 VaultIndexer.swift 里找不到 ${name}`);
  return [...m[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]);
}

function diff(a, b) {
  const sa = new Set(a);
  const sb = new Set(b);
  const onlyA = a.filter((x) => !sb.has(x));
  const onlyB = b.filter((x) => !sa.has(x));
  return { onlyA, onlyB };
}

console.log('两张默认规则表是否一致\n');

const jsSrc = fs.readFileSync(JS, 'utf8');
const swiftSrc = fs.readFileSync(SWIFT, 'utf8');

/* ---- ignoredDirs ---- */
{
  const a = jsList(jsSrc, 'DEFAULT_IGNORED_DIRS');
  const b = swiftList(swiftSrc, 'defaultIgnoredDirs');
  const { onlyA, onlyB } = diff(a, b);
  check('ignoredDirs 两张表元素相同', onlyA.length === 0 && onlyB.length === 0,
    `只在 config.js：${onlyA.join(', ') || '无'} ；只在 Swift：${onlyB.join(', ') || '无'}`);
  check('ignoredDirs 顺序也相同（改表时两边一起改，diff 才看得懂）',
    a.join('\u0000') === b.join('\u0000'),
    a.join('\u0000') === b.join('\u0000') ? '' : '顺序不一致');
  check('ignoredDirs 无重复项', new Set(a).size === a.length,
    `原始 ${a.length} / 去重 ${new Set(a).size}`);
}

/* ---- denyRead ---- */
{
  const a = jsList(jsSrc, 'DEFAULT_DENY_READ');
  const b = swiftList(swiftSrc, 'defaultDenyRead');
  const { onlyA, onlyB } = diff(a, b);
  check('denyRead 两张表元素相同', onlyA.length === 0 && onlyB.length === 0,
    `只在 config.js：${onlyA.join(', ') || '无'} ；只在 Swift：${onlyB.join(', ') || '无'}`);
  check('denyRead 顺序也相同', a.join('\u0000') === b.join('\u0000'),
    a.join('\u0000') === b.join('\u0000') ? '' : '顺序不一致');
}

/* ---- ignoredDirSuffixes ---- */
{
  const a = jsList(jsSrc, 'DEFAULT_IGNORED_DIR_SUFFIXES');
  const b = swiftList(swiftSrc, 'defaultIgnoredDirSuffixes');
  const { onlyA, onlyB } = diff(a, b);
  check('ignoredDirSuffixes 两张表元素相同', onlyA.length === 0 && onlyB.length === 0,
    `只在 config.js：${onlyA.join(', ') || '无'} ；只在 Swift：${onlyB.join(', ') || '无'}`);
}

/* ---- 具体的「亲眼见过它出问题」的那几个条目 ---- */
{
  const a = new Set(jsList(jsSrc, 'DEFAULT_IGNORED_DIRS'));
  const mustHave = ['.build', '.venv', 'venv', '.git', 'node_modules'];
  for (const k of mustHave) {
    check(`构建产物目录 ${k} 确实在忽略表里`, a.has(k));
  }
}

/* ---- 行为：叠加而不是替换 ---- */
{
  const { loadConfig, DEFAULT_IGNORED_DIRS, DEFAULT_DENY_READ } = require('../lib/config');
  const os = require('node:os');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lv-ign-'));
  const oldHome = process.env.HOME;
  const oldData = process.env.LOCALVAULT_DATA_DIR;
  const oldCfg = process.env.LOCALVAULT_CONFIG;
  try {
    // 造一份「老机器」的配置：一份不含 .build 的完整快照 + 一个用户自加项
    const stale = DEFAULT_IGNORED_DIRS.filter((x) => x !== '.build' && x !== '.venv');
    fs.writeFileSync(path.join(tmp, 'config.json'), JSON.stringify({
      version: 2, dataDir: tmp, ignoredDirs: [...stale, '我自己的目录'],
      denyRead: ['.env'], roots: [{ path: tmp, label: 't' }], primaryRoot: tmp,
    }));
    process.env.HOME = tmp;
    process.env.LOCALVAULT_DATA_DIR = tmp;
    delete process.env.LOCALVAULT_CONFIG;

    const cfg = loadConfig();
    check('老配置里没有 .build，读出来也生效（叠加，不是替换）', cfg.ignoredDirs.includes('.build'));
    check('老配置里没有 .venv，读出来也生效', cfg.ignoredDirs.includes('.venv'));
    check('用户自己加的条目没丢', cfg.ignoredDirs.includes('我自己的目录'));
    check('老配置只写了 .env，默认的凭据规则也补齐了',
      DEFAULT_DENY_READ.every((x) => cfg.denyRead.includes(x)));

    // `!名字` 能取消默认项
    fs.writeFileSync(path.join(tmp, 'config.json'), JSON.stringify({
      version: 2, dataDir: tmp, ignoredDirs: ['!build', '我自己的目录'],
      roots: [{ path: tmp, label: 't' }], primaryRoot: tmp,
    }));
    const cfg2 = loadConfig();
    check('写 "!build" 可以取消这一条默认项', !cfg2.ignoredDirs.includes('build'));
    check('  —— 而且只取消这一条，别的默认项还在', cfg2.ignoredDirs.includes('node_modules'));
    check('  —— 用户自加项不受影响', cfg2.ignoredDirs.includes('我自己的目录'));
    check('  —— "!build" 本身不会进列表', !cfg2.ignoredDirs.includes('!build'));
  } finally {
    if (oldHome === undefined) delete process.env.HOME; else process.env.HOME = oldHome;
    if (oldData === undefined) delete process.env.LOCALVAULT_DATA_DIR; else process.env.LOCALVAULT_DATA_DIR = oldData;
    if (oldCfg === undefined) delete process.env.LOCALVAULT_CONFIG; else process.env.LOCALVAULT_CONFIG = oldCfg;
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

console.log(`\n通过 ${passed} · 失败 ${failed}`);
if (failed > 0) { console.log('默认规则表分叉或叠加行为不对。'); process.exitCode = 1; }
else { console.log('两张表一致，叠加行为正确。'); process.exitCode = 0; }
