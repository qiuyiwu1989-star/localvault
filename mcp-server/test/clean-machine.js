#!/usr/bin/env node
'use strict';

/**
 * 干净机器安装测试。
 *
 * 验证的是产品主张里最难的一条：**「每台电脑装完配一下就能用」**。
 *
 * 做法不是断言，而是真的演一遍：
 *   1. 按 package.json 的 `files` 清单打包（模拟 npm pack 会装进去的东西）
 *   2. 解到一个干净前缀（模拟 `npm i -g`）
 *   3. 造一个**别人的主目录**：英文内容、完全不同的目录结构，
 *      外加一个和开发者工作区同名的诱饵目录
 *   4. 只给 HOME 环境变量，跑 init → index → search → coverage → audit
 *   5. 断言：这台机器的内容可搜；**开发者的内容一条都不该出现**
 *
 * 跑法：node test/clean-machine.js
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const PKG = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));

/**
 * npm 包里**允许出现**的非代码文件（精确白名单）。
 *
 * 为什么需要白名单：npm 首页就是包内 `README.md`，而 LICENSE 是发布惯例 ——
 * 二者都必须在包里。但它们不能成为「什么 .md 都能进包」的口子，
 * 所以规则写成「除白名单外，一律不放行」。
 */
const ALLOWED_PACK_FILES = ['README.md', 'LICENSE'];

/**
 * 包内文件是否合规。抽成函数是为了让 clean-machine 能**双向验证它**：
 * 合规的包放行、不合规的包拦住。否则断言容易被写成永远为真的空断言。
 */
function packFileIsAllowed(rel) {
  const base = path.posix.basename(String(rel).replace(/\\/g, '/'));
  if (ALLOWED_PACK_FILES.includes(base)) return true;
  const parts = String(rel).split('/');
  if (parts.includes('test')) return false; // 测试不进包
  if (base.endsWith('.md')) return false; // 其余交付文档不进包
  return true;
}

let passed = 0;
let failed = 0;
function check(name, ok, detail) {
  if (ok) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.log(`  ✗ ${name}${detail ? ` —— ${detail}` : ''}`);
  }
}
function section(t) {
  console.log(`\n${t}`);
}

/** 按 package.json 的 files 清单收集文件 —— 这就是 npm pack 会带走的东西。 */
function collectPackFiles() {
  const out = [];
  const addPath = (rel) => {
    const abs = path.join(ROOT, rel);
    if (!fs.existsSync(abs)) return;
    const st = fs.statSync(abs);
    if (st.isDirectory()) {
      for (const e of fs.readdirSync(abs)) addPath(path.join(rel, e));
    } else {
      out.push(rel);
    }
  };
  for (const f of PKG.files || []) addPath(f);
  out.push('package.json');
  return out;
}

function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'localvault-cleanmachine-'));
  const prefix = path.join(tmp, 'prefix', 'node_modules', 'localvault');
  const fakeHome = path.join(tmp, 'fakehome');

  // ---- 1. 打包 ----
  section('打包（按 package.json 的 files 清单）');
  const packFiles = collectPackFiles();
  for (const rel of packFiles) {
    const dest = path.join(prefix, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(path.join(ROOT, rel), dest);
  }
  const installed = JSON.parse(fs.readFileSync(path.join(prefix, 'package.json'), 'utf8'));
  check('包名是 localvault（不是 @local/... 私有名）', installed.name === 'localvault', installed.name);
  check('bin 暴露 localvault 命令', Boolean(installed.bin && installed.bin.localvault), JSON.stringify(installed.bin));
  check('声明 node >= 22.5（node:sqlite 要求）', /22\.5/.test(installed.engines && installed.engines.node));

  // 白名单断言。分三步，保证它「漏了会红、且两边都不是空断言」：
  //   ① 规则本身双向验证过（合规放行 / 违规拦住）——这部分是纯函数，不依赖包内容
  //   ② 真实 packFiles 里不能有违规项
  //   ③ 允许的 README.md / LICENSE 必须**真的在包里**（防止断言退化成「什么都不检查」）
  {
    const ruleProbe = [
      ['cli.js', true],
      ['lib/vault.js', true],
      ['README.md', true],
      ['LICENSE', true],
      ['test/smoke.js', false],
      ['test/clean-machine.js', false],
      ['NOTES.md', false],
      ['工具/本地上下文MCP/README.md', true], // basename 命中白名单，属预期
      ['docs/guide.md', false],
    ];
    const ruleOk = ruleProbe.every(([f, want]) => packFileIsAllowed(f) === want);
    check(
      '白名单规则双向生效（README/LICENSE 放行；test/ 与其他 .md 拦住）',
      ruleOk,
      ruleProbe.filter(([f, want]) => packFileIsAllowed(f) !== want).map(([f]) => f).join(',') || 'ok',
    );

    const offenders = packFiles.filter((f) => !packFileIsAllowed(f));
    check('包内不含测试与白名单外文档', offenders.length === 0, offenders.join(',') || packFiles.join(','));

    // 非空断言：README/LICENSE 进了包，断言才不是空转
    const packBases = new Set(packFiles.map((f) => path.posix.basename(String(f).replace(/\\/g, '/'))));
    for (const must of ALLOWED_PACK_FILES) {
      check(`包内含 ${must}（npm 首页/许可，故意放进白名单）`, packBases.has(must), packFiles.join(','));
    }
  }

  check('包内含全部 lib 模块', fs.readdirSync(path.join(prefix, 'lib')).length >= 12, String(fs.readdirSync(path.join(prefix, 'lib')).length));

  // ---- 2. 造别人的主目录 ----
  section('造一台「别人的电脑」');
  const files = {
    'Desktop/quarterly-plan-2026.txt': 'Quarterly revenue plan for the Berlin office. Contact: anna@example.org\n',
    'Desktop/standup-notes.md': 'Standup notes: shipped the ingest pipeline, next up the retry queue.\n',
    'Downloads/invoice-1042.txt': 'The quick brown fox jumps over the lazy dog. Placeholder invoice 1042.\n',
    'Documents/projects/report-drafts/agenda.md': 'Design review agenda: pricing page, onboarding flow, churn dashboard.\n',
    'Documents/notes/vector-recall.md': 'Research memo on vector search recall vs substring matching.\n',
    // 诱饵：目录名和开发者工作区同名，但里面没有台账/规则文档
    'Desktop/项目管理/decoy.txt': "Shares a name with the developer's workspace. marker=FAKEMARKER.\n",
  };
  for (const [rel, body] of Object.entries(files)) {
    const abs = path.join(fakeHome, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, body, 'utf8');
  }
  check('假主目录已建好（含同名诱饵目录）', fs.existsSync(path.join(fakeHome, 'Desktop/项目管理/decoy.txt')));

  const CLI = path.join(prefix, 'cli.js');
  const run = (args) =>
    spawnSync(process.execPath, [CLI, ...args], {
      env: { HOME: fakeHome, PATH: process.env.PATH, LOCALVAULT_QUIET: '' },
      encoding: 'utf8',
    });

  // ---- 3. init ----
  section('init');
  const init = run(['init']);
  check('init 退出码 0', init.status === 0, init.stderr.slice(0, 300));
  const cfgFile = path.join(fakeHome, '.localvault', 'config.json');
  check('配置写到假主目录下', fs.existsSync(cfgFile), cfgFile);
  let cfg = null;
  try { cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8')); } catch (e) { /* 保持 null */ }
  check('配置可解析', cfg !== null);
  if (cfg) {
    check('索引根指向假主目录，而非开发者机器',
      cfg.roots.length === 2 && cfg.roots.every((r) => !String(r.path).includes('邱懿武')),
      JSON.stringify(cfg.roots));
    check('探测到 桌面 + 下载', cfg.roots.some((r) => /Desktop/.test(r.path)) && cfg.roots.some((r) => /Downloads/.test(r.path)));
    check('未默认索引 Documents（要用户显式指定）', !cfg.roots.some((r) => /Documents/.test(r.path)));
    check('配置不含个人台账/规则/入口文档',
      cfg.ledgerFile === null && cfg.rulesFile === null && cfg.canonicalDocs.length === 0 && Object.keys(cfg.dirNotes).length === 0,
      JSON.stringify({ l: cfg.ledgerFile, r: cfg.rulesFile, c: cfg.canonicalDocs.length }));
    check('未配置的检查保持关闭', cfg.policy.inboxDir === null && cfg.policy.projectCardDir === null);
  }

  // ---- 4. index ----
  section('index');
  const idx = run(['index']);
  check('index 退出码 0', idx.status === 0, idx.stderr.slice(0, 300));
  check('索引到桌面 3 个文件 + 下载 1 个', /4 个文件/.test(idx.stdout), idx.stdout.split('\n').find((l) => /扫描完成/.test(l)));

  // ---- 5. 这台机器的内容可搜 ----
  section('这台机器自己的内容可搜');
  const s1 = run(['search', 'brown fox']);
  check('搜到本机文件内容', s1.status === 0 && s1.stdout.includes('invoice-1042.txt'), s1.stdout.slice(0, 200));
  const s2 = run(['search', 'FAKEMARKER']);
  check('同名诱饵目录里的文件也能正常搜到', s2.status === 0 && s2.stdout.includes('decoy.txt'), s2.stdout.slice(0, 200));
  const cov = run(['coverage']);
  check('coverage 可用', cov.status === 0 && cov.stdout.includes('覆盖度报告'), cov.stdout.slice(0, 200));

  // ---- 6. 隔离性：开发者的内容一条都不许出现 ----
  section('隔离性（最重要的断言）');
  const leaked = [];
  for (const q of ['邱懿武', '造物云', '深脑', '硬脑', '永乐教育', 'qmem', 'shennao']) {
    const r = run(['search', q]);
    if (!/→ 0 条/.test(r.stdout)) leaked.push(`${q}: ${(r.stdout.match(/→ \d+ 条/) || ['?'])[0]}`);
  }
  check('开发者工作区的词条检索零命中', leaked.length === 0, leaked.join('；'));

  const ins = run(['instructions']);
  check('instructions 未泄漏开发者内容',
    ins.status === 0 && !/邱懿武|造物云|shennao|qmem/.test(ins.stdout) && /desktop|Desktop/.test(ins.stdout),
    ins.stdout.slice(0, 200));
  const mp = run(['map']);
  check('地图未泄漏开发者内容', mp.status === 0 && !/邱懿武|造物云|shennao/.test(mp.stdout));

  // ---- 7. 治理检查：未配置的必须说「未检查」而不是 0 ----
  section('治理检查');
  const aud = run(['audit', 'inbox,root_clutter,naming']);
  check('audit 退出码 0', aud.status === 0, aud.stderr.slice(0, 300));
  check('未配置的收集目录检查明确显示「未配置，未检查」',
    aud.stdout.includes('未配置，未检查'), aud.stdout.split('\n').filter((l) => /待整理积压/.test(l)).join(' | '));
  check('审计正文说明该项已跳过', aud.stdout.includes('未配置，已跳过'));
  check('命名检查不误报英文内容', /0 个命中自定义词表/.test(aud.stdout), aud.stdout.split('\n').find((l) => /命名违规/.test(l)));

  // ---- 8. 用一个中文用户自己的约定（验证可配置性）----
  section('可配置性（换成这台机器自己的约定）');
  cfg.policy.inboxDir = '项目管理';      // 这台机器用 项目管理/ 当收集目录
  cfg.policy.versionNamePatterns = ['draft', 'wip'];
  fs.writeFileSync(cfgFile, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
  const aud2 = run(['audit', 'inbox']);
  check('配置后收集目录检查生效', aud2.status === 0 && aud2.stdout.includes('decoy.txt'), aud2.stdout.slice(0, 300));
  check('配置后不再显示「未配置，未检查」', !aud2.stdout.includes('未配置，未检查'));

  console.log(`\n结果\n  通过 ${passed} 项，失败 ${failed} 项`);
  if (failed === 0) {
    console.log(`\n全部通过 —— 「另一台电脑装完配一下就能用」已验证。`);
    fs.rmSync(tmp, { recursive: true, force: true });
  } else {
    console.log(`\n有失败项。临时目录保留：${tmp}`);
  }
  process.exitCode = failed === 0 ? 0 : 1;
}

main();
