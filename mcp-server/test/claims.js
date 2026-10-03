#!/usr/bin/env node
'use strict';
/**
 * 判断记忆（条陈）的读侧测试。
 *
 * ## 这个测试要守住什么
 *
 * 「已经签过的判断，agent 读得出来」——这句话很容易被写成一个**看起来对**的功能，
 * 所以下面每一条都尽量做到**能被证伪**：
 *
 * 1. **表结构与 App 逐字一致。**
 *    写这个库的是 Swift，读它的是 JS。两边各写一份 DDL 就一定会飘。
 *    这里直接把 `ClaimStore.swift` 里的 DDL 原文抠出来，跟 JS 的逐列对比。
 *    Swift 那边改一列、这边没跟着改 → 立刻红。
 *
 * 2. **投影的 `seen` 那一步不能省。**
 *    撤回过的目标必须**彻底消失**，不能露出更旧的那条判断。
 *    少了 `seen` 就会露 —— 这是这个功能最阴的一个 bug：
 *    它只在「先签 → 再撤回」的序列上出现，随手测测不出来。
 *
 * 3. **同一秒内的新旧。** `ts` 只到秒，连点两下就是同一秒。
 *    只按 `ts` 排序时，同秒内的顺序由 SQLite 决定，于是投影可能取到旧的那条。
 *    必须靠 `id DESC` 兜底。这条测试就是造两条同 `ts` 的记录。
 *
 * 4. **只追加是数据库层的事。** 直接对库里发 `UPDATE` / `DELETE`，必须失败。
 *    不是「我们的代码没写 UPDATE」——那是自律；触发器是约束。
 *
 * 5. **读不写。** 读一遍判断记忆之后，库文件的哈希必须一模一样。
 *    顺手加一条：库不存在时，读**不能凭空造**一个出来
 *    （否则「还没签过」和「判断被清空了」看起来会一样）。
 *
 * 全程在**假 HOME** 里跑，绝不碰真的 `~/.localvault/claims.db`。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync, spawn } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const SERVER = path.join(ROOT, 'server.js');
const SWIFT = path.join(ROOT, '..', 'app', 'Sources', 'LocalVault', 'ClaimStore.swift');

let passed = 0;
let failed = 0;
let skipped = 0;

function check(name, ok, detail = '') {
  if (ok) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    console.log(`  ✗ ${name}`);
    if (detail) console.log(`      ${String(detail).split('\n').join('\n      ')}`);
  }
}
function skip(name, why) {
  skipped++;
  console.log(`  ⊘ 跳过 ${name} —— ${why}`);
}

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'lvclaims-'));
const DATA = path.join(HOME, '.localvault');
fs.mkdirSync(DATA, { recursive: true });

const C = require(path.join(ROOT, 'lib', 'claims.js'));
const cfg = { dataDir: DATA, dataDirAbs: DATA, dbPath: path.join(DATA, 'vault.db') };

function sha(p) {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

/* ── 1. 表结构与 App 逐字一致 ─────────────────────────────────────── */
console.log('\n── 1. 表结构与 App（Swift）逐字一致 ──');

function normaliseColumns(ddl) {
  const m = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?claims\s*\(([\s\S]*?)\n\s*\);/i.exec(ddl);
  if (!m) return null;
  return m[1]
    .split('\n')
    .map((l) => l.trim().replace(/\s+/g, ' '))
    .filter((l) => l && !l.startsWith('--'))
    .map((l) => l.replace(/,$/, ''))
    .filter(Boolean)
    .join('\n');
}

if (!fs.existsSync(SWIFT)) {
  skip('Swift 的 DDL 原文', `没找到 ${SWIFT}`);
} else {
  const swift = fs.readFileSync(SWIFT, 'utf8');
  const swiftCols = normaliseColumns(swift);
  const jsCols = normaliseColumns(C.CLAIMS_SCHEMA);
  check('能从 ClaimStore.swift 里抠出 claims 表定义', Boolean(swiftCols),
    '没匹配到 CREATE TABLE claims(...) —— Swift 那边的写法变了？');
  check('能从 lib/claims.js 里抠出 claims 表定义', Boolean(jsCols));
  if (swiftCols && jsCols) {
    const a = swiftCols.split('\n');
    const b = jsCols.split('\n');
    check(`两边列定义逐行一致（${a.length} 列 vs ${b.length} 列）`, a.length === b.length && a.every((x, i) => x === b[i]),
      a.map((x, i) => (x === b[i] ? null : `Swift: ${x}\n  JS : ${b[i] ?? '（缺）'}`)).filter(Boolean).join('\n'));
  }
  // 两个不变量必须在 schema 里就是硬的，不是靠调用方自觉。
  const jsDdl = C.CLAIMS_SCHEMA;
  check('signed_by 是 NOT NULL', /signed_by\s+TEXT\s+NOT NULL/i.test(jsDdl));
  check('actor_type 是 NOT NULL 且限定 human/machine',
    /actor_type\s+TEXT\s+NOT NULL\s+CHECK\(\s*actor_type\s+IN\s*\(\s*'human'\s*,\s*'machine'\s*\)/i.test(jsDdl),
    jsDdl.split('\n').filter((l) => l.includes('actor_type')).join('\n'));
  check('authority 限定 L0/L1/L2', /authority\s+TEXT\s+NOT NULL\s+CHECK\(authority\s+IN\s*\('L0','L1','L2'\)\)/i.test(jsDdl));
  check('source_ref / holder / target 都是 NOT NULL',
    /source_ref\s+TEXT\s+NOT NULL/i.test(jsDdl) && /holder\s+TEXT\s+NOT NULL/i.test(jsDdl) && /target\s+TEXT\s+NOT NULL/i.test(jsDdl));
}

/* ── 2. 建库并验「只追加」 ─────────────────────────────────────────── */
console.log('\n── 2. 只追加：数据库层拒绝 UPDATE / DELETE ──');

const opened = C.openClaims(cfg, { create: true });
check('能打开（并建好）判断记忆库', opened.ok, opened.reason || '');
const db = opened.db;
const dbPath = C.claimsDbPath(cfg);

if (!opened.ok) {
  console.log(`\n通过 ${passed} · 失败 ${failed}`);
  process.exit(1);
}

const w = C.appendClaim(db, {
  kind: 'judgment', targetType: 'file', target: '/tmp/a.md',
  verdict: '保留', note: '别删', sourceRef: 'vault://file//tmp/a.md',
  holder: '邱懿武', signedBy: '邱懿武', actorType: 'human', authority: 'L1', ts: 1000,
});
check('能追加一条人签判断', w.ok, w.reason || '');

let updateErr = null;
try { db.exec("UPDATE claims SET verdict='可清理' WHERE target='/tmp/a.md'"); } catch (e) { updateErr = e; }
check('UPDATE 被拒绝（不变量 II）', Boolean(updateErr), updateErr ? '' : 'UPDATE 竟然成功了 —— 触发器没装上');

let deleteErr = null;
try { db.exec("DELETE FROM claims WHERE target='/tmp/a.md'"); } catch (e) { deleteErr = e; }
check('DELETE 被拒绝（不变量 II）', Boolean(deleteErr), deleteErr ? '' : 'DELETE 竟然成功了 —— 触发器没装上');

check('被拒之后那条记录还在', C.listClaims(db, {}).total === 1);

/* ── 3. 不变量 I：机器只能写 L0 ────────────────────────────────────── */
console.log('\n── 3. 不变量 I：机器与人一眼可分 ──');

const m1 = C.appendClaim(db, {
  kind: 'material', targetType: 'file', target: '/tmp/b.md', verdict: null, note: '机器备注',
  sourceRef: 'vault://file//tmp/b.md', holder: C.MACHINE_POLICY,
  signedBy: C.MACHINE_POLICY, actorType: 'machine', authority: 'L1',
});
check('机器写 L1 被拒', !m1.ok, JSON.stringify(m1));
check('被拒的原因说的是不变量 I', !m1.ok && /不变量 I/.test(m1.reason), m1.reason);

const m2 = C.appendClaim(db, {
  kind: 'judgment', targetType: 'file', target: '/tmp/b.md', verdict: '保留', note: '',
  sourceRef: 'vault://file//tmp/b.md', holder: C.MACHINE_POLICY,
  signedBy: C.MACHINE_POLICY, actorType: 'machine', authority: 'L0',
});
check('机器签判断（verdict）被拒', !m2.ok, JSON.stringify(m2));

const m3 = C.appendClaim(db, {
  kind: 'material', targetType: 'file', target: '/tmp/c.md', verdict: null, note: 'x',
  sourceRef: 'vault://file//tmp/c.md', holder: C.MACHINE_POLICY,
  signedBy: '   ', actorType: 'machine', authority: 'L0',
});
check('signed_by 只有空格被拒（NOT NULL 挡不住空串）', !m3.ok, JSON.stringify(m3));

const good = C.annotate(db, { target: '/tmp/d.md', note: '这条能写进去' });
check('annotate 能写机器条陈', good.ok, good.reason || '');
const annotated = C.listClaims(db, { target: '/tmp/d.md' }).rows[0];
check('它挂的是策略名而不是人名', annotated && annotated.signedBy === C.MACHINE_POLICY && annotated.actorType === 'machine');
check('它是 L0 待签', annotated && annotated.authority === 'L0');

/* ── 4. 投影：撤回必须彻底 ─────────────────────────────────────────── */
console.log('\n── 4. 投影：撤回之后不能露出更旧的那条 ──');

const rows = [
  // 已按 ts DESC, id DESC 排好（跟 SQL 的 ORDER BY 一样）
  { target: '/x', verdict: '撤回', ts: 300, id: 3 },
  { target: '/x', verdict: '保留', ts: 200, id: 2 },   // ← 更旧的那条，不许露出来
  { target: '/y', verdict: '待看', ts: 150, id: 1 },
];
const proj = C.projectCurrent(rows);
check('撤回过的目标不在当前状态里', !proj.has('/x'),
  proj.has('/x') ? `竟然还在：${JSON.stringify(proj.get('/x'))}` : '');
check('没撤回的目标正常保留', proj.get('/y') && proj.get('/y').verdict === '待看');

// 反向证明：把 `seen` 那一步去掉会怎样。模拟一个「没有 seen」的错误实现。
function projectWithoutSeen(rs) {
  const p = new Map();
  for (const c of rs) { if (c.verdict !== C.RETRACTED) p.set(c.target, c); }
  return p;
}
check('（反向证明）去掉 seen 的错误实现确实会露出旧判断',
  projectWithoutSeen(rows).get('/x') && projectWithoutSeen(rows).get('/x').verdict === '保留',
  '如果这条不成立，说明我造的反例没造对，上面那条「撤回成功」就成了空话');

/* ── 5. 同一秒内的新旧 ─────────────────────────────────────────────── */
console.log('\n── 5. 同一秒内连签两条，取的是新的那条 ──');

const sameSec = 5000;
C.appendClaim(db, {
  kind: 'judgment', targetType: 'file', target: '/tmp/same.md', verdict: '待看', note: '第一条',
  sourceRef: 'vault://file//tmp/same.md', holder: '邱懿武', signedBy: '邱懿武',
  actorType: 'human', authority: 'L1', ts: sameSec,
});
C.appendClaim(db, {
  kind: 'judgment', targetType: 'file', target: '/tmp/same.md', verdict: '保留', note: '第二条（同一秒）',
  sourceRef: 'vault://file//tmp/same.md', holder: '邱懿武', signedBy: '邱懿武',
  actorType: 'human', authority: 'L1', ts: sameSec,
});
const sameRows = C.listClaims(db, { target: '/tmp/same.md' }).rows;
check('同一秒的两条都被存下来了（不是覆盖）', sameRows.length === 2, `实际 ${sameRows.length} 条`);
check('排序里 id 大的在前（靠 id DESC 兜底，不能只靠 ts）',
  sameRows[0].id > sameRows[1].id, sameRows.map((r) => `${r.id}@${r.ts}`).join(' , '));
const sameProj = C.projectCurrent(sameRows);
check('投影取到的是后签的那条（保留）', sameProj.get('/tmp/same.md').verdict === '保留',
  `取到了 ${sameProj.get('/tmp/same.md').verdict}`);

/* ── 6. 读不写 ─────────────────────────────────────────────────────── */
console.log('\n── 6. 读不写：读一遍判断记忆，库文件一个字节都不该变 ──');

const before = sha(dbPath);
const ro = C.openClaims(cfg, { readOnly: true });
check('能以只读方式打开', ro.ok, ro.reason || '');
if (ro.ok) {
  C.summary(ro.db);
  C.listClaims(ro.db, { limit: 100 });
  ro.db.close();
}
const after = sha(dbPath);
check('读完之后哈希不变', before === after, `${before.slice(0, 12)} → ${after.slice(0, 12)}`);

check('只读打开时 UPDATE 也会失败', (() => {
  const r = C.openClaims(cfg, { readOnly: true });
  if (!r.ok) return false;
  let threw = false;
  try { r.db.exec("UPDATE claims SET note='tampered'"); } catch { threw = true; }
  r.db.close();
  return threw;
})());

db.close();

/* ── 7. 库不存在时不凭空造 ─────────────────────────────────────────── */
console.log('\n── 7. 还没签过任何判断时，读不能凭空造库 ──');

const EMPTY_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'lvclaims-empty-'));
const emptyCfg = {
  dataDir: path.join(EMPTY_HOME, '.localvault'),
  dataDirAbs: path.join(EMPTY_HOME, '.localvault'),
  dbPath: path.join(EMPTY_HOME, '.localvault', 'vault.db'),
};
check('claimsExists 说不存在', C.claimsExists(emptyCfg) === false);
const missing = C.openClaims(emptyCfg, { readOnly: true });
check('只读打开一个不存在的库 → 明确说不行', !missing.ok && /不存在/.test(missing.reason), missing.reason || '');
check('读完之后仍然没有造出 claims.db', !fs.existsSync(C.claimsDbPath(emptyCfg)),
  `竟然造出来了：${C.claimsDbPath(emptyCfg)}`);
fs.rmSync(EMPTY_HOME, { recursive: true, force: true });

/* ── 8. MCP 工具真的接上了 ─────────────────────────────────────────── */
console.log('\n── 8. MCP 侧：read_claims / triage / vault://claims 真的接上了 ──');

function connect(dataDir, home) {
  const proc = spawn(process.execPath, [SERVER], {
    env: { ...process.env, LOCALVAULT_DATA_DIR: dataDir, HOME: home, CFFIXED_USER_HOME: home },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const pending = new Map();
  const rl = require('node:readline').createInterface({ input: proc.stdout });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  });
  let seq = 0;
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = ++seq;
    const timer = setTimeout(() => reject(new Error(`超时：${method}`)), 30000);
    pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  return { proc, call };
}

(async () => {
  const s = connect(DATA, HOME);
  await s.call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 't', version: '1' } });

  const list = await s.call('tools/list', {});
  const names = (list.result.tools || []).map((t) => t.name);
  check('工具清单里有 read_claims', names.includes('read_claims'), names.join(', '));
  check('工具清单里有 triage', names.includes('triage'), names.join(', '));

  const res = await s.call('resources/list', {});
  const uris = (res.result.resources || []).map((r) => r.uri);
  check('资源清单里有 vault://claims', uris.includes('vault://claims'), uris.join(', '));

  const read = await s.call('tools/call', { name: 'read_claims', arguments: { format: 'json' } });
  const readText = ((read.result.content || [])[0] || {}).text || '';
  let parsed = null;
  try { parsed = JSON.parse(readText); } catch { /* 下面会报出来 */ }
  check('read_claims 能读出当前判断', parsed && Array.isArray(parsed.current) && parsed.current.length > 0,
    readText.slice(0, 300));
  if (parsed) {
    check('读出来的目标里有那条人签的 /tmp/a.md',
      parsed.current.some((c) => c.target === '/tmp/a.md' && c.verdict === '保留'),
      JSON.stringify(parsed.current.map((c) => c.target)));
    check('撤回过的目标不在当前状态里',
      !parsed.current.some((c) => c.target === '/x'), JSON.stringify(parsed.current.map((c) => c.target)));
  }

  const tri = await s.call('tools/call', { name: 'triage', arguments: { target: '/tmp/mcp.md', note: 'agent 的观察' } });
  const triText = ((tri.result.content || [])[0] || {}).text || '';
  check('triage 能追加机器条陈', /已追加/.test(triText), triText.slice(0, 200));

  const after3 = C.openClaims(cfg, { readOnly: true });
  const wrote = C.listClaims(after3.db, { target: '/tmp/mcp.md' }).rows[0];
  after3.db.close();
  check('追加进来的确实是机器 + L0', wrote && wrote.actorType === 'machine' && wrote.authority === 'L0',
    JSON.stringify(wrote));

  // 人签的那条不能被这次写入动到。
  const after4 = C.openClaims(cfg, { readOnly: true });
  const human = C.listClaims(after4.db, { target: '/tmp/a.md' }).rows[0];
  after4.db.close();
  check('triage 没有动到已有的人签判断', human && human.verdict === '保留' && human.note === '别删',
    JSON.stringify(human));

  const rc = await s.call('resources/read', { uri: 'vault://claims' });
  const rcText = ((rc.result.contents || [])[0] || {}).text || '';
  check('vault://claims 读得出来', rcText.includes('你签过的判断') || rcText.includes('还没有任何判断'),
    rcText.slice(0, 200));

  // 人签判断不能从 MCP 这边产生：triage 只写机器条陈。
  const bad = await s.call('tools/call', { name: 'triage', arguments: {} });
  check('triage 缺参数时明确报错而不是静默写入',
    Boolean(bad.error) || /需要 target/.test(((bad.result && bad.result.content) || [{}])[0].text || ''),
    JSON.stringify(bad).slice(0, 200));

  /* ── 8b. read_claims 这个**工具**也不能建库 ────────────────────────
   *
   * 这一段是**反向证明逼出来的**。
   *
   * 原来只在 `lib/claims.js` 层面测了「openClaims 不建库」，没测工具本身。
   * 于是我把 mcp.js 里的 `{readOnly: true}` 改成 `{create: true}` ——
   * 一个读工具开始往盘上写文件 —— 测试**照样 42 全绿**。
   *
   * 「模块不写」和「工具不写」是两件事。要断言的是**工具**。
   */
  const H2 = fs.mkdtempSync(path.join(os.tmpdir(), 'lvclaims-rw-'));
  const D2 = path.join(H2, '.localvault');
  fs.mkdirSync(D2, { recursive: true });
  const s2 = connect(D2, H2);
  await s2.call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 't', version: '1' } });
  const r2 = await s2.call('tools/call', { name: 'read_claims', arguments: {} });
  const t2 = ((r2.result && r2.result.content) || [{}])[0].text || '';
  check('read_claims 在库不存在时老实说「还不存在」', /不存在/.test(t2), t2.slice(0, 200));
  check('read_claims 没有凭空造出 claims.db', !fs.existsSync(path.join(D2, 'claims.db')),
    `竟然造出来了：${path.join(D2, 'claims.db')}`);
  s2.proc.kill();
  fs.rmSync(H2, { recursive: true, force: true });

  s.proc.kill();
  fs.rmSync(HOME, { recursive: true, force: true });

  console.log(`\n通过 ${passed} · 失败 ${failed}${skipped ? ` · 跳过 ${skipped}（跳过不等于通过）` : ''}`);
  process.exit(failed === 0 ? 0 : 1);
})();
