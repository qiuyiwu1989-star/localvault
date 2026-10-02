'use strict';

/**
 * 覆盖度报告：这块盘有多黑，以及「变亮」分别需要付出什么。
 *
 * 设计原则（来自硬脑决策层方法论的等价推论）：
 *   一个数字的存在理由，是它驱动一个具体动作。
 * 所以这里不报一个笼统的「覆盖率」，而是把暗区按**变亮所需的手段**分层：
 * 有的白捡（抽取 bug）、有的确定性可解（格式解析）、有的要花钱（OCR/转录）、
 * 有的**本来就不该变亮**（.dylib / .ttf / 机器包）。
 *
 * 最后那一类是最容易被治理工具忽略的：把不该索引的东西算进「暗区」，
 * 会让分母虚高，进而把「我们只覆盖了 4%」变成一句吓人但推不出动作的话。
 */

const path = require('node:path');
const { formatBytes, formatDate, mdTable } = require('./util');

/** 变亮手段，按「代价从低到高」排列。 */
const LADDER = {
  ok: { order: 0, label: '已有正文', cost: '—', note: '已经可搜' },
  fix: { order: 1, label: '白捡（抽取 bug）', cost: '零', note: '本来就是文本，抽取却没拿到正文——修抽取层即可' },
  chunk: { order: 2, label: '超限分块', cost: '零', note: '文件大于抽取上限，分块读取即可' },
  extractor: { order: 3, label: '需要格式解析', cost: '零（算力）', note: 'PDF / Office / Pages 等，确定性解析，不调模型' },
  ocr: { order: 4, label: '需要 OCR', cost: '本地免费 / 云端花钱', note: '图片与扫描件' },
  asr: { order: 5, label: '需要转录', cost: '花钱 + 耗算力', note: '音视频' },
  unpack: { order: 6, label: '需要解包', cost: '低，但通常不值得', note: '压缩包与安装包；解包后可能又是几千个文件' },
  nosql: { order: 7, label: '需要查库', cost: '零', note: 'sqlite / db 文件，需要按表查询而非全文索引' },
  skip: { order: 8, label: '不必变亮', cost: '—', note: '动态库 / 字体 / 机器包 / 密钥，索引它们不驱动任何动作' },
  excluded: { order: 9, label: '按策略排除', cost: '—', note: '密钥类只记元数据；符号链接与 0 字节' },
};

/** 本来就索引不到任何人类内容的扩展名。 */
const NEVER_BRIGHT = new Set([
  '.dylib', '.so', '.a', '.o', '.class', '.pyc', '.pyo', '.wasm',
  '.ttf', '.otf', '.woff', '.woff2', '.eot',
  '.enc', '.1', '.mo', '.pak', '.bin', '.dat', '.idx',
  '.cer', '.crt', '.der', '.p12', '.pfx',
]);

function classify(rec, cfg) {
  const ext = String(rec.ext || '').toLowerCase();
  const kind = String(rec.kind || 'other');
  const size = Number(rec.size) || 0;
  const bodyLen = Number(rec.body_len) || 0;

  if (Number(rec.gone)) return 'excluded';
  if (Number(rec.is_symlink)) return 'excluded';
  if (size === 0) return 'excluded';
  if (Number(rec.denied)) return 'excluded';
  if (kind === 'bundle') return 'skip';

  if (bodyLen > 0) return 'ok';

  // 无正文，逐个找原因
  if (!Number(rec.is_text)) {
    if (NEVER_BRIGHT.has(ext)) return 'skip';
    if (kind === 'image') return 'ocr';
    if (kind === 'audio' || kind === 'video') return 'asr';
    if (kind === 'archive') return 'unpack';
    if (kind === 'doc' || kind === 'sheet' || kind === 'slide') return 'extractor';
    if (kind === 'data') return 'nosql';
    return 'skip';
  }

  // 声明是文本，却没有正文
  if (size > cfg.maxTextBytes) return 'chunk';
  if (Number(rec.is_binary)) return 'skip';
  return 'fix';
}

/**
 * @param {object} db
 * @param {object} cfg
 * @returns {object} 覆盖度结构（含 markdown）
 */
function computeCoverage(db, cfg) {
  const rows = db
    .prepare(
      `SELECT root, rel, name, ext, kind, size, mtime, is_text, is_symlink, denied,
              is_binary, truncated, gone, length(coalesce(body,'')) AS body_len
       FROM files`,
    )
    .all();

  const live = rows.filter((r) => !Number(r.gone));

  const buckets = new Map();
  for (const k of Object.keys(LADDER)) {
    buckets.set(k, { key: k, files: 0, bytes: 0, exts: new Map(), samples: [] });
  }

  let totalFiles = 0;
  let totalBytes = 0;
  let searchableFiles = 0;
  let searchableBytes = 0;
  let truncated = 0;

  for (const r of live) {
    const key = classify(r, cfg);
    const b = buckets.get(key);
    const size = Number(r.size) || 0;
    b.files += 1;
    b.bytes += size;
    const ext = String(r.ext || '(无扩展名)').toLowerCase();
    b.exts.set(ext, (b.exts.get(ext) || 0) + 1);
    if (b.samples.length < 5) b.samples.push(String(r.rel));
    totalFiles += 1;
    totalBytes += size;
    if (key === 'ok') {
      searchableFiles += 1;
      searchableBytes += size;
    }
    if (Number(r.truncated)) truncated += 1;
  }

  // 按根分列
  const perRoot = db
    .prepare(
      `SELECT f.root AS root, count(*) AS files, sum(f.size) AS bytes,
              sum(CASE WHEN length(coalesce(f.body,'')) > 0 THEN 1 ELSE 0 END) AS with_body
       FROM files f WHERE f.gone = 0 GROUP BY f.root`,
    )
    .all()
    .map((r) => ({
      root: r.root,
      label: (cfg.roots.find((x) => x.path === r.root) || {}).label || path.basename(r.root),
      files: Number(r.files),
      bytes: Number(r.bytes),
      withBody: Number(r.with_body),
      pct: Number(r.files) ? (Number(r.with_body) / Number(r.files)) * 100 : 0,
    }));

  // 最大的单个暗文件（按体量），这是「体量上的暗」最直观的证据
  const biggestDark = live
    .filter((r) => classify(r, cfg) !== 'ok')
    .sort((a, b) => Number(b.size) - Number(a.size))
    .slice(0, 10)
    .map((r) => ({
      rel: String(r.rel),
      size: Number(r.size),
      kind: String(r.kind),
      key: classify(r, cfg),
      label: LADDER[classify(r, cfg)].label,
    }));

  const ordered = Object.keys(LADDER)
    .map((k) => buckets.get(k))
    .filter((b) => b.files > 0)
    .sort((a, b) => LADDER[a.key].order - LADDER[b.key].order);

  const result = {
    generatedAt: Date.now(),
    totals: {
      files: totalFiles,
      bytes: totalBytes,
      searchableFiles,
      searchableBytes,
      pctFiles: totalFiles ? (searchableFiles / totalFiles) * 100 : 0,
      pctBytes: totalBytes ? (searchableBytes / totalBytes) * 100 : 0,
      truncated,
    },
    buckets: ordered.map((b) => ({
      key: b.key,
      label: LADDER[b.key].label,
      cost: LADDER[b.key].cost,
      note: LADDER[b.key].note,
      files: b.files,
      bytes: b.bytes,
      pctFiles: totalFiles ? (b.files / totalFiles) * 100 : 0,
      topExts: [...b.exts.entries()].sort((x, y) => y[1] - x[1]).slice(0, 8).map(([ext, n]) => ({ ext, n })),
      samples: b.samples,
    })),
    perRoot,
    biggestDark,
  };
  result.markdown = renderCoverage(result, cfg);
  return result;
}

function renderCoverage(cov, cfg) {
  const t = cov.totals;
  const L = [];
  L.push('# 覆盖度报告：这块盘有多黑');
  L.push('');
  L.push(`生成时间：${formatDate(cov.generatedAt)}`);
  L.push('');
  L.push('> 只读统计，不移动任何文件。分母是**索引范围内**的文件（已排除 node_modules/.git/dist 等机器生成目录）。');
  L.push('');

  L.push('## 一句话');
  L.push('');
  L.push(
    `**${t.files.toLocaleString()} 个文件里有 ${t.searchableFiles.toLocaleString()} 个可搜正文（${t.pctFiles.toFixed(1)}%）**；` +
      `但按体量只有 ${t.pctBytes.toFixed(1)}%（${formatBytes(t.searchableBytes)} / ${formatBytes(t.bytes)}）。`,
  );
  L.push('');
  L.push('数量和体量差这么远，是因为暗区的体量集中在少数大文件上——下面「体量最大的暗文件」一节会看到。');
  L.push('');

  L.push('## 暗区按「变亮需要付出什么」分层');
  L.push('');
  L.push('这是本报告的主表。**不按文件类型分层，按代价分层**——因为类型驱动不了动作，代价才能。');
  L.push('');
  L.push(
    mdTable(
      ['变亮手段', '代价', '文件数', '占比', '体量', '主要扩展名'],
      cov.buckets.map((b) => [
        b.label,
        b.cost,
        b.files.toLocaleString(),
        `${b.pctFiles.toFixed(1)}%`,
        formatBytes(b.bytes),
        b.topExts.slice(0, 5).map((e) => `${e.ext}(${e.n})`).join(' '),
      ]),
    ),
  );
  L.push('');

  // 关键：把"白捡"和"本来就不该变亮"单独拎出来
  const fix = cov.buckets.find((b) => b.key === 'fix');
  const chunk = cov.buckets.find((b) => b.key === 'chunk');
  const skip = cov.buckets.find((b) => b.key === 'skip');
  const extractor = cov.buckets.find((b) => b.key === 'extractor');
  const ocr = cov.buckets.find((b) => b.key === 'ocr');
  const asr = cov.buckets.find((b) => b.key === 'asr');

  L.push('### 两个最该先看的数字');
  L.push('');
  if (fix && fix.files) {
    L.push(
      `- **白捡 ${fix.files} 个**：声明是文本、体积也在上限内，抽取却没拿到正文。` +
        `这些不需要任何新能力，修抽取层就有。示例：${fix.samples.slice(0, 3).map((s) => `\`${s}\``).join('、')}`,
    );
  } else {
    L.push('- **白捡 0 个**：没有"声明是文本却没抽到"的文件，抽取层是干净的。');
  }
  if (skip && skip.files) {
    L.push(
      `- **本来就不该变亮 ${skip.files} 个（${skip.pctFiles.toFixed(1)}%）**：动态库、字体、机器包、密钥。` +
        `把它们算进分母，会把"覆盖率低"变成一句吓人但推不出动作的话。真正需要讨论的分母是 **${(
          ((t.files - skip.files) / t.files) *
          100
        ).toFixed(1)}%**。`,
    );
  }
  L.push('');

  if (chunk && chunk.files) {
    L.push(`- 超限可分块解决：**${chunk.files}** 个（大于单文件抽取上限 ${formatBytes(cfg.maxTextBytes)}）。`);
  }
  if (extractor && extractor.files) {
    L.push(`- 需要格式解析（确定性、不调模型）：**${extractor.files}** 个。`);
  }
  if (ocr && ocr.files) {
    L.push(`- 需要 OCR（图片）：**${ocr.files}** 个，${formatBytes(ocr.bytes)}。`);
  }
  if (asr && asr.files) {
    L.push(`- 需要转录（音视频）：**${asr.files}** 个，${formatBytes(asr.bytes)}——体量最大的一档。`);
  }
  const unpack = cov.buckets.find((b) => b.key === 'unpack');
  if (unpack && unpack.files) {
    L.push(`- 需要解包（压缩包/安装包）：**${unpack.files}** 个，${formatBytes(unpack.bytes)}——先问值不值得，解包后常常又是几千个文件。`);
  }
  const nosql = cov.buckets.find((b) => b.key === 'nosql');
  if (nosql && nosql.files) {
    L.push(`- 数据库文件：**${nosql.files}** 个，${formatBytes(nosql.bytes)}——需要按表查询，全文索引对它们无效。`);
  }
  L.push('');

  L.push('## 各索引根');
  L.push('');
  L.push(
    mdTable(
      ['根', '路径', '文件数', '有正文', '覆盖率', '体量'],
      cov.perRoot.map((r) => [
        r.label,
        `\`${r.root}\``,
        r.files.toLocaleString(),
        r.withBody.toLocaleString(),
        `${r.pct.toFixed(1)}%`,
        formatBytes(r.bytes),
      ]),
    ),
  );
  L.push('');

  L.push('## 体量最大的暗文件');
  L.push('');
  L.push('数量上暗区是图片；**体量上暗区是视频**。这一节解释为什么两个百分比差那么远。');
  L.push('');
  L.push(
    mdTable(
      ['文件', '体量', '类型', '变亮手段'],
      cov.biggestDark.map((r) => [`\`${r.rel}\``, formatBytes(r.size), r.kind, r.label]),
    ),
  );
  L.push('');

  if (t.truncated) {
    L.push('## 抽取截断');
    L.push('');
    L.push(`有 **${t.truncated}** 个文件被截断入库（超过单文件正文上限），它们算「有正文」，但正文不完整。`);
    L.push('');
  }

  L.push('## 怎么用这份报告');
  L.push('');
  L.push('1. **先看「本来就不该变亮」占多少。** 扣掉它，才是真正需要处理的分母。');
  L.push('2. **再看「白捡」。** 有的话先修抽取层——零成本，且不需要任何架构改动。');
  L.push('3. **然后按代价从低到高排。** 格式解析 → OCR → 转录，每上一级都要先问「这一级值得花吗」。');
  L.push('4. **最后才谈向量与语义。** 向量只对已有正文的那部分有用；先有正文，再谈相似度。');
  L.push('');
  L.push('> 这份报告本身不驱动任何写操作。要变亮任何一档，都要你先确认。');
  return L.join('\n');
}

module.exports = { computeCoverage, renderCoverage, classify, LADDER };
