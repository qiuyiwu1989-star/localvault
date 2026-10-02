'use strict';

/**
 * 角色判定。**唯一的实现处，而且只有一条规则。**
 *
 * 来件：「只有有依据的用户原话或本人原创正文使用user；Agent建议/生成稿用assistant；
 * 第三方或未核实作者用external。整段用户转贴的来信仍需标明其中引用的第三方，
 * 不能把包裹它的user角色当作全部正文归属。未核实speaker ID不自动匹配成人物身份。」
 *
 * ## 为什么把判定收窄成「只认清单」
 *
 * 一个文件躺在用户的目录里，**不说明作者是用户**。它可能是下载的合同、
 * 别人发来的稿子、Agent 生成的草稿。任何「从路径/内容猜角色」的启发式，
 * 都会在某个时刻把第三方的话记成用户本人说的 —— 而这个错误一旦进了记忆中心，
 * 后面所有的归属核验都在一个错的前提上做。
 *
 * 所以：**清单没写 = external**，且清单里**没有**这个文件时它根本不进同步。
 * 宁可漏（用户可以补登记），不可错（错误归属会污染下游）。
 */

const ROLES = Object.freeze(['user', 'assistant', 'external']);

/** 默认角色：**external**，不是 user。 */
const DEFAULT_ROLE = 'external';

/**
 * 解析一条资料的 role。
 *
 * @param {object} entry 清单条目
 * @returns {{role:string, basis:string}}
 */
function resolveRole(entry) {
  const raw = entry && entry.role;
  if (raw === undefined || raw === null || raw === '') {
    return { role: DEFAULT_ROLE, basis: '未声明 → external（未知保持未知）' };
  }
  if (typeof raw !== 'string' || !ROLES.includes(raw)) {
    throw new Error(
      `role 只能是 ${ROLES.join(' / ')}，收到 ${JSON.stringify(raw)}（来源：${entry.path || entry.stable_id || '?'}）`
    );
  }
  return { role: raw, basis: `清单显式声明 role=${raw}` };
}

/**
 * 作者。**未核实就留空，不许填 'unknown' / '未知' / '-'。**
 *
 * 用占位字符串代替「没有」是同一个病：下游看到 `author: "unknown"`
 * 会当它是个值，于是「作者未知」和「作者叫 unknown」再也分不开。
 */
function resolveAuthor(entry) {
  const a = entry && entry.author;
  if (a === undefined || a === null) return undefined;
  const s = String(a).trim();
  if (s === '') return undefined;
  if (['unknown', '未知', '未核实', '-', 'n/a', 'na', 'null', 'none'].includes(s.toLowerCase())) {
    throw new Error(
      `author 不许用占位值「${s}」（来源：${entry.path || '?'}）—— 未知就整个字段省略，不要填一个看起来像值的值`
    );
  }
  return s;
}

/** 原始日期：只接受 `YYYY-MM-DD`，未知返回 undefined。**绝不用 mtime 顶替。** */
function resolveOriginalDate(entry) {
  const d = entry && entry.original_date;
  if (d === undefined || d === null || d === '') return undefined;
  const s = String(d).trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    throw new Error(`original_date 必须是 YYYY-MM-DD，收到「${s}」（来源：${entry.path || '?'}）`);
  }
  const t = Date.parse(`${s}T00:00:00Z`);
  if (Number.isNaN(t)) throw new Error(`original_date 不是合法日期：「${s}」`);
  return s;
}

/**
 * 来源类型。
 *
 * 来件：「原始对话为conversation；文档或会议转录为document；
 * 任何二手摘要、AI整理结果为imported_summary，并关联原件。」
 */
const SOURCE_TYPES = Object.freeze(['conversation', 'document', 'imported_summary']);

function resolveSourceType(entry) {
  const t = entry && entry.source_type;
  if (t === undefined || t === null || t === '') return 'document';
  if (!SOURCE_TYPES.includes(t)) {
    throw new Error(`source_type 只能是 ${SOURCE_TYPES.join(' / ')}，收到「${t}」`);
  }
  if (t === 'imported_summary' && !(entry && entry.parent_source_key)) {
    throw new Error(
      `imported_summary 必须带 parent_source_key（来源：${entry.path || '?'}）—— ` +
      '二手摘要不能冒充直接证据'
    );
  }
  return t;
}

module.exports = {
  ROLES, DEFAULT_ROLE, SOURCE_TYPES,
  resolveRole, resolveAuthor, resolveOriginalDate, resolveSourceType,
};
