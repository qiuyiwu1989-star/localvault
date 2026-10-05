'use strict';

/**
 * 编排：枚举变化 → 读版本 → 分段 → 幂等提交 → 存收据 → 失败补偿。
 *
 * ## 一条顺序上的硬规矩
 *
 * **先完成账本写入，再推进游标。**
 *
 * 反过来的话，进程在两者之间被杀掉，那一批资料就永远丢了 ——
 * 游标走过去了，账本里也没有失败记录可以补偿。
 * 来件「增量游标不得越过未持久记录的失败项」讲的就是这件事，
 * 它的实现不是一个判断，而是**调用顺序**。
 *
 * ## 结果不明 = 用同一份 payload 重试
 *
 * 提交超时/断连时，服务端**可能已经收下了**。这时候绝不能生成新 source_key
 * （那会变成两条重复记录）。做法是：账本里那一行**阶段不变**、只涨 `attempts`，
 * 下次补偿时用它 `payload_json` 里存着的**原样 payload** 重发。
 * 为此账本里存了完整 payload 而不只是 hash。
 */

const { enumerateChanges, readVersion, normalizeRel } = require('./enumerate');
const { buildImports, stripLocal, validatePayload } = require('./mapping');
const L = require('./ledger');

const STAGE = Object.freeze({
  PENDING: 'pending', SUBMITTED: 'submitted', RECEIPTED: 'receipted',
  INDEXED: 'indexed', FAILED: 'failed',
});

/** 从工具返回里抠出 source_id / job_id —— 服务端形状未核查，所以写得宽容。 */
function extractReceipt(result) {
  const out = { sourceId: null, jobId: null, raw: result };
  const seen = new Set();
  const walk = (v, depth) => {
    if (depth > 8 || !v || typeof v !== 'object' || seen.has(v)) return;
    seen.add(v);
    for (const [k, val] of Object.entries(v)) {
      if (typeof val === 'string') {
        if (/^source_?id$/i.test(k) && !out.sourceId) out.sourceId = val;
        if (/^job_?id$/i.test(k) && !out.jobId) out.jobId = val;
        // 真正的返回体被塞在 `content[].text` 里 —— **一个 JSON 字符串**。
        // 只在键名上匹配是不够的：那时 `source_id` 是个字符串的**内容**，
        // 不是键，所以永远抠不到，账本里 sourceId/jobId 永远是 null。
        //
        // 我原来的假端点直接返回扁平对象 `{source_id, job_id}`，
        // 于是这条路径一次都没被走过 —— 测试的假服务器形状不像真服务器，
        // 是「测试发现不了自己的 bug」的典型。
        if (val.trim().startsWith('{')) {
          try { walk(JSON.parse(val), depth + 1); } catch { /* 不是 JSON 就算了 */ }
        }
      } else if (typeof val === 'object') walk(val, depth + 1);
    }
  };
  walk(result, 0);
  return out;
}

function newBridge({ db, ledger, manifest, client, log = () => {} }) {
  const { scope, instance } = manifest;
  const allow = new Map();
  for (const e of manifest.entries) allow.set(`${e.root}\u0000${normalizeRel(e.path)}`, e);

  /**
   * dry-run：只算数量、hash、错误。**不打印完整私有正文。**
   * 来件：「dry-run只展示数量、hash及错误，不打印完整私有正文。」
   */
  function plan({ limit = Infinity } = {}) {
    const cursor = L.getCursor(ledger, instance);
    const { nextCursor, changed, removed } = enumerateChanges(db, cursor, { allow });
    const items = [];
    const errors = [];

    for (const row of changed.slice(0, limit)) {
      const entry = allow.get(`${row.root}\u0000${normalizeRel(row.rel)}`);
      if (!entry) continue;
      if (row.denied) {
        errors.push({ rel: row.rel, kind: 'denied', reason: '索引标了 denied（用户明确要求不读）' });
        continue;
      }
      const read = readVersion(row);
      if (!read.ok) { errors.push({ rel: row.rel, kind: read.kind, reason: read.reason }); continue; }
      const built = buildImports({ row, text: read.text, entry, scope, instance });
      const problems = built.batches.flatMap((b) => validatePayload(stripLocal(b)));
      if (problems.length) { errors.push({ rel: row.rel, kind: 'payload', reason: problems.join('；') }); continue; }
      items.push({
        rel: row.rel,
        bytes: read.bytes,
        role: built.role,
        sourceType: built.sourceType,
        sourceKey: built.sourceKey,
        versionHash: built.versionHash,
        batches: built.batches.length,
        messages: built.batches.reduce((n, b) => n + b.messages.length, 0),
      });
    }

    return { cursor, nextCursor, changed: changed.length, removed: removed.length, items, errors };
  }

  /**
   * 真提交。逐批提交、逐批记收据。一批失败不影响其它批（失败被持久记录）。
   */
  async function push({ limit = Infinity, dryRun = false } = {}) {
    const cursor = L.getCursor(ledger, instance);
    const { nextCursor, changed } = enumerateChanges(db, cursor, { allow });
    const stats = { submitted: 0, receipted: 0, failed: 0, skipped: 0, notArchived: [] };
    let hadFailure = false;

    for (const row of changed.slice(0, limit)) {
      const entry = allow.get(`${row.root}\u0000${normalizeRel(row.rel)}`);
      if (!entry) continue;
      if (row.denied) { stats.skipped++; L.logEvent(ledger, instance, 'skipped-denied', row.rel); continue; }

      const read = readVersion(row);
      if (!read.ok) { stats.failed++; hadFailure = true; L.logEvent(ledger, instance, `read-${read.kind}`, row.rel); continue; }

      const built = buildImports({ row, text: read.text, entry, scope, instance });

      for (const batch of built.batches) {
        const payload = stripLocal(batch);
        const src = batch.source_key;
        const up = L.upsertSubmission(ledger, {
          instance, stableId: built.stableId, versionHash: built.versionHash,
          sourceKey: src, partIndex: batch._local.partIndex0, partTotal: batch._local.partTotal,
          locator: batch._local.locator, payloadDigest: batch._local.digest,
          scope, sourceType: built.sourceType, role: built.role, payload,
        });

        if (dryRun) { stats.submitted++; continue; }
        if (!up.isNew && stageOf(ledger, src) === STAGE.RECEIPTED) { stats.skipped++; continue; }

        try {
          const res = await client.importArchive(payload);
          const r = extractReceipt(res);
          L.markSubmitted(ledger, src, { sourceId: r.sourceId, jobId: r.jobId });
          L.markReceipted(ledger, src);        // 拿到返回即视为已归档；索引状态另行查
          stats.submitted++; stats.receipted++;
        } catch (e) {
          if (e.kind === 'auth') {
            // 权限问题：**立刻停**，不换 scope、不继续。已成功的收据保留。
            L.markFailed(ledger, src, 'auth', e.message);
            L.logEvent(ledger, instance, 'stopped-auth', e.message);
            return {
              ...stats, stopped: 'auth', message: e.message,
              cursor: L.getCursor(ledger, instance),
              cursorAdvanced: false,          // 权限没解决之前，游标一步都不许动
            };
          }
          if (e.kind === 'unknown' || e.kind === 'transient') {
            // 结果不明 / 暂时性：状态不动，只涨次数 —— 下次补偿用**原样 payload** 重发
            L.bumpAttempt(ledger, src, e.kind, e.message);
          } else {
            // 含工具级拒绝（kind='tool'）：记失败，**不记收据**。
            // 游标因为有失败而不推进，下次 push 会重新遇到这批。
            L.markFailed(ledger, src, e.kind || 'validation', e.message);
          }
          stats.failed++; hadFailure = true;
          stats.notArchived.push({ sourceKey: src, kind: e.kind, reason: e.message });
          L.logEvent(ledger, instance, `fail-${e.kind}`, `${src} ${e.message}`);
        }
      }

      // 只有这一版的**所有分段**都拿到收据，才算「已归档」
      const vc = L.versionComplete(ledger, instance, built.stableId, built.versionHash);
      if (!vc.complete) {
        hadFailure = true;
        L.logEvent(ledger, instance, 'version-incomplete',
          `${built.stableId}/${built.versionHash} ${vc.done}/${vc.total}`);
      }
    }

    // 先写账本 → 再推游标；有失败就不推（否则失败项会被游标越过）
    const adv = L.advanceCursor(ledger, instance, nextCursor, { blocked: hadFailure });
    return { ...stats, cursor: adv.scanId, cursorAdvanced: adv.advanced };
  }

  function stageOf(dbLedger, sourceKey) {
    const r = dbLedger.prepare('SELECT stage FROM submissions WHERE source_key = ?').get(sourceKey);
    return r ? r.stage : null;
  }

  /**
   * 失败补偿：重启后把没完成的分段按**原样 payload** 重发。
   *
   * 这里刻意**不重新读磁盘、不重新分段** ——
   * 重读会得到新版本（文件可能又改了），那就变成「补偿」变「新同步」，
   * 旧版本永远补不完。账本里存的 payload 就是当时那一份。
   */
  async function compensate({ maxAttempts = 5, limit = Infinity } = {}) {
    const pending = L.pendingParts(ledger, instance).slice(0, limit);
    const out = { tried: 0, ok: 0, failed: 0, givenUp: 0, stopped: null };
    for (const p of pending) {
      if (p.attempts >= maxAttempts) { out.givenUp++; continue; }
      out.tried++;
      try {
        const payload = JSON.parse(p.payload_json);
        const res = await client.importArchive(payload);
        const r = extractReceipt(res);
        L.markSubmitted(ledger, p.source_key, { sourceId: r.sourceId, jobId: r.jobId });
        L.markReceipted(ledger, p.source_key);
        out.ok++;
      } catch (e) {
        if (e.kind === 'auth') { out.stopped = e.message; L.logEvent(ledger, instance, 'compensate-stopped-auth', e.message); break; }
        if (e.kind === 'unknown' || e.kind === 'transient') L.bumpAttempt(ledger, p.source_key, e.kind, e.message);
        else L.markFailed(ledger, p.source_key, e.kind || 'validation', e.message);
        out.failed++;
      }
    }
    // 补偿动了状态，这时才允许推进游标
    const vc = pending.length;
    if (out.failed === 0 && !out.stopped) {
      L.logEvent(ledger, instance, 'compensate-done', `tried=${out.tried} ok=${out.ok} pending=${vc}`);
    }
    return out;
  }

  /** 删除事件：**只记 tombstone，显示待处理**，不声称已撤回。 */
  function tombstone({ limit = Infinity } = {}) {
    const cursor = L.getCursor(ledger, instance);
    const { removed } = enumerateChanges(db, cursor, { allow });
    const added = [];
    for (const row of removed.slice(0, limit)) {
      const entry = allow.get(`${row.root}\u0000${normalizeRel(row.rel)}`);
      if (!entry) continue;
      const sid = entry.stable_id || require('./versions').stableId(row.root, normalizeRel(row.rel));
      const isNew = L.addTombstone(ledger, {
        instance, stableId: sid, sourceKey: '', reason: '文件在本地消失',
      });
      if (isNew) added.push(row.rel);
    }
    return { added, pending: L.tombstoneCount(ledger, instance) };
  }

  function status() {
    const rows = ledger.prepare(`
      SELECT stage, COUNT(*) AS n FROM submissions WHERE instance = ? GROUP BY stage
    `).all(instance);
    const byStage = Object.fromEntries(rows.map((r) => [r.stage, Number(r.n)]));
    return {
      instance,
      cursor: L.getCursor(ledger, instance),
      stages: { pending: 0, submitted: 0, receipted: 0, indexed: 0, failed: 0, ...byStage },
      tombstonesPending: L.tombstoneCount(ledger, instance),
      note: '「已归档」不等于「已提炼」也不等于「已确认」—— 首版不产生后两个状态。',
    };
  }

  return { plan, push, compensate, tombstone, status, STAGE };
}

module.exports = { newBridge, extractReceipt, STAGE };
