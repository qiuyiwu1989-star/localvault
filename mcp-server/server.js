#!/usr/bin/env node
'use strict';


/** node:sqlite 需要 Node >= 22.5；低于此版本给出明确提示而不是崩溃。 */
(function requireModernNode() {
  const [maj, min] = process.versions.node.split('.').map(Number);
  if (maj > 22 || (maj === 22 && min >= 5)) return;
  process.stderr.write(
    `localvault 需要 Node >= 22.5（当前 ${process.version}）。\n` +
      '原因：内置 node:sqlite。请升级 Node，或用 DSH 自带的运行时。\n',
  );
  process.exit(2);
})();

/**
 * localvault MCP 服务器入口（stdio）。
 *
 * 这个进程由 dsh-mcp-client 通过 stdio 拉起。
 * stdout 是协议通道：除了 JSON-RPC 帧，任何内容都不能写进去。
 * 所有日志必须走 stderr。
 */

// node:sqlite 在当前 Node 版本上会打 ExperimentalWarning；对 stdio 服务器只是噪声，过滤掉。
const originalEmitWarning = process.emitWarning;
process.emitWarning = function emitWarningFiltered(warning, ...rest) {
  const text = typeof warning === 'string' ? warning : (warning && warning.message) || '';
  const type = typeof rest[0] === 'string' ? rest[0] : rest[0] && rest[0].type;
  if (type === 'ExperimentalWarning' && /SQLite/i.test(text)) return undefined;
  return originalEmitWarning.call(process, warning, ...rest);
};

const { start } = require('./lib/mcp');

let server;
try {
  server = start();
} catch (e) {
  process.stderr.write(`[localvault] 启动失败：${(e && e.stack) || e}\n`);
  process.exit(1);
}

process.on('uncaughtException', (e) => {
  process.stderr.write(`[localvault] uncaughtException: ${(e && e.stack) || e}\n`);
});
process.on('unhandledRejection', (e) => {
  process.stderr.write(`[localvault] unhandledRejection: ${(e && e.stack) || e}\n`);
});

// stdin 关闭即退出（宿主结束会话时）
process.stdin.on('end', () => {
  process.stderr.write('[localvault] stdin 已关闭，退出。\n');
  process.exit(0);
});

module.exports = server;
