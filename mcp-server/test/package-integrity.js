#!/usr/bin/env node
'use strict';
/**
 * 发布清单的自检：**npm 会不会在我不知情的情况下改掉我要发的东西。**
 *
 * ## 为什么要有这个测试
 *
 * `package.json` 里原来写的是：
 *
 *     "bin": { "localvault": "./cli.js" }
 *
 * 那个 `./` 看起来完全无害 —— 路径确实对，本地 `node cli.js` 也跑得通，
 * `npm pack` 打出来的包里 `bin` 也还在。**但它会在发布那一刻被 npm 悄悄删掉：**
 *
 *     npm warn publish npm auto-corrected some errors in your package.json
 *     npm warn publish "bin[localvault]" script name cli.js was invalid and removed
 *
 * 后果不是「少个警告」，是**装完没有任何命令可跑** ——
 * 而这条警告只在 `npm publish --dry-run` 时出现，`npm pack` 不报。
 * 换句话说：**只有真正按发布那条命令走一遍，才看得见它。**
 *
 * ## 这个测试怎么防止它复发
 *
 * 1. 静态判据：`bin` 的值不能以 `./` 开头（这就是根因，写死它）。
 * 2. 结构判据：`bin` / `main` / `files` 指向的东西必须真的存在、且带 shebang。
 * 3. **真跑一次 `npm publish --dry-run`**，断言输出里没有 `auto-corrected`。
 *    第 3 条才是关键 —— 前两条是我对 npm 行为的**理解**，
 *    第 3 条是 npm 的**实际行为**。理解会过时，行为不会。
 *
 * 第 3 条需要 npm。本机没有 npm 时它会**明确报「跳过」，不计入通过** ——
 * 静默当成通过比不检查更糟（那会让人以为查过了）。
 *
 * 跑法：node test/package-integrity.js
 */

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const PKG = path.join(ROOT, 'package.json');

let passed = 0;
let failed = 0;
let skipped = 0;

function check(name, ok, detail) {
  if (ok) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.log(`  ✗ ${name}`);
    if (detail) console.log(`      ${String(detail).split('\n').slice(0, 6).join('\n      ')}`);
  }
}

function skip(name, why) {
  skipped++;
  console.log(`  ⊘ ${name}`);
  console.log(`      跳过原因：${why}`);
}

const pkg = JSON.parse(fs.readFileSync(PKG, 'utf8'));

// ── 1. bin：值不能带 ./ ───────────────────────────────────────────────
//
// 这不是风格问题。npm 把 `./cli.js` 判为「invalid」并从发布清单里删掉，
// 于是 `npx localvault` / 安装后的 `localvault` 全部不存在。
console.log('\nbin');
const bins = pkg.bin && typeof pkg.bin === 'object' ? Object.entries(pkg.bin) : [];
check('声明了 bin（否则装完没有命令）', bins.length > 0, JSON.stringify(pkg.bin));

for (const [name, target] of bins) {
  check(`bin["${name}"] 的值不以 ./ 开头（带了会被 npm 静默删掉）`,
    typeof target === 'string' && !target.startsWith('./'),
    `实际是 ${JSON.stringify(target)}`);

  const abs = path.join(ROOT, target);
  check(`bin["${name}"] 指向的文件存在：${target}`, fs.existsSync(abs), abs);

  if (fs.existsSync(abs)) {
    const head = fs.readFileSync(abs, 'utf8').split('\n')[0];
    check(`bin["${name}"] 的文件带 node shebang（否则装完执行会失败）`,
      /^#!.*\bnode\b/.test(head), `第一行是 ${JSON.stringify(head)}`);
  }
}

// ── 2. main / files：写进清单的都要真的存在 ──────────────────────────
console.log('\nmain / files');
if (pkg.main) {
  check(`main 指向的文件存在：${pkg.main}`, fs.existsSync(path.join(ROOT, pkg.main)), pkg.main);
}
for (const f of pkg.files || []) {
  const rel = f.replace(/\/$/, '');
  check(`files 里的 ${f} 存在`, fs.existsSync(path.join(ROOT, rel)), rel);
}

// ── 3. repository：写错就是把人送到 404 ──────────────────────────────
console.log('\nrepository');
const repoUrl = (pkg.repository && (pkg.repository.url || pkg.repository)) || '';
const m = String(repoUrl).match(/github\.com[/:]([^/]+)\/([^/.]+)/);
check('repository.url 是正常的 GitHub 地址', !!m, repoUrl);
if (m) {
  const remote = spawnSync('git', ['-C', ROOT, 'remote', 'get-url', 'origin'], { encoding: 'utf8' });
  const remoteUrl = (remote.stdout || '').trim();
  if (remoteUrl) {
    const rm = remoteUrl.match(/github\.com[/:]([^/]+)\/([^/.]+)/);
    check('repository.url 和 git 远端是同一个仓库（写错会把人送到 404）',
      !!rm && rm[1] === m[1] && rm[2] === m[2],
      `package.json=${repoUrl} · origin=${remoteUrl}`);
  } else {
    skip('repository.url 与 git 远端一致', '当前仓库没有配 origin');
  }
}

// ── 4. engines ──────────────────────────────────────────────────────
console.log('\nengines');
check('声明了 engines.node（用 node:sqlite 需要 >=22.5）', !!(pkg.engines && pkg.engines.node),
  JSON.stringify(pkg.engines));

// ── 5. 真跑一次 npm publish --dry-run ────────────────────────────────
//
// 前面几条是「我对 npm 行为的理解」。这一条是 npm 的实际行为。
// 只有它能证明「npm 不会偷偷改掉我要发的东西」。
console.log('\nnpm（实际行为）');
const npmOk = spawnSync('npm', ['--version'], { encoding: 'utf8' }).status === 0;

if (!npmOk) {
  skip('npm publish --dry-run 不产生 auto-corrected',
    '本机上没有 npm。这一条是名单里**唯一能证明 npm 实际行为**的检查，' +
    '跳过它意味着「只有静态规则在守」——CI 上有 npm，那道门还在。');
  skip('npm pack 的产物里含有 bin 目标与所有 files 条目',
    '本机上没有 npm。');
} else {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lv-pkg-'));
  const userconfig = path.join(tmp, 'npmrc');
  fs.writeFileSync(userconfig, 'registry=https://registry.npmjs.org/\n');
  const env = {
    ...process.env,
    NPM_CONFIG_USERCONFIG: userconfig,
    NODE_AUTH_TOKEN: 'dry-run-placeholder',
    npm_config_audit: 'false',
    npm_config_fund: 'false',
  };

  // 用 --json 拿结构化结果，别去正则解析人看的输出。
  const pack = spawnSync('npm', ['pack', '--dry-run', '--json'], { cwd: ROOT, encoding: 'utf8', env });
  let files = null;
  if (pack.status === 0) {
    try {
      const start = pack.stdout.indexOf('[');
      files = JSON.parse(pack.stdout.slice(start))[0].files.map((f) => f.path);
    } catch { /* 落到下面的失败分支 */ }
  }
  check('npm pack --dry-run --json 能解析出文件清单', Array.isArray(files),
    (pack.stderr || pack.stdout || '').slice(0, 300));

  if (Array.isArray(files)) {
    for (const [name, target] of bins) {
      // npm 的 bin 条目在包里就是那个文件本身
      check(`打出来的包里含有 bin 目标 ${target}`, files.includes(target), files.join(', '));
      void name;
    }
    for (const f of pkg.files || []) {
      if (f.endsWith('/')) {
        const prefix = f.slice(0, -1) + '/';
        check(`包里含有 ${f} 下的文件`, files.some((p) => p.startsWith(prefix)),
          files.filter((p) => p.startsWith(prefix)).slice(0, 3).join(', ') || '（一个都没有）');
      } else {
        check(`包里含有 ${f}`, files.includes(f), files.join(', '));
      }
    }
  }

  const pub = spawnSync('npm', ['publish', '--dry-run', '--access', 'public'],
    { cwd: ROOT, encoding: 'utf8', env });
  const out = (pub.stdout || '') + (pub.stderr || '');
  // 只找「npm 自己改了清单」这一类。登录提示是正常的，不算。
  check('npm publish --dry-run 没有 auto-corrected（它改过的东西不会告诉你要不要）',
    !/auto-corrected|was invalid and removed/i.test(out),
    out.split('\n').filter((l) => /warn publish|error/i.test(l)).slice(0, 6).join('\n'));

  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n通过 ${passed} · 失败 ${failed}${skipped ? ` · 跳过 ${skipped}（跳过不等于通过）` : ''}`);
process.exit(failed === 0 ? 0 : 1);
