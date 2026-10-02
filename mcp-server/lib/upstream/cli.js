'use strict';

/**
 * `node cli.js upstream <子命令>` —— 上游对接的命令行入口。
 *
 * ```
 *   doctor      核查：端点、凭据、清单、能力。**不联网、不提交。**
 *   plan        dry-run：枚举变化 + 分段 + hash。**只出数量、hash、错误，不打印正文。**
 *   push        真提交（需要凭据）。逐批拿收据、逐批记账。
 *   status      账本状态：各阶段数量、游标、待处理墓碑。
 *   compensate  补偿回放：把没完成的分段按**原样 payload** 重发。
 *   tombstone   把本地消失的资料记成待处理（不声称已撤回）。
 *   manifest   打印清单摘要（不含正文）。
 *   init-manifest  生成一份空的清单骨架，供用户填写授权范围。
 * ```
 *
 * 首版边界：只 `archive`，不调用任何 LLM，**不直接写入正式记忆**。
 */

const fs = require('node:fs');
const path = require('node:path');
const { loadConfig } = require('../config');
const { dataDir } = require('../config');
const { toPosix } = require('../util');

const MANIFEST_NAME = 'upstream-manifest.json';
const LEDGER_NAME = 'upstream-ledger.db';

function manifestPath(cfg) {
  return path.join(cfg.dataDirAbs || dataDir(cfg), MANIFEST_NAME);
}
function ledgerPath(cfg) {
  return path.join(cfg.dataDirAbs || dataDir(cfg), LEDGER_NAME);
}

function expand(p) { return p.startsWith('~') ? path.join(require('node:os').homedir(), p.slice(1)) : p; }

function makeContext(cfg) {
  const M = require('./manifest');
  const Led = require('./ledger');
  const C = require('./client');
  const B = require('./bridge');

  const mfPath = manifestPath(cfg);
  if (!fs.existsSync(mfPath)) {
    const err = new Error(
      `还没有授权清单：${toPosix(mfPath)}\n` +
      '  首版只处理清单里列出的资料 —— 清单不存在，就一个字节都不会出去。\n' +
      '  先生成骨架：node cli.js upstream init-manifest'
    );
    err.kind = 'no-manifest';
    throw err;
  }
  const manifest = M.loadManifest(mfPath, { defaultRoot: cfg.primaryRoot });
  const ledger = Led.openLedger(ledgerPath(cfg));
  const client = new C.MemoryCenterClient({
    endpoint: process.env.LOCALVAULT_MEMORY_ENDPOINT || undefined,
    // token 只从环境来；这里不读、不打印、不外传
    token: process.env.LOCALVAULT_MEMORY_TOKEN || undefined,
  });
  const db = require('./enumerate').openVaultReadOnly(cfg.dbPath);   // 只读，绝不写用户的索引库
  const bridge = B.newBridge({ db, ledger, manifest, client });
  return { manifest, ledger, client, bridge, db, mfPath, ledgerPath: ledgerPath(cfg) };
}

function printSummary(manifest) {
  const byRole = {};
  for (const e of manifest.entries) byRole[e.role] = (byRole[e.role] || 0) + 1;
  return Object.entries(byRole).map(([r, n]) => `${r}:${n}`).join(' ');
}

async function upstreamCommand(argv) {
  const sub = argv.positional[0] || 'status';
  const cfg = loadConfig();
  const out = [];
  const say = (s) => { console.log(s); out.push(s); };

  // ── init-manifest：不需要 context（清单还不存在） ──
  if (sub === 'init-manifest') {
    const p = manifestPath(cfg);
    if (fs.existsSync(p) && !argv.flags.force) {
      say(`清单已存在，没有覆盖：${toPosix(p)}`);
      return 0;
    }
    const skeleton = {
      scope: argv.flags.scope || 'agent:localvault-inbox',
      instance: argv.flags.instance || require('node:os').hostname(),
      primaryRoot: cfg.primaryRoot,
      sources: [
        { path: '在这里写相对 primaryRoot 的路径', role: 'user', author: '', original_date: 'YYYY-MM-DD' },
      ],
      _说明: [
        '只处理这个数组里列出的资料。',
        'role 只能是 user / assistant / external；不写就是 external（未知保持未知）。',
        'author / original_date 未知就整行删掉，不要填 unknown 或占位日期。',
        'source_type 只能是 conversation / document / imported_summary。',
        'imported_summary 必须带 parent_source_key。',
      ],
    };
    fs.writeFileSync(p, JSON.stringify(skeleton, null, 2) + '\n');
    say(`已写入清单骨架：${toPosix(p)}`);
    say('填好之后先跑：node cli.js upstream doctor');
    return 0;
  }

  let ctx;
  try {
    ctx = makeContext(cfg);
  } catch (e) {
    if (e.kind === 'no-manifest') { console.error(e.message); return 1; }
    throw e;
  }
  const { manifest, ledger, client, bridge } = ctx;

  try {
    switch (sub) {
      case 'doctor': {
        say('# 上游对接核查');
        say('');
        say(`清单：${toPosix(ctx.mfPath)}`);
        say(`  实例：${manifest.instance}`);
        say(`  scope：${manifest.scope}`);
        say(`  资料：${manifest.entries.length} 条（${printSummary(manifest)}）`);
        say(`账本：${toPosix(ctx.ledgerPath)}`);
        say('');
        say('能力：');
        say(`  稳定ID / 版本 hash / 分段：✓ 本地可算（不需要凭据）`);
        say(`  枚举变化（scan_id 游标）：✓`);
        say(`  删除标记（tombstone，待处理）：✓ —— 不会自动传播撤回`);
        say(`  MCP 端点：${client.endpoint}`);
        say(`  凭据：${client.describeToken()}`);
        if (!client.hasToken()) {
          say('');
          say('  凭据未配置 —— 这**不影响** doctor/plan/status 本地工作，但 push 会 401。');
          say('  做法：export LOCALVAULT_MEMORY_TOKEN=…（不进源码、不进日志）');
          say(`  scope「${manifest.scope}」目前**尚未在记忆中心注册**：填了名字不等于拿到权限。`);
        }
        const st = bridge.status();
        say('');
        say(`账本状态：游标 ${st.cursor} · ${JSON.stringify(st.stages)} · 待处理墓碑 ${st.tombstonesPending}`);
        return 0;
      }

      case 'plan': {
        const p = bridge.plan();
        say('# dry-run（不发请求、不打印正文）');
        say('');
        say(`游标：${p.cursor} → ${p.nextCursor}`);
        say(`变化：${p.changed} 条资料（其中消失 ${p.removed} 条）`);
        say(`可提交：${p.items.length} 条资料 / ${p.items.reduce((n, i) => n + i.batches, 0)} 批 / ${p.items.reduce((n, i) => n + i.messages, 0)} 条消息`);
        say('');
        for (const i of p.items) {
          say(`  ${i.rel}`);
          say(`    ${i.role} · ${i.sourceType} · ${i.bytes} 字节 · ${i.batches} 批 · ${i.messages} 条`);
          say(`    version ${i.versionHash} · key ${i.sourceKey}`);
        }
        if (p.errors.length) {
          say('');
          say(`排除/错误 ${p.errors.length} 条：`);
          for (const e of p.errors) say(`  ⚠ [${e.kind}] ${e.rel} —— ${e.reason}`);
        }
        say('');
        say('（dry-run 只展示数量、hash 及错误。正文一个字符都没有打印。）');
        return p.errors.length ? 0 : 0;
      }

      case 'push': {
        if (!client.hasToken()) {
          console.error('凭据未配置：设 LOCALVAULT_MEMORY_TOKEN 后再推。本轮**没有发出任何请求**。');
          return 1;
        }
        const r = await bridge.push({ dryRun: Boolean(argv.flags['dry-run']) });
        say('# 提交结果');
        say('');
        say(`提交 ${r.submitted} · 收讫 ${r.receipted} · 失败 ${r.failed} · 跳过 ${r.skipped}`);
        say(`游标：${r.cursor}（${r.cursorAdvanced ? '已推进' : '未推进 —— 有未完成项'}）`);
        if (r.stopped) {
          say('');
          say(`⚠ 已停下（${r.stopped}）：${r.message}`);
          say('  权限没解决之前不换 scope、不继续。');
        }
        if (r.notArchived && r.notArchived.length) {
          say('');
          say(`未归档 ${r.notArchived.length} 批（已持久记录，可补偿）：`);
          for (const n of r.notArchived.slice(0, 10)) say(`  ⚠ ${n.sourceKey} [${n.kind}] ${String(n.reason).slice(0, 120)}`);
        }
        say('');
        say('注意：「已归档」不等于「已提炼」，也不等于「已确认」。');
        return r.failed > 0 || r.stopped ? 1 : 0;
      }

      case 'compensate': {
        if (!client.hasToken()) {
          console.error('凭据未配置：本轮**没有发出任何请求**。');
          return 1;
        }
        const r = await bridge.compensate({ maxAttempts: Number(argv.flags['max-attempts'] || 5) });
        say('# 补偿回放');
        say('');
        say(`尝试 ${r.tried} · 成功 ${r.ok} · 失败 ${r.failed} · 放弃 ${r.givenUp}`);
        if (r.stopped) say(`⚠ 权限问题停下：${r.stopped}`);
        say('');
        say('补偿用的是账本里存的**原样 payload**（同一 source_key），不重新读盘、不重新分段 ——');
        say('否则文件若已改动，补偿就变成了新同步，旧版本永远补不完。');
        return r.failed > 0 || r.stopped ? 1 : 0;
      }

      case 'tombstone': {
        const t = bridge.tombstone();
        say('# 删除事件');
        say('');
        say(`新增待处理 ${t.added.length} 条 · 累计待处理 ${t.pending} 条`);
        for (const a of t.added) say(`  · ${a}`);
        say('');
        say('**只是记下来，没有声称已撤回。** memory_import 目前没有删除/撤回协议，');
        say('旧引用与派生记忆的失效策略需要与记忆中心一起补齐 —— 补齐前不做自动传播。');
        return 0;
      }

      case 'status': {
        const st = bridge.status();
        say('# 同步账本状态');
        say('');
        say(`实例：${st.instance}`);
        say(`游标：${st.cursor}`);
        say(`阶段：${JSON.stringify(st.stages)}`);
        say(`待处理墓碑：${st.tombstonesPending}`);
        say('');
        say(st.note);
        return 0;
      }

      case 'manifest': {
        say(`scope ${manifest.scope} · 实例 ${manifest.instance} · ${manifest.entries.length} 条`);
        for (const e of manifest.entries) {
          const bits = [e.role, e.sourceType];
          if (e.author) bits.push(`作者=${e.author}`);
          if (e.originalDate) bits.push(`日期=${e.originalDate}`);
          say(`  ${e.path}  [${bits.join(' · ')}]`);
        }
        return 0;
      }

      default:
        console.error(`未知子命令：${sub}`);
        console.error('可用：doctor / plan / push / status / compensate / tombstone / manifest / init-manifest');
        return 1;
    }
  } finally {
    try { ledger.close(); } catch { /* ignore */ }
    try { ctx.db.close(); } catch { /* ignore */ }
  }
}

module.exports = { upstreamCommand, MANIFEST_NAME, LEDGER_NAME, manifestPath, ledgerPath };
