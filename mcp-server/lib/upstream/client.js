'use strict';

/**
 * 记忆中心 MCP 客户端（Streamable HTTP）。
 *
 * 来件：「现有记忆中心MCP地址：https://qiuyiwu.com/api/memory/mcp，
 * 传输为Streamable HTTP，认证使用Authorization: Bearer <专用Token>。
 * 这不是模型API Key，不使用网站登录密码。先通过MCP初始化及tools/list核查部署中的实际schema。」
 *
 * ## 凭据只从环境读
 *
 * 「Token放本机密钥存储或环境配置，不进源码、原文、日志和导出包。」
 * 所以：**没有任何一处能传 token 参数**。只能读 `LOCALVAULT_MEMORY_TOKEN`。
 * 错误信息里也**绝不回显 token**（哪怕是前几位）。
 *
 * ## 错误分类，不是错误汇总
 *
 * 来件对不同错误要求不同处置，混成一类会让「该停的」被重试、或反之：
 *
 *   401 / 403           → `auth`      **停下解决权限，不换 scope**
 *   4xx 校验错误         → `validation` 记录原因等修复，**不回退重试**
 *   429 / 5xx / 网络     → `transient`  有界退避
 *   结果不明（超时）      → `unknown`    **用完全相同的 source_key 和 payload 重试**
 */

const DEFAULT_ENDPOINT = 'https://qiuyiwu.com/api/memory/mcp';
const PROTOCOL_VERSION = '2024-11-05';
const CLIENT_NAME = 'localvault-adapter';
const CLIENT_VERSION = '1.0.0';

class MemoryCenterError extends Error {
  constructor(kind, message, { status, retryable, body } = {}) {
    super(message);
    this.name = 'MemoryCenterError';
    this.kind = kind;                 // auth | validation | transient | unknown | protocol
    this.status = status;
    this.retryable = Boolean(retryable);
    this.body = body;
  }
}

function classify(status, text) {
  if (status === 401 || status === 403) {
    return new MemoryCenterError('auth', `凭据被拒（HTTP ${status}）：停在权限问题上，不换 scope、不重试`, { status });
  }
  if (status === 429) {
    return new MemoryCenterError('transient', `限流（HTTP 429）`, { status, retryable: true });
  }
  if (status >= 500) {
    return new MemoryCenterError('transient', `服务端错误（HTTP ${status}）`, { status, retryable: true, body: text });
  }
  if (status >= 400) {
    return new MemoryCenterError('validation', `参数/校验错误（HTTP ${status}）：${(text || '').slice(0, 300)}`,
                                 { status, body: text });
  }
  return new MemoryCenterError('protocol', `意外的 HTTP ${status}`, { status, body: text });
}

/** Streamable HTTP 可能返回 `application/json` 或 `text/event-stream`。两者都要认。 */
function parseRpcBody(contentType, text) {
  if ((contentType || '').includes('text/event-stream')) {
    const out = [];
    for (const line of text.split('\n')) {
      const t = line.trim();
      if (!t.startsWith('data:')) continue;
      const payload = t.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try { out.push(JSON.parse(payload)); } catch { /* 不是 JSON 的事件忽略 */ }
    }
    return out.length ? out[out.length - 1] : null;
  }
  try { return JSON.parse(text); } catch { return null; }
}

class MemoryCenterClient {
  /**
   * @param {object} [opts]
   * @param {string} [opts.endpoint]
   * @param {string} [opts.token]   不传则读环境变量。**不要把它传到别处去。**
   * @param {Function} [opts.fetch] 测试注入
   * @param {number} [opts.timeoutMs]
   * @param {number} [opts.maxRetries]
   */
  constructor(opts = {}) {
    this.endpoint = opts.endpoint || process.env.LOCALVAULT_MEMORY_ENDPOINT || DEFAULT_ENDPOINT;
    this.token = opts.token || process.env.LOCALVAULT_MEMORY_TOKEN || '';
    this.fetchImpl = opts.fetch || globalThis.fetch;
    this.timeoutMs = opts.timeoutMs || 30000;
    this.maxRetries = opts.maxRetries == null ? 3 : opts.maxRetries;
    this._id = 0;
    this._initialized = false;
    if (!this.fetchImpl) throw new MemoryCenterError('protocol', '运行环境没有 fetch（需要 Node ≥ 18）');
  }

  hasToken() { return this.token.length > 0; }

  /** token 的**可安全打印**形式：只说有没有，不说是什么。 */
  describeToken() {
    return this.hasToken() ? '已配置（不回显）' : '未配置';
  }

  headers() {
    const h = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    };
    if (this.token) h.Authorization = `Bearer ${this.token}`;
    return h;
  }

  async _rpc(method, params, { retryable = true } = {}) {
    const id = ++this._id;
    const body = JSON.stringify({ jsonrpc: '2.0', id, method, params });

    let attempt = 0;
    for (;;) {
      let res;
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), this.timeoutMs);
      try {
        res = await this.fetchImpl(this.endpoint, {
          method: 'POST', headers: this.headers(), body, signal: ctl.signal,
        });
      } catch (e) {
        clearTimeout(timer);
        // 网络层失败（含超时）：**结果不明** —— 调用方必须用同一个 source_key 重试
        if (retryable && attempt < this.maxRetries) {
          await sleep(backoff(attempt));
          attempt++;
          continue;
        }
        throw new MemoryCenterError('unknown', `请求结果不明（${e.name === 'AbortError' ? '超时' : e.message}）：` +
          '服务端可能已经收到。重试时必须复用完全相同的 source_key 和 payload。',
          { retryable: true });
      }
      clearTimeout(timer);

      const text = await res.text();
      if (!res.ok) {
        const err = classify(res.status, text);
        if (err.retryable && retryable && attempt < this.maxRetries) {
          await sleep(backoff(attempt));
          attempt++;
          continue;
        }
        throw err;
      }

      const rpc = parseRpcBody(res.headers.get('content-type'), text);
      if (!rpc) throw new MemoryCenterError('protocol', '响应不是可解析的 JSON/SSE');
      if (rpc.error) {
        const kind = /scope|forbidden|not allowed|unauthor/i.test(rpc.error.message || '') ? 'auth' : 'validation';
        throw new MemoryCenterError(kind, `服务端返回错误：${JSON.stringify(rpc.error).slice(0, 300)}`, { body: rpc.error });
      }
      return rpc.result;
    }
  }

  async initialize() {
    const r = await this._rpc('initialize', {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: CLIENT_NAME, version: CLIENT_VERSION },
    });
    this._initialized = true;
    await this._notify('notifications/initialized', {});
    return r;
  }

  async _notify(method, params) {
    try {
      await this.fetchImpl(this.endpoint, {
        method: 'POST', headers: this.headers(),
        body: JSON.stringify({ jsonrpc: '2.0', method, params }),
      });
    } catch { /* 通知失败不影响后续调用 */ }
  }

  async ensureInitialized() {
    if (!this._initialized) await this.initialize();
  }

  /** 核查部署中的实际 schema（来件要求先做这一步）。 */
  async listTools() {
    await this.ensureInitialized();
    const r = await this._rpc('tools/list', {});
    return (r && r.tools) || [];
  }

  /**
   * 调一个工具。
   *
   * `processing_policy: 'archive'` 由调用方在 payload 里显式写明 ——
   * 这个类**不替调用方决定** policy，因为来件说了「显式传 archive 只能表达客户端策略，
   * 不能作为服务端安全保证」，所以它必须是 payload 里看得见的一个字段。
   */
  async callTool(name, args) {
    await this.ensureInitialized();
    const r = await this._rpc('tools/call', { name, arguments: args });
    return r;
  }

  /** 便捷：提交一批归档。 */
  async importArchive(payload) {
    if (payload.processing_policy !== 'archive') {
      throw new MemoryCenterError('validation',
        `拒绝提交：processing_policy 必须是 archive，收到 ${JSON.stringify(payload.processing_policy)}`);
    }
    return this.callTool('memory_import', payload);
  }

  /** 查归档/索引状态。按来件：归档与索引状态分开看。 */
  async importStatus({ sourceKey, sourceId, jobId }) {
    const args = {};
    if (sourceKey) args.source_key = sourceKey;
    if (sourceId) args.source_id = sourceId;
    if (jobId) args.job_id = jobId;
    return this.callTool('memory_import_status', args);
  }
}

function backoff(attempt) {
  const base = Math.min(500 * 2 ** attempt, 8000);
  return base + Math.floor(Math.random() * 250);
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

module.exports = { MemoryCenterClient, MemoryCenterError, DEFAULT_ENDPOINT, PROTOCOL_VERSION, classify, parseRpcBody };
