#!/usr/bin/env node
'use strict';
/**
 * 造一份「什么场景都有」的语料，用来喂 App 的只读自检。
 *
 * ## 为什么需要它
 *
 * `--selftest` 有一批检查长这样：「语料里没有 X 就跳过」。这在**真机上是对的**——
 * 硬要在没有重复文件的机器上检查「重复文件判定」，只能编。诚实跳过比编一个强。
 *
 * 但它有个副作用：在干净机器上跑自检，会跳过一大片，看着像「通过」，
 * 实际只验了很小一部分。CI 里尤其糟——**绿得没有含量**。
 *
 * 所以 CI 里先造这份语料，把那些分支真的点亮，再跑自检。
 *
 * ## 每个目录为什么在那儿
 *
 * | 内容 | 点亮哪条检查 |
 * | --- | --- |
 * | `node_modules/` `.git/` `build/` | 「口径：跳过的机器生成目录」 |
 * | 正文 > 4000 字的笔记 | 「找得到超过 4000 字、且会报字数的文件」 |
 * | 同一正文里重复出现的中文词 | 检索那一整组（片段 / 相关度 / hitCount / 筛选） |
 * | `.png` / `.dmg`（二进制） | 「无正文文件」两个口径 + 兜底片段 |
 * | 多个 kind（md / txt / js / png / dmg / pdf） | 「类型筛选既有命中又全部合规」 |
 * | 刚改过 + 很久没改 | 「时间筛选既有命中又全部合规」 |
 * | 分散在多个子目录 | 「目录筛选既有命中又全部合规」 |
 * | 内容相同的两份 | 重复件判定 |
 * | `~/Documents/` 里放一个诱饵 | **默认根不该索引到它** |
 *
 * 用法：`node scripts/make-ci-fixture.mjs <HOME 路径>`
 */

import fs from 'node:fs';
import path from 'node:path';

const home = process.argv[2] || process.env.HOME;
if (!home) {
  console.error('用法：node scripts/make-ci-fixture.mjs <HOME 路径>');
  process.exit(2);
}

const w = (rel, text) => {
  const p = path.join(home, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text, 'utf8');
};
const wb = (rel, bytes) => {
  const p = path.join(home, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, Buffer.from(bytes));
};

// ── 三个系统目录（默认根从这两个探测）─────────────────────────────
fs.mkdirSync(path.join(home, 'Desktop'), { recursive: true });
fs.mkdirSync(path.join(home, 'Downloads'), { recursive: true });
fs.mkdirSync(path.join(home, 'Documents'), { recursive: true });

// 重复词：检索那一整组要求「同一篇正文里出现 ≥2 次的中文词」。
// 用它当关键词，hitCount / score / 片段 / 相关度 全都能真的被检验。
const KEY = '本地上下文';

w('Desktop/项目/README.md', [
  `# ${KEY}`,
  '',
  `这份方案讲的是${KEY}怎么落地。`,
  `${KEY}的第一版只做索引，不做提炼。`,
  `${KEY}的第二版才接记忆中心。`,
  '',
  '## 边界',
  '',
  '- 只读',
  '- 不上传',
  '',
].join('\n'));

// 正文 > 4000 字 → 点亮「会报字数」「truncated」
w('Desktop/项目/长文.md', `# 长文\n\n${'这是一段足够长的中文正文，用来验证字数统计与截断。'.repeat(200)}\n`);

// 同一份内容两份 → 重复件
const dup = `# 重复的方案\n\n${KEY}重复内容。\n${KEY}再出现一次。\n`;
w('Desktop/项目/重复-A.md', dup);
w('Downloads/重复-B.md', dup);

// kind 多样性
w('Desktop/笔记.txt', `${KEY}写在纯文本里。\n${KEY}再写一次。\n`);
w('Desktop/项目/脚本.js', `// ${KEY}\nconsole.log('${KEY}');\nconsole.log('${KEY}');\n`);
wb('Downloads/截图.png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(512).fill(0x20)]);
wb('Downloads/安装包.dmg', [...Buffer.from('koly'), ...Array(2048).fill(0x00)]);
w('Downloads/资料.pdf', `%PDF-1.4\n${KEY} 的 PDF（假的，只为多样本）\n%%EOF\n`);

// 无正文：空文件
w('Desktop/项目/空文件.md', '');

// 时间：很久没改的文件（时间筛选要能筛出「近 7 天」和「不是近 7 天」两类）
const old = 'Downloads/旧资料.md';
w(old, `# 旧资料\n\n${KEY}（这份是旧的）。\n${KEY}（确实旧）。\n`);
const longAgo = new Date(Date.now() - 400 * 24 * 3600 * 1000);
fs.utimesSync(path.join(home, old), longAgo, longAgo);

// 机器生成目录 —— 必须被跳过，但也必须**存在**，否则那条检查无从检验
w('Desktop/项目/node_modules/x/包说明.md', `${KEY}（这是依赖里的，不该进索引）\n`);
w('Desktop/项目/.git/COMMIT_EDITMSG', '初始提交\n');
w('Desktop/项目/build/产物.md', `${KEY}（这是构建产物，不该进索引）\n`);

// 诱饵：默认根不该索引 ~/Documents
w('Documents/不该被索引.md', `${KEY} 只出现在这里。如果索引了它，说明默认根探测越界。\n`);

console.log(`已造语料：${home}`);
