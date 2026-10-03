#!/usr/bin/env node
'use strict';
/**
 * 工具「诚实性」验收 —— 守住四类**看起来是答案、其实是别的东西**的返回。
 *
 * 这四条都是实测出来的（阶段 5.1：拿 5 个真问题接进 agent 跑一遍），
 * 共同点是：工具不报错、返回格式正常、读起来像个结论，但它是错的或残缺的。
 * 这类问题最坏的地方在于**它不会自己暴露** —— 调用方（尤其 agent）
 * 会把它当成事实继续往下推。
 *
 *   1. `vault_audit` 的同名簇数字 = `min(候选数, limit)`，是个上限却被当成计数。
 *      而旁边那个「完全重复组」是真计数，两者并排放，读的人分不出。
 *      实测本机真实同名簇 ≥1713，报告说 20。
 *   2. `recent_changes` 的「命中 N 条」= LIMIT 出来的行数。limit=40 就报 40，
 *      真值 4,805。上限被写成了总数。
 *   3. `.env` 这类被策略排除的文件：搜索返回「没有命中」，而 `list_directory`
 *      列得出来。同一份数据，一个说「有」一个说「没有」，且搜索不给任何提示。
 *   4. 参数写错一律静默降级：假 root、`since:"昨天"`、`sort:"bogus"` 全被忽略，
 *      调用方无法知道自己给错了 —— agent 试一次拿到答案，就以为参数是对的。
 *
 * 每条都**先在修复前的行为上做过反证**（改回去 → 变红）。
 *
 * 跑法：node test/tool-honesty.js
 */

const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const ROOT = path.join(__dirname, '..');
const CLI = path.join(ROOT, 'cli.js');
const SERVER = path.join(ROOT, 'server.js');

let pass = 0;
let fail = 0;
function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  ✓ ${name}${detail ? '  — ' + detail : ''}`); }
  else { fail++; console.log(`  ✗ ${name}${detail ? '  — ' + detail : ''}`); }
}

/** 起一个真服务器，走真 stdio 通道。 */
function connect(dataDir, home) {
  // **必须把假 HOME 一并传进去。** 只给 `LOCALVAULT_DATA_DIR` 不够：
  // 配置里存的是 `~/Desktop` 这种未展开的写法，服务器要在使用时展开它 ——
  // 用哪个 HOME 展开，就决定它去比哪些 `root` 值。
  // 只给 DATA_DIR 的话，`~/Desktop` 展开成**真实家目录**，而库里的 root 是假的，
  // 于是每个查询都「共 0 条」—— 看起来像产品 bug，其实是测试自己没把环境传全。
  const proc = spawn(process.execPath, [SERVER], {
    env: { ...process.env, LOCALVAULT_DATA_DIR: dataDir, HOME: home, CFFIXED_USER_HOME: home },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const rl = readline.createInterface({ input: proc.stdout });
  const pending = new Map();
  let id = 0;
  rl.on('line', (line) => {
    let m; try { m = JSON.parse(line); } catch { return; }
    if (m.id != null && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  });
  proc.stderr.on('data', () => {});
  const call = (method, params) => new Promise((res, rej) => {
    const i = ++id;
    const t = setTimeout(() => rej(new Error(`${method} 超时`)), 60000);
    pending.set(i, (m) => { clearTimeout(t); res(m); });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n');
  });
  return { proc, call };
}

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'lvhon-'));
const dataDir = path.join(HOME, '.localvault');

// ── 语料 ────────────────────────────────────────────────────────
// 每条都对应上面一个断言，不能随手改。
const PAD = '正文。'.repeat(400);              // 保证 ≥1024 字节
fs.mkdirSync(path.join(HOME, 'Desktop'), { recursive: true });
fs.mkdirSync(path.join(HOME, 'Downloads'), { recursive: true });

// 3 组同名（每组 2 个）→ 同名簇真值 = 3；同名文件跨两个根
for (const [i, n] of ['甲.md', '乙.md', '丙.md'].entries()) {
  fs.writeFileSync(path.join(HOME, 'Desktop', n), `# ${n}\n\n${PAD}\n${i}`);
  fs.writeFileSync(path.join(HOME, 'Downloads', n), `# ${n}\n\n${PAD}\n${i}`);
}
// 12 个「最近改动」文件，用来验 recent_changes 的真总数
for (let i = 0; i < 12; i++) {
  fs.writeFileSync(path.join(HOME, 'Desktop', `近${String(i).padStart(2, '0')}.md`), `# 近${i}\n\n${PAD}`);
}
// 被策略排除的
fs.writeFileSync(path.join(HOME, 'Desktop', '.env'), 'TOKEN=should-not-be-indexed\n');

// 一棵子目录，用来测 `list_directory` 的「直接子项」语义
fs.mkdirSync(path.join(HOME, 'Desktop', '深', '里'), { recursive: true });
fs.writeFileSync(path.join(HOME, 'Desktop', '深', 'a.md'), `# a\n\n${PAD}`);
fs.writeFileSync(path.join(HOME, 'Desktop', '深', '里', 'b.md'), `# b\n\n${PAD}`);

// 主根（桌面）里的**全部**条目 —— 同名文件与被策略排除的 `.env` 也是索引里的一行，
// 所以它们都该算进「共 N 条」。第一次只数了 `近*`，期望 12、实得 16，
// 那是**断言写错了**，不是工具错了。（这类「测试自己错」要先排除，再去改产品。）
//
// **必须递归数。** 原来是 `readdirSync(Desktop).length`，在「桌面下没有子目录」时
// 恰好等于文件数；一旦加了子目录它就少了 —— 而少的那部分会看起来像工具报错了。
// 测试自己算错，比工具算错更难发现。
function countFilesRecursive(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    n += e.isDirectory() ? countFilesRecursive(path.join(dir, e.name)) : 1;
  }
  return n;
}
const RECENT_TOTAL = countFilesRecursive(path.join(HOME, 'Desktop'));   // 12 + 3 + 1 + 2 = 18
const LIST_DIR_TOTAL = RECENT_TOTAL;

function runCli(args) {
  return spawnSync(process.execPath, [CLI, ...args], {
    env: { ...process.env, HOME, CFFIXED_USER_HOME: HOME },
    encoding: 'utf8',
  });
}

console.log('工具诚实性（返回的数字必须是真的数字）');
console.log('');

const ci = runCli(['init']);
const cx = runCli(['index']);
if (ci.status !== 0 || cx.status !== 0) {
  console.log(`  ✗ 夹具建不起来：init=${ci.status} index=${cx.status}`);
  console.log((ci.stderr || '') + (cx.stderr || ''));
  process.exit(1);
}

(async () => {
  const { proc, call } = connect(dataDir, HOME);
  await call('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'honesty', version: '1' } });
  proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const tool = async (name, args) => {
    const r = await call('tools/call', { name, arguments: args });
    return r.result?.content?.[0]?.text ?? '';
  };

  // ── 1. 同名簇：它是计数，不该随 limit 变 ─────────────────────
  //
  // 这一条的形状是关键：**同一个量在两个不同 limit 下必须相等**。
  // 修之前它是 min(候选数, limit)，所以 limit=1 报 1、limit=25 报 25 ——
  // 越看越像统计值，实际是参数的回声。
  {
    const j1 = JSON.parse(await tool('vault_audit', { checks: 'duplicates', format: 'json', limit: 1 }));
    const j25 = JSON.parse(await tool('vault_audit', { checks: 'duplicates', format: 'json', limit: 25 }));
    const s1 = j1.summary ?? j1.checks?.[0]?.summary;
    const s25 = j25.summary ?? j25.checks?.[0]?.summary;
    check('vault_audit 的 json 里有同名簇计数', s1 && typeof s1.sameNameGroups === 'number',
      s1 ? `sameNameGroups=${s1.sameNameGroups}` : '拿不到 summary');
    check('同名簇计数不随 limit 变（修前：limit=1→1，limit=25→25）',
      s1 && s1.sameNameGroups === s25.sameNameGroups,
      `limit=1 → ${s1?.sameNameGroups}；limit=25 → ${s25?.sameNameGroups}`);
    check('同名簇计数等于夹具真值', s25?.sameNameGroups === 3,
      `报 ${s25?.sameNameGroups}，真值 3`);
    check('「列了几个」与「一共有几个」分得开',
      typeof s25?.sameNameShown === 'number' && typeof s25?.sameNameCapped === 'boolean',
      `sameNameShown=${s25?.sameNameShown} sameNameCapped=${s25?.sameNameCapped}`);
  }

  // ── 2. recent_changes：「命中」不能再等于 LIMIT ───────────────
  {
    const t = await tool('recent_changes', { since: '7d', limit: 3 });
    check('recent_changes 报出真总数，而不是 limit',
      t.includes(`共 ${RECENT_TOTAL} 条`),
      `夹具真值 ${RECENT_TOTAL}；输出里找到的：「${(t.match(/共 \d+ 条/) || ['(没有「共 N 条」)'])[0]}」`);
    check('recent_changes 说清下面列了几条',
      /下面列出最近改动的 3 条/.test(t),
      '修前只有一个「命中 3 条」，读起来就是总数');
    check('recent_changes 提醒默认只查主根',
      /不传时只查主根/.test(t),
      '默认视图看不到其它根，这一点修前完全没写');
  }

  // ── 3. 被策略排除的文件：必须能与「真的没有」区分开 ──────────
  {
    const t = await tool('find_files', { query: '.env' });
    check('搜被排除的文件时，明说「按策略排除」而不是只说「没有命中」',
      /按策略排除|按策略/.test(t),
      t.split('\n').filter((l) => l.trim() && !l.startsWith('可以尝试')).slice(0, 4).join(' / '));
    check('   —— 并且解释了这不是故障',
      /这不是「索引坏了」/.test(t),
      '用户看到 0 条第一反应是「工具坏了」或「文件没了」');
    // 反向：一个真不存在的词，不该被说成「被排除」
    const t2 = await tool('find_files', { query: '这个词一定不存在xyzzy' });
    check('真的没有时，说「确实没有」而不是「被排除」',
      /索引里确实没有匹配的文件/.test(t2) && !/但有 \d+ 个文件是按策略排除的/.test(t2),
      '两种情况必须给出不同的答案');
  }

  // ── 4. 参数写错要出声 ─────────────────────────────────────────
  {
    const t = await tool('find_files', { query: '正文', root: '不存在的根', since: '昨天', sort: 'bogus' });
    check('假 root 被指出', /不对应任何索引根/.test(t));
    check('看不懂的 since 被指出', /看不懂/.test(t));
    check('非法 sort 被指出', /不是可用的排序/.test(t));
    check('三条提示同时出现（不是只报第一条）',
      /不对应任何索引根/.test(t) && /看不懂/.test(t) && /不是可用的排序/.test(t));
  }

  // ── 5. list_directory：真的列目录，不是「前缀下所有文件」 ────
  //
  // 修前它做的是 `path LIKE '目录/%'`，把整棵子树的文件平铺成一张表。
  // 在浅目录上看起来完全正常，在深目录上差几千行 —— 而且没有任何迹象。
  //
  // 这一节的关键判据是**同一个量在不同参数下必须一致**：
  // `totalDescendantFiles` 是「整棵子树一共几个文件」，它不该随 depth/limit 变。
  {
    const D = path.join(HOME, 'Desktop');
    const d1 = JSON.parse(await tool('list_directory', { path: D, depth: 1, format: 'json' }));
    const d2 = JSON.parse(await tool('list_directory', { path: D, depth: 2, format: 'json' }));
    const d3 = JSON.parse(await tool('list_directory', { path: D, depth: 3, format: 'json' }));
    const dL = JSON.parse(await tool('list_directory', { path: D, depth: 3, limit: 1, format: 'json' }));
    const dD = JSON.parse(await tool('list_directory', { path: D, depth: 1, dirs_only: true, format: 'json' }));

    check('depth=1 只给直接子项：恰好 1 个子目录（修前会平铺整棵树）',
      d1.returnedDirs === 1, `返回 ${d1.returnedDirs} 个：[${d1.dirs.map((x) => x.name).join(', ')}]`);
    // 判据写「rel 里一个斜杠都没有」而不是「不含 /深/」。
    //
    // 原来写的是 `f.rel.includes('/深/')` —— 而 rel 是**相对根目录**的，
    // 实际值是 `深/a.md`，它开头就是 `深/`，**根本不含 `/深/`**。
    // 于是断言永远成立：把实现改回「平铺整棵树」，测试照样全绿。
    // 这是这个测试自己的 bug，不是产品的。
    check('depth=1 的文件全是直接子项（rel 里不该出现任何 /）',
      d1.files.every((f) => !f.rel.includes('/')),
      d1.files.map((f) => f.rel).filter((r) => r.includes('/')).join(', '));
    check('depth=2 多出二级子目录「里」', d2.returnedDirs === 2,
      `返回 ${d2.returnedDirs} 个：[${d2.dirs.map((x) => x.name).join(', ')}]`);
    check('depth=3 才看得到最深那个文件', d3.files.some((f) => f.rel.endsWith('里/b.md')),
      d3.files.map((f) => f.rel).join(', '));

    check('子孙总数不随 depth 变（这修的正是「上限被当总数」）',
      d1.totalDescendantFiles === d2.totalDescendantFiles && d2.totalDescendantFiles === d3.totalDescendantFiles,
      `${d1.totalDescendantFiles} / ${d2.totalDescendantFiles} / ${d3.totalDescendantFiles}`);
    check('子孙总数等于夹具真值',
      d1.totalDescendantFiles === LIST_DIR_TOTAL,
      `报 ${d1.totalDescendantFiles}，真值 ${LIST_DIR_TOTAL}`);
    check('limit=1 时总数仍然是真总数（修前这里会变成 1）',
      dL.totalDescendantFiles === LIST_DIR_TOTAL && dL.returnedFiles === 1,
      `总数 ${dL.totalDescendantFiles} · 显示 ${dL.returnedFiles}`);
    check('dirs_only 只给目录、不给文件', dD.returnedDirs === 1 && dD.returnedFiles === 0,
      `目录 ${dD.returnedDirs} 文件 ${dD.returnedFiles}`);
    // 这里要能扛住 `dirs` 为空 —— 反向证明时它就是空的。
    // 不扛住的话测试会**崩**，而不是干净地报一条 ✗（崩也算失败，但看不出是哪个判据）。
    const d0 = d1.dirs[0];
    check('子目录带子孙文件数与占用（看得出哪个目录占地方）',
      Boolean(d0) && d0.fileCount === 2 && typeof d0.bytesText === 'string',
      d0 ? JSON.stringify(d0) : 'dirs 是空的（depth=1 应该至少给一个子目录）');

    // markdown 里也要说清「一共多少」，否则那张表会被当成全部
    const md = await tool('list_directory', { path: D, depth: 1 });
    check('markdown 里明说整棵子树共有多少（不是只有表格）',
      new RegExp(`整棵子树共有 ${LIST_DIR_TOTAL} 个文件`).test(md),
      md.split('\n').filter((l) => l.includes('共有')).join(' / ') || '（没找到）');
  }

  // ── 6. find_files 的总数、read_text 的 JSON ──────────────────
  {
    // 修前 searchFiles 根本没有 total：只报 returned，于是「返回 5 条」被当成命中数。
    const j5 = JSON.parse(await tool('find_files', { query: '正文', limit: 5, format: 'json' }));
    const j50 = JSON.parse(await tool('find_files', { query: '正文', limit: 50, format: 'json' }));
    check('find_files 的 json 里有 total', typeof j5.total === 'number', JSON.stringify(j5).slice(0, 200));
    check('total 不随 limit 变（这正是「上限不是总数」）',
      j5.total === j50.total, `limit=5 → ${j5.total}；limit=50 → ${j50.total}`);
    check('total ≥ returned', j5.total >= j5.returned, `total=${j5.total} returned=${j5.returned}`);

    const md5 = await tool('find_files', { query: '正文', limit: 5 });
    check('markdown 里把「共 N 条」和「显示 M 条」分开说',
      /共 \d+ 条/.test(md5) && /这里显示 5 条/.test(md5),
      md5.split('\n')[0]);

    // read_text：markdown 带行号（给人），json 给原样正文（给程序）
    const target = path.join(HOME, 'Desktop', '深', 'a.md');
    const mdT = await tool('read_text', { path: target });
    const jsT = JSON.parse(await tool('read_text', { path: target, format: 'json' }));
    check('markdown 版本带行号前缀（方便引用某行）', /^\s*1\| /m.test(mdT),
      mdT.split('\n').find((l) => l.includes('|')) || '（没有行号）');
    check('json 版本**不带**行号前缀（否则拿去解析必然失败）',
      !/^\s*1\| /m.test(jsT.content),
      JSON.stringify(jsT.content.slice(0, 80)));
    check('json 版本的正文是原样内容', jsT.content.startsWith('# a'),
      JSON.stringify(jsT.content.slice(0, 40)));
    check('json 里行号信息用字段给，不掺进正文',
      jsT.startLine === 1 && typeof jsT.totalLines === 'number' && typeof jsT.returnedLines === 'number',
      JSON.stringify({ startLine: jsT.startLine, totalLines: jsT.totalLines, returnedLines: jsT.returnedLines }));

    // 五个工具的 json 都必须是**合法 JSON**（不是「看起来像 JSON」）
    for (const [name, args] of [
      ['find_files', { query: '正文', format: 'json' }],
      ['find_project', { query: '甲', format: 'json' }],
      ['read_text', { path: target, format: 'json' }],
      ['list_directory', { path: path.join(HOME, 'Desktop'), format: 'json' }],
      ['recent_changes', { since: '7d', format: 'json' }],
    ]) {
      let ok = false; let why = '';
      try { const v = JSON.parse(await tool(name, args)); ok = Boolean(v) && typeof v === 'object'; }
      catch (e) { why = e.message; }
      check(`${name} 的 format=json 输出是合法 JSON`, ok, why);
    }
  }

  proc.kill('SIGKILL');
  console.log(`\n通过 ${pass} · 失败 ${fail}`);
  fs.rmSync(HOME, { recursive: true, force: true });
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.log(`  ✗ 测试本身出错：${e.message}`);
  fs.rmSync(HOME, { recursive: true, force: true });
  process.exit(1);
});
