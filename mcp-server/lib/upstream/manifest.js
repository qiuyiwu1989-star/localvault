'use strict';

/**
 * 授权清单 —— 首版**唯一的授权边界**。
 *
 * 来件：「首版只处理用户选定的白名单目录/资料集，不默认扫描整台电脑或全部仓库。」
 *
 * 所以这份清单不只是「配置」，它是安全边界：**不在清单里的资料一个字节都不出去。**
 * 这一点在 `enumerate.js` 里强制执行（而不是在提交前临时过滤 —— 那样容易漏）。
 *
 * 格式（`~/.localvault/upstream-manifest.json`）：
 * ```json
 * {
 *   "scope": "agent:localvault-inbox",
 *   "instance": "mac-mini-home",
 *   "sources": [
 *     { "path": "项目管理/01-项目台账.md", "role": "user",
 *       "original_date": "2026-09-30", "source_type": "document" }
 *   ]
 * }
 * ```
 *
 * `path` 相对清单里声明的根（默认用配置的 `primaryRoot`）；也接受 `root` 逐条覆盖。
 */

const fs = require('fs');
const path = require('path');
const { resolveRole, resolveAuthor, resolveOriginalDate, resolveSourceType } = require('./roles');

/** 允许出现的键 —— 多写一个都报错，避免「写了以为生效了」。 */
const ALLOWED_ENTRY_KEYS = new Set([
  'path', 'root', 'stable_id', 'role', 'author', 'original_date',
  'source_type', 'parent_source_key', 'locator', 'source_title',
]);

function fail(msg) { throw new Error(`授权清单有问题：${msg}`); }

/**
 * 校验并归一化清单。
 * @returns {{scope:string, instance:string, primaryRoot:string, entries:Array<object>}}
 */
function parseManifest(raw, { defaultRoot } = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) fail('顶层必须是一个 JSON 对象');
  const scope = raw.scope;
  if (typeof scope !== 'string' || scope.trim() === '') fail('缺少 scope');
  if (!/^agent:[a-z0-9-]+$/.test(scope)) fail(`scope 形状不对：「${scope}」（应当形如 agent:localvault-inbox）`);
  const instance = typeof raw.instance === 'string' && raw.instance.trim() !== ''
    ? raw.instance.trim() : 'default';
  const primaryRoot = typeof raw.primaryRoot === 'string' && raw.primaryRoot.trim() !== ''
    ? raw.primaryRoot : (defaultRoot || '');
  if (!Array.isArray(raw.sources) || raw.sources.length === 0) fail('sources 必须是非空数组');

  const seen = new Set();
  const entries = raw.sources.map((e, i) => {
    if (!e || typeof e !== 'object' || Array.isArray(e)) fail(`sources[${i}] 不是对象`);
    for (const k of Object.keys(e)) {
      if (!ALLOWED_ENTRY_KEYS.has(k)) fail(`sources[${i}] 有未知字段「${k}」（拼错一个键就等于没写）`);
    }
    if (typeof e.path !== 'string' || e.path.trim() === '') fail(`sources[${i}] 缺少 path`);
    const p = e.path.trim();
    if (path.isAbsolute(p)) fail(`sources[${i}].path 必须是相对路径：「${p}」`);
    if (p.split('/').includes('..')) fail(`sources[${i}].path 不许含 ..：「${p}」`);
    if (seen.has(p)) fail(`sources 里 path 重复：「${p}」`);
    seen.add(p);

    // 这些会在使用时报错（占位作者、非法日期…）；这里先跑一遍，让**读取清单**时就失败
    const role = resolveRole(e).role;
    const author = resolveAuthor(e);
    const originalDate = resolveOriginalDate(e);
    const sourceType = resolveSourceType(e);

    return {
      // 原样保留清单里的键：`resolveRole` / `resolveOriginalDate` / `resolveSourceType`
      // 读的是 snake_case 的原字段（`original_date` / `source_type`）。
      // 一开始这里只返回驼峰别名，于是 `original_date` 静默丢了 ——
      // 症状是「日期声明了却没带上」，而两边都不报错。
      ...e,
      path: p,
      root: typeof e.root === 'string' && e.root.trim() !== '' ? e.root.trim() : primaryRoot,
      stable_id: typeof e.stable_id === 'string' ? e.stable_id.trim() : undefined,
      role, author, originalDate, sourceType,
      parentSourceKey: e.parent_source_key,
      locator: typeof e.locator === 'string' ? e.locator : undefined,
      sourceTitle: typeof e.source_title === 'string' ? e.source_title : undefined,
    };
  });

  return { scope, instance, primaryRoot, entries };
}

function loadManifest(file, opts) {
  if (!fs.existsSync(file)) {
    fail(`找不到清单 ${file}\n` +
         '  首版只处理清单里列出的资料。先建一份，例如：\n' +
         '  {"scope":"agent:localvault-inbox","sources":[{"path":"某个文件.md","role":"user"}]}');
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    fail(`读不出 ${file}：${e.message}`);
  }
  return parseManifest(raw, opts);
}

/** 按路径查条目（`enumerate` 用它做白名单过滤）。 */
function indexByPath(manifest) {
  const m = new Map();
  for (const e of manifest.entries) m.set(`${e.root}\u0000${e.path}`, e);
  return m;
}

module.exports = { parseManifest, loadManifest, indexByPath, ALLOWED_ENTRY_KEYS };
