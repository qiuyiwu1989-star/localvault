#!/usr/bin/env node
'use strict';

/**
 * 端到端冒烟测试。
 *
 * 在临时目录里造一个「迷你工作区」，跑真实索引、真实检索、真实治理体检，
 * 并用真实管道对 MCP 服务器做一次 JSON-RPC 握手与工具调用。
 *
 *   node test/smoke.js
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
let passed = 0;
let failed = 0;

function check(name, cond, detail) {
  if (cond) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.log(`  ✗ ${name}${detail ? ' —— ' + detail : ''}`);
  }
}

function section(title) {
  console.log(`\n${title}`);
}

/* ------------------------------------------------------------------ *
 * 造测试工作区
 * ------------------------------------------------------------------ */

function buildFixture(dir) {
  const w = (rel, content) => {
    const abs = path.join(dir, rel);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, content, 'utf8');
    return abs;
  };

  w('00-从这里开始.md', [
    '# 从这里开始',
    '',
    '- [文件管理规则](协作资料/文件管理规则.md)',
    '- [一个坏链](协作资料/不存在的文件.md)',
    '- [项目台账](项目管理/01-项目台账.md)',
    '',
  ].join('\n'));

  w('协作资料/文件管理规则.md', [
    '# 文件管理方案',
    '',
    '## 日常规则',
    '',
    '1. **根目录不堆新文件。** 新文件明确归属就直接进对应目录。',
    '2. **按项目和用途分类，不按扩展名分类。**',
    '3. **一份内容，一个主要版本。**',
    '4. 持续更新的文档用固定名称，一次性报告用 YYYY-MM-DD-主题.md。',
    '',
    '## 其他',
    '',
    '1. 这段不该被抽成规则。',
    '',
  ].join('\n'));

  w('项目管理/01-项目台账.md', '# 项目管理台账\n\n| P001 | 演示项目 | 产品 |\n');

  w(
    '项目管理/项目台账.json',
    JSON.stringify(
      {
        baseline: '2026-09-28',
        scope: '测试',
        count_semantics: '测试用',
        projects: [
          {
            id: 'P001',
            group: '测试分组',
            name: '演示项目',
            kind: '产品',
            domains: ['demo.example.com'],
            repositories: ['demo/repo'],
            note: '这是一条测试备注',
            routes: [],
          },
          {
            id: 'P002',
            group: '测试分组',
            name: '另一个项目',
            kind: '公共能力',
            domains: ['other.example.com'],
            repositories: [],
            note: '',
            routes: [],
          },
        ],
      },
      null,
      2,
    ),
  );

  w('项目管理/项目卡片/P001.md', '# P001 · 演示项目\n\n这是项目卡片正文，提到语义检索与上下文注入。\n');
  w('项目管理/项目资料/P001-演示项目/方案.md', '# 演示项目方案\n\n本方案说明如何治理本地文件。\n');
  w('待整理/临时的东西.txt', '这是一个还没有归属的临时文件。\n');
  w('最终版-方案.md', '这是一个用「最终版」命名的文件。\n');
  w('dup-a.txt', '完全相同的正文内容 repeated content 12345\n');
  w('dup-b.txt', '完全相同的正文内容 repeated content 12345\n');
  w('输出/报告.md', '# 输出报告\n\n阶段性产出。\n');
  // 非文本资产：用来验证覆盖度报告能把它们分到「需要 OCR / 需要解包」档
  fs.mkdirSync(path.join(dir, '输出'), { recursive: true });
  fs.writeFileSync(path.join(dir, '输出/截图.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d]));
  fs.writeFileSync(path.join(dir, '输出/访谈录音.mp4'), Buffer.from([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]));
  fs.writeFileSync(path.join(dir, '输出/资料包.zip'), Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x14, 0x00]));
  w('.env', 'SECRET_TOKEN=should-never-be-indexed\n');
  w('node_modules/some-lib/index.js', 'module.exports = "should be skipped";\n');
  w('dist/bundle.js', 'console.log("machine generated");\n');
  w('.git/config', '[core]\n\trepositoryformatversion = 0\n');

  return dir;
}

/* ------------------------------------------------------------------ *
 * 运行子进程
 * ------------------------------------------------------------------ */

function runCli(fixture, dataDir, args, extraEnv) {
  const env = {
    ...process.env,
    LOCALVAULT_ROOTS: fixture,
    LOCALVAULT_DATA_DIR: dataDir,
    ...(extraEnv || {}),
  };
  delete env.LOCALVAULT_CONFIG;
  const res = spawnSync(process.execPath, [path.join(ROOT, 'cli.js'), ...args], {
    env,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  return res;
}

/* ------------------------------------------------------------------ *
 * MCP 管道测试
 * ------------------------------------------------------------------ */

function mcpSession(fixture, dataDir) {
  return new Promise((resolve, reject) => {
    const env = {
      ...process.env,
      LOCALVAULT_ROOTS: fixture,
      LOCALVAULT_DATA_DIR: dataDir,
    };
    delete env.LOCALVAULT_CONFIG;
    const child = spawn(process.execPath, [path.join(ROOT, 'server.js')], {
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let buf = '';
    const responses = new Map();
    const notifications = [];
    let stderr = '';

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buf += chunk;
      for (;;) {
        const i = buf.indexOf('\n');
        if (i < 0) break;
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch (e) {
          reject(new Error('服务器输出了非 JSON 内容：' + line.slice(0, 200)));
          return;
        }
        if (msg.id !== undefined && responses.has(msg.id)) {
          responses.get(msg.id)(msg);
          responses.delete(msg.id);
        } else {
          notifications.push(msg);
        }
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (c) => {
      stderr += c;
    });

    let nextId = 1;
    const send = (method, params, isNotification) => {
      const msg = { jsonrpc: '2.0', method };
      if (!isNotification) msg.id = nextId;
      if (params !== undefined) msg.params = params;
      const id = nextId;
      nextId += 1;
      const p = isNotification
        ? Promise.resolve(null)
        : new Promise((res, rej) => {
            const timer = setTimeout(() => rej(new Error(`请求超时：${method}`)), 30000);
            responses.set(id, (m) => {
              clearTimeout(timer);
              res(m);
            });
          });
      child.stdin.write(JSON.stringify(msg) + '\n');
      return p;
    };

    const cleanup = () => {
      try {
        child.stdin.end();
      } catch (_e) {
        /* ignore */
      }
      setTimeout(() => {
        try {
          child.kill('SIGKILL');
        } catch (_e) {
          /* ignore */
        }
      }, 300);
    };

    // 等服务器起来（stderr 里会有启动日志），再做握手。
    // 注意：这里不能关掉 stdin —— 会话要继续用。
    setTimeout(() => resolve({ send, stderr: () => stderr, notifications, cleanup }), 500);
  });
}

async function testMcp(fixture, dataDir) {
  section('MCP 协议（真实 stdio 管道）');
  const session = await mcpSession(fixture, dataDir);
  const { send } = session;

  const init = await send('initialize', {
    protocolVersion: '2026-07-28',
    capabilities: {},
    clientInfo: { name: 'smoke-test', version: '0.0.0' },
  });
  check('initialize 有 result', Boolean(init.result), JSON.stringify(init).slice(0, 300));
  check('protocolVersion 被协商', init.result && init.result.protocolVersion === '2026-07-28', init.result && init.result.protocolVersion);
  check('serverInfo.name = localvault', init.result && init.result.serverInfo && init.result.serverInfo.name === 'localvault');
  check('capabilities 声明 tools 与 resources', Boolean(init.result && init.result.capabilities && init.result.capabilities.tools && init.result.capabilities.resources));
  const instructions = (init.result && init.result.instructions) || '';
  check('instructions 非空', instructions.length > 50, `${instructions.length} 字符`);
  check('instructions 未超 32768 字节', Buffer.byteLength(instructions, 'utf8') <= 32768, `${Buffer.byteLength(instructions, 'utf8')} 字节`);
  check('instructions 注入了入口文档', instructions.includes('00-从这里开始.md'));
  check('instructions 注入了目录用途', instructions.includes('协作资料'));
  check('instructions 声明了只读边界', /只读/.test(instructions));

  await send('notifications/initialized', {}, true);

  const tools = await send('tools/list', {});
  const names = ((tools.result && tools.result.tools) || []).map((t) => t.name);
  check('tools/list 返回 10 个工具', names.length === 10, `实际 ${names.length}：${names.join(',')}`);
  for (const expected of ['vault_map', 'disk_coverage', 'find_files', 'find_project', 'read_text', 'list_directory', 'recent_changes', 'vault_audit', 'propose_organize', 'refresh_index']) {
    check(`工具 ${expected} 存在且带 inputSchema`, names.includes(expected) && Boolean(tools.result.tools.find((t) => t.name === expected).inputSchema));
  }

  const ping = await send('ping', {});
  check('ping 返回空结果', ping.result && typeof ping.result === 'object');

  const mapCall = await send('tools/call', { name: 'vault_map', arguments: {} });
  const mapText = mapCall.result && mapCall.result.content[0].text;
  check('vault_map 调通', Boolean(mapText) && mapText.includes('本地上下文地图'), (mapText || '').slice(0, 120));
  check('vault_map 列出了入口文档', (mapText || '').includes('00-从这里开始.md'));

  const searchCall = await send('tools/call', { name: 'find_files', arguments: { query: '治理' } });
  const searchText = searchCall.result && searchCall.result.content[0].text;
  check('中文 2 字子串检索命中', Boolean(searchText) && /命中|方案|规则/.test(searchText), (searchText || '').slice(0, 160));

  const projCall = await send('tools/call', { name: 'find_project', arguments: { query: 'demo.example.com' } });
  const projText = projCall.result && projCall.result.content[0].text;
  check('按域名反查项目', Boolean(projText) && projText.includes('P001') && projText.includes('演示项目'), (projText || '').slice(0, 160));

  const readCall = await send('tools/call', { name: 'read_text', arguments: { path: '项目管理/项目卡片/P001.md' } });
  const readText = readCall.result && readCall.result.content[0].text;
  check('read_text 读到正文', Boolean(readText) && readText.includes('上下文注入'));

  const denyCall = await send('tools/call', { name: 'read_text', arguments: { path: '.env' } });
  const denyText = denyCall.result && denyCall.result.content[0].text;
  check('.env 正文被拒绝', Boolean(denyText) && /敏感|拒绝|排除/.test(denyText), (denyText || '').slice(0, 120));

  const auditCall = await send('tools/call', { name: 'vault_audit', arguments: { checks: 'duplicates,naming,links,root_clutter' } });
  const auditText = auditCall.result && auditCall.result.content[0].text;
  check('vault_audit 调通', Boolean(auditText) && auditText.includes('文件治理体检报告'));
  check('检出完全重复文件', (auditText || '').includes('dup-a.txt'));
  check('检出「最终版」命名', (auditText || '').includes('最终版-方案.md'));
  check('检出断链', (auditText || '').includes('不存在的文件.md'));
  check('检出根目录散文件', (auditText || '').includes('最终版-方案.md'));

  const covCall = await send('tools/call', { name: 'disk_coverage', arguments: {} });
  const covText = covCall.result && covCall.result.content[0].text;
  check('disk_coverage 调通', Boolean(covText) && covText.includes('覆盖度报告'));
  check('disk_coverage 给出可搜正文占比', /个可搜正文（[\d.]+%）/.test(covText || ''));
  check('disk_coverage 按代价分层', (covText || '').includes('本来就不该变亮'));
  check('disk_coverage 把图片归到需要 OCR', (covText || '').includes('需要 OCR（图片）：**1** 个'));
  check('disk_coverage 把视频归到需要转录', (covText || '').includes('需要转录（音视频）：**1** 个'));
  check('disk_coverage 把压缩包归到需要解包', (covText || '').includes('需要解包（压缩包/安装包）：**1** 个'));
  const covJson = await send('tools/call', { name: 'disk_coverage', arguments: { format: 'json' } });
  const covObj = JSON.parse(covJson.result.content[0].text);
  check('disk_coverage json 有 totals', typeof covObj.totals.files === 'number' && covObj.totals.files > 0);
  check(
    'disk_coverage 分类之和等于总数',
    covObj.buckets.reduce((s, b) => s + b.files, 0) === covObj.totals.files,
    `${covObj.buckets.reduce((s, b) => s + b.files, 0)} vs ${covObj.totals.files}`,
  );

  const orgCall = await send('tools/call', { name: 'propose_organize', arguments: {} });
  const orgText = orgCall.result && orgCall.result.content[0].text;
  check('propose_organize 只出报告', Boolean(orgText) && orgText.includes('没有执行任何改动'));

  const resList = await send('resources/list', {});
  check('resources/list 返回 4 个资源', resList.result && resList.result.resources.length === 4);
  const tmpl = await send('resources/templates/list', {});
  check('resources/templates/list 有 file 模板', tmpl.result && tmpl.result.resourceTemplates.some((t) => t.uriTemplate.includes('vault://file/')));

  const resRead = await send('resources/read', { uri: 'vault://map' });
  check('resources/read vault://map 成功', resRead.result && resRead.result.contents[0].text.includes('本地上下文地图'));

  const resFile = await send('resources/read', { uri: 'vault://file/' + encodeURIComponent(path.join(fixture, '输出/报告.md')) });
  check('resources/read vault://file/... 成功', resFile.result && resFile.result.contents[0].text.includes('输出报告'), JSON.stringify(resFile.result || resFile).slice(0, 200));

  const bad = await send('tools/call', { name: 'no_such_tool', arguments: {} });
  check('未知工具返回 JSON-RPC 错误', Boolean(bad.error), JSON.stringify(bad).slice(0, 200));

  const badMethod = await send('no/such/method', {});
  check('未知方法返回 -32601', badMethod.error && badMethod.error.code === -32601);

  const clean = session.stderr().includes('已启动');
  check('stderr 有启动日志且 stdout 未被污染', clean);
  session.cleanup();
}

/* ------------------------------------------------------------------ *
 * 主流程
 * ------------------------------------------------------------------ */

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'localvault-smoke-'));
  const fixture = path.join(tmp, 'workspace');
  const dataDir = path.join(tmp, 'data');
  fs.mkdirSync(fixture, { recursive: true });
  fs.mkdirSync(dataDir, { recursive: true });
  buildFixture(fixture);

  console.log(`临时工作区：${fixture}`);
  console.log(`临时数据目录：${dataDir}`);

  section('doctor（环境自检）');
  {
    const res = runCli(fixture, dataDir, ['doctor']);
    const text = res.stdout + res.stderr;
    check('doctor 在索引前正确报出「尚未索引」', res.status === 1 && text.includes('索引还没建过'), `exit=${res.status}`);
    check('doctor 报告 SQLite 可用', text.includes('SQLite'));
  }

  section('index（真实索引构建）');
  {
    const res = runCli(fixture, dataDir, ['index']);
    const text = res.stdout + res.stderr;
    check('index 退出码 0', res.status === 0, `exit=${res.status}\n${text.slice(-1200)}`);
    check('index 报告扫描完成', text.includes('扫描完成'), text.slice(-400));
    check('index 刷新了 instructions', /instructions/.test(text));
  }

  section('doctor（索引之后应全部通过）');
  {
    const res = runCli(fixture, dataDir, ['doctor']);
    const text = res.stdout + res.stderr;
    check('doctor 通过', res.status === 0, `exit=${res.status}\n${text.slice(-800)}`);
    check('doctor 报告 instructions 字节数', /instructions：\d+ 字节/.test(text));
  }

  section('存储层断言');  {
    const { DatabaseSync } = require('node:sqlite');
    const db = new DatabaseSync(path.join(dataDir, 'vault.db'));
    const count = (sql, ...p) => Number(db.prepare(sql).get(...p).c);

    check('node_modules 被跳过', count("SELECT count(*) c FROM files WHERE path LIKE '%node_modules%'") === 0);
    check('dist 被跳过', count("SELECT count(*) c FROM files WHERE rel LIKE 'dist/%'") === 0);
    check('.git 被跳过', count("SELECT count(*) c FROM files WHERE rel LIKE '.git/%'") === 0);
    check('普通文件已入库', count('SELECT count(*) c FROM files') >= 10, `实际 ${count('SELECT count(*) c FROM files')}`);

    const env = db.prepare("SELECT denied, body FROM files WHERE name = '.env'").get();
    check('.env 记录为 denied', env && Number(env.denied) === 1);
    check('.env 正文为空', env && (env.body === '' || env.body == null), JSON.stringify(env));

    const rules = db.prepare("SELECT body FROM files WHERE name = '文件管理规则.md'").get();
    check('规则文件正文已抽取', rules && rules.body.includes('根目录不堆新文件'));

    const md = db.prepare("SELECT headings, title FROM files WHERE name = '00-从这里开始.md'").get();
    check('markdown 标题已抽取', md && md.title === '从这里开始', JSON.stringify(md));

    const symOrGone = count('SELECT count(*) c FROM files WHERE gone = 1');
    check('没有误标消失的文件', symOrGone === 0, `gone=${symOrGone}`);
    db.close();
  }

  section('CLI 检索与治理');
  {
    const s1 = runCli(fixture, dataDir, ['search', '治理']);
    check('search 命中中文子串', s1.status === 0 && /方案|规则/.test(s1.stdout), s1.stdout.slice(0, 300));

    const s2 = runCli(fixture, dataDir, ['search', 'repeated content']);
    check('search 命中正文', s2.status === 0 && /dup-/.test(s2.stdout), s2.stdout.slice(0, 300));

    const s3 = runCli(fixture, dataDir, ['search', '方案', '--ext', '.md']);
    check('search 支持 ext 过滤', s3.status === 0 && s3.stdout.includes('.md'), s3.stdout.slice(0, 200));

    const p1 = runCli(fixture, dataDir, ['project', 'P001']);
    check('project 按编号命中', p1.status === 0 && p1.stdout.includes('演示项目'), p1.stdout.slice(0, 300));

    const a1 = runCli(fixture, dataDir, ['audit', 'duplicates']);
    check('audit duplicates 检出重复', a1.status === 0 && a1.stdout.includes('dup-a.txt'));

    // inbox 是可选工作流：未配置时应当明确跳过，而不是谎报 0 个。
    const a2 = runCli(fixture, dataDir, ['audit', 'inbox']);
    check('audit inbox 未配置时明确跳过', a2.status === 0 && a2.stdout.includes('未配置，已跳过'), a2.stdout.slice(0, 400));

    // 配上 policy.inboxDir 后应当检出积压
    const cfgFile = path.join(dataDir, 'config.json');
    const cfgObj = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
    cfgObj.policy = { ...(cfgObj.policy || {}), inboxDir: '待整理' };
    fs.writeFileSync(cfgFile, JSON.stringify(cfgObj, null, 2) + '\n', 'utf8');
    const a2b = runCli(fixture, dataDir, ['audit', 'inbox']);
    check('audit inbox 配置后检出待整理', a2b.status === 0 && a2b.stdout.includes('临时的东西.txt'), a2b.stdout.slice(0, 400));
    // 复原，免得影响后续断言
    cfgObj.policy.inboxDir = null;
    fs.writeFileSync(cfgFile, JSON.stringify(cfgObj, null, 2) + '\n', 'utf8');

    const o1 = runCli(fixture, dataDir, ['organize']);
    check('organize 输出 dry-run 方案', o1.status === 0 && o1.stdout.includes('dry-run'));

    const c1 = runCli(fixture, dataDir, ['coverage']);
    check('coverage 输出覆盖度报告', c1.status === 0 && c1.stdout.includes('覆盖度报告'));
    const c2 = runCli(fixture, dataDir, ['coverage', '--json']);
    check('coverage --json 可解析', c2.status === 0 && (() => { try { return JSON.parse(c2.stdout).totals.files > 0; } catch (e) { return false; } })());

    const i1 = runCli(fixture, dataDir, ['instructions']);
    check('instructions 子命令可用', i1.status === 0 && i1.stdout.includes('localvault'));

    // 台账是自动发现的（fixture 没有配置 ledgerFile），所以顺带验证发现能力
    const l1 = runCli(fixture, dataDir, ['ledger']);
    check('ledger 自动发现并解析成功', l1.status === 0 && l1.stdout.includes('2 个') && l1.stdout.includes('auto'), l1.stdout.slice(0, 300));
  }

  section('增量更新');
  {
    const target = path.join(fixture, '项目管理/项目资料/P001-演示项目/新增.md');
    fs.writeFileSync(target, '# 新增文档\n\n这是后来加上的独一无二标记 ZZZUNIQUE。\n', 'utf8');
    const res = runCli(fixture, dataDir, ['index']);
    check('增量 index 退出码 0', res.status === 0);
    const s = runCli(fixture, dataDir, ['search', 'ZZZUNIQUE']);
    check('增量后能检索到新文件', s.status === 0 && s.stdout.includes('新增.md'), s.stdout.slice(0, 300));

    fs.unlinkSync(target);
    const res2 = runCli(fixture, dataDir, ['index']);
    check('删除文件后再次 index 成功', res2.status === 0);
    const s2 = runCli(fixture, dataDir, ['search', 'ZZZUNIQUE']);
    check('已删除文件不再命中（标记 gone）', s2.status === 0 && /→ 0 条/.test(s2.stdout), s2.stdout.slice(0, 200));
  }

  await testMcp(fixture, dataDir);

  section('通用性（不绑定特定机器/工作区）');
  {
    // 防回归守卫（源码文本层）：个人标识绝不该出现在源码任何地方。
    // 注意这里查的是「不该出现的东西」；像「待整理」这种词出现在注释或
    // 配置示例里是**对的** —— 用户需要看到怎么配。所以默认值那层改用行为断言。
    const forbidden = ['邱懿武', '/Users/Apple', 'Documents/邱懿武03'];
    const files = [];
    const walkDir = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walkDir(p);
        else if (e.name.endsWith('.js')) files.push(p);
      }
    };
    walkDir(path.join(ROOT, 'lib'));
    files.push(path.join(ROOT, 'cli.js'));

    const leaks = [];
    for (const f of files) {
      const text = fs.readFileSync(f, 'utf8');
      text.split('\n').forEach((line, i) => {
        for (const bad of forbidden) {
          if (line.includes(bad)) leaks.push(`${path.relative(ROOT, f)}:${i + 1} 出现「${bad}」`);
        }
      });
    }
    check('lib/ 与 cli.js 不含个人标识', leaks.length === 0, leaks.slice(0, 6).join('\n'));

    // 防回归守卫（默认值行为层）：这是「通用化」真正的验收标准。
    const defaultProbe = spawnSync(process.execPath, ['-e', `
      const {defaultConfig}=require('${path.join(ROOT, 'lib/config.js')}');
      process.stdout.write(JSON.stringify(defaultConfig()));
    `], { encoding: 'utf8' });
    let def = null;
    try { def = JSON.parse(defaultProbe.stdout); } catch (e) { /* 保持 null */ }
    check('defaultConfig() 可求值', def !== null, defaultProbe.stderr.slice(0, 300));
    if (def) {
      check('默认不含个人台账/规则路径', def.ledgerFile === null && def.rulesFile === null, JSON.stringify({ l: def.ledgerFile, r: def.rulesFile }));
      check('默认不含个人入口文档与目录用途', def.canonicalDocs.length === 0 && Object.keys(def.dirNotes).length === 0);
      check('默认不含个人收集目录与卡片目录', def.policy.inboxDir === null && def.policy.projectCardDir === null);
      check('默认根不写死任何具体路径（只探测系统目录）',
        def.roots.every((r) => !String(r.path).includes('邱懿武')), JSON.stringify(def.roots));
      check('治理词表可配置且非空', Array.isArray(def.policy.versionNamePatterns) && def.policy.versionNamePatterns.length > 0);
    }

    // 零配置时默认根只来自系统目录探测，root 必须真实存在
    const cfgProbe = spawnSync(process.execPath, ['-e', `
      const {loadConfig}=require('${path.join(ROOT, 'lib/config.js')}');
      const c=loadConfig();
      const out={roots:c.roots.map(r=>r.path),version:c.version,canonicalDocs:c.canonicalDocs.length,ledgerFile:c.ledgerFile,rulesFile:c.rulesFile,inboxDir:c.policy.inboxDir};
      process.stdout.write(JSON.stringify(out));
    `], {
      env: { ...process.env, LOCALVAULT_CONFIG: path.join(tmp, 'nonexistent-config.json') },
      encoding: 'utf8',
    });
    let probe = null;
    try { probe = JSON.parse(cfgProbe.stdout); } catch (e) { /* 保持 null */ }
    check('零配置可加载（不依赖任何已有配置）', probe !== null, cfgProbe.stderr.slice(0, 300));
    if (probe) {
      check('零配置默认根全部真实存在', probe.roots.length > 0 && probe.roots.every((p) => {
        try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
      }), JSON.stringify(probe.roots));
      check('零配置不含个人台账/规则/收集目录', probe.ledgerFile === null && probe.rulesFile === null && probe.inboxDir === null, JSON.stringify(probe));
      check('零配置的入口文档为空（应靠自动发现）', probe.canonicalDocs === 0);
    }

    // setup-dsh 生成的补丁必须能被解析成合法结构
    const setupOut = path.join(tmp, 'setup-dsh-out');
    const sd = runCli(fixture, dataDir, ['setup-dsh', '--out', setupOut]);
    check('setup-dsh 退出码 0', sd.status === 0, sd.stderr.slice(0, 300));
    const patchFile = path.join(setupOut, 'cordis.patch.yml');
    check('setup-dsh 生成 cordis.patch.yml', fs.existsSync(patchFile));
    if (fs.existsSync(patchFile)) {
      const y = fs.readFileSync(patchFile, 'utf8');
      check('补丁内含本机绝对路径（而非写死的路径）',
        y.includes(path.join(ROOT, 'server.js')) && y.includes("command: !!js process.execPath"));
      // 补丁里出现工具自身的安装路径是对的（它必须指向本机装在哪）；
      // 不该出现的是「把某个工作区写死成索引根」。
      check('补丁不把任何工作区写死成索引根', !/roots\s*:/.test(y) && !y.includes('LOCALVAULT_ROOTS'));
    }
  }

  section('结果');
  console.log(`  通过 ${passed} 项，失败 ${failed} 项`);
  if (failed === 0) {
    console.log(`\n全部通过。临时目录：${tmp}`);
    console.log('（可用 rm -rf 清理）');
  } else {
    console.log(`\n有失败项。临时目录保留以便排查：${tmp}`);
  }
  process.exitCode = failed === 0 ? 0 : 1;
}

main().catch((e) => {
  console.error('测试崩溃：', (e && e.stack) || e);
  process.exitCode = 1;
});
