'use strict';

/**
 * 工作区地图、入口文档、项目台账、以及注入系统提示词的 instructions。
 *
 * 这是整个 MCP 的「价值核心」：把本地文件的结构、权威入口、命名约定
 * 编译成一段 agent 一开工就能看到的上下文。
 */

const fs = require('node:fs');
const path = require('node:path');
const { toPosix, formatBytes, formatDate, squeeze, truncate, readJsonSafe, expandHome } = require('./util');

/* ------------------------------------------------------------------ *
 * 项目台账
 * ------------------------------------------------------------------ */

function ledgerPath(cfg, db) {
  if (cfg.ledgerFile) return path.join(cfg.primaryRoot, cfg.ledgerFile);
  const { discoverLedger } = require('./discover');
  const found = db ? discoverLedger(db, cfg) : null;
  return found ? path.join(cfg.primaryRoot, found.rel) : null;
}

/**
 * 台账条目可以在多种形状里。通用软件不能假定一定是 { projects: [...] }：
 * 数组、{items:[]}、{id: {...}} 映射都算。归一化后再交给上层。
 */
function ledgerEntries(data) {
  if (Array.isArray(data)) return data;
  if (!data || typeof data !== 'object') return null;
  for (const k of ['projects', 'items', 'entries', 'list', 'rows', 'records', 'nodes']) {
    if (Array.isArray(data[k])) return data[k];
  }
  const keys = Object.keys(data);
  const objs = keys.filter((k) => data[k] && typeof data[k] === 'object' && !Array.isArray(data[k]));
  if (keys.length >= 1 && objs.length >= keys.length / 2) {
    return objs.map((k) => ({ id: k, ...data[k] }));
  }
  return null;
}

const pick = (o, ...keys) => {
  for (const k of keys) {
    if (o && o[k] != null && o[k] !== '') return o[k];
  }
  return undefined;
};
const arr = (o, ...keys) => {
  const v = pick(o, ...keys);
  return Array.isArray(v) ? v : [];
};

function loadLedger(cfg, db) {
  const file = ledgerPath(cfg, db);
  if (!file) return null;
  let stat;
  try {
    stat = fs.statSync(file);
  } catch (_e) {
    return null;
  }
  const data = readJsonSafe(file);
  const raw = ledgerEntries(data);
  if (!raw) return null;
  return {
    file,
    mtime: Math.floor(stat.mtimeMs),
    shape: require('./discover').inspectLedgerShape(file, path.extname(file)) || { shape: 'unknown', count: raw.length },
    baseline: pick(data, 'baseline', 'baseline_date', 'as_of') || '',
    scope: pick(data, 'scope', 'range') || '',
    countSemantics: pick(data, 'count_semantics', 'countSemantics') || '',
    projects: raw
      .map((p) => {
        if (!p || typeof p !== 'object') return null;
        return {
          id: String(pick(p, 'id', 'key', 'slug', 'code') || '').trim(),
          name: String(pick(p, 'name', 'title', 'label') || '').trim(),
          group: String(pick(p, 'group', 'category', 'type', 'section') || '').trim(),
          kind: pick(p, 'kind'),
          domains: arr(p, 'domains', 'urls', 'sites'),
          repositories: arr(p, 'repositories', 'repos', 'git'),
          note: String(pick(p, 'note', 'description', 'desc', 'summary') || ''),
          routes: arr(p, 'routes', 'paths', 'locations'),
        };
      })
      .filter((p) => p && (p.id || p.name)),
  };
}

function projectCardPath(cfg, id) {
  const dir = cfg.policy && cfg.policy.projectCardDir;
  if (!dir) return null;
  return path.join(cfg.primaryRoot, dir, `${id}.md`);
}

/**
 * 反查项目：按编号 / 名称 / 域名 / 仓库 / 卡片正文命中。
 */
function findProject(cfg, db, query, limit) {
  const q = squeeze(query);
  if (!q) return { ok: false, error: '需要 query' };
  const ledger = loadLedger(cfg, db);
  const lim = Math.min(Math.max(Number(limit) || 8, 1), 30);
  const ql = q.toLowerCase();
  const results = [];

  if (ledger) {
    for (const p of ledger.projects) {
      let score = 0;
      const why = [];
      if (p.id && p.id.toLowerCase() === ql) { score += 100; why.push('编号精确匹配'); }
      else if (p.id && p.id.toLowerCase().includes(ql)) { score += 40; why.push('编号部分匹配'); }
      if (p.name && p.name.toLowerCase() === ql) { score += 90; why.push('名称精确匹配'); }
      else if (p.name && p.name.toLowerCase().includes(ql)) { score += 45; why.push('名称包含'); }
      else if (p.name && ql.includes(p.name.toLowerCase()) && p.name.length >= 2) { score += 30; why.push('被输入包含'); }
      for (const d of p.domains) {
        if (d.toLowerCase().includes(ql) || ql.includes(d.toLowerCase())) { score += 35; why.push(`域名 ${d}`); break; }
      }
      for (const r of p.repositories) {
        if (r.toLowerCase().includes(ql)) { score += 30; why.push(`仓库 ${r}`); break; }
      }
      if (p.group && p.group.toLowerCase().includes(ql)) { score += 12; why.push(`分组 ${p.group}`); }
      if (p.note && p.note.toLowerCase().includes(ql)) { score += 8; why.push('备注提到'); }
      if (score > 0) results.push({ project: p, score, why: why.slice(0, 4), source: '台账' });
    }
  }

  // 目录名里含查询词的目录也算命中。
  // 用户常常直接按项目名建目录 —— 这里不假设任何特定的目录层级或名字。
  if (db) {
    try {
      const { escapeLike } = require('./search');
      const rows = db
        .prepare(
          `SELECT DISTINCT rel FROM files
           WHERE gone = 0 AND root = ? AND rel LIKE ? ESCAPE '\\' AND instr(rel, '/') > 0
           LIMIT 800`,
        )
        .all(cfg.primaryRoot, '%' + escapeLike(q) + '%');

      const dirRels = new Set();
      for (const r of rows) {
        const parts = toPosix(r.rel).split('/');
        parts.pop(); // 去掉文件名，只看目录链
        const acc = [];
        for (const seg of parts) {
          acc.push(seg);
          if (seg.toLowerCase().includes(ql)) dirRels.add(acc.join('/'));
        }
      }

      for (const dirRel of dirRels) {
        const seg = dirRel.split('/').pop();
        // 已有结果里的项目如果和这个目录对得上，就挂到它上面，不再新增候选
        const already = results.find(
          (x) =>
            (x.project.id && dirRel.includes(x.project.id)) ||
            (x.project.name && seg.includes(x.project.name)),
        );
        if (already) {
          already.score += 15;
          already.why.push(`目录 ${dirRel}`);
          if (!already.folder) already.folder = toPosix(dirRel);
          continue;
        }
        results.push({
          project: { id: '', name: seg.replace(/^[A-Za-z]+\d+[-_]/, ''), folderName: seg },
          score: 20,
          why: [`目录 ${dirRel}`],
          source: '目录',
          folder: toPosix(dirRel),
        });
      }
    } catch (_e) {
      /* 忽略：目录结构可能不存在 */
    }
  }

  results.sort((a, b) => b.score - a.score);
  const top = results.slice(0, lim).map((r) => {
    const p = r.project;
    const cardAbs = p.id ? projectCardPath(cfg, p.id) : null;
    let card = null;
    if (cardAbs && fs.existsSync(cardAbs)) {
      let st = null;
      try {
        st = fs.statSync(cardAbs);
      } catch (_e) {
        st = null;
      }
      card = {
        path: toPosix(cardAbs),
        rel: toPosix(path.relative(cfg.primaryRoot, cardAbs)),
        mtime: st ? Math.floor(st.mtimeMs) : 0,
        date: st ? formatDate(st.mtimeMs) : '?',
      };
    }
    return {
      id: p.id || null,
      name: p.name || p.folderName || '',
      group: p.group || null,
      kind: p.kind || null,
      domains: p.domains || [],
      repositories: p.repositories || [],
      note: p.note ? truncate(p.note, 120) : '',
      folder: r.folder || null,
      card,
      matchedBy: r.why,
      source: r.source,
      score: r.score,
    };
  });

  return {
    ok: true,
    query: q,
    ledger: ledger
      ? { file: toPosix(ledger.file), baseline: ledger.baseline, projectCount: ledger.projects.length, mtime: ledger.mtime }
      : null,
    candidates: top,
  };
}

/* ------------------------------------------------------------------ *
 * 统计与地图
 * ------------------------------------------------------------------ */

/** 从目录内自己的说明文档推断用途（README / 00-xxx / index，优先浅层）。 */
/** 目录用途推断。实现搬到 discover.js，这里保留薄封装以免调用点四处改。 */
function autoDirNote(db, root, seg) {
  if (!seg) return null;
  return require('./discover').noteFromDir(db, root, seg);
}

function rootStats(db, root) {
  const row = db
    .prepare('SELECT count(*) AS c, coalesce(sum(size),0) AS s, coalesce(max(mtime),0) AS m FROM files WHERE gone = 0 AND root = ?')
    .get(root);
  return { files: Number(row.c), bytes: Number(row.s), latestMtime: Number(row.m) };
}

function topLevelDirs(db, root) {
  return db
    .prepare(
      `SELECT CASE WHEN instr(rel,'/') > 0 THEN substr(rel, 1, instr(rel,'/') - 1) ELSE '' END AS seg,
              count(*) AS c, coalesce(sum(size),0) AS s, coalesce(max(mtime),0) AS m
       FROM files WHERE gone = 0 AND root = ?
       GROUP BY seg ORDER BY c DESC`,
    )
    .all(root)
    .map((r) => ({ seg: String(r.seg || ''), files: Number(r.c), bytes: Number(r.s), mtime: Number(r.m) }));
}

function kindDistribution(db, root) {
  return db
    .prepare(
      `SELECT kind, count(*) AS c, coalesce(sum(size),0) AS s FROM files
       WHERE gone = 0 ${root ? 'AND root = ?' : ''} GROUP BY kind ORDER BY c DESC`,
    )
    .all(...(root ? [root] : []))
    .map((r) => ({ kind: r.kind, files: Number(r.c), bytes: Number(r.s) }));
}

/**
 * 权威入口文档：**显式配置优先，自动发现补空**。
 * 返回项带 origin，让读的人知道哪些是用户指定的、哪些是猜的。
 */
function entryDocs(db, cfg, discovered) {
  const merged = [];
  const seen = new Set();
  for (const rel of cfg.canonicalDocs || []) {
    const key = toPosix(rel);
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push({ rel: key, origin: 'config' });
  }
  const configCount = (cfg.canonicalDocs || []).length;
  let skippedDeeper = 0;
  for (const d of (discovered && discovered.canonicalDocs) || []) {
    if (seen.has(d.rel)) continue;
    // 用户已经声明了入口文档时，只补**根级**导航；
    // 子目录里的 README 属于"目录用途"，已经由 dirNotes 覆盖，
    // 全塞进"权威入口"会把清单稀释成噪声。
    if (configCount > 0 && d.depth > 0) {
      skippedDeeper += 1;
      continue;
    }
    seen.add(d.rel);
    merged.push({ rel: d.rel, origin: 'auto', autoTitle: d.title, autoScore: d.score });
  }

  const out = [];
  for (const item of merged) {
    const abs = path.join(cfg.primaryRoot, item.rel);
    const row = db
      .prepare('SELECT size, mtime, title, body FROM files WHERE gone = 0 AND path = ?')
      .get(abs);
    let exists = Boolean(row);
    let stat = null;
    if (!exists) {
      try {
        stat = fs.statSync(abs);
        exists = true;
      } catch (_e) {
        exists = false;
      }
    }
    if (!exists) continue;
    const title = row && row.title ? squeeze(row.title) : (item.autoTitle || path.basename(item.rel));
    out.push({
      rel: toPosix(item.rel),
      path: toPosix(abs),
      title: truncate(title, 80),
      origin: item.origin,
      size: row ? Number(row.size) : (stat ? stat.size : 0),
      mtime: row ? Number(row.mtime) : (stat ? Math.floor(stat.mtimeMs) : 0),
      date: formatDate(row ? Number(row.mtime) : (stat ? stat.mtimeMs : 0)),
    });
  }
  return { docs: out, skippedDeeper };
}
/**
 * 从用户自己的规则文档里抽取「日常规则」清单。
 * 没有规则文档是完全正常的 —— 返回 exists:false，不报错。
 */
function extractRules(cfg, discovered) {
  const rel = cfg.rulesFile || (discovered && discovered.rules) || null;
  if (!rel) return { file: null, exists: false, origin: 'none', rules: [] };
  const file = path.join(cfg.primaryRoot, rel);
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (_e) {
    return { file: toPosix(file), exists: false, origin: cfg.rulesFile ? 'config' : 'auto', rules: [] };
  }
  const lines = text.split(/\r?\n/);
  const rules = [];
  let inSection = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (/^##\s+/.test(line)) {
      inSection = /日常规则|命名|规范|rule|convention|guideline/i.test(line);
      continue;
    }
    if (!inSection) continue;
    const m = /^\d+\.\s+(.*)$/.exec(line);
    if (m) rules.push(squeeze(m[1].replace(/\*\*/g, '')));
  }
  return { file: toPosix(file), exists: true, origin: cfg.rulesFile ? 'config' : 'auto', rules: rules.slice(0, 20) };
}

/**
 * 构建完整地图对象。会被缓存在 meta 里，供 instructions 快速读取。
 */
function buildMap(db, cfg) {
  const started = Date.now();
  // 一次推断，多处复用。显式配置永远优先。
  const discovered = require('./discover').runDiscovery(db, cfg);
  const roots = cfg.roots.map((r) => {
    const st = rootStats(db, r.path);
    let exists = false;
    try {
      exists = fs.statSync(r.path).isDirectory();
    } catch (_e) {
      exists = false;
    }
    return {
      path: toPosix(r.path),
      label: r.label,
      priority: r.priority,
      exists,
      files: st.files,
      bytes: st.bytes,
      bytesText: formatBytes(st.bytes),
      latestMtime: st.latestMtime,
      latestDate: formatDate(st.latestMtime),
    };
  });

  const primary = roots.find((r) => r.path === toPosix(cfg.primaryRoot)) || roots[0] || null;
  const dirs = primary ? topLevelDirs(db, primary.path) : [];
  const annotated = dirs.map((d) => {
    const manual = (cfg.dirNotes && cfg.dirNotes[d.seg]) || '';
    let note = manual;
    let noteSource = manual ? 'config' : null;
    if (!manual && d.seg) {
      const auto = (discovered.dirNotes && discovered.dirNotes[d.seg]) || null;
      if (auto) {
        note = auto.note;
        noteSource = auto.source;
      }
    }
    return {
      name: d.seg || '(根目录散文件)',
      isRootLoose: !d.seg,
      files: d.files,
      bytes: d.bytes,
      bytesText: formatBytes(d.bytes),
      mtime: d.mtime,
      date: formatDate(d.mtime),
      note,
      noteSource,
    };
  });

  const ledger = loadLedger(cfg, db);
  const entriesRes = entryDocs(db, cfg, discovered);
  const map = {
    generatedAt: Date.now(),
    generatedDate: formatDate(Date.now()),
    tookMs: Date.now() - started,
    dataDir: toPosix(cfg.dataDirAbs),
    primaryRoot: toPosix(cfg.primaryRoot),
    roots,
    totalFiles: roots.reduce((a, r) => a + r.files, 0),
    totalBytes: roots.reduce((a, r) => a + r.bytes, 0),
    topLevelDirs: annotated,
    kinds: kindDistribution(db, primary ? primary.path : null),
    entryDocs: entriesRes.docs,
    rules: extractRules(cfg, discovered),
    /** 哪些东西是推断来的、依据是什么 —— 猜错时必须看得出怎么猜的。 */
    discovery: {
      configFile: toPosix(cfg.configFile || ''),
      sources: discovered.sources,
      canonicalDocsFromConfig: (cfg.canonicalDocs || []).length,
      dirNotesFromConfig: Object.keys(cfg.dirNotes || {}).length,
      entryDocsSkippedDeeper: entriesRes.skippedDeeper,
      ledgerRel: discovered.ledger ? discovered.ledger.rel : null,
      ledgerShape: discovered.ledger ? discovered.ledger.shape : null,
      rulesRel: cfg.rulesFile || discovered.rules || null,
    },
    ledger: ledger
      ? {
          file: toPosix(ledger.file),
          baseline: ledger.baseline,
          projectCount: ledger.projects.length,
          groups: [...new Set(ledger.projects.map((p) => p.group).filter(Boolean))],
          mtime: ledger.mtime,
        }
      : null,
    lastScanAt: Number(require('./store').getMeta(db, 'last_scan_at') || 0),
  };
  map.totalBytesText = formatBytes(map.totalBytes);
  map.lastScanDate = formatDate(map.lastScanAt);
  return map;
}

/** 渲染成给人看的 Markdown 地图。 */
function renderMapMarkdown(map, cfg) {
  const L = [];
  L.push(`# 本地上下文地图`);
  L.push('');
  L.push(`生成时间：${map.generatedDate}　|　数据基线：${map.lastScanDate}　|　索引目录：\`${map.dataDir}\``);
  L.push('');
  L.push('## 索引范围');
  L.push('');
  L.push('| 根 | 路径 | 文件数 | 体量 | 最新改动 |');
  L.push('| --- | --- | ---: | ---: | --- |');
  for (const r of map.roots) {
    L.push(`| ${r.label}${r.exists ? '' : '（不存在）'} | \`${r.path}\` | ${r.files} | ${r.bytesText} | ${r.latestDate} |`);
  }
  L.push('');
  L.push(`合计 **${map.totalFiles}** 个文件 / ${map.totalBytesText}。`);
  L.push('');
  if (map.entryDocs.length) {
    L.push('## 权威入口文档');
    L.push('');
    L.push('| 文档 | 相对路径 | 大小 | 更新 |');
    L.push('| --- | --- | ---: | --- |');
    for (const d of map.entryDocs) L.push(`| ${d.title} | \`${d.rel}\` | ${formatBytes(d.size)} | ${d.date} |`);
    L.push('');
  }
  if (map.topLevelDirs.length) {
    L.push(`## ${map.primaryRoot} 顶层目录`);
    L.push('');
    L.push('| 目录 | 文件数 | 体量 | 最新改动 | 用途 |');
    L.push('| --- | ---: | ---: | --- | --- |');
    for (const d of map.topLevelDirs) {
      L.push(`| \`${d.name}\` | ${d.files} | ${d.bytesText} | ${d.date} | ${d.note || ''}${d.noteSource && d.noteSource !== 'config' ? `（据 \`${d.noteSource}\`）` : ''} |`);
    }
    L.push('');
  }
  if (map.ledger) {
    L.push('## 项目台账');
    L.push('');
    L.push(
      `\`${map.ledger.file}\`：**${map.ledger.projectCount}** 个项目，${map.ledger.groups.length} 个分组` +
        (map.ledger.baseline ? `，盘点基线 ${map.ledger.baseline}` : '') +
        '。',
    );
    L.push('');
  }
  if (map.rules && map.rules.rules.length) {
    L.push('## 用户自定义规则（摘要）');
    L.push('');
    L.push(`来源：\`${map.rules.file}\`` + (map.rules.origin === 'auto' ? '（自动发现的规则文档）' : '（配置指定）'));
    L.push('');
    map.rules.rules.forEach((r, i) => L.push(`${i + 1}. ${r}`));
    L.push('');
  }
  L.push('## 类型分布');
  L.push('');
  L.push('| 类型 | 文件数 | 体量 |');
  L.push('| --- | ---: | ---: |');
  for (const k of map.kinds) L.push(`| ${k.kind} | ${k.files} | ${formatBytes(k.bytes)} |`);
  L.push('');
  return L.join('\n');
}

/**
 * 渲染注入系统提示词的 instructions。
 * 硬上限由 dsh-mcp-client 的 maxInstructionBytes（默认 32768）控制，
 * 这里保守截到 24000 字节。
 */
function renderInstructions(map, cfg) {
  const L = [];
  L.push('本机「本地上下文」索引已就绪（MCP server: localvault）。回答任何关于本机文件、项目、资料位置的问题之前，先用这里的工具检索，不要凭印象猜路径。');
  L.push('');
  L.push(`索引数据基线：${map.lastScanDate}（由本机文件系统生成，非人工盘点）。`);
  L.push('');
  L.push('索引范围：');
  for (const r of map.roots) {
    if (!r.exists) {
      L.push(`- ${r.label} \`${r.path}\` —— 当前不存在或不可读`);
    } else {
      L.push(`- ${r.label} \`${r.path}\` —— ${r.files} 个文件 / ${r.bytesText}，最新改动 ${r.latestDate}`);
    }
  }
  L.push('');

  if (map.entryDocs.length) {
    L.push(`工作区权威入口（根：\`${map.primaryRoot}\`）。这些是唯一权威来源；谈项目状态、资产归属、服务器现状时先读入口，再谈细节：`);
    for (const d of map.entryDocs) {
      L.push(`- ${d.rel}（${d.title}，更新 ${d.date}）`);
    }
    L.push('');
  }

  if (map.topLevelDirs.length) {
    L.push('工作区顶层目录用途：');
    for (const d of map.topLevelDirs) {
      if (d.isRootLoose) {
        L.push(`- 根目录散落文件 —— ${d.files} 个（违反「根目录只放导航与分类目录」，见 vault_audit 的 root_clutter）`);
        continue;
      }
      const purpose = d.note ? `${d.note}${d.noteSource && d.noteSource !== 'config' ? `（据 ${d.noteSource}）` : ''}` : '（用途未标注）';
      L.push(`- \`${d.name}/\` —— ${purpose}；${d.files} 个文件，${d.bytesText}，最新改动 ${d.date}`);
    }
    L.push('');
  }

  if (map.ledger) {
    L.push(
      `项目台账：\`${map.ledger.file}\` 共 ${map.ledger.projectCount} 个项目、${map.ledger.groups.length} 个分组` +
        (map.ledger.baseline ? `，盘点基线 ${map.ledger.baseline}` : '') +
        '。按名称 / 域名 / 仓库 / 编号反查项目用 `mcp__localvault__find_project`。',
    );
    L.push('');
  }

  if (map.rules && map.rules.rules.length) {
    L.push(`文件管理规则（摘自 \`${map.rules.file}\`）—— 新增或整理文件时按这些规则执行：`);
    map.rules.rules.slice(0, 12).forEach((r, i) => L.push(`${i + 1}. ${r}`));
    L.push(`（共 ${map.rules.rules.length} 条，完整内容读该文件。）`);
    L.push('');
  }

  L.push('可用工具（什么时候用哪个）：');
  L.push('- `mcp__localvault__vault_map` —— 开局或需要确认目录结构与入口文档时；返回完整地图。');
  L.push('- `mcp__localvault__find_files` —— 按关键词/正文/类型/时间检索本地文件，中文按子串匹配（含 2 字词）。');
  L.push('- `mcp__localvault__find_project` —— 用项目名、域名、仓库名或 P 编号反查项目卡片与资料目录。');
  L.push('- `mcp__localvault__read_text` —— 读索引里任意文本文件的正文（带行号与上限）。');
  L.push('- `mcp__localvault__list_directory` —— 列某个目录下的条目，用于导航与盘点。');
  L.push('- `mcp__localvault__recent_changes` —— 看最近改了什么（默认 7 天），适合接手他人在途工作。');
  L.push('- `mcp__localvault__disk_coverage` —— 覆盖度报告：多少文件真能搜、暗区按「变亮要付什么代价」分层。谈「值不值得治理、先做哪一层」之前先看它。');
  L.push('- `mcp__localvault__vault_audit` —— 文件治理体检：重复文件、陈旧文件、版本化命名、待整理积压、根目录堆积、断链。');
  L.push('- `mcp__localvault__propose_organize` —— 按文件管理规则生成整理方案（**只出报告，不动文件**）。');
  L.push('- `mcp__localvault__refresh_index` —— 索引过期或刚改过文件后重建（增量，秒级到分钟级）。');
  L.push('');
  L.push('边界与纪律：');
  L.push('- 这些治理工具**只读**：不会移动、重命名或删除任何文件。要真正改动，走正常文件操作并先向用户确认。');
  L.push('- 密钥类文件（`.env`、`*.pem`、`*.key`、`*credential*` 等）只记录元数据，正文从未进入索引。');
  L.push('- 索引是某一时刻的快照。凡是要断言「现在是什么状态」，先看基线时间，必要时先 `refresh_index`。');

  let text = L.join('\n');
  const MAX = 24000;
  if (Buffer.byteLength(text, 'utf8') > MAX) {
    // 按行裁剪，保证不截断 UTF-8
    const lines = text.split('\n');
    const kept = [];
    let used = 0;
    for (const line of lines) {
      const b = Buffer.byteLength(line, 'utf8') + 1;
      if (used + b > MAX - 200) break;
      kept.push(line);
      used += b;
    }
    kept.push('');
    kept.push('（instructions 因长度上限被截断，完整地图请调用 mcp__localvault__vault_map。）');
    text = kept.join('\n');
  }
  return text;
}

function readTextFile(cfg, db, targetPath, opts) {
  const o = opts || {};
  const abs = path.isAbsolute(targetPath) ? targetPath : path.resolve(cfg.primaryRoot, targetPath);
  const maxBytes = Math.min(Math.max(Number(o.maxBytes) || 200000, 1000), 2 * 1024 * 1024);
  const startLine = Math.max(Number(o.startLine) || 1, 1);
  const maxLines = Math.min(Math.max(Number(o.maxLines) || 400, 1), 5000);

  const row = db
    .prepare('SELECT path, rel, size, mtime, is_text, denied, title, body, truncated FROM files WHERE path = ?')
    .get(abs);

  let body = null;
  let source = 'db';
  let denied = row ? Boolean(Number(row.denied)) : false;

  if (denied && !o.allowDenied) {
    return {
      ok: false,
      path: toPosix(abs),
      error: '该文件被敏感文件规则排除，索引中没有正文。请直接用文件读取工具打开（并注意其中可能含密钥）。',
      denied: true,
    };
  }

  if (row && row.body) {
    body = String(row.body);
  } else {
    // 不在索引里 / 没正文：现场读，但必须落在已配置的根目录内
    const inside = cfg.roots.some((r) => abs === r.path || abs.startsWith(r.path + path.sep));
    if (!inside) {
      return {
        ok: false,
        path: toPosix(abs),
        error: '路径不在任何已配置索引根内，拒绝读取。',
        outsideRoots: true,
      };
    }
    let st;
    try {
      st = fs.statSync(abs);
    } catch (e) {
      return { ok: false, path: toPosix(abs), error: `文件不存在或不可读：${e.code || e.message}` };
    }
    if (st.isDirectory()) {
      return { ok: false, path: toPosix(abs), error: '这是目录，请用 list_directory。' };
    }
    if (st.size > maxBytes) {
      return {
        ok: false,
        path: toPosix(abs),
        error: `文件 ${formatBytes(st.size)} 超过单次读取上限 ${formatBytes(maxBytes)}；请提高 maxBytes 或改用其他方式。`,
      };
    }
    try {
      const { extractFile } = require('./extract');
      const res = extractFile(abs, { maxBytes: maxBytes, maxStoredChars: maxBytes });
      if (!res.ok) return { ok: false, path: toPosix(abs), error: res.reason };
      if (res.binary) return { ok: false, path: toPosix(abs), error: '二进制文件，无法按文本读取。' };
      body = res.body || '';
      source = 'disk';
    } catch (e) {
      return { ok: false, path: toPosix(abs), error: String(e.message || e) };
    }
  }

  const lines = body.split('\n');
  const slice = lines.slice(startLine - 1, startLine - 1 + maxLines);
  const width = String(startLine + slice.length - 1).length;
  const numbered = slice
    .map((l, i) => `${String(startLine + i).padStart(width, ' ')}| ${l}`)
    .join('\n');

  return {
    ok: true,
    path: toPosix(abs),
    rel: row ? toPosix(row.rel) : toPosix(path.relative(cfg.primaryRoot, abs)),
    source,
    indexed: Boolean(row),
    title: row && row.title ? squeeze(row.title) : '',
    size: row ? Number(row.size) : body.length,
    mtime: row ? Number(row.mtime) : 0,
    date: formatDate(row ? Number(row.mtime) : Date.now()),
    truncatedInIndex: row ? Boolean(Number(row.truncated)) : false,
    totalLines: lines.length,
    startLine,
    returnedLines: slice.length,
    hasMoreLines: startLine - 1 + slice.length < lines.length,
    content: numbered,
  };
}

function resolveRoot(cfg, value) {
  if (!value) return null;
  const v = expandHome(String(value));
  const byPath = cfg.roots.find((r) => r.path === v);
  if (byPath) return byPath.path;
  const byLabel = cfg.roots.find((r) => r.label === value);
  if (byLabel) return byLabel.path;
  const byBase = cfg.roots.find((r) => path.basename(r.path) === value);
  if (byBase) return byBase.path;
  return null;
}

module.exports = {
  loadLedger,
  findProject,
  buildMap,
  renderMapMarkdown,
  renderInstructions,
  readTextFile,
  resolveRoot,
  rootStats,
  topLevelDirs,
  kindDistribution,
  extractRules,
  ledgerPath,
};
