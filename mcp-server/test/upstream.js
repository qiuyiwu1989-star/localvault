#!/usr/bin/env node
'use strict';

/**
 * 上游对接 · 合成验收。
 *
 *   node test/upstream.js
 *
 * **全部在临时目录里跑，用一个假端点。**
 * 不碰真实 `~/.localvault`，不连 `qiuyiwu.com`，不发任何真实资料。
 *
 * 来件要求必须验证的七条（编号对应 §五）：
 *   1. 长中文/emoji/转义文本重组完全一致
 *   2. 多作者不混归属
 *   3. 相同版本重复 / 未知结果重试不重复入库
 *   4. 重启补偿未完成分段
 *   5. 新版本不覆盖旧件
 *   6. 撤权 / 跨范围 / 付费提炼 / 正式确认被拒绝
 *   7. 删除事件明确显示待处理，而非假装已撤回
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
let passed = 0;
let failed = 0;

/* ------------------------------------------------------------------ *
 * 物理隔离：测试期间禁止任何真实网络请求
 *
 * 起因：本测试第一版把 `fetchImpl` 传成了错误的选项名，客户端于是回退到
 * `globalThis.fetch`，**真的打到了生产端点**（拿到 401 才停下）。
 * 那一次因为认证失败没有资料出去，但「测试能打到生产」这件事本身就是漏洞。
 *
 * 所以这里不再依赖「记得传对参数」：把 `globalThis.fetch` 换成一个一碰就炸的
 * 替身。任何漏传 fetch 的实现会**立刻、显式**失败，而不是悄悄连上去。
 * 这是今天第二起「测试打真实环境」——第一起是漏了 CFFIXED_USER_HOME。
 * 两次的教训是同一条：**不要靠「记得」，要让错的那条路走不通。**
 * ------------------------------------------------------------------ */
const REAL_FETCH = globalThis.fetch;
const PRODUCTION_HOST = 'qiuyiwu.com';
const networkAttempts = [];
globalThis.fetch = async (url) => {
  networkAttempts.push(String(url));
  throw new Error(
    `测试里禁止真实网络请求，但有人请求了 ${url}。\n` +
    '  多半是漏传了 fetch（客户端选项名是 `fetch`，不是 `fetchImpl`）。\n' +
    '  测试必须物理上够不到生产端点 —— 这层替身就是为此存在的。'
  );
};

function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; console.log(`  ✗ ${name}${detail ? ' —— ' + detail : ''}`); }
}
function section(t) { console.log(`\n${t}`); }

/* ------------------------------------------------------------------ *
 * 假端点：记录收到的每一个 payload，可以按脚本失败
 * ------------------------------------------------------------------ */
/**
 * 真实 MCP 工具结果的形状：返回体装在 `content[].text` 里，**是个 JSON 字符串**。
 *
 * 原来这里直接返回扁平对象 `{source_id, job_id}`，于是
 * `extractReceipt` 的「解析 TextContent」那条路一次都没被走过 ——
 * 测试的假服务器形状不像真服务器，是「测试发现不了自己的 bug」的典型。
 * 中心侧用真实回环 HTTP 一测就测出来了。
 */
function toolResult(obj) {
  return { content: [{ type: 'text', text: JSON.stringify(obj) }] };
}

/** 工具级失败：**HTTP 仍然是 200**，只有 `isError` 标记它是失败。 */
function toolError(msg) {
  return { content: [{ type: 'text', text: msg }], isError: true };
}

function makeFakeServer(script = {}) {
  const received = [];
  const state = { mode: 'ok', failTimes: 0, failKind: 'transient',
                  toolErrorTimes: 0, toolErrorText: '工具级拒绝（默认文案）' };
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    if (body.method === 'initialize') {
      return jsonRes({ jsonrpc: '2.0', id: body.id, result: { protocolVersion: '2024-11-05', serverInfo: { name: 'fake-memory-center' } } });
    }
    if (body.method === 'notifications/initialized') return jsonRes({});
    if (body.method === 'tools/list') {
      return jsonRes({ jsonrpc: '2.0', id: body.id, result: { tools: [
        { name: 'memory_import', inputSchema: { type: 'object' } },
        { name: 'memory_import_status', inputSchema: { type: 'object' } },
      ] } });
    }
    if (body.method === 'tools/call') {
      const { name, arguments: args } = body.params;
      received.push({ name, args, at: Date.now() });

      if (script.before && script.before(name, args, received) === 'abort') return jsonRes({}, 500);

      if (state.failTimes > 0) {
        state.failTimes--;
        if (state.failKind === 'network') throw new Error('socket hang up');
        if (state.failKind === 'auth') return jsonRes({ error: 'forbidden' }, 403);
        return jsonRes({ error: 'busy' }, 503);
      }

      if (name === 'memory_import') {
        if (args.processing_policy !== 'archive') return jsonRes({ error: 'policy not allowed' }, 400);
        // 工具级拒绝：HTTP 200，result.isError = true
        if (state.toolErrorTimes > 0) {
          state.toolErrorTimes--;
          return jsonRes({ jsonrpc: '2.0', id: body.id, result: toolError(state.toolErrorText) });
        }
        // 真实形状：收据在 content[].text 那个 JSON 字符串里
        return jsonRes({ jsonrpc: '2.0', id: body.id, result: toolResult({
          source_id: `src-${received.length}`, job_id: `job-${received.length}`, status: 'archived',
        }) });
      }
      if (name === 'memory_import_status') {
        return jsonRes({ jsonrpc: '2.0', id: body.id, result: toolResult({ archived: true, indexed: true, extracted: false, confirmed: false }) });
      }
      return jsonRes({ error: 'unknown tool' }, 400);
    }
    return jsonRes({ jsonrpc: '2.0', id: body.id, result: {} });
  };
  return { fetchImpl, received, state,
    setFail(n, kind) { state.failTimes = n; state.failKind = kind; },
    setToolError(n, text) { state.toolErrorTimes = n; if (text) state.toolErrorText = text; } };
}

function jsonRes(obj, status = 200) {
  return {
    ok: status < 400,
    status,
    headers: { get: () => 'application/json' },
    text: async () => JSON.stringify(obj),
  };
}

/* ------------------------------------------------------------------ *
 * 造索引：真的跑 init + index
 * ------------------------------------------------------------------ */
function buildIndexedFixture(label) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), `lv-up-${label}-`));
  const home = path.join(base, 'home');
  const data = path.join(base, 'data');
  const tree = path.join(home, 'Documents', '工作区');
  fs.mkdirSync(tree, { recursive: true });
  fs.mkdirSync(data, { recursive: true });

  const env = { ...process.env, HOME: home, LOCALVAULT_DATA_DIR: data, LOCALVAULT_QUIET: '1' };
  const run = (args) => {
    const r = spawnSync(process.execPath, [path.join(ROOT, 'cli.js'), ...args], { env, encoding: 'utf8' });
    if (r.status !== 0 && !args.includes('index')) {
      throw new Error(`cli ${args.join(' ')} 失败：${r.stderr || r.stdout}`);
    }
    return r;
  };
  run(['init', '--root', tree]);
  // init 写完配置后，把根指向我们的树
  const cfgPath = path.join(data, 'config.json');
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  cfg.roots = [{ path: tree, label: '工作区' }];
  cfg.primaryRoot = tree;
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));

  return { base, home, data, tree, cfgPath, env, run, write(rel, content) {
    const abs = path.join(tree, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content, 'utf8');
    return abs;
  }, reindex() { return run(['index']); } };
}

function openVault(dataDir) {
  const { DatabaseSync } = require('node:sqlite');
  return new DatabaseSync(path.join(dataDir, 'vault.db'), { readOnly: true });
}

function loadModules() {
  return {
    cp: require('../lib/upstream/codepoints'),
    V: require('../lib/upstream/versions'),
    M: require('../lib/upstream/manifest'),
    S: require('../lib/upstream/segmenter'),
    Map: require('../lib/upstream/mapping'),
    Led: require('../lib/upstream/ledger'),
    En: require('../lib/upstream/enumerate'),
    C: require('../lib/upstream/client'),
    B: require('../lib/upstream/bridge'),
  };
}

function makeBridge({ fx, manifestRaw, server, ledgerFile }) {
  const mods = loadModules();
  const manifest = mods.M.parseManifest(manifestRaw, { defaultRoot: fx.tree });
  const ledger = mods.Led.openLedger(ledgerFile);
  const client = new mods.C.MemoryCenterClient({
    endpoint: 'http://fake.invalid/mcp',        // 绝不是生产端点
    token: 'test-token-not-real',
    fetch: server.fetchImpl,                    // ← 选项名是 fetch
  });
  if (client.endpoint.includes(PRODUCTION_HOST)) {
    throw new Error(`测试端点指向了生产：${client.endpoint} —— 拒绝继续`);
  }
  const bridge = mods.B.newBridge({
    db: openVault(fx.data), ledger, manifest, client, log: () => {},
  });
  return { mods, manifest, ledger, client, bridge };
}

/* ================================================================== */
async function main() {
  console.log('上游对接 · 合成验收（全部在临时目录，假端点）');

  /* ---------- §1 码点一致性 ---------- */
  section('§1 长中文 / emoji / 转义文本重组完全一致');
  {
    const { cp, S } = loadModules();
    const samples = {
      '纯中文长段': '项目台账。'.repeat(300),
      '混合 emoji（代理对）': '结论：😀👍🏽 通过。'.repeat(200),
      '生僻字（BMP 外）': '𠮷𡃁𠀋 的用法。'.repeat(150),
      '转义敏感字符': '引号"反斜杠\\换行\n制表\t'.repeat(120),
      '组合字符与变音': 'e\u0301a\u0300 n\u0303'.repeat(200),
    };
    for (const [label, text] of Object.entries(samples)) {
      const cps = cp.toCodePoints(text);
      const parts = S.segmentBody(text, 500);
      const joined = parts.map((p) => p.text).join('');
      check(`${label}：拼回去逐码点等于原文`, joined === text,
        `原文 ${cps.length} 码点 / 拼回 ${cp.cpLength(joined)} 码点`);
      check(`${label}：每一段都不超预算`,
        // 空数组上 `.every()` 恒真；顺带 `Math.max(...[])` 是 `-Infinity`。
        // 两个征兆指向同一件事：这段预算没考虑「一段都没有」的情况。
        parts.length > 0 && parts.every((p) => cp.cpLength(p.text) <= 500),
        `共 ${parts.length} 段 · 最大 ${parts.length ? Math.max(...parts.map((p) => cp.cpLength(p.text))) : '—'}`);
      // 段必须逐段等于原文的连续切片（不是重排、不是改写）
      let okSlice = true;
      for (const p of parts) if (cp.sliceCp(text, p.startCp, p.endCp) !== p.text) okSlice = false;
      check(`${label}：每段都是原文的连续切片（位置可信）`, okSlice);
    }
    // UTF-16 直接 slice 会坏 —— 证明这一点，说明为什么需要本模块
    const emoji = '😀😀😀';
    check('反证：UTF-16 裸切会切坏 emoji', emoji.slice(0, 1) !== '😀' && emoji.slice(0, 1).length === 1,
      JSON.stringify(emoji.slice(0, 1)));
    check('cpLength 与 Array.from 一致', cp.cpLength(emoji) === 3);
  }

  /* ---------- 版本 hash 覆盖 ---------- */
  section('§1b 版本 hash 覆盖正文/角色/作者/日期，不只文件名');
  {
    const { V } = loadModules();
    const base = { stableId: 'aaaa', body: '内容一', role: 'user', author: '邱懿武', originalDate: '2026-09-30' };
    const h0 = V.versionHash(base);
    check('正文改一个字 → 新 hash', V.versionHash({ ...base, body: '内容二' }) !== h0);
    check('角色变 → 新 hash', V.versionHash({ ...base, role: 'assistant' }) !== h0);
    check('作者变 → 新 hash', V.versionHash({ ...base, author: '别人' }) !== h0);
    check('日期变 → 新 hash', V.versionHash({ ...base, originalDate: '2026-10-01' }) !== h0);
    check('解析器版本变 → 新 hash', V.versionHash({ ...base, parserVersion: 'v2' }) !== h0);
    check('完全相同 → 同 hash（幂等前提）', V.versionHash({ ...base }) === h0);
    check('「没有 author」≠「author 是空串」',
      V.versionHash({ ...base, author: undefined }) !== V.versionHash({ ...base, author: '' }));
  }

  /* ---------- 建 fixture ---------- */
  const fx = buildIndexedFixture('main');
  fx.write('甲-本人笔记.md', '# 我的判断\n\n我认为这个方向可行。\n\n第二段继续说明理由。');
  fx.write('乙-第三方来信.md', '# 来信\n\n尊敬的用户，我们建议调整方案。');
  fx.write('丙-助手草稿.md', '# 草稿\n\n这是 Agent 生成的建议稿。');
  fx.write('丁-长文.md', ('长文正文。'.repeat(60) + '\n\n').repeat(40));
  fx.reindex();

  const manifestRaw = {
    scope: 'agent:localvault-inbox',
    instance: 'test-instance',
    sources: [
      { path: '甲-本人笔记.md', role: 'user', author: '邱懿武', original_date: '2026-09-30' },
      { path: '乙-第三方来信.md', role: 'external' },
      { path: '丙-助手草稿.md', role: 'assistant' },
      { path: '丁-长文.md', role: 'user', source_type: 'document' },
    ],
  };

  /* ---------- §2 多作者不混归属 ---------- */
  section('§2 多作者不混归属；未知保持未知');
  {
    const server = makeFakeServer();
    const { bridge, ledger } = makeBridge({ fx, manifestRaw, server, ledgerFile: path.join(fx.base, 'l1.db') });
    const p = bridge.plan();
    const byRel = Object.fromEntries(p.items.map((i) => [i.rel, i]));
    check('四条资料都被枚举到', p.items.length === 4, `实际 ${p.items.length}：${p.items.map((i) => i.rel).join('、')}`);
    check('本人笔记 → user', byRel['甲-本人笔记.md'] && byRel['甲-本人笔记.md'].role === 'user');
    check('第三方来信 → external（不因在用户目录里就标 user）',
      byRel['乙-第三方来信.md'] && byRel['乙-第三方来信.md'].role === 'external');
    check('助手草稿 → assistant', byRel['丙-助手草稿.md'] && byRel['丙-助手草稿.md'].role === 'assistant');

    await bridge.push();
    const sent = server.received.filter((r) => r.name === 'memory_import');
    // 先守住「确实发出去了」—— 否则下面几条对空数组 .every() 恒真，全是空洞断言
    check('确实产生了提交（后面几条角色的断言才有对象）', sent.length >= 4, `实际 ${sent.length} 个请求`);
    const roles = sent.flatMap((r) => r.args.messages.map((m) => m.role));
    check('发出的消息非空', roles.length > 0, `实际 ${roles.length} 条消息`);
    // 上一行虽然断言了 roles 非空，但那是**另一条**断言；这一条自己也要能失败。
    check('发出的消息里三种角色都在，且没有别的值',
      roles.length > 0 && roles.every((r) => ['user', 'assistant', 'external'].includes(r)));
    const thirdParty = sent.filter((r) => JSON.stringify(r.args.messages).includes('我们建议调整方案'));
    check('第三方那条确实发出去了', thirdParty.length >= 1, `实际 ${thirdParty.length}`);
    check('第三方那条的正文没有被标成 user',
      thirdParty.length >= 1 && thirdParty.every((r) =>
        r.args.messages.length > 0 && r.args.messages.every((m) => m.role === 'external')));

    // 未声明作者 → 字段整个省略，而不是 "unknown"
    const extPayload = thirdParty.length ? thirdParty[0].args : null;
    check('未核实的作者：author 字段整个不出现（不是 "unknown"）',
      extPayload !== null && !('author' in extPayload.source_metadata),
      extPayload ? JSON.stringify(extPayload.source_metadata) : '没找到第三方那条');
    const userSent = sent.filter((r) => JSON.stringify(r.args.messages).includes('我认为这个方向可行'));
    check('本人那条确实发出去了', userSent.length >= 1, `实际 ${userSent.length}`);
    check('已声明的作者被带上', userSent.length >= 1 && userSent[0].args.source_metadata.author === '邱懿武');
    check('已声明的日期被带上', userSent.length >= 1 && userSent[0].args.source_metadata.original_date === '2026-09-30');
    ledger.close();
  }

  /* ---------- §3 幂等 ---------- */
  section('§3 相同版本重复提交 / 未知结果重试 不重复入库');
  {
    const server = makeFakeServer();
    const lf = path.join(fx.base, 'l3.db');
    const a = makeBridge({ fx, manifestRaw, server, ledgerFile: lf });
    const r1 = await a.bridge.push();
    const n1 = server.received.length;
    check('首次提交有收据', r1.receipted > 0, JSON.stringify(r1));
    const r2 = await a.bridge.push();
    check('再跑一次：没有新请求（游标没动 / 已收讫）', server.received.length === n1,
      `请求数 ${n1} → ${server.received.length}`);
    a.ledger.close();

    // 未知结果：让失败**持续到超过客户端自己的重试上限**，才能真正落到「待补偿」
    const server2 = makeFakeServer();
    const lf2 = path.join(fx.base, 'l3b.db');
    const fx2 = buildIndexedFixture('idem');
    fx2.write('唯一.md', '只有这一篇。');
    fx2.reindex();
    const m2 = {
      scope: 'agent:localvault-inbox', instance: 'idem',
      sources: [{ path: '唯一.md', role: 'user' }],
    };
    const b = makeBridge({ fx: fx2, manifestRaw: m2, server: server2, ledgerFile: lf2 });
    server2.setFail(99, 'network');        // 比客户端 maxRetries 大：客户端内退避也救不回来
    const rr = await b.bridge.push();
    check('网络失败被交到账本等补偿，游标不推进', rr.cursorAdvanced === false,
      `failed=${rr.failed} cursorAdvanced=${rr.cursorAdvanced}`);
    const rowAfterFail = b.ledger.prepare('SELECT source_key, stage, attempts, payload_json FROM submissions').get();
    check('账本里那一行还在，attempts 涨了', rowAfterFail && rowAfterFail.attempts >= 1, JSON.stringify(rowAfterFail));
    const payloadBefore = rowAfterFail.payload_json;

    server2.setFail(0);                    // 网络恢复
    const c = await b.bridge.compensate();
    check('补偿把失败的分段补上了', c.ok >= 1, JSON.stringify(c));
    const rowAfter = b.ledger.prepare('SELECT source_key, stage, payload_json FROM submissions').get();
    check('重试用的是同一个 source_key', rowAfter.source_key === rowAfterFail.source_key);
    check('重试的 payload 逐字节相同（不是重新生成的）', rowAfter.payload_json === payloadBefore);
    const sentAfter = server2.received.filter((r) => r.name === 'memory_import');
    check('同一 source_key 只产生一条账本记录',
      b.ledger.prepare('SELECT COUNT(*) AS n FROM submissions').get().n === 1);
    check('服务端拿到的 source_key 两次相同', new Set(sentAfter.map((s) => s.args.source_key)).size === 1,
      [...new Set(sentAfter.map((s) => s.args.source_key))].join(','));
    b.ledger.close();
  }

  /* ---------- §4 重启补偿 ---------- */
  section('§4 重启后补偿未完成的分段');
  {
    const fx4 = buildIndexedFixture('restart');
    for (let i = 0; i < 12; i++) fx4.write(`文件${String(i).padStart(2, '0')}.md`, `第 ${i} 篇内容。`);
    fx4.reindex();
    const m4 = {
      scope: 'agent:localvault-inbox', instance: 'restart',
      sources: Array.from({ length: 12 }, (_, i) => ({ path: `文件${String(i).padStart(2, '0')}.md`, role: 'user' })),
    };
    const server = makeFakeServer();
    const lf = path.join(fx4.base, 'l4.db');

    // 假装「推到第 5 个时进程被杀」：让服务端从第 5 个请求起全部失败
    let n = 0;
    const server5 = makeFakeServer({ before: () => (++n > 5 ? 'abort' : undefined) });
    const first = makeBridge({ fx: fx4, manifestRaw: m4, server: server5, ledgerFile: lf });
    await first.bridge.push();
    const doneBefore = first.ledger.prepare("SELECT COUNT(*) AS n FROM submissions WHERE stage = 'receipted'").get().n;
    const pendingBefore = first.ledger.prepare("SELECT COUNT(*) AS n FROM submissions WHERE stage != 'receipted'").get().n;
    check('中断后：一部分已收讫、一部分未完成', doneBefore > 0 && pendingBefore > 0,
      `收讫 ${doneBefore} / 未完成 ${pendingBefore}`);
    const cursorAfterCrash = first.ledger.prepare('SELECT scan_id FROM cursors WHERE instance = ?').get('restart');
    check('有未完成项时游标没有推进', !cursorAfterCrash || Number(cursorAfterCrash.scan_id) === 0,
      JSON.stringify(cursorAfterCrash));
    first.ledger.close();

    // 重启：新的进程、新的连接，同一个账本
    const serverOk = makeFakeServer();
    const second = makeBridge({ fx: fx4, manifestRaw: m4, server: serverOk, ledgerFile: lf });
    const comp = await second.bridge.compensate();
    check('重启后补偿把剩下的补完', comp.failed === 0 && comp.ok >= pendingBefore,
      `ok=${comp.ok} pendingBefore=${pendingBefore}`);
    const all = second.ledger.prepare("SELECT COUNT(*) AS n FROM submissions WHERE stage = 'receipted'").get().n;
    check('所有分段最终都是 receipted', all === 12, `receipted=${all}`);
    check('补偿请求数 == 未完成数（不重发已收讫的）',
      serverOk.received.filter((r) => r.name === 'memory_import').length === pendingBefore,
      `${serverOk.received.filter((r) => r.name === 'memory_import').length} vs ${pendingBefore}`);
    second.ledger.close();
  }

  /* ---------- §5 新版本不覆盖旧件 ---------- */
  section('§5 新版本不覆盖旧件；旧收据还在');
  {
    const fx5 = buildIndexedFixture('version');
    fx5.write('会改的文件.md', '第一版内容。');
    fx5.reindex();
    const m5 = {
      scope: 'agent:localvault-inbox', instance: 'ver',
      sources: [{ path: '会改的文件.md', role: 'user' }],
    };
    const server = makeFakeServer();
    const lf = path.join(fx5.base, 'l5.db');
    const b = makeBridge({ fx: fx5, manifestRaw: m5, server, ledgerFile: lf });
    await b.bridge.push();
    const v1Key = b.ledger.prepare('SELECT source_key FROM submissions').get().source_key;

    fx5.write('会改的文件.md', '第二版内容，改了一行。');
    fx5.reindex();
    await b.bridge.push();

    const rows = b.ledger.prepare('SELECT source_key, stage FROM submissions ORDER BY id').all();
    check('两个版本各占一行，旧的那行没被覆盖', rows.length === 2, JSON.stringify(rows));
    check('新版本是新的 source_key', rows[1].source_key !== v1Key);
    check('旧版本仍是 receipted（历史可追溯）', rows[0].stage === 'receipted');
    const sentTexts = server.received.filter((r) => r.name === 'memory_import')
      .map((r) => r.args.messages.map((m) => m.text).join(''));
    check('服务端两版都收到了（没有「新替换旧」的假象）',
      sentTexts.some((t) => t.includes('第一版')) && sentTexts.some((t) => t.includes('第二版')));
    b.ledger.close();
  }

  /* ---------- §6 拒绝项 ---------- */
  section('§6 撤权 / 跨范围 / 付费提炼 / 正式确认 被拒绝');
  {
    const { Map: MP, C, M } = loadModules();

    // 付费提炼：policy 不是 archive → 本地就拒绝，连请求都不发
    const c = new C.MemoryCenterClient({ endpoint: 'http://fake.invalid/mcp', token: 't', fetch: async () => jsonRes({}) });
    let threw = null;
    try {
      await c.importArchive({
        scope: 'agent:localvault-inbox', source_key: 'k',
        processing_policy: 'extract', source_type: 'document',
        messages: [{ id: 'p1', role: 'external', text: 'x' }],
      });
    } catch (e) { threw = e; }
    check('付费提炼（processing_policy != archive）被本地拒绝', threw && threw.kind === 'validation',
      threw && threw.message);

    // 服务端 403 → auth 类，停下，不换 scope
    const server403 = makeFakeServer();
    server403.setFail(1, 'auth');
    const fx6 = buildIndexedFixture('auth');
    fx6.write('a.md', '内容。');
    fx6.reindex();
    const m6 = { scope: 'agent:localvault-inbox', instance: 'auth', sources: [{ path: 'a.md', role: 'user' }] };
    const b6 = makeBridge({ fx: fx6, manifestRaw: m6, server: server403, ledgerFile: path.join(fx6.base, 'l6.db') });
    const r6 = await b6.bridge.push();
    check('403 → 立刻停下（stopped=auth）', r6.stopped === 'auth', JSON.stringify(r6).slice(0, 200));
    check('停下后游标不推进', r6.cursorAdvanced === false);
    const after403 = server403.received.filter((r) => r.name === 'memory_import');
    // `after403` 为空时 `.every()` 恒真 —— 而「一次都没发」恰恰是最该看见的情况，
    // 所以必须先把非空写进去，否则这条测试在「什么都没发生」时反而变绿。
    check('拒绝后没有换 scope 重试',
      after403.length > 0 && after403.every((r) => r.args.scope === 'agent:localvault-inbox'),
      `403 之后的 memory_import 次数 ${after403.length}`);
    b6.ledger.close();

    // 清单层面的拒绝
    const bad = [
      ['撤权：清单为空 → 拒绝', { scope: 'agent:localvault-inbox', sources: [] }, /非空数组/],
      ['跨范围：scope 形状不对 → 拒绝', { scope: 'personal', sources: [{ path: 'a.md' }] }, /scope 形状/],
      ['正式确认：不认识的角色 → 拒绝', { scope: 'agent:localvault-inbox', sources: [{ path: 'a.md', role: 'owner' }] }, /role 只能/],
      ['占位作者 → 拒绝', { scope: 'agent:localvault-inbox', sources: [{ path: 'a.md', author: 'unknown' }] }, /占位值/],
      ['二手摘要缺原件 → 拒绝', { scope: 'agent:localvault-inbox', sources: [{ path: 'a.md', source_type: 'imported_summary' }] }, /parent_source_key/],
      ['路径逃逸 ../ → 拒绝', { scope: 'agent:localvault-inbox', sources: [{ path: '../外面.md' }] }, /\.\./],
      ['未知字段 → 拒绝（拼错键=没写）', { scope: 'agent:localvault-inbox', sources: [{ path: 'a.md', rolee: 'user' }] }, /未知字段/],
    ];
    for (const [name, raw, re] of bad) {
      let e = null;
      try { M.parseManifest(raw); } catch (err) { e = err; }
      check(name, e && re.test(e.message), e && e.message);
    }

    // source_metadata 白名单：多余字段必须被**列出**（不是静默丢掉）
    const probs = MP.validatePayload({
      scope: 'agent:localvault-inbox', source_key: 'k', processing_policy: 'archive',
      source_type: 'document', messages: [{ id: 'p1', role: 'external', text: 'x' }],
      source_metadata: { original_ref: 'r', trusted: 'yes' },
    });
    check('source_metadata 多余字段被列出（trusted / owner / verified）', probs.some((p) => /trusted/.test(p)), probs.join('；'));

    const probs2 = MP.validatePayload({
      scope: 'agent:localvault-inbox', source_key: 'k', processing_policy: 'extract',
      source_type: 'document', messages: [{ id: 'p1', role: 'external', text: 'x' }],
      source_metadata: { original_ref: 'r' },
    });
    check('dry-run 自检会抓出非 archive 的 policy', probs2.some((p) => /archive/.test(p)), probs2.join('；'));
  }

  /* ---------- §6b 工具级拒绝 / 收据形状 / 长度判据 ---------- */
  section('§6b 工具级拒绝（HTTP 200 + isError）不得被记成收据');
  {
    const { S, Map: MP } = loadModules();

    // ① 权限类工具拒绝 → 立刻停，不记收据，游标不动
    const sA = makeFakeServer();
    sA.setToolError(1, 'not allowed: scope agent:localvault-inbox cannot import into personal');
    const fxA = buildIndexedFixture('tooldeny-a');
    fxA.write('a.md', '内容。'); fxA.reindex();
    const bA = makeBridge({ fx: fxA, server: sA, ledgerFile: path.join(fxA.base, 'la.db'),
      manifestRaw: { scope: 'agent:localvault-inbox', instance: 'tooldeny-a', sources: [{ path: 'a.md', role: 'user' }] } });
    const rA = await bA.bridge.push();
    check('权限类工具拒绝：receipted 为 0（拒绝没被当成收据）', rA.receipted === 0,
      JSON.stringify(rA).slice(0, 220));
    check('权限类工具拒绝：游标不推进', rA.cursorAdvanced === false, `advanced=${rA.cursorAdvanced}`);
    const rowsA = bA.ledger.prepare('SELECT stage FROM submissions').all();
    check('权限类工具拒绝：账本里有行，且没有一行是 receipted',
      rowsA.length > 0 && rowsA.every((r) => r.stage !== 'receipted'),
      `stage=${rowsA.map((r) => r.stage).join(',') || '(空)'}`);
    bA.ledger.close();

    // ② 非权限类工具拒绝 → 记失败、游标不动（不是静默丢弃）
    const sB = makeFakeServer();
    sB.setToolError(1, '参数校验失败：messages 为空');
    const fxB = buildIndexedFixture('tooldeny-b');
    fxB.write('b.md', '内容。'); fxB.reindex();
    const bB = makeBridge({ fx: fxB, server: sB, ledgerFile: path.join(fxB.base, 'lb.db'),
      manifestRaw: { scope: 'agent:localvault-inbox', instance: 'tooldeny-b', sources: [{ path: 'b.md', role: 'user' }] } });
    const rB = await bB.bridge.push();
    check('普通工具拒绝：receipted 为 0', rB.receipted === 0, JSON.stringify(rB).slice(0, 220));
    check('普通工具拒绝：游标不推进', rB.cursorAdvanced === false, `advanced=${rB.cursorAdvanced}`);
    const rowsB = bB.ledger.prepare('SELECT stage FROM submissions').all();
    check('普通工具拒绝：被记成 failed（可补偿，不是静默丢弃）',
      rowsB.some((r) => r.stage === 'failed'), `stage=${rowsB.map((r) => r.stage).join(',') || '(空)'}`);
    bB.ledger.close();

    // ③ 收据在 content[].text 的 JSON 里 —— 必须真的抠出来并落盘
    const sC = makeFakeServer();
    const fxC = buildIndexedFixture('receipt-shape');
    fxC.write('c.md', '内容。'); fxC.reindex();
    const bC = makeBridge({ fx: fxC, server: sC, ledgerFile: path.join(fxC.base, 'lc.db'),
      manifestRaw: { scope: 'agent:localvault-inbox', instance: 'receipt-shape', sources: [{ path: 'c.md', role: 'user' }] } });
    const rC = await bC.bridge.push();
    const rowC = bC.ledger.prepare('SELECT stage, source_id, job_id FROM submissions LIMIT 1').get();
    check('收据被抠出来了（source_id 非空）', Boolean(rowC && rowC.source_id), JSON.stringify(rowC));
    check('job_id 也落进了账本', Boolean(rowC && rowC.job_id), JSON.stringify(rowC));
    check('正常形状下仍然记成 receipted', rC.receipted > 0 && Boolean(rowC) && rowC.stage === 'receipted',
      JSON.stringify(rowC));
    bC.ledger.close();

    // ④ 顶层白名单：杜撰的顶层键必须**抛错**，不能静默通过
    const probs = MP.validatePayload({
      scope: 'agent:localvault-inbox', source_key: 'k', source_type: 'document',
      processing_policy: 'archive', source_metadata: {},
      messages: [{ id: 'p1', role: 'user', text: 'x' }],
      parent_source_key: '本地杜撰的顶层键',
    });
    check('顶层杜撰字段（parent_source_key）被拒绝', probs.some((x) => /顶层字段/.test(x)),
      probs.join('；') || '(竟然没报错)');
    const clean = MP.validatePayload({
      scope: 'agent:localvault-inbox', source_key: 'k', source_type: 'document',
      processing_policy: 'archive', source_metadata: {},
      messages: [{ id: 'p1', role: 'user', text: 'x' }],
    });
    check('白名单内的正常 payload 不被误伤', clean.length === 0, clean.join('；'));

    // ⑤ 长度判据必须是 UTF-8 字节（按码元数会低估 2.67 倍）
    const cjk = { t: '中文测试'.repeat(10) };
    const byChars = JSON.stringify(cjk).length;
    const byBytes = Buffer.byteLength(JSON.stringify(cjk), 'utf8');
    check('utf8JsonLen 数的是字节，不是 UTF-16 码元',
      S.utf8JsonLen(cjk) === byBytes && byBytes > byChars,
      `函数=${S.utf8JsonLen(cjk)} 字节=${byBytes} 码元=${byChars}`);
  }

  /* ---------- §7 删除 ---------- */
  section('§7 删除事件显示「待处理」，不假装已撤回');
  {
    const fx7 = buildIndexedFixture('del');
    fx7.write('会被删的.md', '内容。');
    fx7.write('留下的.md', '内容。');
    fx7.reindex();
    const m7 = {
      scope: 'agent:localvault-inbox', instance: 'del',
      sources: [{ path: '会被删的.md', role: 'user' }, { path: '留下的.md', role: 'user' }],
    };
    const server = makeFakeServer();
    const b = makeBridge({ fx: fx7, manifestRaw: m7, server, ledgerFile: path.join(fx7.base, 'l7.db') });
    await b.bridge.push();

    fs.unlinkSync(path.join(fx7.tree, '会被删的.md'));
    fx7.reindex();
    const t = b.bridge.tombstone();
    check('删除被记成 tombstone', t.added.includes('会被删的.md'), JSON.stringify(t));

    const st = b.bridge.status();
    check('状态里 tombstone 显示为「待处理」', st.tombstonesPending === 1, JSON.stringify(st));
    check('状态说明写明「归档 ≠ 提炼 ≠ 确认」', /已归档.*不等于|不等于.*提炼|不产生后两个状态/.test(st.note), st.note);
    const stages = st.stages;
    check('首版从不产生 extracted / confirmed 状态', !('extracted' in stages) && !('confirmed' in stages), JSON.stringify(stages));

    // 服务端没有任何撤回请求
    const removalCalls = server.received.filter((r) => /delete|revoke|withdraw/i.test(r.name));
    check('没有悄悄发撤回请求（因为没有该协议）', removalCalls.length === 0);
    b.ledger.close();
  }

  /* ---------- 补充：dry-run 不泄露正文 + 白名单 ---------- */
  section('§8 dry-run 只给数量/hash，不给正文；白名单是硬边界');
  {
    const server = makeFakeServer();
    const b = makeBridge({ fx, manifestRaw: manifestRaw, server, ledgerFile: path.join(fx.base, 'l8.db') });
    const p = b.bridge.plan();
    const dump = JSON.stringify(p);
    check('dry-run 里没有正文句子', !dump.includes('我认为这个方向可行') && !dump.includes('我们建议调整方案'),
      dump.slice(0, 200));
    check('dry-run 里有 sourceKey 和 versionHash',
      p.items.length > 0 && p.items.every((i) => i.sourceKey && i.versionHash),
      `items ${p.items.length}`);
    check('dry-run 有耗时字段之外的数量', typeof p.changed === 'number' && typeof p.removed === 'number');
    check('dry-run 不发任何请求', server.received.length === 0);

    // 白名单：清单外文件不被枚举
    const mNarrow = {
      scope: 'agent:localvault-inbox', instance: 'narrow',
      sources: [{ path: '甲-本人笔记.md', role: 'user' }],
    };
    const b2 = makeBridge({ fx, manifestRaw: mNarrow, server, ledgerFile: path.join(fx.base, 'l8b.db') });
    const p2 = b2.bridge.plan();
    check('清单外资料一个都不进（白名单是硬边界）', p2.items.length === 1 && p2.items[0].rel === '甲-本人笔记.md',
      p2.items.map((i) => i.rel).join('、'));
    b.ledger.close(); b2.ledger.close();
  }

  /* ---------- 补充：截断的正文必须回磁盘读全文 ---------- */
  section('§9 索引正文可能被截断 → 提交的是磁盘全文');
  {
    const fx9 = buildIndexedFixture('trunc');
    // 造一篇超过 maxStoredBodyChars 的长文，让索引里的 body 被截断
    const long = '这是正文。'.repeat(120000);   // ~ 720k 字符 > 400k
    fx9.write('超长.md', long);
    fx9.reindex();
    const db = openVault(fx9.data);
    const row = db.prepare("SELECT truncated, length(body) AS blen, size FROM files WHERE rel = '超长.md'").get();
    check('索引里这篇确实被截断了', row && row.truncated === 1, JSON.stringify(row));

    const { En } = loadModules();
    const full = En.readVersion({ path: path.join(fx9.tree, '超长.md'), size: row.size, rel: '超长.md' });
    check('readVersion 从磁盘拿到了全文', full.ok && full.text.length === long.length,
      full.ok ? `${full.text.length} vs ${long.length}` : full.reason);
    check('磁盘全文比索引里的长得多（证明不能复用索引正文）', full.ok && full.text.length > row.blen,
      full.ok ? `${full.text.length} > ${row.blen}` : '');

    // 索引过期时必须报错，不猜
    const stale = En.readVersion({ path: path.join(fx9.tree, '超长.md'), size: 12345, rel: '超长.md' });
    check('索引与磁盘不一致 → 明确报错，不猜哪个对', !stale.ok && stale.kind === 'size-mismatch', JSON.stringify(stale));
    db.close();
  }

  /* ---------- 汇总 ---------- */
  section('§10 测试自身的隔离');
  {
    check('测试全过程一次真实网络请求都没有发生', networkAttempts.length === 0,
      networkAttempts.length ? `实际打了 ${networkAttempts.length} 次：${networkAttempts.slice(0, 3).join('、')}` : '');
    check('没有任何请求指向生产端点', !networkAttempts.some((u) => u.includes(PRODUCTION_HOST)));
  }
  console.log(`\n通过 ${passed} · 失败 ${failed}`);
  if (failed > 0) { console.log(`合成验收未通过：${failed} 项失败。`); process.exitCode = 1; }
  else { console.log('合成验收通过。'); process.exitCode = 0; }
  globalThis.fetch = REAL_FETCH;
}

main().catch((e) => {
  console.error('\n合成验收崩了：', e && e.stack || e);
  process.exitCode = 1;
});
