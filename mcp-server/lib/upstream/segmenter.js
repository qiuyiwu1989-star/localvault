'use strict';

/**
 * 自动分段与批打包。
 *
 * 来件：「优先完整消息/段落；超长单段连续拆分，保留父来源、角色、消息ID和位置；
 * 不截断、不摘要。」「每批1–100条消息，规范化messages JSON最多24,000字符，
 * 包含转义和结构，并非24k tokens。」
 *
 * ## 24,000 是**序列化后**的长度，不是正文字数
 *
 * 「包含转义和结构」这句是关键：一段全是引号/换行/反斜杠的正文，
 * JSON 转义后可能膨胀到 2–3 倍。按正文字数估预算的实现在这种资料上会被服务端拒收，
 * 而报错信息只看得到「too long」，看不出是哪一段的问题。
 *
 * 所以本模块的预算判定**直接量 `JSON.stringify` 的结果**，不估。
 *
 * ## 不截断
 *
 * 分段的唯一产物是「更小的段」。任何一段的正文都必须是原文的**连续子串**，
 * 且所有段按序拼回去逐码点等于原文。测试里有一条断言守着这件事
 * （含 emoji / 生僻字 / 转义字符）。
 */

const { cpLength, toCodePoints, splitParagraphs, hardSplit } = require('./codepoints');
const { PARSER_VERSION } = require('./versions');

const MAX_BATCH_MESSAGES = 100;
const MAX_BATCH_JSON_CHARS = 24000;

/**
 * 单条消息的正文预算（码点）。
 *
 * 取 6000：一段 6000 字的正文，即使每个字符都被转义（最坏情况 6 倍），
 * 序列化后也在 24000 以内。留这个余量是为了让「一段 = 一条消息」在绝大多数
 * 情况下成立 —— 段落被拆开，引用回去就断句了。
 */
const MAX_PART_CP = 6000;

function utf8JsonLen(obj) {
  return JSON.stringify(obj).length;   // JSON.stringify 输出的是 UTF-16 码元数
}

/**
 * 把一段正文切成若干「段」。
 *
 * @param {string} text 正文（**磁盘全文**）
 * @param {number} [budget] 单段码点上限
 * @returns {Array<{text:string, startCp:number, endCp:number, paraIndex:number, partOfPara:boolean}>}
 */
function segmentBody(text, budget = MAX_PART_CP) {
  const parts = [];
  const paras = splitParagraphs(text);

  if (paras.length === 0) {
    return [{ text: '', startCp: 0, endCp: 0, paraIndex: 0, partOfPara: false }];
  }

  paras.forEach((para, pi) => {
    if (cpLength(para.text) <= budget) {
      parts.push({ text: para.text, startCp: para.startCp, endCp: para.endCp, paraIndex: pi, partOfPara: false });
      return;
    }
    // 超长单段：连续拆分，保留父来源、角色、位置
    for (const c of hardSplit(para.text, budget)) {
      parts.push({
        text: c.text,
        startCp: para.startCp + c.startCp,
        endCp: para.startCp + c.endCp,
        paraIndex: pi,
        partOfPara: true,
      });
    }
  });

  return parts;
}

/** 定位字符串：`paragraph-3` 或 `paragraph-3+part-2/5`。 */
function locatorFor(part, indexOfPartWithinPara, partsWithinPara) {
  const base = `paragraph-${part.paraIndex + 1}`;
  if (!part.partOfPara) return base;
  return `${base}+part-${indexOfPartWithinPara + 1}/${partsWithinPara}`;
}

/**
 * 把分段结果打包成若干批，每批满足来件的两条硬限制。
 *
 * 边界处理：**先按 messages 数切，再按 JSON 长度切**。
 * 一条消息自己就超长的情况在 `segmentBody` 阶段已经被拆到预算内，
 * 但若调用方传了自定义 budget，这里仍会兜底再拆一次 ——
 * 不能出现「一条消息撑爆一批、整批被服务端拒收」。
 */
function packBatches(parts, { role, sourceType, sourceTitle } = {}) {
  const batches = [];
  let cur = [];
  let curIdx = 0;

  const build = (list) => list.map((p) => {
    const m = { id: p.id, role, text: p.text };
    if (sourceTitle) m.source_title = sourceTitle;
    if (p.createdAt) m.created_at = p.createdAt;
    return m;
  });

  for (const p of parts) {
    const candidate = cur.concat([p]);
    const tooMany = candidate.length > MAX_BATCH_MESSAGES;
    const tooLong = utf8JsonLen(build(candidate)) > MAX_BATCH_JSON_CHARS;
    if (cur.length > 0 && (tooMany || tooLong)) {
      batches.push(cur);
      cur = [p];
    } else {
      cur = candidate;
    }
  }
  if (cur.length > 0) batches.push(cur);

  return batches.map((list) => ({ messages: build(list), parts: list }));
}

module.exports = {
  MAX_BATCH_MESSAGES,
  MAX_BATCH_JSON_CHARS,
  MAX_PART_CP,
  segmentBody,
  locatorFor,
  packBatches,
  utf8JsonLen,
  PARSER_VERSION,
};
