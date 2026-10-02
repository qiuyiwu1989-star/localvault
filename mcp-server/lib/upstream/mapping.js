'use strict';

/**
 * localvault 资料 → `memory_import` 参数。
 *
 * ## 字段白名单是**强制执行**的，不是文档约定
 *
 * 来件：「source_metadata仅接受original_ref、original_date、author、locator、
 * parser_version、parent_source_key，每项字符串最多1,000字符。不要传owner、trusted、
 * verified、预算或额外自定义字段。更丰富的本地元信息放在localvault账本/原件中，
 * 不能静默丢弃；如果核心确需接收，先提字段扩展方案。」
 *
 * 「不能静默丢弃」这句是重点：如果有字段进不了 payload，**必须是显式错误或显式留在账本**，
 * 不能悄悄扔掉。所以这里对多余字段**直接抛错** —— 拼错一个键（`authors` vs `author`）
 * 会立刻失败，而不是变成「同步成功但没有作者」。
 */

const path = require('path');
const { stableId, versionHash, sourceKey, originalRef, payloadDigest, messageId, PARSER_VERSION } = require('./versions');
const { segmentBody, packBatches, MAX_PART_CP } = require('./segmenter');
const { resolveRole, resolveAuthor, resolveOriginalDate, resolveSourceType } = require('./roles');

/** 服务端接受的 source_metadata 键（**只有这六个**）。 */
const ALLOWED_META_KEYS = Object.freeze([
  'original_ref', 'original_date', 'author', 'locator', 'parser_version', 'parent_source_key',
]);

const MAX_META_VALUE = 1000;

function assertMeta(obj) {
  for (const k of Object.keys(obj)) {
    if (!ALLOWED_META_KEYS.includes(k)) {
      throw new Error(
        `source_metadata 不接受字段「${k}」。允许的只有：${ALLOWED_META_KEYS.join('、')}。\n` +
        '  本地更丰富的元信息请留在 localvault 账本里 —— 不要试图让它静默通过。'
      );
    }
    const v = obj[k];
    if (typeof v !== 'string') throw new Error(`source_metadata.${k} 必须是字符串`);
    if (v.length > MAX_META_VALUE) throw new Error(`source_metadata.${k} 超过 ${MAX_META_VALUE} 字符`);
  }
}

/** 计算每个 part 在它所属段落里的序号 / 该段总块数（locator 用），并分配消息 id。 */
function annotateLocators(parts) {
  const byPara = new Map();
  for (const p of parts) {
    if (!byPara.has(p.paraIndex)) byPara.set(p.paraIndex, []);
    byPara.get(p.paraIndex).push(p);
  }
  return parts.map((p, i) => {
    const group = byPara.get(p.paraIndex) || [p];
    const idxInPara = group.indexOf(p);
    const base = `paragraph-${p.paraIndex + 1}`;
    const locator = p.partOfPara ? `${base}+part-${idxInPara + 1}/${group.length}` : base;
    // 消息 id：批内唯一、≤100 字符。用**全局序号**而不是段内序号 ——
    // 分段被重新打包进不同批次时，id 仍然稳定指向同一个位置。
    return { ...p, id: messageId(i), locator };
  });
}

/**
 * 把一份资料映射成若干 `memory_import` 参数（每个是一批）。
 *
 * @param {object} a
 * @param {object} a.row            vault.db 的 files 行
 * @param {string} a.text           **磁盘全文**（不是 files.body）
 * @param {object} a.entry          授权清单条目（已归一化）
 * @param {string} a.scope
 * @param {string} a.instance
 * @returns {{stableId, versionHash, sourceKey, sourceType, role, batches:Array<payload>}}
 */
function buildImports({ row, text, entry, scope, instance }) {
  const rel = String(row.rel).replace(/\\/g, '/');
  const sid = entry.stable_id || stableId(row.root, rel);
  const role = resolveRole(entry).role;
  const author = resolveAuthor(entry);
  const originalDate = resolveOriginalDate(entry);
  const sourceType = resolveSourceType(entry);

  const vhash = versionHash({
    stableId: sid,
    body: text,
    role,
    author,
    originalDate,
    // locator 是**分段之后**才有的，不参与整体版本 hash（否则段数一变版本就变，
    // 而段数变化只是分段器的事）。整体定位由 original_ref 承担。
    locator: undefined,
    parserVersion: entry.parser_version || PARSER_VERSION,
  });

  const sk = sourceKey(sid, vhash);
  const ref = originalRef(sid, vhash);

  const parts = annotateLocators(segmentBody(text, MAX_PART_CP));
  const packed = packBatches(parts, {
    role,
    sourceType,
    sourceTitle: entry.sourceTitle || row.name,
  });

  const total = parts.length;
  const batches = packed.map((b, bi) => {
    const meta = {
      original_ref: ref,
      parser_version: PARSER_VERSION,
      // locator：这一批覆盖的段落区间。起点含、终点不含（码点）。
      locator: locatorRange(b.parts),
    };
    if (author) meta.author = author;
    if (originalDate) meta.original_date = originalDate;
    if (entry.parentSourceKey) meta.parent_source_key = entry.parent_source_key;
    assertMeta(meta);

    return {
      scope,
      // 每一批一个独立的 source_key：服务端的 source_key 是**资料级**的，
      // 而我们一批只装一部分消息 —— 所以批次必须能各自被幂等识别。
      // 用 `#p0001` 后缀，重试时同一批仍是同一个 key。
      source_key: `${sk}#p${String(bi + 1).padStart(4, '0')}`,
      parent_source_key: sk,
      source_type: sourceType,
      processing_policy: 'archive',
      source_metadata: meta,
      messages: b.messages,
      // ── 以下不是 memory_import 字段，是给账本用的（提交前会剥掉）──
      _local: {
        instance,
        stableId: sid,
        versionHash: vhash,
        baseSourceKey: sk,
        partIndex0: b.parts[0] ? parts.indexOf(b.parts[0]) : 0,
        partTotal: total,
        locator: meta.locator,
        role,
      },
    };
  });

  // 每个分段的 payload digest：账本用它对拍「重试时是不是同一份」
  for (const p of batches) p._local.digest = payloadDigest(stripLocal(p));

  return { stableId: sid, versionHash: vhash, sourceKey: sk, sourceType, role, batches };
}

function locatorRange(parts) {
  if (!parts || parts.length === 0) return 'paragraph-1';
  const first = parts[0].locator;
  const last = parts[parts.length - 1].locator;
  return first === last ? first : `${first}..${last}`;
}

/** 剥掉 `_` 前缀的本地字段，得到真正会发出去的 payload。 */
function stripLocal(payload) {
  const out = {};
  for (const [k, v] of Object.entries(payload)) {
    if (k.startsWith('_')) continue;
    out[k] = v;
  }
  return out;
}

/** 192.168 似的自检：一份 payload 是否满足来件的硬限制。 */
function validatePayload(payload) {
  const problems = [];
  if (!payload.scope || typeof payload.scope !== 'string') problems.push('scope 缺失');
  if (!payload.source_key || payload.source_key.length > 300) problems.push('source_key 非法或超长');
  if (payload.processing_policy !== 'archive') problems.push('processing_policy 必须是 archive');
  if (!['conversation', 'document', 'imported_summary'].includes(payload.source_type)) problems.push('source_type 非法');
  if (!Array.isArray(payload.messages) || payload.messages.length === 0) problems.push('messages 为空');
  if (payload.messages && payload.messages.length > 100) problems.push('messages 超过 100 条');
  const ids = new Set();
  for (const m of payload.messages || []) {
    if (!m.id || m.id.length > 100) problems.push('消息 id 非法或超长');
    if (ids.has(m.id)) problems.push(`消息 id 批内重复：${m.id}`);
    ids.add(m.id);
    if (!m.text || m.text.length === 0) problems.push(`消息 ${m.id} 正文为空`);
    if (!['user', 'assistant', 'external'].includes(m.role)) problems.push(`消息 ${m.id} role 非法：${m.role}`);
  }
  const json = JSON.stringify(payload.messages);
  if (json.length > 24000) problems.push(`messages JSON ${json.length} > 24000`);
  try { assertMeta(payload.source_metadata || {}); } catch (e) { problems.push(e.message); }
  return problems;
}

module.exports = {
  ALLOWED_META_KEYS,
  MAX_META_VALUE,
  buildImports,
  validatePayload,
  stripLocal,
  annotateLocators,
};
