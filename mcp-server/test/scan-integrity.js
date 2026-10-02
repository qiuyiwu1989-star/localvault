#!/usr/bin/env node
'use strict';
/**
 * 增量扫描的两件事：**计数是真的**，**并发不会崩**。
 *
 * 两条都是从阶段 2.4 的验收里查出来的，共同点是「看起来很正常」：
 *
 * 1. `scan_runs.files_added` 与 `files_updated` 被赋成**同一个值**
 *    （`filesAdded: extracted, filesUpdated: extracted`）。
 *    于是报告里永远写着「新增 22000、更新 22000」。
 *    它不是错的，是**没实现** —— 而它看起来完全是一份统计。
 *    「占位符长得像数据」比缺一个字段更坏：缺字段会被发现，占位符不会。
 *
 * 2. 并发跑 `cli.js index` 会以 `Error: database is locked` 栈回溯退出。
 *    App 侧**一直**有 `busy_timeout`（`VaultIndexer.swift:158`，
 *    那里的注释还写着「busy_timeout 是这里加的」）—— 已知问题，只是没补到 CLI。
 *
 * 守这条的价值在于：这两个数会被人（和 agent）当成事实引用。一个恒等的计数器
 * 不会被任何人当成 bug，只会被当成「这台机器上更新很频繁」。
 *
 * 跑法：node test/scan-integrity.js
 */

const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const CLI = path.join(ROOT, 'cli.js');

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  ✓ ${name}${detail ? '  — ' + detail : ''}`); }
  else { fail++; console.log(`  ✗ ${name}${detail ? '  — ' + detail : ''}`); }
}

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'lvscan-'));
const dbPath = path.join(HOME, '.localvault', 'vault.db');

function env() {
  return { ...process.env, HOME, CFFIXED_USER_HOME: HOME };
}
function cli(args) {
  return spawnSync(process.execPath, [CLI, ...args], { env: env(), encoding: 'utf8' });
}
function lastScan() {
  const r = spawnSync(process.execPath, ['-e', `
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(process.argv[1], { readOnly: true });
    const row = db.prepare('SELECT files_seen, files_added, files_updated, files_removed, ok FROM scan_runs ORDER BY id DESC LIMIT 1').get();
    process.stdout.write(JSON.stringify(row || {}));
  `, dbPath], { env: env(), encoding: 'utf8' });
  try { return JSON.parse(r.stdout); } catch { return {}; }
}

(async () => {
  fs.mkdirSync(path.join(HOME, 'Desktop'), { recursive: true });
  for (let i = 1; i <= 5; i++) fs.writeFileSync(path.join(HOME, 'Desktop', `f${i}.md`), `文件 ${i} 的内容\n`);

  console.log('增量扫描的计数与并发');
  console.log('');

  const i0 = cli(['init']);
  const i1 = cli(['index']);
  if (i0.status !== 0 || i1.status !== 0) {
    console.log(`  ✗ 夹具建不起来：init=${i0.status} index=${i1.status}`);
    console.log((i0.stderr || '') + (i1.stderr || ''));
    process.exit(1);
  }

  // ── 1. 首次扫描：全是新增，零更新 ─────────────────────────────
  {
    const s = lastScan();
    check('首次扫描：5 个全是新增', s.files_added === 5 && s.files_updated === 0,
      `files_seen=${s.files_seen} added=${s.files_added} updated=${s.files_updated}`);
  }

  // ── 2. 改 2 个、加 1 个：三个数必须各不相同 ───────────────────
  //
  // 这一条是核心回归。修之前 `files_added` 和 `files_updated` 恒等，
  // 所以「两者相等」就是缺陷的特征 —— 断言直接盯这个。
  {
    fs.writeFileSync(path.join(HOME, 'Desktop', 'f1.md'), '改过的内容\n');
    fs.writeFileSync(path.join(HOME, 'Desktop', 'f2.md'), '改过的内容\n');
    fs.writeFileSync(path.join(HOME, 'Desktop', 'f6.md'), '全新的文件\n');
    cli(['index']);
    const s = lastScan();
    check('改 2 个 + 加 1 个：新增数正确', s.files_added === 1, `added=${s.files_added}（期望 1）`);
    check('   —— 更新数正确', s.files_updated === 2, `updated=${s.files_updated}（期望 2）`);
    check('   —— **两个数不再恒等**（修前它们永远相等）',
      s.files_added !== s.files_updated,
      `added=${s.files_added} updated=${s.files_updated}；修前两者都等于「本轮抽取数」`);
    check('   —— 本轮一共 6 个文件被看到',
      s.files_seen === 6, `files_seen=${s.files_seen}`);
  }

  // ── 3. 开库会等锁，不会立刻崩 ───────────────────────────────
  //
  // 这一条原来我写成「起 5 个并发 index，看谁报锁错」—— **那是个假绿**：
  // 把修复倒回去，它照样全绿。原因是夹具里的库**已经是 WAL** 了，
  // 而 `PRAGMA journal_mode = WAL` 对已经是 WAL 的库是空操作，不需要锁。
  //
  // 真正会崩的是「库还不是 WAL、且有人持锁」的时候。所以这里改成
  // **确定性地制造那个状态**：另一个进程建库（默认 journal 模式，不是 WAL）
  // 并持有一把排他锁，然后看本进程开库会不会等。
  //
  // 已用反证确认过这一条真的能红：
  //   正确顺序 → 等 2436ms 后成功
  //   倒回「先 WAL 后 timeout」→ 1ms 内 database is locked
  {
    const lockDb = path.join(HOME, 'locktest.db');
    const holder = spawn(process.execPath, ['-e', `
      const { DatabaseSync } = require('node:sqlite');
      const db = new DatabaseSync(process.argv[1]);
      db.exec('CREATE TABLE IF NOT EXISTS t(x)');
      db.exec('BEGIN EXCLUSIVE');          // 默认 journal 模式：不是 WAL
      process.stdout.write('LOCKED\\n');   // 拿到锁了才喊
      setTimeout(() => { try { db.exec('COMMIT'); } catch {} process.exit(0); }, 2000);
    `, lockDb], { env: env() });

    await new Promise((res) => {
      let buf = '';
      const onData = (d) => { buf += d; if (buf.includes('LOCKED')) res(); };
      holder.stdout.on('data', onData);
      setTimeout(res, 4000);               // 兜底，别挂死
    });

    const { openDatabase } = require('../lib/store.js');
    const t0 = Date.now();
    let opened = null;
    let err = null;
    try { opened = openDatabase(lockDb); } catch (e) { err = e; }
    const waited = Date.now() - t0;

    check('持锁时开库会**等**，而不是立刻报 database is locked',
      !err && Boolean(opened), err ? String(err.message).slice(0, 60) : `等了 ${waited}ms`);
    check('   —— 确实是等出来的（不是碰巧没锁上）', waited >= 500, `等了 ${waited}ms`);
    if (opened) {
      const bt = opened.prepare('PRAGMA busy_timeout').get();
      check('   —— busy_timeout 生效且为 5000（与 App 侧一致）',
        Number(bt.timeout) === 5000, `busy_timeout=${bt.timeout}`);
      const jm = opened.prepare('PRAGMA journal_mode').get();
      check('   —— 最后还是切成了 WAL', String(jm.journal_mode).toLowerCase() === 'wal',
        `journal_mode=${jm.journal_mode}`);
    }
    try { holder.kill(); } catch {}
  }

  console.log(`\n通过 ${pass} · 失败 ${fail}`);
  fs.rmSync(HOME, { recursive: true, force: true });
  process.exit(fail === 0 ? 0 : 1);
})();
