#!/usr/bin/env node
'use strict';
/**
 * CLI 参数解析：开关**收不收值**，不能靠「下一个参数长什么样」猜。
 *
 * ## 为什么值得单独一个测试
 *
 * 原来的解析器是这样的：只要下一个参数不以 `--` 开头，就当成这个开关的值。
 * 于是 `init --force ~/我的项目:工作区` 把路径当成了 `--force` 的值，
 * 位置参数**消失**。表现有两种，都不好：
 *
 *   - 新机器：打出 `init` 的用法提示（exit 1）——
 *     用户看到的是「用法」，不会想到是自己参数顺序写错；
 *   - 已有配置：走「已存在，未改动」分支，**exit 0** ——
 *     用户以为根加上了，其实什么都没发生。
 *
 * 第二种才是真问题：**静默地做了别的事，还报成功。**
 * 这类缺陷不会自己暴露，只会被人当成「这工具时灵时不灵」。
 *
 * 判据应当是「这个开关本来收不收值」。`--force`/`--full`/`--json` 不收。
 *
 * 跑法：node test/cli-args.js
 */

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const CLI = path.join(ROOT, 'cli.js');

let passed = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) { passed += 1; console.log(`  ✓ ${name}${detail ? '  — ' + detail : ''}`); }
  else { failed += 1; console.log(`  ✗ ${name}${detail ? '  — ' + detail : ''}`); }
}

/** 造一个干净的假 HOME，里面有一个待索引的目录。返回 {home, target}。 */
function freshHome() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'lvcli-'));
  const home = path.join(base, 'home');
  const target = path.join(home, '我的项目');
  fs.mkdirSync(target, { recursive: true });
  fs.writeFileSync(path.join(target, '说明.md'), '# 说明\n\n参数解析测试用。\n');
  return { base, home, target };
}

function run(home, args) {
  const r = spawnSync(process.execPath, [CLI, ...args], {
    env: { ...process.env, HOME: home, CFFIXED_USER_HOME: home },
    encoding: 'utf8',
  });
  return { out: (r.stdout || '') + (r.stderr || ''), code: r.status };
}

console.log('CLI 参数解析');
console.log('');

// ── 核心回归：位置参数写在布尔开关前面或后面，必须同效 ──────────────
{
  // 两个各自干净的 HOME：一个把位置参数写在前面，一个写在后面。
  // 用同一个 HOME 不行 —— 第一次 init 已经把配置写下去了，
  // 第二次会走「已存在，未改动」分支，两种写法都会「成功」，测了个寂寞。
  const a = freshHome();
  const rBefore = run(a.home, ['init', `${a.target}:工作区`, '--force']);
  const b = freshHome();
  const rAfter = run(b.home, ['init', '--force', `${b.target}:工作区`]);

  check('位置参数写在 --force 前，退出码 0', rBefore.code === 0, `exit=${rBefore.code}`);
  check('位置参数写在 --force 后，退出码 0', rAfter.code === 0,
    `exit=${rAfter.code}（修之前这里不是用法提示，就是静默走「已存在」分支）`);
  // 真正要守的是这一条：**那个路径真的被当成了索引根**，而不是被吃掉后回退默认。
  check('--force 后面那个路径真的成了索引根',
    rAfter.out.includes('工作区') && rAfter.out.includes(b.target),
    rAfter.out.split('\n').filter((l) => l.includes('工作区') || l.includes('用法')).join(' / ').slice(0, 160));
  check('   —— 而且没有退回默认的桌面/下载',
    !/-\s*桌面[:：]/.test(rAfter.out) && !/-\s*下载[:：]/.test(rAfter.out),
    '退回默认根就是「参数被吃掉」的典型症状');
  check('两种写法的结果一致',
    rBefore.out.includes(a.target) && rAfter.out.includes(b.target));

  fs.rmSync(a.base, { recursive: true, force: true });
  fs.rmSync(b.base, { recursive: true, force: true });
}

// ── 布尔开关不能因为「后面跟了东西」就变成带值的 ────────────────────
{
  const t = freshHome();
  run(t.home, ['init', `${t.target}:工作区`]);   // 必须指定夹具目录：不带位置参数时根是桌面/下载
  run(t.home, ['index']);
  const cov = run(t.home, ['coverage', '--json', '--days', '7']);
  check('--json 当布尔用（输出是 JSON）', cov.out.trimStart().startsWith('{'), cov.out.slice(0, 60));
  check('  —— 且 --json 后面的 --days 7 没被它吃掉',
    (() => { try { JSON.parse(cov.out); return true; } catch { return false; } })(),
    '吃掉的话 --days 会变成 --json 的值，JSON 也就出不来了');
  fs.rmSync(t.base, { recursive: true, force: true });
}

// ── 带值开关仍然收值（没被这次修改打坏）────────────────────────────
{
  const t = freshHome();
  run(t.home, ['init', `${t.target}:工作区`]);
  run(t.home, ['index']);
  // 用**正文里**的词，别用文件名 —— `search` 命中的是正文/标题，不是文件名。
  // （第一次写成搜「说明」拿到 0 条，因为那只是文件名。）
  const lim = run(t.home, ['search', '参数解析测试', '--limit', '1']);
  check('--limit 仍然收值，且检索命中正文', lim.code === 0 && /→\s*1 条/.test(lim.out),
    lim.out.split('\n').find((l) => l.includes('→')) || lim.out.split('\n')[0]);
  // 无检索词时它列全部（exit 0）是设计行为，不是缺陷 —— 别把正常行为写成红线。
  const noQuery = run(t.home, ['search']);
  check('search 无检索词时走得通（列全部），不是崩', noQuery.code === 0 && noQuery.out.length > 0,
    `exit=${noQuery.code}`);
  fs.rmSync(t.base, { recursive: true, force: true });
}

console.log(`\n通过 ${passed} · 失败 ${failed}`);
process.exit(failed === 0 ? 0 : 1);
