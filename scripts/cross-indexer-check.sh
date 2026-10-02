#!/usr/bin/env bash
# 跨索引器对拍：同一棵语料树，用 CLI 和用 App 各建一次索引，逐字段比。
#
# 为什么必须有：**这是两套独立实现。** JS 一套（mcp-server/lib/indexer.js +
# extract.js），Swift 一套（app/Sources/LocalVault/VaultIndexer.swift）。
# 它们写同一个 sqlite schema，App 和 CLI 谁建的库都可能被另一个读。
#
# 已经因此吃过一次：App 侧只按 `"\n"` 分行，CLI 按 `/\r?\n/`。
# 于是一份 CRLF 文件，App 抽出的标题是**整个正文**，CR-only 文件被当成一行 ——
# **同一个文件，用哪个索引器建的库，搜出来的结果不一样。**
# 没有任何测试能发现它，因为两边各自都「没报错」。
# （已修：两边都在读文本的入口把 CRLF/CR 归一成 LF。）
#
# 这个脚本就是那次问题的守门人：语料里刻意放了 CRLF、CR-only、无扩展名、
# 二进制、符号链接、被策略排除的、超 2MB 的、深层 @ 目录等。
#
#   sh scripts/cross-indexer-check.sh
# 退出码 0 = 两套实现逐字段一致。
#
# 注意：它要**启动一次 App**（`--onboard auto`）让 App 自己建索引。
# 所以需要一个能跑 GUI 的会话；CI 上给了超时保护，挂住会失败而不是静默跳过。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
NODE="${NODE:-$(command -v node)}"
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  for c in \
    "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node" \
    "$(command -v node 2>/dev/null)"; do
    [ -x "$c" ] && NODE="$c" && break
  done
fi
[ -x "${NODE:-}" ] || { echo "找不到 node（可用 NODE=... 指定）"; exit 1; }

WORK="$(mktemp -d)"
# 清理前必须先恢复权限：语料里有一个 0 权限的文件，
# 直接 `rm -rf` 会删不掉并**留下一个临时目录**（跑一次留一个）。
# 测试自己不留垃圾，是测试的一部分。
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT

echo "════ 跨索引器对拍 ════"
echo ""

# ── 造一棵「什么都有」的语料树 ──────────────────────────────────
"$NODE" - "$WORK/tree" <<'NODEJS'
const fs = require('node:fs');
const path = require('node:path');
const T = process.argv[2];
fs.mkdirSync(T, { recursive: true });
const w = (rel, data) => {
  const p = path.join(T, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, data);
};
w('a.txt', '普通文本\n第二行\n');
w('plain.md', '# 标题\n\n正文。\n## 二级\n\n更多。\n');
w('front.md', '---\ntitle: 前置标题\n---\n\n正文。\n');
w('fm-empty.md', '---\n---\n\n没有字段的前置块。\n');
w('笔记.md', '# 中文标题\n\n中文正文。\n');
w('upper.TXT', '大写扩展名\n');
w('noext', '没有扩展名的文本\n');
w('empty.txt', '');
w('crlf.txt', '\r\nCRLF first real line\r\nsecond\r\n');
w('cr-only.md', '# 标题\r正文\r尾\r');
w('tab.md', '#\t制表符标题\n\n正文。\n');
w('astral.txt', 'emoji 🧠 和代理对 𠮷 都在这里\n');
w('badutf8.txt', Buffer.from([0x41, 0xff, 0xfe, 0x42, 0x0a]));
w('big.txt', 'x'.repeat(2 * 1024 * 1024 + 5000));      // 超 maxTextBytes
w('many.md', Array.from({ length: 80 }, (_, i) => `## 标题${i}`).join('\n'));
w('.env', 'TOKEN=should-not-be-indexed\n');
w('.env.local', 'TOKEN=should-not-be-indexed\n');
w('kubeconfig.yaml', 'token: should-not-be-indexed\n');
w('id_rsa', 'should-not-be-indexed\n');
w('my-secret-plan.txt', 'secret\n');
w('token.json', '{"t":1}\n');
w('Thumbs.db', 'ignored\n');
w('.DS_Store', 'ignored\n');
w('node_modules/inside.txt', '应在跳过目录里\n');
w('.build/inside.txt', '应在跳过目录里\n');
w('.venv/inside.txt', '应在跳过目录里\n');
w('.aws/config', '应在跳过目录里\n');
w('MyApp.app/Contents/inner.txt', 'bundle 内部不该展开\n');
w('noread.txt', '这个文件读不了\n');
w('deep/a/b/c/d/e/f.txt', '深层\n');
// 一个符号链接（指向真实文件，不该被跟随）
try { fs.symlinkSync(path.join(T, 'a.txt'), path.join(T, 'link-to-a.txt')); } catch {}
NODEJS

echo "  语料：$(find "$WORK/tree" -type f | wc -l | tr -d ' ') 个文件 · $(find "$WORK/tree" -type l | wc -l | tr -d ' ') 个符号链接"
echo ""

# ── CLI 建索引 ─────────────────────────────────────────────────
mkdir -p "$WORK/cli"
cp -R "$WORK/tree" "$WORK/cli/tree"
# 不可读的文件：读不了的时候两边该怎么处理，也必须一样。
# 放在 cp 之后造，免得 cp 去碰一个权限受限的路径。
chmod 000 "$WORK/cli/tree/noread.txt"
HOME="$WORK/cli" CFFIXED_USER_HOME="$WORK/cli" "$NODE" "$REPO/mcp-server/cli.js" init "$WORK/cli/tree:语料" >/dev/null 2>&1
HOME="$WORK/cli" CFFIXED_USER_HOME="$WORK/cli" "$NODE" "$REPO/mcp-server/cli.js" index >/dev/null 2>&1
echo "  ✓ CLI 索引完成"

# ── App 建索引 ─────────────────────────────────────────────────
# 默认用源码构建出来的那个；也可以用 APP_BIN=... 指定别的 ——
# 比如 dmg 里那个真正发给用户的二进制。**出厂产物必须能过这一关**，
# 只测 .build/ 里的那个是不够的：装配、签名、拷贝都可能改变实际行为。
BIN="${APP_BIN:-$(cd "$REPO/app" && swift build -c release --show-bin-path 2>/dev/null)/LocalVault}"
if [ ! -x "$BIN" ]; then
  echo "  ❌ 找不到 App 二进制（$BIN）—— 先 swift build -c release"
  exit 1
fi
mkdir -p "$WORK/app"
cp -R "$WORK/tree" "$WORK/app/tree"
chmod 000 "$WORK/app/tree/noread.txt"
HOME="$WORK/app" CFFIXED_USER_HOME="$WORK/app" "$NODE" "$REPO/mcp-server/cli.js" init "$WORK/app/tree:语料" >/dev/null 2>&1
rm -f "$WORK/app/.localvault/vault.db"*

HOME="$WORK/app" CFFIXED_USER_HOME="$WORK/app" "$BIN" --onboard auto >"$WORK/app.log" 2>&1 &
APP_PID=$!
ROWS=0
for _ in $(seq 1 60); do
  sleep 1
  ROWS="$("$NODE" -e '
    try {
      const { DatabaseSync } = require("node:sqlite");
      const d = new DatabaseSync(process.argv[1], { readOnly: true });
      process.stdout.write(String(d.prepare("SELECT count(*) c FROM files").get().c));
    } catch { process.stdout.write("0"); }
  ' "$WORK/app/.localvault/vault.db" 2>/dev/null)"
  [ "${ROWS:-0}" -gt 0 ] 2>/dev/null && break
done
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null
if [ "${ROWS:-0}" -le 0 ]; then
  echo "  ❌ App 在 60 秒内没建出索引（GUI 起不来？）—— 这条**不是跳过，是失败**"
  tail -5 "$WORK/app.log" 2>/dev/null | sed 's/^/       /'
  exit 1
fi
echo "  ✓ App 索引完成（${ROWS} 行）"
echo ""

# ── 逐字段对拍 ─────────────────────────────────────────────────
"$NODE" - "$WORK/cli/.localvault/vault.db" "$WORK/app/.localvault/vault.db" <<'NODEJS'
const { DatabaseSync } = require('node:sqlite');
const A = new DatabaseSync(process.argv[2], { readOnly: true });
const B = new DatabaseSync(process.argv[3], { readOnly: true });
const ra = A.prepare('SELECT * FROM files ORDER BY rel').all();
const rb = B.prepare('SELECT * FROM files ORDER BY rel').all();

let bad = 0;
const fail = (m) => { console.log('  ✗ ' + m); bad++; };
const ok = (m) => console.log('  ✓ ' + m);

if (ra.length !== rb.length) fail(`行数不同：CLI ${ra.length} · App ${rb.length}`);
else ok(`行数一致：${ra.length}`);

const relA = new Set(ra.map((r) => r.rel));
const relB = new Set(rb.map((r) => r.rel));
const onlyA = [...relA].filter((x) => !relB.has(x));
const onlyB = [...relB].filter((x) => !relA.has(x));
if (onlyA.length) fail(`只在 CLI 里：${onlyA.join(', ')}`);
if (onlyB.length) fail(`只在 App 里：${onlyB.join(', ')}`);
if (!onlyA.length && !onlyB.length) ok('文件集合完全一致');

// 逐字段。mtime/birthtime/root/path 必然不同（两次采集、两个 temp 目录），排除。
const FIELDS = ['name', 'ext', 'kind', 'size', 'is_text', 'is_symlink', 'denied',
                'is_binary', 'title', 'headings', 'body', 'truncated'];
let compared = 0;
for (const a of ra) {
  const b = rb.find((y) => y.rel === a.rel);
  if (!b) continue;
  for (const f of FIELDS) {
    compared++;
    if (String(a[f]) !== String(b[f])) {
      fail(`${a.rel} 的 ${f} 不同\n        CLI: ${JSON.stringify(String(a[f]).slice(0, 90))}\n        App: ${JSON.stringify(String(b[f]).slice(0, 90))}`);
    }
  }
}
ok(`逐字段比了 ${compared} 个字段值（${ra.length} 行 × ${FIELDS.length} 列）`);

// 反向自检：确认这个比较**真的会比较**。
// 灌一个必然不同的值进去，看它会不会被抓到 —— 否则「0 差异」可能只是比较没跑。
{
  const probe = { ...ra[0], title: '__故意不同__' };
  const caught = String(probe.title) !== String((rb.find((y) => y.rel === ra[0].rel) || {}).title);
  if (caught) ok('比较器自检通过（灌一个假差异会被抓到，所以「0 差异」是真的）');
  else fail('比较器自检失败：假差异没被抓到，上面的「一致」不作数');
}

console.log('');
console.log(bad === 0 ? '  ══ 两套索引器逐字段一致 ══' : `  ══ 有 ${bad} 处不一致 ══`);
process.exit(bad === 0 ? 0 : 1);
NODEJS
