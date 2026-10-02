'use strict';

/**
 * MCP 协议层（stdio，换行分隔 JSON-RPC 2.0）。
 *
 * 手写实现，不引入 @modelcontextprotocol/sdk —— 本机没有可用的 npm 网络环境，
 * 且协议面很小（initialize / tools / resources）。stdout 只输出协议帧，
 * 所有日志走 stderr（MCP 规范允许，宿主的子进程日志会收集 stderr）。
 */

const path = require('node:path');
const { spawn } = require('node:child_process');

const PROTOCOL_VERSIONS = ['2026-07-28', '2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const DEFAULT_PROTOCOL = '2025-06-18';

const SERVER_NAME = 'localvault';
const SERVER_VERSION = '1.0.0';

function log(...args) {
  try {
    process.stderr.write(`[localvault] ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`);
  } catch (_e) {
    /* ignore */
  }
}

/** 单次工具结果上限，避免一次体检把上下文塞满。报告的关键结论都在开头。 */
const MAX_TOOL_TEXT_CHARS = 48000;

function capText(text) {
  const s = String(text == null ? '' : text);
  if (s.length <= MAX_TOOL_TEXT_CHARS) return s;
  return (
    s.slice(0, MAX_TOOL_TEXT_CHARS) +
    `\n\n---\n（结果过长已截断，共 ${s.length} 字符。缩小范围的办法：` +
    `vault_audit 传入更小的 limit 或只查具体 checks；find_files 提高过滤条件或降低 limit。）`
  );
}

/* ------------------------------------------------------------------ *
 * JSON-RPC 读写
 * ------------------------------------------------------------------ */

class StdioTransport {
  constructor(onMessage) {
    this.onMessage = onMessage;
    this.buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => this.push(chunk));
    process.stdin.on('end', () => this.onEnd && this.onEnd());
    process.stdin.on('error', (e) => log('stdin error', e.message));
  }

  push(chunk) {
    this.buffer += chunk;
    for (;;) {
      const idx = this.buffer.indexOf('\n');
      if (idx < 0) break;
      const line = this.buffer.slice(0, idx).replace(/\r$/, '');
      this.buffer = this.buffer.slice(idx + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (e) {
        log('无法解析的输入行：', line.slice(0, 200));
        continue;
      }
      try {
        this.onMessage(msg);
      } catch (e) {
        log('处理消息出错：', e && e.stack ? e.stack : String(e));
      }
    }
  }

  send(obj) {
    const text = JSON.stringify(obj);
    process.stdout.write(text + '\n');
  }
}

/* ------------------------------------------------------------------ *
 * 工具定义
 * ------------------------------------------------------------------ */

const TOOLS = [
  {
    name: 'vault_map',
    description:
      '返回本机「本地上下文」地图：索引了哪些根目录、顶层目录用途、权威入口文档、台账概况、文件类型分布、用户自定义规则摘要。**目录用途与入口文档可能是自动推断的**，返回值里的 discovery 字段说明来源。回答任何关于本机文件/项目的问题前先调用它。',
    inputSchema: {
      type: 'object',
      properties: {
        format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown；json 返回结构化地图。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'disk_coverage',
    description:
      '覆盖度报告：本机索引里有多少文件真正可搜，暗区按「变亮需要付出什么」分层（白捡 / 格式解析 / OCR / 转录 / 本来就不该变亮）。要谈「值不值得治理」「先做哪一层」之前调用它；也是判断某个治理动作代价的依据。',
    inputSchema: {
      type: 'object',
      properties: {
        format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown；json 返回结构化覆盖度。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'find_files',
    description:
      '在索引内检索文件。中文按子串匹配（2 个字就能命中），同时匹配文件名、相对路径、文档标题、各级标题和正文。可按类型、扩展名、根目录、路径前缀、修改时间、体积过滤。',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '关键词，空格分隔多个词（必须全部命中）。留空则按时间倒序列出文件。' },
        scope: { type: 'string', enum: ['all', 'name', 'content'], description: '检索范围：all=路径+正文（默认），name=只看路径与文件名，content=只看标题与正文。' },
        kind: { type: 'string', description: '类型过滤：doc/sheet/slide/image/video/audio/archive/code/data/web/other，逗号分隔。' },
        ext: { type: 'string', description: '扩展名过滤，如 ".md,.txt"。' },
        root: { type: 'string', description: '限定某个索引根（绝对路径或配置里的标签，如「工作区」）。' },
        path_prefix: { type: 'string', description: '限定相对路径前缀，如 "docs/specs"（用 INDEX 里看到的实际目录名）。' },
        since: { type: 'string', description: '起始时间：ISO 日期、"30d"、"6m"、"3周" 等。' },
        before: { type: 'string', description: '截止时间，格式同 since。' },
        min_size: { type: 'number', description: '最小体积（字节）。' },
        max_size: { type: 'number', description: '最大体积（字节）。' },
        sort: { type: 'string', enum: ['relevance', 'recent', 'oldest', 'size', 'name'], description: '默认 relevance（无 query 时默认 recent）。' },
        limit: { type: 'number', description: '返回条数，默认 20，上限 200。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'find_project',
    description:
      '用项目名、域名、代码仓库名或编号反查项目：命中台账条目、项目卡片路径、以及相关资料目录。台账位置由配置或自动发现决定（没有台账时退化为全文检索）。谈某个项目之前先用它定位。',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '项目名 / 域名 / 仓库名 / P 编号 / 任意关键词。' },
        limit: { type: 'number', description: '返回候选数，默认 8。' },
      },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'read_text',
    description:
      '读取索引内任意文本文件的正文（带行号）。密钥类文件被规则排除，不会返回正文。不在索引里的文件也会现场读取，但必须位于已配置的索引根内。',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '绝对路径，或相对于工作区根的路径。' },
        start_line: { type: 'number', description: '起始行，默认 1。' },
        max_lines: { type: 'number', description: '最多返回行数，默认 400，上限 5000。' },
        max_bytes: { type: 'number', description: '索引外文件的最大读取字节，默认 200000。' },
      },
      required: ['path'],
      additionalProperties: false,
    },
  },
  {
    name: 'list_directory',
    description: '列出某个目录下的文件条目（来自索引），用于导航、盘点与「这个目录里都有什么」。',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '绝对路径，或相对于工作区根的路径。' },
        limit: { type: 'number', description: '最多返回条数，默认 200。' },
      },
      required: ['path'],
      additionalProperties: false,
    },
  },
  {
    name: 'recent_changes',
    description: '查看最近改动的文件（默认 7 天），按目录聚合 + 明细。接手在途工作时用它快速知道「最近动了什么」。',
    inputSchema: {
      type: 'object',
      properties: {
        since: { type: 'string', description: '时间窗口，如 "7d"、"24h"、"2周"，默认 7d。' },
        root: { type: 'string', description: '限定索引根。' },
        path_prefix: { type: 'string', description: '限定相对路径前缀。' },
        kind: { type: 'string', description: '类型过滤。' },
        limit: { type: 'number', description: '明细条数，默认 40，上限 200。' },
        group_by: { type: 'string', enum: ['topdir', 'none'], description: '默认按工作区顶层目录聚合。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'vault_audit',
    description:
      '文件治理体检（只读）：重复文件（内容哈希）、陈旧文件、版本化命名（词表可配置）、收集目录积压（未配置则跳过）、根目录堆积、Markdown 断链。**判定标准来自用户的 policy 配置，不是通行规范。**绝不移动或删除文件。',
    inputSchema: {
      type: 'object',
      properties: {
        checks: { type: 'string', description: 'comma 分隔：duplicates,stale,naming,inbox,root_clutter,links；默认 all。' },
        root: { type: 'string', description: '限定索引根。' },
        days: { type: 'number', description: '陈旧判定天数（stale/inbox 用），默认取配置。' },
        limit: { type: 'number', description: '每项最多列出多少条。' },
        format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'propose_organize',
    description:
      '生成一份整理方案（dry-run）：哪些根目录散文件、哪些重复/版本化文件建议归档。只出报告，不动文件；**执行必须由用户逐条确认**。',
    inputSchema: {
      type: 'object',
      properties: {
        root: { type: 'string', description: '限定索引根，默认工作区根。' },
        limit: { type: 'number', description: '每类建议最多条数，默认 25。' },
        format: { type: 'string', enum: ['markdown', 'json'], description: '默认 markdown。' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'refresh_index',
    description:
      '重建索引（增量：未改动的文件只刷元数据）。默认在后台子进程运行，立即返回，不会阻塞当前对话；完成后再调用工具即可看到新数据。',
    inputSchema: {
      type: 'object',
      properties: {
        full: { type: 'boolean', description: 'true 表示忽略 mtime 缓存、全部重新抽取正文（慢）。' },
        wait: { type: 'boolean', description: 'true 表示等待完成（小目录可用；大工作区可能超过工具调用超时）。' },
      },
      additionalProperties: false,
    },
  },
];

/* ------------------------------------------------------------------ *
 * 资源定义
 * ------------------------------------------------------------------ */

const STATIC_RESOURCES = [
  { uri: 'vault://map', name: '本地上下文地图', description: '索引范围、目录用途、入口文档、规则摘要、类型分布', mimeType: 'text/markdown' },
  { uri: 'vault://guide', name: '使用指南与边界', description: '这些工具能做什么、不能做什么，以及先读什么', mimeType: 'text/markdown' },
  { uri: 'vault://projects', name: '项目清单', description: '来自本机台账文件的项目列表（位置由配置或自动发现决定）', mimeType: 'text/markdown' },
  { uri: 'vault://recent', name: '最近改动（7 天）', description: '最近 7 天修改过的文件', mimeType: 'text/markdown' },
];

const RESOURCE_TEMPLATES = [
  { uriTemplate: 'vault://file/{path}', name: '读取本地文件', description: '按路径读取索引内的文本文件（path 为绝对路径或相对工作区根的路径）', mimeType: 'text/plain' },
];

/* ------------------------------------------------------------------ *
 * 服务
 * ------------------------------------------------------------------ */

class LocalVaultServer {
  constructor(opts) {
    const o = opts || {};
    this.cfgLoader = o.configLoader || (() => require('./config').loadConfig());
    this.cfg = null;
    this.db = null;
    this.initialized = false;
    this.transport = new StdioTransport((msg) => this.handle(msg));
    this.toolCalls = 0;
  }

  prepare() {
    if (!this.cfg) this.cfg = this.cfgLoader();
    return this.cfg;
  }

  db_() {
    if (!this.db) {
      const fs = require('node:fs');
      const cfg = this.prepare();
      const exists = fs.existsSync(cfg.dbPath);
      const { openDatabase } = require('./store');
      this.db = openDatabase(cfg.dbPath);
      this.dbExisted = exists;
    }
    return this.db;
  }

  hasIndex() {
    try {
      const db = this.db_();
      const v = require('./store').getMeta(db, 'last_scan_at');
      return Boolean(v && Number(v) > 0);
    } catch (_e) {
      return false;
    }
  }

  instructions() {
    try {
      const db = this.db_();
      const { getMeta } = require('./store');
      const cached = getMeta(db, 'instructions');
      if (cached) return cached;
    } catch (_e) {
      /* fallthrough */
    }
    return [
      '本机「本地上下文」索引（MCP server: localvault）尚未建立。',
      '',
      '处理方式：先调用 mcp__localvault__refresh_index 触发首次索引（后台运行），',
      '等它完成后再调用 mcp__localvault__vault_map 获取完整地图。',
      '在此之前，不要凭印象回答关于本机文件与项目的问题。',
      '',
      '注意：本服务器提供的治理能力全部只读，不会移动或删除任何文件。',
    ].join('\n');
  }

  /* ---------------------------- 分发 ---------------------------- */

  handle(msg) {
    if (!msg || typeof msg !== 'object') return;
    if (msg.method === undefined) return; // 客户端响应，本服务器不发起请求
    const isNotification = msg.id === undefined || msg.id === null;

    if (isNotification) {
      if (msg.method === 'notifications/initialized') {
        this.initialized = true;
        log('客户端已完成初始化');
      }
      // 其余通知静默忽略
      return;
    }

    try {
      const result = this.dispatch(msg.method, msg.params || {});
      if (result && typeof result.then === 'function') {
        result.then(
          (r) => this.reply(msg.id, r),
          (e) => this.replyError(msg.id, -32603, String((e && e.message) || e)),
        );
        return;
      }
      this.reply(msg.id, result);
    } catch (e) {
      if (e && e.jsonRpcCode) this.replyError(msg.id, e.jsonRpcCode, e.message);
      else this.replyError(msg.id, -32603, String((e && e.message) || e));
    }
  }

  dispatch(method, params) {
    switch (method) {
      case 'initialize':
        return this.onInitialize(params);
      case 'ping':
        return {};
      case 'tools/list':
        return { tools: TOOLS };
      case 'tools/call':
        return this.onToolCall(params);
      case 'resources/list':
        return { resources: STATIC_RESOURCES };
      case 'resources/templates/list':
        return { resourceTemplates: RESOURCE_TEMPLATES };
      case 'resources/read':
        return this.onResourceRead(params);
      case 'prompts/list':
        return { prompts: [] };
      case 'logging/setLevel':
        return {};
      case 'completion/complete':
        return { completion: { values: [] } };
      default: {
        const err = new Error(`未实现的方法：${method}`);
        err.jsonRpcCode = -32601;
        throw err;
      }
    }
  }

  reply(id, result) {
    this.transport.send({ jsonrpc: '2.0', id, result: result === undefined ? {} : result });
  }

  replyError(id, code, message) {
    this.transport.send({ jsonrpc: '2.0', id, error: { code, message } });
  }

  onInitialize(params) {
    const requested = params && params.protocolVersion;
    const protocolVersion = PROTOCOL_VERSIONS.includes(requested) ? requested : DEFAULT_PROTOCOL;
    let instructions;
    try {
      instructions = this.instructions();
    } catch (e) {
      log('生成 instructions 失败：', e.message);
      instructions = '本地上下文索引读取失败，请调用 mcp__localvault__refresh_index 重建。';
    }
    log(`initialize：protocolVersion=${protocolVersion}，instructions ${Buffer.byteLength(instructions, 'utf8')} 字节`);
    return {
      protocolVersion,
      capabilities: {
        tools: { listChanged: false },
        resources: { subscribe: false, listChanged: false },
      },
      serverInfo: { name: SERVER_NAME, title: '本地上下文 MCP', version: SERVER_VERSION },
      instructions,
    };
  }

  /* ---------------------------- 工具执行 ---------------------------- */

  onToolCall(params) {
    const name = params && params.name;
    const args = (params && params.arguments) || {};
    this.toolCalls += 1;
    const started = Date.now();
    let payload;
    try {
      payload = this.runTool(name, args);
    } catch (e) {
      // 协议级错误（未知工具、参数缺失）按 JSON-RPC error 返回，
      // 其余执行期异常转成 isError 的工具结果，让模型能看到原因。
      if (e && e.jsonRpcCode) throw e;
      log(`工具 ${name} 失败：`, e && e.stack ? e.stack : String(e));
      return {
        content: [{ type: 'text', text: `工具 ${name} 执行失败：${(e && e.message) || e}` }],
        isError: true,
      };
    }
    log(`工具 ${name} 完成，用时 ${Date.now() - started}ms`);
    if (typeof payload === 'string') {
      return { content: [{ type: 'text', text: capText(payload) }] };
    }
    if (payload && payload.__error) {
      return { content: [{ type: 'text', text: payload.__error }], isError: true };
    }
    return { content: [{ type: 'text', text: capText(payload.text) }] };
  }

  ensureIndexed(featureName) {
    try {
      if (this.hasIndex()) return null;
    } catch (e) {
      return `索引无法打开：${e.message}`;
    }
    this.spawnIndexBuild({});
    return [
      `索引尚未建立，已在后台启动首次构建（增量扫描 工作区 / 桌面 / 下载）。`,
      ``,
      `请等待构建完成（首次约 1–3 分钟，取决于文件数量），然后重新调用 ${featureName}。`,
      `可以先做别的事，构建在独立子进程中运行，不会阻塞对话。`,
    ].join('\n');
  }

  runTool(name, args) {
    switch (name) {
      case 'vault_map':
        return this.toolVaultMap(args);
      case 'find_files':
        return this.toolFindFiles(args);
      case 'find_project':
        return this.toolFindProject(args);
      case 'read_text':
        return this.toolReadText(args);
      case 'list_directory':
        return this.toolListDirectory(args);
      case 'recent_changes':
        return this.toolRecentChanges(args);
      case 'vault_audit':
        return this.toolAudit(args);
      case 'disk_coverage':
        return this.toolDiskCoverage(args);
      case 'propose_organize':
        return this.toolProposeOrganize(args);
      case 'refresh_index':
        return this.toolRefreshIndex(args);
      default: {
        const err = new Error(`未知工具：${name}`);
        err.jsonRpcCode = -32602;
        throw err;
      }
    }
  }

  toolVaultMap(args) {
    const pending = this.ensureIndexed('vault_map');
    if (pending) return { text: pending };
    const db = this.db_();
    const { buildMap, renderMapMarkdown } = require('./vault');
    const map = buildMap(db, this.cfg);
    if ((args && args.format) === 'json') return { text: JSON.stringify(map, null, 2) };
    return { text: renderMapMarkdown(map, this.cfg) };
  }

  toolDiskCoverage(args) {
    const pending = this.ensureIndexed('disk_coverage');
    if (pending) return { text: pending };
    const db = this.db_();
    const { computeCoverage } = require('./coverage');
    const cov = computeCoverage(db, this.cfg);
    if ((args && args.format) === 'json') {
      const { markdown, ...rest } = cov;
      return { text: JSON.stringify(rest, null, 2) };
    }
    return { text: cov.markdown };
  }

  /**
   * 参数写错时的提示。**这些原本全是静默降级。**
   *
   * 实测过的四种：`root:"不存在的根"` 被忽略、`since:"昨天"` 被忽略（悄悄按 7 天算）、
   * `sort:"bogus"` 被忽略、`format:"xml"` 被忽略。调用方**无法知道自己给错了** ——
   * 它拿到一个看起来正常的答案，然后基于错误的假设继续。
   *
   * 对 agent 尤其致命：agent 试一次参数、拿到结果、就认为参数是对的。
   * 静默降级把「试错」变成了「撞上一个碰巧的答案」。
   */
  paramWarnings(a) {
    // 本文件用方法内惰性 require，所以这里也得自己取。
    const { resolveRoot } = require('./vault');
    const { parseSince } = require('./util');
    const w = [];
    if (a.root != null && a.root !== '' && !resolveRoot(this.cfg, a.root)) {
      const labels = this.cfg.roots.map((r) => `\`${r.label}\``).join('、');
      w.push(`「root: ${JSON.stringify(a.root)}」不对应任何索引根，**这个条件已被忽略**。可用：${labels}`);
    }
    for (const key of ['since', 'before']) {
      const v = a[key];
      if (v != null && v !== '' && parseSince(v) == null) {
        w.push(`「${key}: ${JSON.stringify(v)}」看不懂，**已按默认值处理**。可用 \`7d\` / \`24h\` / \`3周\` / \`2个月\` 或毫秒时间戳。`);
      }
    }
    if (a.sort != null && !['relevance', 'recent', 'oldest', 'size', 'name'].includes(String(a.sort))) {
      w.push(`「sort: ${JSON.stringify(a.sort)}」不是可用的排序，**已按默认排序**。可用 relevance / recent / oldest / size / name。`);
    }
    if (a.format != null && a.format !== 'json' && a.format !== 'markdown') {
      w.push(`「format: ${JSON.stringify(a.format)}」不认识，**已按 markdown 处理**。可用 json / markdown。`);
    }
    if (a.limit != null) {
      const n = Number(a.limit);
      if (!Number.isFinite(n) || n < 1) {
        w.push(`「limit: ${JSON.stringify(a.limit)}」不是正整数，**已按默认值处理**。`);
      }
    }
    return w;
  }

  toolFindFiles(args) {
    const pending = this.ensureIndexed('find_files');
    if (pending) return { text: pending };
    const db = this.db_();
    const { searchFiles, countDenied } = require('./search');
    const { resolveRoot } = require('./vault');
    const a = args || {};
    const warns = this.paramWarnings(a);
    const rootPath = a.root ? resolveRoot(this.cfg, a.root) : null;
    const res = searchFiles(db, this.cfg, {
      query: a.query,
      scope: a.scope,
      kind: a.kind,
      ext: a.ext,
      root: rootPath || undefined,
      pathPrefix: a.path_prefix,
      since: a.since,
      before: a.before,
      minSize: a.min_size,
      maxSize: a.max_size,
      sort: a.sort,
      limit: a.limit,
    });
    if (!res.ok) return { __error: res.error };

    const L = [];
    if (warns.length) {
      L.push('> ⚠️ **参数有问题**（已按默认值继续，结果可能不是你要的）：');
      for (const w of warns) L.push(`> - ${w}`);
      L.push('');
    }
    L.push(`检索「${res.query || '(空，按时间列出)'}」：返回 ${res.returned} 条${res.hasMore ? '（还有更多，可提高 limit 或缩小范围）' : ''}，用时 ${res.tookMs}ms。`);
    L.push('');
    if (!res.hits.length) {
      L.push('没有命中。');
      L.push('');
      // 「真的没有」和「有但被策略排除」必须能分开。
      // 实测的坑：`find_files{ext:".env"}` 返回 0 条，而 `list_directory` 明确列出了
      // `shilu-studio/.env` —— 同一份数据，一个说「有」，一个说「没有命中」。
      const deniedHit = countDenied(db, { root: rootPath || undefined, nameLike: (a.ext || a.query || '').replace(/^\*/, '') });
      if (deniedHit > 0) {
        L.push(`**但有 ${deniedHit} 个文件是按策略排除的**（密钥类，正文从未入库）——`);
        L.push('它们**不会被检索到**，这是有意的。这不是「索引坏了」，也不是「文件不存在」。');
        L.push('用 `list_directory` 能看到它们的元数据；正文永远读不到（见 隐私.md）。');
      } else {
        L.push('索引里确实没有匹配的文件（也确认过：不是被策略排除造成的）。');
      }
      L.push('');
      L.push('可以尝试：换个同义词、缩短关键词（中文 2 个字也能搜）、把 scope 设为 `name` 只搜文件名、或用 `since` 限定时间范围。');
      return { text: L.join('\n') };
    }
    for (const h of res.hits) {
      L.push(`### ${h.title || h.name}`);
      L.push(`- 路径：\`${h.rel}\``);
      L.push(`- 位于：\`${h.root}\`　类型：${h.kind}　体积：${h.sizeText}　最后改动：${h.date}　命中：${h.matchedIn.join('/') || '-'}`);
      if (h.snippet) L.push(`- 摘要：${h.snippet}`);
      L.push('');
    }
    return { text: L.join('\n') };
  }

  toolFindProject(args) {
    const pending = this.ensureIndexed('find_project');
    if (pending) return { text: pending };
    const db = this.db_();
    const { findProject } = require('./vault');
    const res = findProject(this.cfg, db, (args && args.query) || '', args && args.limit);
    if (!res.ok) return { __error: res.error };
    const L = [];
    L.push(`反查「${res.query}」：${res.candidates.length} 个候选。`);
    if (res.ledger) {
      L.push('');
      L.push(`台账：\`${res.ledger.file}\`（${res.ledger.projectCount} 个项目${res.ledger.baseline ? '，基线 ' + res.ledger.baseline : ''}）`);
    }
    L.push('');
    if (!res.candidates.length) {
      L.push('台账与项目资料目录里都没有匹配项。');
      L.push('');
      L.push('可能原因：名字不同、台账里只有个表格条目、或还没有对应文件。可以改用 `find_files` 全文检索这个词；若没有命中，本项目可能未配置台账。');
      return { text: L.join('\n') };
    }
    for (const c of res.candidates) {
      L.push(`## ${c.id ? c.id + ' · ' : ''}${c.name}`);
      if (c.group) L.push(`- 分组：${c.group}${c.kind ? `　类型：${c.kind}` : ''}`);
      if (c.domains.length) L.push(`- 域名：${c.domains.join('、')}`);
      if (c.repositories.length) L.push(`- 仓库：${c.repositories.join('、')}`);
      if (c.note) L.push(`- 备注：${c.note}`);
      if (c.folder) L.push(`- 资料目录：\`${c.folder}\``);
      if (c.card) L.push(`- 项目卡片：\`${c.card.rel}\`（更新 ${c.card.date}）`);
      L.push(`- 命中依据：${c.matchedBy.join('；')}`);
      L.push('');
    }
    L.push('提示：台账里的「历史观察」是 2026-09-12 的盘点结果，不代表当前线上状态。');
    return { text: L.join('\n') };
  }

  toolReadText(args) {
    const db = this.db_();
    const { readTextFile } = require('./vault');
    const a = args || {};
    if (!a.path) return { __error: '需要 path' };
    const res = readTextFile(this.cfg, db, a.path, {
      startLine: a.start_line,
      maxLines: a.max_lines,
      maxBytes: a.max_bytes,
    });
    if (!res.ok) return { __error: res.error };
    const L = [];
    L.push(`文件：\`${res.rel}\``);
    L.push(`来源：${res.source === 'db' ? '索引' : '磁盘现场读取'}　共 ${res.totalLines} 行，返回第 ${res.startLine}–${res.startLine + res.returnedLines - 1} 行${res.hasMoreLines ? '（还有后续行）' : ''}`);
    if (res.truncatedInIndex) L.push('注意：索引中的正文曾在 400000 字符处截断。');
    L.push('');
    L.push('```');
    L.push(res.content);
    L.push('```');
    return { text: L.join('\n') };
  }

  toolListDirectory(args) {
    const pending = this.ensureIndexed('list_directory');
    if (pending) return { text: pending };
    const db = this.db_();
    const { listDirectory } = require('./search');
    const a = args || {};
    const p = a.path || this.cfg.primaryRoot;
    const abs = path.isAbsolute(p) ? p : path.resolve(this.cfg.primaryRoot, p);
    const res = listDirectory(db, abs, { limit: a.limit });
    const L = [];
    L.push(`目录：\`${res.dir}\``);
    L.push('');
    if (!res.items.length) {
      L.push('索引里这个目录下没有条目（可能不存在、或只有被跳过的机器生成目录）。');
      return { text: L.join('\n') };
    }
    L.push(`返回 ${res.returned} 条${res.hasMore ? '（还有更多，提高 limit）' : ''}：`);
    L.push('');
    L.push('| 路径 | 类型 | 体积 | 最后改动 | 标题 |');
    L.push('| --- | --- | ---: | --- | --- |');
    for (const i of res.items) {
      L.push(`| \`${i.rel}\` | ${i.kind} | ${i.sizeText} | ${i.date} | ${(i.title || '').slice(0, 60)} |`);
    }
    return { text: L.join('\n') };
  }

  toolRecentChanges(args) {
    const pending = this.ensureIndexed('recent_changes');
    if (pending) return { text: pending };
    const db = this.db_();
    const { listFiles } = require('./search');
    const { resolveRoot } = require('./vault');
    const { parseSince, formatBytes, formatDate, daysAgo } = require('./util');
    const a = args || {};
    const sinceMs = parseSince(a.since || '7d') || Date.now() - 7 * 86400000;
    const rootPath = a.root ? resolveRoot(this.cfg, a.root) : this.cfg.primaryRoot;
    // `withTotal` 是关键：没有它，下面那句「命中 N 条」只能是 `LIMIT` 出来的行数。
    // 实测：limit=40 → 报「命中 40 条」，而真值是 4,805 条。
    // 那不是「少报了一点」，是把上限写成了总数，而且它**看起来就是个统计值**。
    const rows = listFiles(db, {
      root: rootPath,
      pathPrefix: a.path_prefix,
      sinceMs,
      limit: a.limit || 40,
      withTotal: true,
    });

    const byTop = new Map();
    for (const r of rows) {
      const rel = r.rel;
      const seg = rel.includes('/') ? rel.split('/')[0] : '(根目录)';
      if (!byTop.has(seg)) byTop.set(seg, { count: 0, bytes: 0 });
      const g = byTop.get(seg);
      g.count += 1;
      g.bytes += r.size;
    }

    const L = [];
    const total = rows.total != null ? rows.total : rows.length;
    const warns = this.paramWarnings(a);
    L.push(`# 最近改动（自 ${formatDate(sinceMs)} 起）`);
    L.push('');
    if (warns.length) {
      L.push('> ⚠️ **参数有问题**（已按默认值继续，结果可能不是你要的）：');
      for (const w of warns) L.push(`> - ${w}`);
      L.push('');
    }
    // 说清三个数：一共多少、返回了多少、下面列出的是什么。
    // 原来只有一个数，还被写成了「命中」。
    L.push(`根：\`${rootPath}\`　**共 ${total} 条**${total > rows.length ? `，下面列出最近改动的 ${rows.length} 条` : ''}。`);
    if (total > rows.length) {
      L.push('');
      L.push(`> 要提高返回条数用 \`limit\`（当前 ${rows.length}）。`);
      L.push('> 想按别的根看，用 `root` 指定 —— **不传时只查主根，其它根一条都不出现**。');
    }
    L.push('');
    if ((a.group_by || 'topdir') !== 'none' && byTop.size) {
      // 这张表建在**返回的那 N 条**上，不是全部。原来没有任何说明，
      // 于是「smart_editing 40 条（100%）」被读成了整体分布。
      L.push(`## 按顶层目录（仅统计上面那 ${rows.length} 条${total > rows.length ? '，不是全部' : ''}）`);
      L.push('');
      L.push('| 目录 | 条数 | 体量 |');
      L.push('| --- | ---: | ---: |');
      for (const [seg, g] of [...byTop.entries()].sort((x, y) => y[1].count - x[1].count)) {
        L.push(`| \`${seg}\` | ${g.count} | ${formatBytes(g.bytes)} |`);
      }
      L.push('');
    }
    L.push('## 明细');
    L.push('');
    for (const r of rows) {
      L.push(`- \`${r.rel}\`　${r.sizeText}　${daysAgo(r.mtime)} 天前　${r.title ? '— ' + r.title : ''}`);
    }
    return { text: L.join('\n') };
  }

  toolAudit(args) {
    const pending = this.ensureIndexed('vault_audit');
    if (pending) return { text: pending };
    const db = this.db_();
    const { audit } = require('./governance');
    const { resolveRoot } = require('./vault');
    const a = args || {};
    const rootPath = a.root ? resolveRoot(this.cfg, a.root) : null;
    const res = audit(db, this.cfg, { checks: a.checks, root: rootPath || undefined, days: a.days, limit: a.limit });
    if ((a.format || 'markdown') === 'json') {
      return { text: JSON.stringify({ checks: res.checks, unknown: res.unknown }, null, 2) };
    }
    let text = res.markdown;
    if (res.unknown.length) text += `\n\n> 忽略了未知检查项：${res.unknown.join('、')}`;
    return { text };
  }

  toolProposeOrganize(args) {
    const pending = this.ensureIndexed('propose_organize');
    if (pending) return { text: pending };
    const db = this.db_();
    const { proposeOrganize } = require('./governance');
    const { resolveRoot } = require('./vault');
    const a = args || {};
    const rootPath = a.root ? resolveRoot(this.cfg, a.root) : this.cfg.primaryRoot;
    const res = proposeOrganize(db, this.cfg, { root: rootPath, limit: a.limit });
    if ((a.format || 'markdown') === 'json') {
      return { text: JSON.stringify({ root: res.root, totalProposals: res.totalProposals, byCategory: res.byCategory, proposals: res.proposals }, null, 2) };
    }
    return { text: res.markdown };
  }

  toolRefreshIndex(args) {
    const a = args || {};
    this.db_(); // 确保数据目录存在
    if (a.wait) {
      const { buildIndex, describeScanSummary } = require('./indexer');
      const summary = buildIndex(this.cfg, this.db_(), { full: Boolean(a.full) });
      this.rebuildCaches();
      return { text: `已完成索引重建。\n\n${describeScanSummary(summary)}` };
    }
    const r = this.spawnIndexBuild({ full: Boolean(a.full) });
    if (r.error) return { __error: r.error };
    return {
      text: [
        '已在后台子进程中启动索引重建（增量）。',
        '',
        `日志：\`${r.logFile}\``,
        '',
        '构建期间索引仍可查询（读到的是上一次的快照）。建议 1–3 分钟后再调用需要新数据的工具。',
        '若要同步等待，可改用 `refresh_index { wait: true }`（大工作区可能超出工具调用超时）。',
      ].join('\n'),
    };
  }

  rebuildCaches() {
    try {
      const { buildMap, renderInstructions } = require('./vault');
      const { setMeta, setMetaJson } = require('./store');
      const db = this.db_();
      const map = buildMap(db, this.cfg);
      setMetaJson(db, 'map', { ...map, _cachedAt: Date.now() });
      setMeta(db, 'instructions', renderInstructions(map, this.cfg));
    } catch (e) {
      log('刷新缓存失败：', e.message);
    }
  }

  spawnIndexBuild(opts) {
    const o = opts || {};
    try {
      const fs = require('node:fs');
      const { ensureDir } = require('./util');
      const dataDir = this.cfg.dataDirAbs;
      ensureDir(dataDir);
      const logFile = path.join(dataDir, 'index.log');
      const out = fs.openSync(logFile, 'a');
      const cli = path.join(__dirname, '..', 'cli.js');
      const args = [cli, 'index'];
      if (o.full) args.push('--full');
      const child = spawn(process.execPath, args, {
        detached: true,
        stdio: ['ignore', out, out],
        env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', LOCALVAULT_QUIET: '1' },
      });
      child.unref();
      log(`已启动后台索引子进程 pid=${child.pid}`);
      return { pid: child.pid, logFile };
    } catch (e) {
      log('启动后台索引失败：', e.message);
      return { error: `启动后台索引失败：${e.message}` };
    }
  }

  /* ---------------------------- 资源 ---------------------------- */

  onResourceRead(params) {
    const uri = params && params.uri;
    if (!uri) {
      const err = new Error('需要 uri');
      err.jsonRpcCode = -32602;
      throw err;
    }
    const db = this.db_();

    if (uri === 'vault://guide') {
      return {
        contents: [{ uri, mimeType: 'text/markdown', text: this.guideText() }],
      };
    }

    if (uri === 'vault://map' || uri === 'vault://overview') {
      const { buildMap, renderMapMarkdown } = require('./vault');
      const map = buildMap(db, this.cfg);
      return { contents: [{ uri, mimeType: 'text/markdown', text: renderMapMarkdown(map, this.cfg) }] };
    }

    if (uri === 'vault://projects') {
      const { loadLedger } = require('./vault');
      const ledger = loadLedger(this.cfg, this.db_());
      if (!ledger) {
        return { contents: [{ uri, mimeType: 'text/markdown', text: '未找到台账文件（未配置 ledgerFile，且自动发现没有找到像台账的文件）。' }] };
      }
      const L = [];
      L.push(`# 项目台账（${ledger.projects.length} 项${ledger.baseline ? '，基线 ' + ledger.baseline : ''}）`);
      L.push('');
      const groups = new Map();
      for (const p of ledger.projects) {
        const g = p.group || '(未分组)';
        if (!groups.has(g)) groups.set(g, []);
        groups.get(g).push(p);
      }
      for (const [g, list] of groups) {
        L.push(`## ${g}（${list.length}）`);
        L.push('');
        for (const p of list) {
          L.push(`- ${p.id} · ${p.name}${p.domains.length ? '　' + p.domains.join('、') : ''}${p.repositories.length ? '　仓库 ' + p.repositories.join('、') : ''}`);
        }
        L.push('');
      }
      return { contents: [{ uri, mimeType: 'text/markdown', text: L.join('\n') }] };
    }

    if (uri === 'vault://recent') {
      const { listFiles } = require('./search');
      const rows = listFiles(db, { root: this.cfg.primaryRoot, sinceMs: Date.now() - 7 * 86400000, limit: 100 });
      const L = [`# 最近 7 天改动（${rows.length} 条）`, ''];
      for (const r of rows) L.push(`- \`${r.rel}\`　${r.sizeText}　${r.date}`);
      return { contents: [{ uri, mimeType: 'text/markdown', text: L.join('\n') }] };
    }

    if (uri.startsWith('vault://file/')) {
      const raw = uri.slice('vault://file/'.length);
      const target = decodeURIComponent(raw);
      const { readTextFile } = require('./vault');
      const res = readTextFile(this.cfg, db, target, { maxLines: 2000 });
      if (!res.ok) {
        return { contents: [{ uri, mimeType: 'text/plain', text: `读取失败：${res.error}` }] };
      }
      return {
        contents: [
          {
            uri,
            mimeType: 'text/plain',
            text: `# ${res.rel}\n（共 ${res.totalLines} 行，以下为前 ${res.returnedLines} 行）\n\n${res.content}`,
          },
        ],
      };
    }

    const err = new Error(`未知资源：${uri}`);
    err.jsonRpcCode = -32602;
    throw err;
  }

  guideText() {
    const cfg = this.prepare();
    return [
      '# 本地上下文 MCP · 使用指南',
      '',
      '## 它能做什么',
      '',
      '- 把本机三个根目录（工作区 / 桌面 / 下载）的文件元数据与文本正文建成索引；',
      '- 支持中文子串全文检索（2 个字起）、类型/时间/体积过滤；',
      '- 把项目台账变成可反查的：项目名、域名、仓库名、P 编号都能定位；',
      '- 提供文件治理体检：重复、陈旧、版本化命名、收集目录积压（可选）、根目录堆积、断链；',
      '- 一开工就把工作区地图注入系统提示词，避免「先乱翻目录」。',
      '',
      '## 它明确不做什么',
      '',
      '- **不移动、不重命名、不删除任何文件。** `propose_organize` 出的只是报告。',
      '- 不读取密钥类文件的正文（`.env`、`*.pem`、`*.key`、`*credential*` 等只留元数据）。',
      '- 不访问网络、不上传任何内容；索引只写在本机。',
      '- 不跟随符号链接，不进入 node_modules / .git / dist 等机器生成目录。',
      '',
      '## 数据位置',
      '',
      `- 索引库：\`${cfg.dbPath}\``,
      `- 配置：\`${cfg.configFile}\``,
      '',
      '## 推荐用法',
      '',
      '1. 开工看 `vault_map`，确认权威入口文档；',
      '2. 需要具体资料用 `find_files`（中文直接搜词）；',
      '3. 谈某个项目先用 `find_project` 定位台账条目与卡片；',
      '4. 接手在途工作先看 `recent_changes`；',
      '5. 想整理文件先跑 `vault_audit` + `propose_organize`，拿到清单后逐条与用户确认。',
      '',
      '## 边界',
      '',
      '- 索引是快照。要断言「现在是什么状态」，先看地图里的数据基线时间，必要时 `refresh_index`。',
      '- 台账里的线上状态是 2026-09-12 的盘点结果，不等于当前线上状态。',
    ].join('\n');
  }
}

function start(opts) {
  const server = new LocalVaultServer(opts);
  try {
    server.prepare();
  } catch (e) {
    log('配置载入失败：', e.message);
  }
  // 预热数据库（不阻塞 initialize 太多：仅在文件存在时打开）
  try {
    server.db_();
  } catch (e) {
    log('数据库打开失败：', e.message);
  }
  log(`已启动 pid=${process.pid}，profile=${process.env.DSH_PROFILE || '-'}`);
  return server;
}

module.exports = { LocalVaultServer, start, TOOLS, STATIC_RESOURCES, RESOURCE_TEMPLATES, log };
