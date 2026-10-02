'use strict';

/**
 * 按 **Unicode 码点** 处理文本。
 *
 * ## 为什么必须单独一个模块
 *
 * 来件点名：「分段坐标采用 Unicode 码点，起点包含、终点不包含；
 * JavaScript 的 UTF-16 下标不能直接混用。」
 *
 * JS 字符串是 UTF-16 码元序列。`'😀'.length === 2`，`str.slice()` 按码元切。
 * 于是「按字符数分段」在中文基本正常、一到 emoji / 生僻字（如「𠮷」）
 * 就会把一个字劈成两半，拼回去是一串替换字符 `�`。
 *
 * 这种错误**不会报错**：长度对得上、没有异常、日志干净。
 * 它只是让原文在无声中损坏 —— 所以单独成模块，并且有一条
 * 「拼回去必须逐码点等于原文」的断言守着（见 segmentText 的返回值约定）。
 *
 * 约定：本模块所有 `*Cp` 后缀的下标都是**码点下标**。
 */

/** 字符串的码点长度。 */
function cpLength(str) {
  let n = 0;
  for (const _ of str) n++;              // for...of 按码点迭代
  return n;
}

/** 把字符串拆成码点数组（每个元素是一个「完整字符」）。 */
function toCodePoints(str) {
  return Array.from(str);
}

/** 按码点下标切片。`start` 包含，`end` 不包含。 */
function sliceCp(str, start, end) {
  const cps = toCodePoints(str);
  return cps.slice(start, end === undefined ? cps.length : end).join('');
}

/** 码点下标 → UTF-16 码元下标（需要转成原生 `slice` 时用）。 */
function cpIndexToUtf16(str, cpIndex) {
  if (cpIndex <= 0) return 0;
  let cp = 0;
  let u = 0;
  while (u < str.length && cp < cpIndex) {
    const code = str.codePointAt(u);
    u += code > 0xffff ? 2 : 1;
    cp++;
  }
  return u;
}

/**
 * 按空行切成「段」。空白行是段边界；段内含换行。
 *
 * 段的粒度是「段落」而不是「行」：Markdown 里一个段落常常写成多行，
 * 按行切会把一句话切成几块，引用回去就读不出原来的意思了。
 *
 * **不裁任何字符。** 段尾的换行、空格照留 —— 它们属于原文。
 * 一开始这里写了 `replace(/\s+$/u,'')`，测试立刻抓到「拼回去少 1 个码点」：
 * 裁空白看着无害，但它让「重组完全一致」这条验收标准直接不成立。
 * 纯空白的段并入相邻段（保持连续），而不是丢掉。
 *
 * @returns {Array<{text:string, startCp:number, endCp:number, paraIndex:number}>}
 */
function splitParagraphs(text) {
  const cps = toCodePoints(text);
  if (cps.length === 0) return [];

  const spans = [];
  let chunkStart = 0;
  let lineStart = 0;
  let i = 0;
  while (i < cps.length) {
    if (cps[i] === '\n') {
      const line = cps.slice(lineStart, i).join('');
      if (line.trim() === '') { spans.push([chunkStart, i + 1]); chunkStart = i + 1; }
      lineStart = i + 1;
    }
    i++;
  }
  if (chunkStart < cps.length) spans.push([chunkStart, cps.length]);
  if (spans.length === 0) spans.push([0, cps.length]);

  const isBlank = (s, e) => cps.slice(s, e).join('').trim() === '';

  // 纯空白段并入**前**一段
  const merged = [];
  for (const [s, e] of spans) {
    if (isBlank(s, e) && merged.length > 0) { merged[merged.length - 1][1] = e; continue; }
    merged.push([s, e]);
  }
  // 开头若仍是纯空白段，并入**后**一段
  while (merged.length > 1 && isBlank(merged[0][0], merged[0][1])) {
    merged[1][0] = merged[0][0];
    merged.shift();
  }

  return merged.map(([s, e], idx) => ({
    text: cps.slice(s, e).join(''),
    startCp: s,
    endCp: e,
    paraIndex: idx,
  }));
}

/**
 * 把一段文本按码点切成若干块，每块 ≤ budget 码点。**不截断、不省略、不改字。**
 *
 * 切点优先选在换行 / 句末标点，避免把一句话切两半；找不到就用预算边界。
 * 无论切在哪，`chunks.map(c=>c.text).join('')` 必须逐码点等于 `text`。
 */
function hardSplit(text, budget) {
  const cps = toCodePoints(text);
  const chunks = [];
  let i = 0;
  while (i < cps.length) {
    let end = Math.min(i + budget, cps.length);
    if (end < cps.length) {
      // 在预算内往回找一个自然断点（最多回退 1/4 预算，且不越过起点）
      const floor = Math.max(i + 1, end - Math.floor(budget / 4));
      for (let j = end; j > floor; j--) {
        const ch = cps[j - 1];
        if (ch === '\n' || '。！？；.!?;'.includes(ch)) { end = j; break; }
      }
    }
    chunks.push({ text: cps.slice(i, end).join(''), startCp: i, endCp: end });
    i = end;
  }
  if (chunks.length === 0) chunks.push({ text: '', startCp: 0, endCp: 0 });
  return chunks;
}

module.exports = { cpLength, toCodePoints, sliceCp, cpIndexToUtf16, splitParagraphs, hardSplit };
