#!/usr/bin/env node
'use strict';


/** node:sqlite 需要 Node >= 22.5；低于此版本给出明确提示而不是崩溃。 */
(function requireModernNode() {
  const [maj, min] = process.versions.node.split('.').map(Number);
  if (maj > 22 || (maj === 22 && min >= 5)) return;
  process.stderr.write(
    `localvault 需要 Node >= 22.5（当前 ${process.version}）。\n` +
      '原因：内置 node:sqlite。请升级 Node，或用 DSH 自带的运行时。\n',
  );
  process.exit(2);
})();

/**
 * localvault 命令行工具。索引构建、体检、以及安装前后的自检都走这里。
 *
 *   node cli.js index [--full] [--root <path>]
 *   node cli.js reindex-cache
 *   node cli.js map
 *   node cli.js instructions
 *   node cli.js search <关键词...>
 *   node cli.js project <关键词>
 *   node cli.js audit [all|duplicates,stale,...]
 *   node cli.js organize
 *   node cli.js coverage [--json]
 *   node cli.js doctor
 */

const originalEmitWarning = process.emitWarning;
process.emitWarning = function emitWarningFiltered(warning, ...rest) {
  const text = typeof warning === 'string' ? warning : (warning && warning.message) || '';
  const type = typeof rest[0] === 'string' ? rest[0] : rest[0] && rest[0].type;
  if (type === 'ExperimentalWarning' && /SQLite/i.test(text)) return undefined;
  return originalEmitWarning.call(process, warning, ...rest);
};

const fs = require('node:fs');
const path = require('node:path');

const { loadConfig, writeDefaultConfigIfMissing } = require('./lib/config');
const { openDatabase, getMeta, setMeta, setMetaJson, recentScanRuns } = require('./lib/store');
const { buildIndex, describeScanSummary } = require('./lib/indexer');
const { buildMap, renderMapMarkdown, renderInstructions, findProject, loadLedger } = require('./lib/vault');
const { searchFiles } = require('./lib/search');
const { audit, proposeOrganize } = require('./lib/governance');
const { computeCoverage } = require('./lib/coverage');
const { toPosix, formatBytes, formatDate, expandHome, compressHome, ensureDir } = require('./lib/util');
const { dataDir } = require('./lib/config');

const QUIET = process.env.LOCALVAULT_QUIET === '1';

function out(...args) {
  if (QUIET) return;
  process.stdout.write(args.join(' ') + '\n');
}
function errOut(...args) {
  process.stderr.write(args.join(' ') + '\n');
}

function parseArgv(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) {
        flags[key] = next;
        i += 1;
      } else {
        flags[key] = true;
      }
    } else {
      positional.push(a);
    }
  }
  return { positional, flags };
}

function open() {
  const cfg = loadConfig();
  const created = writeDefaultConfigIfMissing(cfg);
  const db = openDatabase(cfg.dbPath);
  return { cfg, db, created };
}

function refreshCaches(cfg, db) {
  const map = buildMap(db, cfg);
  setMetaJson(db, 'map', { ...map, _cachedAt: Date.now() });
  const instructions = renderInstructions(map, cfg);
  setMeta(db, 'instructions', instructions);
  return { map, instructions };
}

/* ------------------------------------------------------------------ */

const COMMANDS = {
  /**
   * 首次配置。通用软件靠这一步「适配这台机器」，而不是靠代码里写死路径。
   * 幂等：已有配置时只报告，不覆盖（除非 --force）。
   */
  init(args) {
    const os = require('node:os');
    const { defaultRoots } = require('./lib/config');

    const rootFlags = args.positional.length ? args.positional : [];
    const dataDirAbs = dataDir({ dataDir: process.env.LOCALVAULT_DATA_DIR || '~/.localvault' });
    const file = path.join(dataDirAbs, 'config.json');
    const exists = fs.existsSync(file);

    const chosen = rootFlags.length
      ? rootFlags.map((s, i) => {
          const idx = s.lastIndexOf(':');
          const hasLabel = idx > 0 && !/^[A-Za-z]$/.test(s.slice(idx + 1, idx + 2));
          const p = hasLabel ? s.slice(0, idx) : s;
          const label = hasLabel ? s.slice(idx + 1) : path.basename(p) || `根${i + 1}`;
          return { path: path.resolve(expandHome(p)), label, priority: 10 + i * 10 };
        })
      : defaultRoots();

    out('# localvault 初始化');
    out('');
    out(`配置位置：${toPosix(file)}`);
    out(`数据目录：${toPosix(dataDirAbs)}`);
    out(`系统主目录：${toPosix(os.homedir())}`);
    out('');

    if (exists && !args.flags.force) {
      const cur = loadConfig();
      out('配置**已存在**，未改动。');
      out('');
      out(`当前索引根（${cur.roots.length} 个）：`);
      for (const r of cur.roots) {
        let ok = false;
        try {
          ok = fs.statSync(r.path).isDirectory();
        } catch (_e) { /* 不存在 */ }
        out(`  - ${r.label}：${toPosix(r.path)}${ok ? '' : '  ⚠️ 路径不存在'}`);
      }
      const missing = cur.roots.filter((r) => {
        try { return !fs.statSync(r.path).isDirectory(); } catch (_e) { return true; }
      });
      out('');
      if (missing.length) {
        out(`⚠️ 有 ${missing.length} 个索引根不存在（外置盘未接？）。改配置或重新插盘后重跑 index。`);
      } else {
        out('全部索引根存在。下一步：`localvault index`。');
      }
      out('');
      out('要覆盖重写，跑 `localvault init --force`。');
      return 0;
    }

    if (!chosen.length) {
      errOut('没有探测到任何可用目录，且未指定 --root。');
      errOut('用法：localvault init ~/Documents/我的项目:工作区 ~/Desktop:桌面');
      return 1;
    }

    out('拟写入的索引根：');
    for (const r of chosen) out(`  - ${r.label}：${toPosix(r.path)}`);
    out('');

    if (exists) {
      const bak = file + '.bak-' + new Date().toISOString().replace(/[-:T]/g, '').slice(0, 15);
      fs.copyFileSync(file, bak);
      out(`原配置已备份：${toPosix(bak)}`);
    }

    // 用 loadConfig 规范化后再落盘，保证写出来的就是运行时真正会用的那份
    const cfg = loadConfig({
      roots: chosen.map((r) => ({ ...r, path: compressHome(r.path) })),
      primaryRoot: compressHome(chosen[0].path),
    });
    ensureDir(dataDirAbs);
    const snapshot = require('./lib/config').defaultConfig();
    snapshot.roots = cfg.roots.map((r) => ({ ...r, path: compressHome(r.path) }));
    snapshot.dataDir = cfg.dataDir;
    snapshot.primaryRoot = compressHome(cfg.primaryRoot);
    fs.writeFileSync(file, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
    out(`已写入配置：${toPosix(file)}`);
    out('');
    out('下一步：');
    out('  1. localvault index        建索引（首次约几秒到几分钟）');
    out('  2. localvault coverage     看看覆盖度，判断值不值得治理');
    out('  3. localvault setup-dsh    接入 DSH（可选）');
    out('');
    out('要加更多根目录，编辑配置文件里的 roots，或重跑 `init --force`。');
    return 0;
  },

  /**
   * 为这台机器生成 DSH 插件补丁。路径只能在装机时确定，
   * 所以这一步是「配置」，不是「硬编码」。
   */
  'setup-dsh'(args) {
    const selfDir = __dirname;
    const serverJs = path.join(selfDir, 'server.js');
    const outDir = args.flags.out ? path.resolve(expandHome(String(args.flags.out)))
      : path.join(selfDir, '..', 'bundle');
    const dataDirAbs = dataDir({ dataDir: process.env.LOCALVAULT_DATA_DIR || '~/.localvault' });
    const yaml = `# 由 \`localvault setup-dsh\` 生成（${new Date().toISOString()}）
# 路径是这台机器的绝对路径 —— 每台机器跑一次即可。
- insert:
    - id: localvault-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: localvault
        transport: stdio
        command: !!js process.execPath
        args:
          - '${serverJs}'
        cwd: '${selfDir}'
        env:
          ELECTRON_RUN_AS_NODE: '1'
          LOCALVAULT_DATA_DIR: '${toPosix(dataDirAbs)}'
        toolCallTimeoutMs: 120000
        failOnStartupError: true
        reconnect:
          enabled: true
          maxAttempts: 5
`;
    ensureDir(outDir);
    const patch = path.join(outDir, 'cordis.patch.yml');
    const pkg = path.join(outDir, 'package.json');
    fs.writeFileSync(patch, yaml, 'utf8');
    if (!fs.existsSync(pkg)) {
      fs.writeFileSync(pkg, JSON.stringify({
        name: '@local/localvault-bundle',
        version: require('./package.json').version,
        private: true,
        type: 'module',
        dsh: { bundle: { patch: './cordis.patch.yml' } },
      }, null, 2) + '\n', 'utf8');
    }
    out('已生成本机插件补丁：');
    out(`  ${toPosix(patch)}`);
    out('');
    out('在 DSH 里：Plugins → Add plugin → 粘贴下面这行 → Enable now');
    out('');
    out(`  ${toPosix(outDir)}`);
    return 0;
  },

  index(args) {
    const { cfg, db } = open();
    const full = Boolean(args.flags.full);
    const roots = args.flags.root ? String(args.flags.root).split(',') : null;

    out(`索引根：${cfg.roots.map((r) => `${r.label}(${toPosix(r.path)})`).join('  ')}`);
    out(full ? '模式：全量重建' : '模式：增量更新');
    out('');

    let last = 0;
    const summary = buildIndex(cfg, db, {
      full,
      roots,
      onProgress: (p) => {
        const now = Date.now();
        if (now - last < 3000) return;
        last = now;
        out(`  … 已扫描 ${p.seen} 个文件，抽取 ${p.extracted}，复用 ${p.reused}`);
      },
    });

    out(describeScanSummary(summary));
    const { instructions } = refreshCaches(cfg, db);
    out('');
    out(`已刷新地图与 instructions（${Buffer.byteLength(instructions, 'utf8')} 字节，上限 32768）。`);
    return 0;
  },

  'reindex-cache'() {
    const { cfg, db } = open();
    const { map, instructions } = refreshCaches(cfg, db);
    out(`地图已刷新：${map.totalFiles} 个文件 / ${map.totalBytesText}`);
    out(`instructions 已写入：${Buffer.byteLength(instructions, 'utf8')} 字节`);
    return 0;
  },

  map() {
    const { cfg, db } = open();
    process.stdout.write(renderMapMarkdown(buildMap(db, cfg), cfg) + '\n');
    return 0;
  },

  instructions() {
    const { cfg, db } = open();
    const cached = getMeta(db, 'instructions');
    if (cached) {
      process.stdout.write(cached + '\n');
      process.stderr.write(`\n[字节数 ${Buffer.byteLength(cached, 'utf8')} / 上限 32768]\n`);
      return 0;
    }
    const { instructions } = refreshCaches(cfg, db);
    process.stdout.write(instructions + '\n');
    return 0;
  },

  search(args) {
    const { cfg, db } = open();
    const q = args.positional.join(' ');
    const res = searchFiles(db, cfg, {
      query: q,
      limit: Number(args.flags.limit) || 30,
      kind: args.flags.kind,
      ext: args.flags.ext,
      root: args.flags.root,
      pathPrefix: args.flags.path,
      since: args.flags.since,
      sort: args.flags.sort,
    });
    if (!res.ok) {
      errOut('检索失败：' + res.error);
      return 1;
    }
    out(`「${q || '(空)'}」→ ${res.returned} 条${res.hasMore ? '（更多）' : ''}，${res.tookMs}ms`);
    out('');
    for (const h of res.hits) {
      out(`${h.matchedIn.join('/').padEnd(18)} ${h.date}  ${h.sizeText.padStart(9)}  ${h.rel}`);
      if (h.snippet) out(`    ${h.snippet.slice(0, 160)}`);
    }
    return 0;
  },

  project(args) {
    const { cfg, db } = open();
    const res = findProject(cfg, db, args.positional.join(' '), Number(args.flags.limit) || 8);
    if (!res.ok) {
      errOut(res.error);
      return 1;
    }
    out(`反查「${res.query}」→ ${res.candidates.length} 个候选`);
    for (const c of res.candidates) {
      out('');
      out(`- ${c.id || '-'} ${c.name}  [${c.matchedBy.join('；')}]`);
      if (c.group) out(`    分组：${c.group}　类型：${c.kind || '-'}`);
      if (c.domains.length) out(`    域名：${c.domains.join('、')}`);
      if (c.card) out(`    卡片：${c.card.rel}`);
      if (c.folder) out(`    资料：${c.folder}`);
    }
    return 0;
  },

  audit(args) {
    const { cfg, db } = open();
    const res = audit(db, cfg, {
      checks: args.positional[0] || 'all',
      limit: Number(args.flags.limit) || undefined,
      days: Number(args.flags.days) || undefined,
    });
    process.stdout.write(res.markdown + '\n');
    return 0;
  },

  organize(args) {
    const { cfg, db } = open();
    const res = proposeOrganize(db, cfg, { limit: Number(args.flags.limit) || 25 });
    process.stdout.write(res.markdown + '\n');
    return 0;
  },

  coverage(args) {
    const { cfg, db } = open();
    const res = computeCoverage(db, cfg);
    if (args.flags.json) {
      const { markdown, ...rest } = res;
      process.stdout.write(JSON.stringify(rest, null, 2) + '\n');
    } else {
      process.stdout.write(res.markdown + '\n');
    }
    return 0;
  },

  doctor() {
    const cfg = loadConfig();
    const problems = [];
    const notes = [];

    notes.push(`Node：${process.version}（${process.execPath}）`);
    try {
      const { DatabaseSync } = require('node:sqlite');
      const t = new DatabaseSync(':memory:');
      const v = t.prepare('SELECT sqlite_version() AS v').get();
      notes.push(`SQLite：${v.v}（node:sqlite 可用）`);
      try {
        t.exec("CREATE VIRTUAL TABLE x USING fts5(a)");
        notes.push('FTS5：可用（本实现未使用，检索走 LIKE 子串匹配）');
      } catch (_e) {
        notes.push('FTS5：不可用（无影响）');
      }
      t.close();
    } catch (e) {
      problems.push(`node:sqlite 不可用：${e.message}`);
    }

    notes.push(`配置：${toPosix(cfg.configFile)}${fs.existsSync(cfg.configFile) ? '（存在）' : '（不存在，将使用默认值）'}`);
    notes.push(`索引库：${toPosix(cfg.dbPath)}${fs.existsSync(cfg.dbPath) ? `（${formatBytes(fs.statSync(cfg.dbPath).size)}）` : '（尚未建立）'}`);

    for (const r of cfg.roots) {
      let ok = false;
      let detail = '';
      try {
        const st = fs.statSync(r.path);
        ok = st.isDirectory();
        detail = ok ? '目录存在' : '不是目录';
      } catch (e) {
        detail = `不可读（${e.code || e.message}）`;
      }
      notes.push(`根 ${r.label}：${toPosix(r.path)} —— ${detail}`);
      if (!ok) problems.push(`索引根不可用：${toPosix(r.path)}（${detail}）`);
    }

    let db = null;
    try {
      db = openDatabase(cfg.dbPath);
    } catch (e) {
      problems.push(`无法打开索引库：${e.message}`);
    }

    if (db) {
      const last = getMeta(db, 'last_scan_at');
      if (!last) {
        problems.push('索引还没建过：请先执行 `cli.js index`。');
      } else {
        notes.push(`最近一次索引：${formatDate(Number(last))}（${Math.floor((Date.now() - Number(last)) / 86400000)} 天前）`);
        const instructions = getMeta(db, 'instructions');
        const size = instructions ? Buffer.byteLength(instructions, 'utf8') : 0;
        notes.push(`instructions：${size} 字节（上限 32768）`);
        if (size === 0) problems.push('instructions 为空：执行 `cli.js reindex-cache`。');
        if (size > 32768) problems.push('instructions 超过 32768 字节上限，连接会被拒绝。');
      }
      const files = db.prepare('SELECT count(*) c, sum(gone=1) g FROM files').get();
      notes.push(`索引条目：${files.c} 条（其中已消失 ${files.g || 0} 条）`);
      const runs = recentScanRuns(db, 3);
      if (runs.length) {
        notes.push('最近扫描记录：');
        for (const r of runs) {
          notes.push(`  - ${formatDate(Number(r.started_at))} ${toPosix(r.root)}：${r.files_seen} 文件，${r.errors} 错误，${(Number(r.elapsed_ms) / 1000).toFixed(1)}s`);
        }
      }
      db.close();
    }

    out('# localvault doctor');
    out('');
    for (const n of notes) out(`- ${n}`);
    out('');
    if (problems.length) {
      out('## 问题');
      out('');
      for (const p of problems) out(`- ${p}`);
      return 1;
    }
    out('自检通过：没有发现问题。');
    return 0;
  },

  ledger() {
    const { cfg, db } = open();
    const ledger = loadLedger(cfg, db);
    if (!ledger) {
      const hint = cfg.ledgerFile
        ? toPosix(path.join(cfg.primaryRoot, cfg.ledgerFile))
        : '（未配置 ledgerFile，且自动发现没有找到像台账的文件）';
      errOut(`未找到或无法解析台账：${hint}`);
      return 1;
    }
    out(`台账：${toPosix(ledger.file)}`);
    out(`形状：${ledger.shape.shape}（发现方式：${cfg.ledgerFile ? 'config' : 'auto'}）`);
    out(`基线：${ledger.baseline}`);
    out(`项目：${ledger.projects.length} 个`);
    const groups = new Map();
    for (const p of ledger.projects) {
      const g = p.group || '(未分组)';
      groups.set(g, (groups.get(g) || 0) + 1);
    }
    for (const [g, c] of groups) out(`  - ${g}：${c}`);
    return 0;
  },

  /**
   * 上游对接（个人记忆中心）。**首版只归档**：不调用 LLM、不写正式记忆、
   * 不做全量同步。子命令见 `lib/upstream/cli.js`。
   */
  upstream(args) {
    return require('./lib/upstream/cli').upstreamCommand(args);
  },
};

function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const args = parseArgv(argv.slice(1));

  if (!cmd || cmd === 'help' || cmd === '--help' || cmd === '-h') {
    out('用法：node cli.js <命令>');
    out('');
    for (const k of Object.keys(COMMANDS)) out(`  ${k}`);
    return 0;
  }
  const fn = COMMANDS[cmd];
  if (!fn) {
    errOut(`未知命令：${cmd}`);
    return 1;
  }
  try {
    const r = fn(args);
    // upstream 的 push/compensate 是异步的：把 rejection 也收成退出码，
    // 否则未处理的 rejection 会让退出码变成 0（失败被读成成功）。
    if (r && typeof r.then === 'function') {
      return r.catch((e) => {
        errOut(`命令 ${cmd} 失败：${(e && e.stack) || e}`);
        return 1;
      });
    }
    return r || 0;
  } catch (e) {
    errOut(`命令 ${cmd} 失败：${(e && e.stack) || e}`);
    return 1;
  }
}

if (require.main === module) {
  const r = main();
  if (r && typeof r.then === 'function') r.then((code) => { process.exitCode = code; });
  else process.exitCode = r;
}

module.exports = { COMMANDS };
