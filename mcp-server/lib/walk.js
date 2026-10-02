'use strict';

/**
 * 文件系统遍历。迭代实现，容忍权限错误，跳过机器生成目录与符号链接。
 */

const fs = require('node:fs');
const path = require('node:path');
const { toPosix } = require('./util');
const { skipReason, kindOf, isTextExt } = require('./config');

/**
 * 遍历一个根目录。
 * @returns {{entries: Array<object>, errors: Array<object>, dirCount: number, skippedDirs: number, elapsedMs: number}}
 */
function walkRoot(rootPath, cfg) {
  const started = Date.now();
  const entries = [];
  const errors = [];
  let dirCount = 0;
  let skippedDirs = 0;

  let rootStat;
  try {
    rootStat = fs.statSync(rootPath);
  } catch (e) {
    return {
      entries,
      errors: [{ path: rootPath, code: e.code || 'ERR', message: String(e.message || e) }],
      dirCount,
      skippedDirs,
      elapsedMs: Date.now() - started,
      missing: true,
    };
  }
  if (!rootStat.isDirectory()) {
    return {
      entries,
      errors: [{ path: rootPath, code: 'NOT_DIR', message: '根路径不是目录' }],
      dirCount,
      skippedDirs,
      elapsedMs: Date.now() - started,
      missing: true,
    };
  }

  const stack = [{ dir: rootPath, depth: 0 }];

  while (stack.length > 0) {
    const { dir, depth } = stack.pop();

    let dirents;
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      errors.push({ path: dir, code: e.code || 'ERR', message: String(e.message || e) });
      continue;
    }
    dirCount += 1;

    for (const d of dirents) {
      const full = path.join(dir, d.name);

      // 符号链接：不跟随（避免环与重复计数），但仍记录一条元数据。
      if (d.isSymbolicLink()) {
        let target = null;
        try {
          target = fs.readlinkSync(full);
        } catch (_e) {
          /* ignore */
        }
        entries.push({
          path: full,
          rel: toPosix(path.relative(rootPath, full)),
          name: d.name,
          ext: '',
          kind: 'symlink',
          size: 0,
          mtime: 0,
          isText: false,
          isSymlink: true,
          symlinkTarget: target,
          depth,
        });
        continue;
      }

      if (d.isDirectory()) {
        const reason = skipReason(d.name, cfg);
        if (reason === 'ignored-suffix') {
          // 目录型 bundle（.app 等）：记一条元数据，让「下载里有个解压出来的 App」
          // 这类问题可见，但不展开内部成百上千个文件。
          let st = null;
          try {
            st = fs.statSync(full);
          } catch (_e) {
            st = null;
          }
          entries.push({
            path: full,
            rel: toPosix(path.relative(rootPath, full)),
            name: d.name,
            ext: path.extname(d.name).toLowerCase(),
            kind: 'bundle',
            size: 0,
            mtime: st ? Math.floor(st.mtimeMs) : 0,
            isText: false,
            isSymlink: false,
            isBundleDir: true,
            depth,
          });
          skippedDirs += 1;
          continue;
        }
        if (reason === 'ignored-name') {
          skippedDirs += 1;
          continue;
        }
        if (depth + 1 > cfg.maxDepth) {
          skippedDirs += 1;
          continue;
        }
        stack.push({ dir: full, depth: depth + 1 });
        continue;
      }

      if (!d.isFile()) continue;

      // .DS_Store 等纯噪声
      if (d.name === '.DS_Store' || d.name === 'Thumbs.db' || d.name === 'desktop.ini') continue;

      let st;
      try {
        st = fs.statSync(full);
      } catch (e) {
        errors.push({ path: full, code: e.code || 'ERR', message: String(e.message || e) });
        continue;
      }

      const ext = path.extname(d.name).toLowerCase();
      entries.push({
        path: full,
        rel: toPosix(path.relative(rootPath, full)),
        name: d.name,
        ext,
        kind: kindOf(ext),
        size: st.size,
        mtime: Math.floor(st.mtimeMs),
        birthtime: Math.floor(st.birthtimeMs || 0),
        isText: isTextExt(ext),
        isSymlink: false,
        depth,
      });
    }
  }

  return {
    entries,
    errors,
    dirCount,
    skippedDirs,
    elapsedMs: Date.now() - started,
    missing: false,
  };
}

module.exports = { walkRoot };
