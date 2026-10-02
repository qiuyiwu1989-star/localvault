#!/usr/bin/env node
'use strict';

/**
 * 「没有配置 Token 时，任何命令都不发网络请求」的验证。
 *
 *   node test/no-network.js
 *
 * ## 为什么需要这个测试
 *
 * 「不上传」是这个工具产品主张里最重的一句：用户的文件正文进本地 SQLite，
 * 唯一的出口是上游对接（`lib/upstream/`），而它默认是关着的。
 *
 * 这类主张没有断言守着就会烂掉：某天有人在 `bridge.push()` 外面少写一道
 * `hasToken()` 判断，症状不是报错，而是「装完就静默往外发」——
 * 装的人不会发现，写的人也不会发现，因为没有任何东西是红的。
 *
 * ## 为什么必须在**同一个进程**里跑命令
 *
 * 计数器只有和被测代码同进程才有意义。若命令是 `spawnSync` 出去的子进程，
 * 父进程的计数器永远是 0 —— 那条「没有网络请求」的断言就退化成恒真，
 * 正好是本项目明令禁止的那种断言（见 `scripts/check-assertions.py`）。
 * 所以这里用 `cli.js` 导出的 `COMMANDS` 直接调用，并把 stdout/stderr 临时接管。
 *
 * ## 0 必须是「证明过的 0」，不是「什么都没做的 0」
 *
 * 光断言计数为 0 还不够，有三种坏代码能让它假绿：
 *   1. 上游客户端不再走 `globalThis.fetch`，改用 `node:https` 直连 —— 守卫看不见；
 *   2. `push` 之所以没发请求，是因为队列本来就是空的；
 *   3. 环境里本来就有 `LOCALVAULT_MEMORY_TOKEN`，命令走了别的分支。
 * 所以下面有三组正对照：直连客户端类（证明守卫会记账）、配上假 Token 跑
 * `upstream push`（证明「有 Token 就会发」，且这条路真的经过 `globalThis.fetch`）、
 * 以及断言 `plan` 确实看到了 ≥1 条可提交资料。三者都通过之后，
 * 无 Token 时的 0 才是有内容的 0。
 *
 * 全部在临时目录里跑：HOME / CFFIXED_USER_HOME / LOCALVAULT_DATA_DIR 都指向自建临时目录，
 * 结束时还会校验真实 `~/.localvault` 的 mtime 没变。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');

/* ------------------------------------------------------------------ *
 * 网络守卫：一碰就炸，并且记账
 *
 * 做法照抄 `test/upstream.js`：不靠「记得传 fetch」，而是让错的那条路走不通。
 * 区别是那个测试关心「payload 内容」，这个测试关心「有没有发出去」，
 * 所以守卫抛错之后还要留在原地被计数。
 * ------------------------------------------------------------------ */
const REAL_FETCH = globalThis.fetch;
const networkAttempts = [];
globalThis.fetch = async (url) => {
  networkAttempts.push(String(url));
  throw new Error(
    `测试禁止真实网络请求，但有人请求了 ${url}。\n` +
    '  这条命令本该在「凭据未配置」处早退，却走到了发请求这一步。'
  );
};

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}${detail ? ' —— ' + detail : ''}`); }
}
function section(t) { console.log(`\n${t}`); }

/** 接管 stdout/stderr 跑一段被测代码，返回退出码与全部输出。 */
async function capture(fn) {
  const out = [];
  const err = [];
  const realOut = process.stdout.write;
  const realErr = process.stderr.write;
  process.stdout.write = (chunk) => { out.push(String(chunk)); return true; };
  process.stderr.write = (chunk) => { err.push(String(chunk)); return true; };
  let code = null;
  let threw = null;
  try {
    code = await fn();
  } catch (e) {
    threw = e;
  } finally {
    process.stdout.write = realOut;
    process.stderr.write = realErr;
  }
  return { code, threw, stdout: out.join(''), stderr: err.join('') };
}

function statOrNull(p) {
  try { return fs.statSync(p).mtimeMs; } catch { return null; }
}

async function main() {
  /* ---------------- 临时世界 ---------------- */
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'lv-nonet-'));
  const home = path.join(base, 'home');
  const data = path.join(base, 'data');
  const tree = path.join(home, 'Desktop');
  fs.mkdirSync(tree, { recursive: true });
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(tree, '笔记.md'), '# 一条会被索引的笔记\n\n正文标记：本机内容。\n', 'utf8');

  // 真实主目录：`os.userInfo()` 读的是 passwd，不受 HOME 影响，所以它才是「真的那个」。
  let realHome = null;
  try { realHome = os.userInfo().homedir; } catch { realHome = null; }
  const realVaultMtimeBefore = realHome ? statOrNull(path.join(realHome, '.localvault')) : null;

  process.env.HOME = home;
  process.env.CFFIXED_USER_HOME = home;      // macOS 上部分消费方认这个，不认 HOME
  process.env.LOCALVAULT_DATA_DIR = data;
  delete process.env.LOCALVAULT_CONFIG;
  delete process.env.LOCALVAULT_ROOTS;
  delete process.env.LOCALVAULT_QUIET;
  delete process.env.LOCALVAULT_MEMORY_ENDPOINT;
  // 上游客户端的 Token 只从环境读；环境里留着一个真 Token 会让这个测试失去意义。
  delete process.env.LOCALVAULT_MEMORY_TOKEN;

  console.log('不配 Token 时的网络请求（全部在临时目录，假 HOME）');

  const { COMMANDS } = require(path.join(ROOT, 'cli.js'));

  /* ---------------- 前提 ---------------- */
  section('前提：环境干净、确有东西可发');
  check('测试进程里 LOCALVAULT_MEMORY_TOKEN 确实不存在',
    process.env.LOCALVAULT_MEMORY_TOKEN === undefined,
    `实际 ${process.env.LOCALVAULT_MEMORY_TOKEN === undefined ? '未设置' : '已设置'}`);
  check('索引数据目录指向自建临时目录，不是 ~/.localvault',
    path.resolve(data).startsWith(path.resolve(base)),
    data);

  /* ---------------- 建 fixture：init → 写文件 → index ---------------- */
  const init = await capture(() => COMMANDS.init({ positional: [tree], flags: {} }));
  check('init 退出码 0', init.code === 0, init.stderr.slice(0, 200));
  const index = await capture(() => COMMANDS.index({ positional: [], flags: {} }));
  check('index 退出码 0', index.code === 0, index.stderr.slice(0, 200));

  // 先跑一次 init-manifest 生成骨架（它不需要清单，是唯一一个不用 ctx 的子命令）
  const initManifest = await capture(() => COMMANDS.upstream({ positional: ['init-manifest'], flags: { force: true } }));
  check('upstream init-manifest 退出码 0', initManifest.code === 0, initManifest.stderr.slice(0, 200));

  // 再把骨架换成一份真清单：有内容可发，后面的「零请求」才有对象
  const manifestFile = path.join(data, 'upstream-manifest.json');
  fs.writeFileSync(manifestFile, JSON.stringify({
    scope: 'agent:localvault-inbox',
    instance: 'no-network-test',
    sources: [{ path: '笔记.md', role: 'user', original_date: '2026-10-03' }],
  }, null, 2) + '\n', 'utf8');

  /* ---------------- 正对照 1：客户端类直连 ---------------- */
  section('正对照 1：守卫真的会记账（否则后面的 0 是空断言）');
  {
    const { MemoryCenterClient } = require(path.join(ROOT, 'lib', 'upstream', 'client.js'));
    const before = networkAttempts.length;
    // 刻意不传 opts.fetch：走的就是生产环境那条 `globalThis.fetch` 默认路径
    const client = new MemoryCenterClient({ endpoint: 'http://no-network.invalid/mcp', token: 'fake', maxRetries: 0 });
    let threw = null;
    try {
      await client.importArchive({
        scope: 'agent:localvault-inbox', source_key: 'k', processing_policy: 'archive',
        source_type: 'document', messages: [{ id: 'p1', role: 'user', text: 'x' }],
      });
    } catch (e) { threw = e; }
    const hits = networkAttempts.length - before;
    check('客户端的默认路径被守卫拦下并计数',
      hits === 1 && threw !== null,
      `计数 ${hits}，抛错 ${threw ? threw.kind : '无'}`);
  }

  /* ---------------- 正对照 2：配上 Token 的 CLI 真的会发 ---------------- *
   * 这一步会走客户端的有界退避（约 4 秒），是有意付的成本：
   * 它证明「无 Token 时零请求」的原因是凭据判断，而不是「队列空」或
   * 「CLI 那条路根本不经过 globalThis.fetch」。
   * ------------------------------------------------------------------ */
  section('正对照 2：配上假 Token 后，upstream push 会去请求（被守卫拦下）');
  let tokenPush = null;
  {
    process.env.LOCALVAULT_MEMORY_TOKEN = 'fake-token-control';
    const before = networkAttempts.length;
    tokenPush = await capture(() => COMMANDS.upstream({ positional: ['push'], flags: {} }));
    delete process.env.LOCALVAULT_MEMORY_TOKEN;
    check('配了 Token 的 CLI push 触发了请求尝试',
      networkAttempts.length > before && tokenPush.code === 1,
      `计数 ${networkAttempts.length - before}，退出码 ${tokenPush.code}`);
    check('守卫在位：没有谁把它还原成真 fetch', globalThis.fetch !== REAL_FETCH);
  }

  /* ---------------- 被测部分：无 Token，逐条命令 ---------------- */
  section('无 Token：逐条跑命令');
  // 正对照已经证明守卫会记账，从这里开始只数被测命令的账。
  networkAttempts.length = 0;

  const invoke = (argv) => {
    const [cmd, ...rest] = argv;
    return COMMANDS[cmd]({ positional: rest, flags: {} });
  };
  const cases = [
    ['index', ['index'], 0],
    ['map', ['map'], 0],
    ['doctor', ['doctor'], 0],
    ['upstream doctor', ['upstream', 'doctor'], 0],
    ['upstream plan', ['upstream', 'plan'], 0],
    ['upstream push', ['upstream', 'push'], 1],        // 凭据未配置：早退，退出码 1
    ['upstream status', ['upstream', 'status'], 0],
    ['upstream compensate', ['upstream', 'compensate'], 1],
    ['upstream tombstone', ['upstream', 'tombstone'], 0],
    ['upstream manifest', ['upstream', 'manifest'], 0],
  ];
  const byLabel = {};
  for (const [label, argv, want] of cases) {
    const r = await capture(() => invoke(argv));
    byLabel[label] = r;
    check(`${label} 退出码 ${want}`, r.code === want,
      `实际 ${r.code}${r.threw ? `，抛错 ${r.threw.message}` : ''}`);
  }

  /* ---------------- 输出层的证据 ---------------- */
  section('输出层的证据（命令确实跑到了「凭据未配置」这一步）');
  check('upstream doctor 报「凭据：未配置」',
    byLabel['upstream doctor'].stdout.includes('凭据：未配置'),
    byLabel['upstream doctor'].stdout.split('\n').filter((l) => /凭据/.test(l)).join(' | '));
  check('upstream plan 看到了 ≥1 条可提交资料（所以零请求不是因为没东西可发）',
    Number((/可提交：(\d+) 条资料/.exec(byLabel['upstream plan'].stdout) || [])[1]) >= 1,
    (byLabel['upstream plan'].stdout.split('\n').find((l) => /可提交/.test(l)) || '没找到「可提交」那一行'));
  check('upstream push 明说本轮没有发出任何请求',
    /没有发出任何请求/.test(byLabel['upstream push'].stderr),
    byLabel['upstream push'].stderr.slice(0, 200));
  check('upstream compensate 同样在凭据处早退（另一个会发请求的分支）',
    /没有发出任何请求/.test(byLabel['upstream compensate'].stderr),
    byLabel['upstream compensate'].stderr.slice(0, 200));
  check('map 有实际输出（命令没被静默跳过）',
    byLabel['map'].stdout.includes('# ') && byLabel['map'].stdout.length > 200,
    `${byLabel['map'].stdout.length} 字节`);

  /* ---------------- 最终断言 ---------------- */
  section('最终断言');
  check('上述 10 条命令跑完，globalThis.fetch 一次都没有被调用',
    networkAttempts.length === 0,
    networkAttempts.length ? `实际 ${networkAttempts.length} 次：${networkAttempts.slice(0, 3).join('、')}` : '');
  check('整个测试期间没有任何请求指向生产端点',
    !networkAttempts.some((u) => u.includes('qiuyiwu.com')),
    networkAttempts.join('、'));

  if (realHome) {
    const before = realVaultMtimeBefore;
    const after = statOrNull(path.join(realHome, '.localvault'));
    check('真实 ~/.localvault 的 mtime 没有被这个测试改动',
      before === after,
      `${before} → ${after}（${path.join(realHome, '.localvault')}）`);
  } else {
    console.log('  ! 读不到真实主目录（os.userInfo 失败），这项隔离检查没做');
  }

  console.log(`\n通过 ${passed} · 失败 ${failed}`);
  if (failed > 0) {
    console.log(`没配 Token 时仍有网络请求，或某条命令的行为变了。临时目录保留：${base}`);
    process.exitCode = 1;
  } else {
    console.log('没配 Token 时零网络请求 —— 由正对照证明过的 0。');
    fs.rmSync(base, { recursive: true, force: true });
    process.exitCode = 0;
  }
  globalThis.fetch = REAL_FETCH;
}

main().catch((e) => {
  console.error('\n测试崩了：', (e && e.stack) || e);
  process.exitCode = 1;
});
