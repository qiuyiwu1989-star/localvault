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
    // 新增 / 更新必须分开 —— 原来这两个数被赋成**同一个值**：
    //   filesAdded: extracted, filesUpdated: extracted
    // 于是报告里永远写着「新增 22000、更新 22000」。它不是错的，是**没实现**，
    // 而它看起来完全是一份统计。这种「占位符长得像数据」比缺一个字段更坏。
    //
    // 表里没有「首次出现」列，所以这里用扫描前的路径快照来判：不在快照里 = 新增。
    // 只取 `gone = 0` 的行：一个曾被标记消失、这次又出现的文件算**新增**
    // （它确实重新进入了索引），这也比把它算作「更新」更贴近事实。
    // 一次全表 path 查询（本机约 1 万行）很便宜，放进 Set 后每文件 O(1)。
    const knownPaths = new Set(
      db.prepare('SELECT path FROM files WHERE gone = 0').all().map((r) => r.path),
    );
    let addedHere = 0;
    let updatedHere = 0;
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

      if (knownPaths.has(entry.path)) updatedHere += 1;
      else addedHere += 1;

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
      added: addedHere,
      updated: updatedHere,
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
      filesAdded: addedHere,
      filesUpdated: updatedHere,
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
