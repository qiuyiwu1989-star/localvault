'use strict';

/**
 * 索引构建器：遍历 → 抽取 → 写库。增量更新（size+mtime 未变则跳过抽取）。
 */

const fs = require('node:fs');
const { walkRoot } = require('./walk');
const { extractFile } = require('./extract');
const { BatchWriter, markGoneOlderThan, recordScanRun, setMeta, setMetaJson } = require('./store');
const { buildDenyMatchers, isDeniedRead } = require('./config');
const { formatBytes, toPosix } = require('./util');

/**
 * @param {object} cfg 已解析配置
 * @param {object} db  已打开数据库
 * @param {object} opts { full?:boolean, onProgress?:fn, roots?:Array }
 */
function buildIndex(cfg, db, opts) {
  const options = opts || {};
  const startedAt = Date.now();
  const denyMatchers = buildDenyMatchers(cfg.denyRead);
  const targets = options.roots && options.roots.length
    ? cfg.roots.filter((r) => options.roots.includes(r.path) || options.roots.includes(r.label))
    : cfg.roots;

  const summary = {
    startedAt,
    roots: [],
    filesSeen: 0,
    filesExtracted: 0,
    filesReused: 0,
    filesRemoved: 0,
    dirsSeen: 0,
    skippedDirs: 0,
    errors: 0,
    errorSamples: [],
    bytesIndexed: 0,
  };

  const scanId = Date.now();

  for (const root of targets) {
    const rootStart = Date.now();
    const walk = walkRoot(root.path, cfg);
    summary.dirsSeen += walk.dirCount;
    summary.skippedDirs += walk.skippedDirs;
    summary.errors += walk.errors.length;
    for (const e of walk.errors.slice(0, 5)) summary.errorSamples.push(e);

    if (walk.missing) {
      summary.roots.push({
        root: root.path,
        label: root.label,
        missing: true,
        files: 0,
        errors: walk.errors.length,
      });
      continue;
    }

    // 预载已有记录，用于增量判断（只取判断所需的小字段）
    const existing = new Map();
    if (!options.full) {
      const rows = db
        .prepare('SELECT path, size, mtime, is_text, denied FROM files WHERE root = ?')
        .all(root.path);
      for (const r of rows) existing.set(r.path, r);
    }

    const writer = new BatchWriter(db);
    let extracted = 0;
    let reused = 0;

    for (const entry of walk.entries) {
      summary.filesSeen += 1;
      const prev = existing.get(entry.path);
      const denied = isDeniedRead(entry.name, denyMatchers);

      const unchanged =
        prev &&
        Number(prev.size) === entry.size &&
        Number(prev.mtime) === entry.mtime &&
        Boolean(Number(prev.is_text)) === entry.isText &&
        Boolean(Number(prev.denied)) === denied;

      if (unchanged) {
        // 只刷元数据，正文原样保留；行不存在时回退到全量写入。
        const touched = writer.touch({
          root: root.path,
          path: entry.path,
          rel: entry.rel,
          name: entry.name,
          ext: entry.ext,
          kind: entry.kind,
          size: entry.size,
          mtime: entry.mtime,
          scanId,
          denied,
        });
        if (touched) {
          reused += 1;
          summary.filesReused += 1;
          if (options.onProgress && summary.filesSeen % 5000 === 0) {
            options.onProgress({ root: root.path, seen: summary.filesSeen, extracted, reused });
          }
          continue;
        }
      }

      let title = '';
      let headings = '';
      let body = '';
      let truncated = false;
      let isBinary = false;

      if (!denied && entry.isText && entry.size > 0 && entry.size <= cfg.maxTextBytes) {
        const res = extractFile(entry.path, {
          maxBytes: cfg.maxTextBytes,
          maxStoredChars: cfg.maxStoredBodyChars,
        });
        if (res.ok) {
          title = res.title || '';
          headings = (res.headings || []).join('\n');
          body = res.body || '';
          truncated = Boolean(res.truncated);
          isBinary = Boolean(res.binary);
          extracted += 1;
          summary.filesExtracted += 1;
          summary.bytesIndexed += entry.size;
        } else {
          summary.errors += 1;
          if (res.reason && summary.errorSamples.length < 10) {
            summary.errorSamples.push({ path: entry.path, message: res.reason });
          }
        }
      }

      writer.put({
        root: root.path,
        path: entry.path,
        rel: entry.rel,
        name: entry.name,
        ext: entry.ext,
        kind: entry.kind,
        size: entry.size,
        mtime: entry.mtime,
        birthtime: entry.birthtime,
        isText: entry.isText,
        isSymlink: entry.isSymlink,
        denied,
        isBinary,
        title,
        headings,
        body,
        truncated,
        scanId,
      });

      if (options.onProgress && summary.filesSeen % 5000 === 0) {
        options.onProgress({ root: root.path, seen: summary.filesSeen, extracted, reused });
      }
    }

    writer.commit();
    const removed = markGoneOlderThan(db, root.path, scanId);
    summary.filesRemoved += removed;

    summary.roots.push({
      root: root.path,
      label: root.label,
      missing: false,
      files: walk.entries.length,
      extracted,
      reused,
      removed,
      dirs: walk.dirCount,
      skippedDirs: walk.skippedDirs,
      errors: walk.errors.length,
      elapsedMs: Date.now() - rootStart,
    });

    recordScanRun(db, {
      startedAt: rootStart,
      finishedAt: Date.now(),
      root: root.path,
      filesSeen: walk.entries.length,
      filesAdded: extracted,
      filesUpdated: extracted,
      filesRemoved: removed,
      dirsSeen: walk.dirCount,
      skippedDirs: walk.skippedDirs,
      errors: walk.errors.length,
      elapsedMs: Date.now() - rootStart,
      ok: true,
    });
  }

  summary.finishedAt = Date.now();
  summary.elapsedMs = summary.finishedAt - startedAt;
  setMeta(db, 'last_scan_at', String(summary.finishedAt));
  setMetaJson(db, 'last_scan_summary', {
    finishedAt: summary.finishedAt,
    elapsedMs: summary.elapsedMs,
    filesSeen: summary.filesSeen,
    filesExtracted: summary.filesExtracted,
    filesReused: summary.filesReused,
    filesRemoved: summary.filesRemoved,
    errors: summary.errors,
    roots: summary.roots,
  });
  return summary;
}

function describeScanSummary(summary) {
  const lines = [];
  lines.push(`扫描完成：${summary.filesSeen} 个文件，用时 ${(summary.elapsedMs / 1000).toFixed(1)}s`);
  lines.push(`新抽取 ${summary.filesExtracted}，复用 ${summary.filesReused}，标记消失 ${summary.filesRemoved}，错误 ${summary.errors}`);
  lines.push(`索引正文体积 ${formatBytes(summary.bytesIndexed)}`);
  for (const r of summary.roots) {
    if (r.missing) {
      lines.push(`- ${r.label} ${toPosix(r.root)}：不存在或不可读（已跳过）`);
    } else {
      lines.push(
        `- ${r.label} ${toPosix(r.root)}：${r.files} 文件 / ${r.dirs} 目录（跳过 ${r.skippedDirs}），抽取 ${r.extracted}，复用 ${r.reused}，用时 ${(r.elapsedMs / 1000).toFixed(1)}s`,
      );
    }
  }
  if (summary.errorSamples.length) {
    lines.push('错误样例：');
    for (const e of summary.errorSamples.slice(0, 5)) {
      lines.push(`- ${toPosix(e.path || '')} ${e.code ? '[' + e.code + '] ' : ''}${e.message || ''}`);
    }
  }
  return lines.join('\n');
}

module.exports = { buildIndex, describeScanSummary };
