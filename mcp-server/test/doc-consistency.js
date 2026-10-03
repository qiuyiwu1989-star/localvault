/**
 * 文档一致性：文档里写的数字，必须等于代码里的数字。
 *
 * 为什么要有这个测试：
 *
 * 加了 `read_claims` / `triage` 两个工具之后，`README.md` 的标题改成了
 * 「12 个工具」，但正文里还有**三处**写着「10 个只读工具」——
 * 第 31 行、第 141 行、第 195 行。手改文档必然漏，而且漏的地方
 * 读起来完全正常。文档说错了数字，比不说更坏：它会被当成事实引用。
 *
 * 所以这里不检查「文档写得对不对」（那个没法自动判），只检查一件可判的事：
 * **同一个量在文档和代码里必须相等**，以及**每一个工具/资源都在文档里出现过**。
 *
 * 数字的来源全部从 `lib/mcp.js` **实际解析**出来，不另写一份常量 ——
 * 另写一份的话，它自己就会变成第 2 个会说谎的源头。
 *
 * 跑法：node test/doc-consistency.js
 */
const fs = require('fs');
const path = require('path');

// 仓库根 —— 注意是**两层**。
//
// 原来写的是 `path.join(__dirname, '..')`，那指向 `mcp-server/`：
// 于是这个测试一直在查 npm 包里那份 `mcp-server/README.md`，
// 而没查仓库根那份 `README.md`。
//
// 这个错误**意外地有用** —— 它当场翻出一个真问题：npm 包里那份 README
// 是旧的（写着「10 个只读工具」「4 个资源」，没有 read_claims/triage/vault://claims）。
// 但那是运气。测试查错了文件却报「通过」，就是**一个测不出自己错了的测试**。
// 现在两份都查。
const ROOT = path.join(__dirname, '..', '..');
let pass = 0;
let fail = 0;

function check(name, ok, detail = '') {
  if (ok) { pass += 1; console.log(`  ✓ ${name}${detail ? '  — ' + detail : ''}`); }
  else { fail += 1; console.log(`  ✗ ${name}${detail ? '  — ' + detail : ''}`); }
}

const PKG = path.join(ROOT, 'mcp-server');
const mcpSrc = fs.readFileSync(path.join(PKG, 'lib', 'mcp.js'), 'utf8');

// ── 从源码里解析出真实的工具清单 ────────────────────────────────
const toolsBlk = mcpSrc.slice(mcpSrc.indexOf('const TOOLS = ['), mcpSrc.indexOf('* 资源定义'));
const toolNames = [...toolsBlk.matchAll(/name: '([a-z_]+)',/g)].map((m) => m[1]);

// ── 解析出真实资源清单 ──────────────────────────────────────────
const resStart = mcpSrc.indexOf('const STATIC_RESOURCES');
const resBlk = mcpSrc.slice(resStart, mcpSrc.indexOf('\nconst ', resStart + 10));
const resourceUris = [...resBlk.matchAll(/uri: '(vault:\/\/[a-z]+)'/g)].map((m) => m[1]);

// ── 「只读」到底有几个：看哪个工具的代码真的开过可写连接 ──────────
//
// 不硬编码一张表 —— 硬编码的表在加了新写入工具之后照样是错的，
// 那它就变成了第二个会说谎的源头。这里按方法体里有没有
// `create: true`（打开可写 claims 库的唯一方式）来判。
function methodBody(name) {
  const sig = `  tool${name.charAt(0).toUpperCase()}${name.slice(1)}(args) {`;
  const i = mcpSrc.indexOf(sig);
  if (i < 0) return null;
  let depth = 0;
  for (let j = i + sig.length - 1; j < mcpSrc.length; j += 1) {
    if (mcpSrc[j] === '{') depth += 1;
    else if (mcpSrc[j] === '}') { depth -= 1; if (depth === 0) return mcpSrc.slice(i, j + 1); }
  }
  return null;
}

const writerTools = toolNames.filter((n) => {
  const b = methodBody(n);
  return b ? /create:\s*true/.test(b) : false;
});
const readOnlyCount = toolNames.length - writerTools.length;

console.log('文档一致性（文档里的数字 = 代码里的数字）');
console.log('');
console.log(`  解析结果：工具 ${toolNames.length} 个（其中写入 ${writerTools.length}：${writerTools.join(', ') || '无'}）`);
console.log(`            资源 ${resourceUris.length} 个`);
console.log('');

check('解析出了工具清单（不是空数组）', toolNames.length > 0, `${toolNames.length} 个`);
check('解析出了资源清单（不是空数组）', resourceUris.length > 0, `${resourceUris.length} 个`);
check('解析出了至少一个写入工具（否则「只读 N 个」这条判据会退化成等于总数）',
  writerTools.length > 0, writerTools.join(', '));

// ── 文档里的数字 ────────────────────────────────────────────────
// 两份 README 都要查：仓库根那份给人看，`mcp-server/README.md` 那份
// **随 npm 包发出去**。后者过时的影响更大 —— 用户装完看到的文档就是它。
const DOCS = ['README.md', 'mcp-server/README.md', '接进-agent.md', '开箱即用.md'];
const docText = {};
for (const d of DOCS) {
  const p = path.join(ROOT, d);
  docText[d] = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
}

// 「N 个工具」「工具（N 个」「N 个只读工具」「N 个资源」「资源（N 个」
const CLAIMS = [
  { re: /(\d+)\s*个只读[^。\n]{0,12}工具/g, kind: 'readonly-tools', label: 'N 个只读工具' },
  { re: /(\d+)\s*个(?!只读)[^。\n]{0,12}工具/g, kind: 'tools', label: 'N 个工具' },
  { re: /工具[（(]\s*(\d+)\s*个/g, kind: 'tools', label: '工具（N 个' },
  { re: /(\d+)\s*个资源/g, kind: 'resources', label: 'N 个资源' },
  { re: /资源[（(]\s*(\d+)\s*个/g, kind: 'resources', label: '资源（N 个' },
];

const EXPECTED = {
  'readonly-tools': readOnlyCount,
  tools: toolNames.length,
  resources: resourceUris.length,
};

let claimCount = 0;
for (const doc of DOCS) {
  for (const { re, kind, label } of CLAIMS) {
    for (const m of docText[doc].matchAll(re)) {
      claimCount += 1;
      const got = Number(m[1]);
      const want = EXPECTED[kind];
      // 上下文取一句，失败时能直接看到是哪一句
      const line = docText[doc].slice(0, m.index).split('\n').length;
      check(`${doc}:${line} 「${label}」= ${want}`, got === want,
        got === want ? `文档写 ${got}` : `文档写 ${got}，代码是 ${want}`);
    }
  }
}
check('文档里确实有可校验的数字声明（否则这套检查是空转）', claimCount > 0, `共 ${claimCount} 处`);

// ── 每个工具/资源都必须在文档里出现过 ────────────────────────────
console.log('');
// 只要求「有工具清单的那几份」列全。
// `开箱即用.md` 是一份上手步骤，本来就不列工具表 —— 要求它列全，
// 是**我写错了验收标准**，不是文档缺了东西。测试的标准写错，
// 会逼着后来的人往文档里堆没用的内容去「喂饱测试」。
const MUST_LIST_TOOLS = ['README.md', 'mcp-server/README.md', '接进-agent.md'];
for (const doc of MUST_LIST_TOOLS) {
  if (!docText[doc]) continue;
  for (const n of toolNames) {
    check(`${doc} 提到工具 ${n}`, docText[doc].includes(n));
  }
}
for (const u of resourceUris) {
  check(`README 提到资源 ${u}`, docText['README.md'].includes(u));
  check(`npm 包 README 提到资源 ${u}`, docText['mcp-server/README.md'].includes(u));
}

// ── CLI 命令：两张表都必须列全 ──────────────────────────────────
//
// `mcp-server/README.md` 的 CLI 表曾经停在 14 个（缺 `upstream` 和 `claims`），
// 而 `cli.js` 里有 16 个。装上包的人按 README 找命令会找不到 —— 而且是
// 「文档没写」而不是「功能没有」，他会以为是自己记错了。
const cliSrc = fs.readFileSync(path.join(PKG, 'cli.js'), 'utf8');
const cliBlk = cliSrc.slice(cliSrc.indexOf('const COMMANDS = {'));
// 命令是 `COMMANDS` 对象上的方法：`  init(args) {`
// （不是 `init: () => {}` —— 第一版按 `key:` 写，解析出 0 个，
//   而下面那条「≥15」的断言当场把它抓出来了，没有静默通过。）
// 两处坑，都靠下面「>=15 个」那条断言抓出来的（否则会静默只查一半）：
//   1. 命令是方法、不是属性：`init(args) {`。第一版按 `key:` 写，解析出 0 个；
//   2. `'setup-dsh'(args) {` 与 `'reindex-cache'() {` 的键**带引号**，
//      且有几个方法没有参数 —— 不带引号、又要求 `(args)` 的正则只找到 9 个。
// `help` 不在 COMMANDS 里（main() 里特判），单独补上。
const cliNames = [...cliBlk.slice(0, cliBlk.indexOf('\n};'))
  .matchAll(/^ {2}'?([a-z][a-z-]*)'?\(/gm)].map((m) => m[1]);
if (!cliNames.includes('help')) cliNames.push('help');

check('解析出了 CLI 命令（不是空数组）', cliNames.length > 0, `${cliNames.length} 个`);
check('CLI 命令数 ≥ 15（少了说明解析错了，而不是命令变少了）', cliNames.length >= 15,
  `${cliNames.length} 个：${cliNames.join(', ')}`);

for (const doc of ['README.md', 'mcp-server/README.md']) {
  if (!docText[doc]) continue;
  for (const c of cliNames) {
    // 命令表里的写法可能带参数，所以只匹配反引号里的命令名本身
    const re = new RegExp('`' + c + '(?: |`)');
    check(`${doc} 的 CLI 表列了 ${c}`, re.test(docText[doc]),
      c === 'help' ? '（这条能反过来证明检查本身有效）' : '');
  }
}

console.log(`\n通过 ${pass} · 失败 ${fail}`);
process.exit(fail === 0 ? 0 : 1);
