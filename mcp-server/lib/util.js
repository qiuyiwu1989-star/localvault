'use strict';

/**
 * 通用工具函数。零依赖。
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const HOME = os.homedir();

/** 把 ~/foo 展开为绝对路径，并规范化。 */
function expandHome(p) {
  if (typeof p !== 'string' || p.length === 0) return p;
  let out = p;
  if (out === '~') out = HOME;
  else if (out.startsWith('~/')) out = path.join(HOME, out.slice(2));
  return path.resolve(out);
}

/** 反向：把绝对路径里的 HOME 压回 ~/，用于展示。 */
function compressHome(p) {
  if (typeof p !== 'string') return p;
  if (p === HOME) return '~';
  if (p.startsWith(HOME + path.sep)) return '~/' + p.slice(HOME.length + 1);
  return p;
}

/** 统一用 / 分隔，便于跨平台比较和输出。 */
function toPosix(p) {
  return String(p).split(path.sep).join('/');
}

function formatBytes(n) {
  if (!Number.isFinite(n)) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  const digits = v >= 100 || i === 0 ? 0 : v >= 10 ? 1 : 2;
  return `${v.toFixed(digits)}${units[i]}`;
}

function formatLocalTime(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '?';
  const d = new Date(ms);
  const pad = (x) => String(x).padStart(2, '0');
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`
  );
}

function formatDate(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return '?';
  const d = new Date(ms);
  const pad = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function nowMs() {
  return Date.now();
}

function daysAgo(ms) {
  return Math.floor((Date.now() - ms) / 86400000);
}

function truncate(s, n) {
  if (typeof s !== 'string') return '';
  if (s.length <= n) return s;
  return s.slice(0, Math.max(0, n - 1)) + '…';
}

/** 折叠空白，用于单行摘要。 */
function squeeze(s) {
  return String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
}

/** child 是否在 parent 之内（含相等）。 */
function isInside(parent, child) {
  const a = path.resolve(parent);
  const b = path.resolve(child);
  if (a === b) return true;
  return b.startsWith(a.endsWith(path.sep) ? a : a + path.sep);
}

/** 相对路径（posix 风格）。 */
function relPosix(from, to) {
  return toPosix(path.relative(from, to));
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function readJsonSafe(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_e) {
    return null;
  }
}

/** 把毫秒时间戳解析成 ms；支持 ISO 串、YYYY-MM-DD、相对天数（如 7d / 30d）。 */
function parseSince(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'number' && Number.isFinite(value)) {
    // 小于 10^11 视为「天」的相对量
    return value < 1e11 ? Date.now() - value * 86400000 : value;
  }
  const s = String(value).trim();
  const rel = /^(\d+(?:\.\d+)?)\s*(d|day|days|天|w|week|weeks|周|m|month|months|月)$/i.exec(s);
  if (rel) {
    const n = Number(rel[1]);
    const unit = rel[2].toLowerCase();
    const mult = unit.startsWith('d') || unit === '天'
      ? 86400000
      : unit.startsWith('w') || unit === '周'
        ? 7 * 86400000
        : 30 * 86400000;
    return Date.now() - n * mult;
  }
  const t = Date.parse(s);
  return Number.isFinite(t) ? t : null;
}

/** 稳定的短哈希，用于去重分组键。 */
function shortHash(input) {
  const crypto = require('node:crypto');
  return crypto.createHash('sha1').update(input).digest('hex').slice(0, 12);
}

/** 简单的 JSON 输出格式控制。 */
function jsonBlock(value) {
  return JSON.stringify(value, null, 2);
}

/** 生成 Markdown 表格。 */
function mdTable(headers, rows) {
  const head = `| ${headers.join(' | ')} |`;
  const sep = `| ${headers.map(() => '---').join(' | ')} |`;
  const body = rows.map((r) => `| ${r.map((c) => String(c == null ? '' : c)).join(' | ')} |`);
  return [head, sep, ...body].join('\n');
}

module.exports = {
  HOME,
  expandHome,
  compressHome,
  toPosix,
  formatBytes,
  formatLocalTime,
  formatDate,
  nowMs,
  daysAgo,
  truncate,
  squeeze,
  isInside,
  relPosix,
  ensureDir,
  readJsonSafe,
  parseSince,
  shortHash,
  jsonBlock,
  mdTable,
};
