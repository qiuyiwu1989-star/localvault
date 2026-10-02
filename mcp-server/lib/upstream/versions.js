'use strict';

/**
 * 稳定资料ID、版本 hash、source_key。
 *
 * ## 这里定义的是「什么算同一个版本」
 *
 * 来件：「建议版本标识包含稳定资料ID及规范化输入hash；hash覆盖正文、角色、
 * 作者/日期/定位及解析版本，不能只hash文件名。相同输入产生相同part key，
 * 变化产生新归档版本。」
 *
 * 这一条决定了整条桥的幂等性，所以它必须只有一处实现 —— 见 `versionHash()`。
 *
 * ## 只 hash 文件名错在哪
 *
 * 文件名不变、正文改一行 → 同一个 source_key → 服务端认为是重复提交，
 * **新内容永远进不去**，而本地看起来一切正常（收据都有）。
 * 这是「坏掉看起来像正常」的又一个面孔：hash 覆盖不够，症状是「同步成功但内容是旧的」。
 */

const crypto = require('crypto');

/** 解析器版本。任何影响分段/映射的改动都必须动这个串。 */
const PARSER_VERSION = 'localvault-adapter-v1';

/** source_key 恒 ≤ 300 字符（来件限制）。16+16 位十六进制留足余量。 */
const ID_HEX_LEN = 16;

/** 每条消息 id ≤ 100 字符。 */
const MAX_MSG_ID = 100;

function sha256Hex(input) {
  return crypto.createHash('sha256').update(input, 'utf8').digest('hex');
}

/**
 * 稳定资料ID：路径派生。
 *
 * 用 `root + ':' + rel` 而不是绝对路径 —— 换用户名 / 换挂载点后同一个资料
 * 应该还是同一个ID。
 *
 * **已知边界**：文件改名 = 新ID。这不是 bug 而是取舍 ——
 * 追踪改名需要文件系统 inode，而 inode 在跨卷复制时会变、在备份还原时不保留。
 * 宁可改名算新资料（多一份归档、可追溯），也不要错把两个不同文件认成同一个。
 */
function stableId(root, rel) {
  return sha256Hex(`${root}\n${rel}`).slice(0, ID_HEX_LEN);
}

/**
 * 规范化：把参与 hash 的字段拼成一个**确定性**的字符串。
 *
 * 两个要点：
 * 1. 字段顺序固定、用不可能出现在值里的分隔符，避免 `a=b, c` 和 `a=b, c` 撞车。
 * 2. 缺失字段记成 `\u0000`（而不是空串）：`author: ""` 和「没有 author」是两回事，
 *    混起来会让「补上作者」这个变化**不产生新版本**。
 */
function canonicalize(fields) {
  const order = ['stableId', 'body', 'role', 'author', 'originalDate', 'locator', 'parserVersion'];
  return order
    .map((k) => {
      const v = fields[k];
      return `${k}\u001f${v === undefined || v === null ? '\u0000' : String(v)}`;
    })
    .join('\u001e');
}

/**
 * 版本 hash。
 *
 * @param {object} fields
 * @param {string} fields.stableId
 * @param {string} fields.body        正文（**磁盘全文，不是索引里可能被截断的那份**）
 * @param {string} [fields.role]
 * @param {string} [fields.author]
 * @param {string} [fields.originalDate]
 * @param {string} [fields.locator]
 * @param {string} [fields.parserVersion]
 */
function versionHash(fields) {
  const f = { ...fields, parserVersion: fields.parserVersion || PARSER_VERSION };
  return sha256Hex(canonicalize(f)).slice(0, ID_HEX_LEN);
}

/** `localvault:<stableId>:<versionHash>` —— 长度恒定 10+16+1+16 = 43。 */
function sourceKey(stableIdHex, versionHashHex) {
  const k = `localvault:${stableIdHex}:${versionHashHex}`;
  if (k.length > 300) throw new Error(`source_key 超长（${k.length} > 300）：${k}`);
  return k;
}

/**
 * 分段 key：`<source_key>#p0001`。
 *
 * 用**固定宽度**的序号，是为了让字典序等于分段序 ——
 * 排序时不至于出现 p10 排在 p2 前面。
 */
function partKey(srcKey, index) {
  const k = `${srcKey}#p${String(index).padStart(4, '0')}`;
  if (k.length > 100 + 300) throw new Error('part key 过长');
  return k;
}

/** 消息 id（≤100 字符，批内唯一）。 */
function messageId(index) {
  const id = `p${String(index).padStart(4, '0')}`;
  if (id.length > MAX_MSG_ID) throw new Error('消息 id 过长');
  return id;
}

/** `localvault://<stableId>/<versionHash>` */
function originalRef(stableIdHex, versionHashHex) {
  return `localvault://${stableIdHex}/${versionHashHex}`;
}

/** 提交内容的摘要，用于账本对拍「重试时 payload 是不是同一份」。 */
function payloadDigest(payload) {
  return sha256Hex(JSON.stringify(payload));
}

module.exports = {
  PARSER_VERSION,
  sha256Hex,
  stableId,
  canonicalize,
  versionHash,
  sourceKey,
  partKey,
  messageId,
  originalRef,
  payloadDigest,
};
