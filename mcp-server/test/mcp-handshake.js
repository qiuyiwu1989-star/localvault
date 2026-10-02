#!/usr/bin/env node
'use strict';
/**
 * MCP 握手验收 —— 把 `接进-agent.md` 里那句承诺变成会自动失败的断言。
 *
 * 文档承诺了两件事：
 *   1. 照它写就能起一个 stdio 服务器，`tools/list` 列出 **10 个工具**
 *   2. 其中至少一个能**成功调一次**（不是「列出来了」就算通）
 *
 * 为什么值得单独一个测试：这两件事以前**没有任何东西守着**。
 * 文档是手写的，工具是手写的，两边谁先漂了都不会有人吭声 ——
 * 等用户照着接、发现是空的，才发现。而那时候他已经在怀疑自己的配置了。
 *
 * 这个测试走的是**真实的 stdio 通道**（跟客户端一模一样），
 * 不是直接 require 模块调函数 —— 因为会出问题的恰恰是中间那一层。
 *
 * 全程在假 HOME 里跑，不碰真实的 ~/.localvault。
 */

const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const ROOT = path.join(__dirname, '..');
const SERVER = path.join(ROOT, 'server.js');

let pass = 0;
let fail = 0;
const note = (s) => console.log(`  · ${s}`);

function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  ✓ ${name}${detail ? '  — ' + detail : ''}`); }
  else { fail++; console.log(`  ✗ ${name}${detail ? '  — ' + detail : ''}`); }
}

/** 起一个真服务器，用 JSON-RPC 跟它对话。返回一个 call()。 */
function connect(dataDir) {
  const proc = spawn(process.execPath, [SERVER], {
    env: { ...process.env, LOCALVAULT_DATA_DIR: dataDir },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stderr = '';
  proc.stderr.on('data', (d) => { stderr += d.toString(); });

  const rl = readline.createInterface({ input: proc.stdout });
  const pending = new Map();
  let nextId = 0;
  const stray = [];

  rl.on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch {
      // stdout 是协议通道。非 JSON 的东西出现在上面，本身就是缺陷 —— 记下来。
      stray.push(line);
      return;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  });

  const call = (method, params) => new Promise((resolve, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => reject(new Error(`等 ${method} 超时`)), 20000);
    pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });

  const notify = (method, params) => {
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  };

  return { proc, call, notify, stray, stderrText: () => stderr };
}

(async () => {
  console.log('MCP 握手验收');
  console.log('');

  // ── 在假 HOME 里建一份最小索引 ────────────────────────────────
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'lv-handshake-'));
  fs.mkdirSync(path.join(home, 'Desktop'), { recursive: true });
  fs.mkdirSync(path.join(home, 'Downloads'), { recursive: true });
  fs.writeFileSync(path.join(home, 'Desktop', '说明.md'),
    '# 说明\n\n这是本地上下文的手握验收语料。\n本地上下文再出现一次，好让检索有命中。\n');
  const dataDir = path.join(home, '.localvault');

  const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, LOCALVAULT_DATA_DIR: dataDir };
  const init = spawnSync(process.execPath, [path.join(ROOT, 'cli.js'), 'init'], { env, encoding: 'utf8' });
  check('cli init 退出码 0', init.status === 0, init.stderr.slice(0, 200));
  const idx = spawnSync(process.execPath, [path.join(ROOT, 'cli.js'), 'index'], { env, encoding: 'utf8' });
  check('cli index 退出码 0', idx.status === 0, idx.stderr.slice(0, 200));

  const c = connect(dataDir);
  try {
    // ── 握手 ────────────────────────────────────────────────────
    const initRes = await c.call('initialize', {
      protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'handshake', version: '1' },
    });
    check('initialize 返回 serverInfo.name = localvault',
      initRes.result && initRes.result.serverInfo && initRes.result.serverInfo.name === 'localvault',
      JSON.stringify(initRes.result && initRes.result.serverInfo));
    c.notify('notifications/initialized', {});

    // ── 工具清单：文档承诺 10 个 ───────────────────────────────────
    const tools = await c.call('tools/list', {});
    const toolList = (tools.result && tools.result.tools) || [];
    const names = toolList.map((t) => t.name);

    // 这份名单是 `接进-agent.md` 里那张表的**逐字对应**。
    // 一边改了另一边没改 → 这条红。文档与代码谁先漂都会被抓住。
    const EXPECTED = ['vault_map', 'disk_coverage', 'find_files', 'find_project', 'read_text',
      'list_directory', 'recent_changes', 'vault_audit', 'propose_organize', 'refresh_index'];
    check('tools/list 恰好 10 个工具（与接进-agent.md 的表一致）',
      names.length === EXPECTED.length, `实际 ${names.length}：${names.join(', ')}`);
    check('工具名单与文档里的那张表逐字相同',
      JSON.stringify(names) === JSON.stringify(EXPECTED),
      names.filter((n) => !EXPECTED.includes(n)).length
        ? `文档里没有：${names.filter((n) => !EXPECTED.includes(n)).join(', ')}`
        : '');
    check('每个工具都有 description 与 inputSchema',
      // 非空前提不能省：空数组上 `.every()` 恒真 —— 一个「工具列表变成空」的回归
      // 会在这里伪装成「每条描述都齐全」。守卫和接收者用同一个变量，
      // 静态扫描器（scripts/check-assertions.py）才看得见这个前提。
      toolList.length > 0 && toolList.every((t) => t.description && t.inputSchema),
      '缺描述的工具需要补，否则 agent 不知道该用它');

    // ── 资源与模板 ──────────────────────────────────────────────
    const res = await c.call('resources/list', {});
    const uris = ((res.result && res.result.resources) || []).map((r) => r.uri);
    check('resources/list 有 4 个资源', uris.length === 4, uris.join(', '));
    check('vault://map 在资源里（文档让用户第一句就读它）', uris.includes('vault://map'));

    const tpl = await c.call('resources/templates/list', {});
    const templates = ((tpl.result && tpl.result.resourceTemplates) || []).map((t) => t.uriTemplate);
    check('resources/templates/list 有 vault://file/{path}',
      templates.includes('vault://file/{path}'), templates.join(', '));

    // ── 真的调一次（这才是「接通了」）────────────────────────────
    // 「列得出来」和「调得通」是两件事。只测前者会漏掉一整个类别的故障。
    const map = await c.call('tools/call', { name: 'vault_map', arguments: {} });
    const mapText = (map.result && map.result.content && map.result.content[0] && map.result.content[0].text) || '';
    check('调 vault_map 有内容返回', mapText.length > 100, `${mapText.length} 字符`);
    check('vault_map 返回的是地图（不是错误消息）',
      mapText.includes('本地上下文地图'), mapText.slice(0, 80).replace(/\n/g, ' / '));
    check('vault_map 没有把这次调用当失败返回',
      !map.result || map.result.isError !== true, JSON.stringify(map.result && map.result.isError));

    const found = await c.call('tools/call', { name: 'find_files', arguments: { query: '本地上下文' } });
    const foundText = (found.result && found.result.content && found.result.content[0] && found.result.content[0].text) || '';
    check('调 find_files 能找到刚建的那个文件', foundText.includes('说明.md'), foundText.slice(0, 120).replace(/\n/g, ' / '));

    // ── stdout 纪律 ─────────────────────────────────────────────
    // stdout 是协议通道。混进任何非 JSON 的东西，客户端就会解析失败。
    check('stdout 上除了 JSON-RPC 帧没有别的东西', c.stray.length === 0,
      c.stray.slice(0, 3).join(' | '));
    // 反过来也要守：协议帧不许漏进 stderr。
    // （写这一条时我先写过 `check(..., true, ...)` —— 正是本项目在修的恒真断言。
    //   它连「stderr 有没有东西」都答不了，等于没写。改成能失败的形状。）
    check('协议帧没有漏进 stderr', !c.stderrText().includes('"jsonrpc"'),
      c.stderrText().slice(0, 200));

    // ── 未知工具要明确报错，不能假装成功 ────────────────────────
    const bogus = await c.call('tools/call', { name: '这不存在的工具', arguments: {} });
    check('调不存在的工具会被明确报错（不是静默返回空）',
      bogus.error !== undefined || (bogus.result && bogus.result.isError === true),
      JSON.stringify(bogus.error || (bogus.result && bogus.result.isError)));
  } catch (e) {
    fail++;
    console.log(`  ✗ 握手过程抛异常：${e.message}`);
    console.log(`    stderr：${c.stderrText().slice(0, 400)}`);
  } finally {
    c.proc.kill('SIGKILL');
  }

  fs.rmSync(home, { recursive: true, force: true });

  console.log('');
  console.log(`  结果`);
  console.log(`    通过 ${pass} 项，失败 ${fail} 项`);
  console.log('');
  process.exit(fail === 0 ? 0 : 1);
})();
