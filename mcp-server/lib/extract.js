'use strict';

/**
 * 文本抽取：标题、标题层级、正文（截断存储）。
 * 中文语料下不做分词，检索走子串匹配，因此这里只需保留原文本。
 */

const path = require('node:path');

/** 前 8KB 内出现 NUL 基本可判定为二进制。 */
function looksBinary(buf) {
  const n = Math.min(buf.length, 8192);
  for (let i = 0; i < n; i += 1) {
    if (buf[i] === 0) return true;
  }
  return false;
}

function stripBom(s) {
  return s.charCodeAt(0) === 0xfeff ? s.slice(1) : s;
}

/** 解析 YAML frontmatter（只取需要的几个标量字段，不做完整 YAML）。 */
function parseFrontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return { frontmatter: {}, body: text };
  const fm = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (!kv) continue;
    let v = kv[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    fm[kv[1]] = v;
  }
  return { frontmatter: fm, body: text.slice(m[0].length) };
}

function collectHeadings(body, limit) {
  const out = [];
  const re = /^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$/gm;
  let m;
  while ((m = re.exec(body)) !== null) {
    const t = m[2].trim();
    if (!t) continue;
    out.push(`${'#'.repeat(m[1].length)} ${t}`);
    if (out.length >= limit) break;
  }
  return out;
}

/** 从 markdown 链接里抽取本地绝对路径，用于断链检查。 */
function extractLocalLinks(body) {
  const out = [];
  const re = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    let target = m[1];
    if (!target) continue;
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue; // http:, mailto:, data: 等
    if (target.startsWith('#')) continue;
    const hashIdx = target.indexOf('#');
    if (hashIdx >= 0) target = target.slice(0, hashIdx);
    if (!target) continue;
    try {
      target = decodeURIComponent(target);
    } catch (_e) {
      /* 保留原样 */
    }
    out.push(target);
  }
  return out;
}

/**
 * 从一段文本里推断标题与摘要行。
 */
function guessTitle(body, frontmatter, ext) {
  if (frontmatter && frontmatter.title) return String(frontmatter.title).trim();
  if (frontmatter && frontmatter.name) return String(frontmatter.name).trim();
  const lines = body.split('\n');
  const isMd = ext === '.md' || ext === '.markdown' || ext === '.mdx';
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    if (/^#{1,6}\s+/.test(line)) return line.replace(/^#{1,6}\s+/, '').trim();
    if (isMd && /^[-*_=]{3,}$/.test(line)) continue;
    if (/^[<>{}[\]()]/.test(line) && line.length < 8) continue;
    return line.length > 140 ? line.slice(0, 140) : line;
  }
  return '';
}

/**
 * 抽取一个文件的内容。
 * @param {string} file 绝对路径
 * @param {object} opts { maxBytes, maxStoredChars, denied }
 * @returns {{ok:boolean, reason?:string, title:string, headings:string[], body:string, truncated:boolean, bytes:number}}
 */
function extractFile(file, opts) {
  const fs = require('node:fs');
  const { maxBytes = 2 * 1024 * 1024, maxStoredChars = 400000, denied = false } = opts || {};

  if (denied) {
    return { ok: true, title: '', headings: [], body: '', truncated: true, bytes: 0, denied: true };
  }

  let fd;
  try {
    fd = fs.openSync(file, 'r');
  } catch (e) {
    return { ok: false, reason: `open failed: ${e.code || e.message}`, title: '', headings: [], body: '', truncated: false, bytes: 0 };
  }
  try {
    const buf = Buffer.allocUnsafe(maxBytes);
    const read = fs.readSync(fd, buf, 0, maxBytes, 0);
    const slice = buf.subarray(0, read);
    if (looksBinary(slice)) {
      return { ok: true, title: '', headings: [], body: '', truncated: false, bytes: read, binary: true };
    }
    let text = stripBom(slice.toString('utf8'));
    const truncated = read >= maxBytes;
    const ext = path.extname(file).toLowerCase();
    const isMd = ext === '.md' || ext === '.markdown' || ext === '.mdx';
    let frontmatter = {};
    if (isMd) {
      const parsed = parseFrontmatter(text);
      frontmatter = parsed.frontmatter;
      text = parsed.body;
    }
    const headings = isMd ? collectHeadings(text, 60) : [];
    const title = guessTitle(text, frontmatter, ext);
    let body = text;
    let bodyTruncated = truncated;
    if (body.length > maxStoredChars) {
      body = body.slice(0, maxStoredChars);
      bodyTruncated = true;
    }
    return {
      ok: true,
      title,
      headings,
      body,
      truncated: bodyTruncated,
      bytes: read,
      frontmatter,
      isMarkdown: isMd,
    };
  } catch (e) {
    return { ok: false, reason: `read failed: ${e.code || e.message}`, title: '', headings: [], body: '', truncated: false, bytes: 0 };
  } finally {
    try {
      fs.closeSync(fd);
    } catch (_e) {
      /* ignore */
    }
  }
}

module.exports = {
  looksBinary,
  parseFrontmatter,
  collectHeadings,
  extractLocalLinks,
  guessTitle,
  extractFile,
};
