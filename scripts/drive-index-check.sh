#!/bin/sh
# 云盘到底能不能被 agent 读到 —— 端到端检查。
#
# 守的是一句承诺。云盘自己的 `说明.md` 写着：
#
#     把你想让 agent 了解的文件直接拖进这个文件夹。
#     - 拖进来之后在被索引时会自动被读到
#
# 而真实配置里云盘**从来不在 roots 中**，所以那句话一直不成立：
# `find_files` 查不到、`read_text` 回「路径不在任何已配置索引根内，拒绝读取」。
#
# 这个脚本分两段，缺一不可：
#
#   ① 配置层：`VaultConfig.ensureRoot` 的性质（幂等 / 不冲掉用户手写的键 /
#      读不懂就抛错不覆盖）。由 app/test/DriveRootCheck 跑，36 条断言。
#
#   ② 端到端：造一个假主目录和假云盘 → **用产品代码**登记根 →
#      跑真实索引 → **用真实 MCP 协议**查一次。
#      第 ② 段是重点：第 ① 段只能证明「配置写对了」，
#      证明不了「写对之后 agent 真的读得到」—— 而后者才是那句承诺。
#
# 全程在临时目录里。真实 `~/.localvault` 与真实云盘一个字节都不碰
# （`DriveRootCheck` 里有一道拒跑闸门，见下）。

set -eu
cd "$(dirname "$0")/.."

# 在改 HOME 之前抓住真实环境。后面 export HOME=假目录，$HOME 就变味了 ——
# 用它去找工具链会找到假目录里去，用它去比对真实库会比对到假库上。
REAL_HOME="$HOME"
REAL_DB="$REAL_HOME/.localvault/vault.db"
REAL_DB_BEFORE=""
if [ -f "$REAL_DB" ]; then
  REAL_DB_BEFORE="$(stat -f '%z %m' "$REAL_DB")"
fi

# ── 拒跑闸门 ──────────────────────────────────────────────────────
#
# `NSHomeDirectory()` 只认 `CFFIXED_USER_HOME`，**不认 `HOME`**（实测）。
# 只设 HOME 会静默指到真实主目录 —— 这个仓库真的因此覆盖过一次真实
# config.json。所以这里同时设两个变量，之后**再验一遍结果值**：
# 拿不到临时主目录就整个中止，宁可这条检查不跑。
#
# 用它自己判：让二进制跑一次 `--register-only` 太晚了（那时已经可能写过了）。
# 所以先用一个最小程序问 `NSHomeDirectory()`，确认是临时的再继续。
PROBE_DIR="$(mktemp -d)"
cat > "$PROBE_DIR/home.swift" <<'SWIFT'
import Foundation
print(NSHomeDirectory())
SWIFT
if ! xcrun swiftc -O "$PROBE_DIR/home.swift" -o "$PROBE_DIR/homeprobe" >/dev/null 2>&1; then
  echo "  ✗ 探针编译失败（需要 Xcode 命令行工具）"
  exit 1
fi

FAKE_HOME="$PROBE_DIR/home"
mkdir -p "$FAKE_HOME"

ACTUAL="$(HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" "$PROBE_DIR/homeprobe")"
case "$ACTUAL" in
  "$FAKE_HOME") : ;;
  *)
    echo "  ✗ 拒跑：CFFIXED_USER_HOME 没生效，NSHomeDirectory() = $ACTUAL"
    echo "    继续跑会覆盖真实 ~/.localvault/config.json。"
    exit 1
    ;;
esac
echo "  ✓ 假主目录已生效：$FAKE_HOME"
echo ""

# ── ① 配置层 ────────────────────────────────────────────────────
OUT="$(mktemp -d)/drive-root-check"
if ! xcrun swiftc -O app/Sources/LocalVault/VaultConfig.swift \
      app/test/DriveRootCheck/main.swift -o "$OUT" > "$OUT.log" 2>&1; then
  echo "  ✗ 编译失败："
  sed 's/^/    /' "$OUT.log"
  exit 1
fi
if [ -x "$OUT" ]; then :; else
  echo "  ✗ swiftc 报了成功但没产出可执行文件"
  exit 1
fi
grep -q "warning:" "$OUT.log" && { echo "  ⚠️  编译有警告："; grep "warning:" "$OUT.log" | sed 's/^/    /'; echo ""; }

echo "── ① 配置层 ──"
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" "$OUT" || exit 1

# ── ② 端到端：登记 → 真实索引 → 真实 MCP 查询 ────────────────────
echo ""
echo "── ② 端到端（登记 → 索引 → 真实 MCP 查询）──"

NODE_BIN="${NODE:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ]; then
  if [ -x "$REAL_HOME/.localvault-toolchain/node-v24.21.0-darwin-arm64/bin/node" ]; then
    NODE_BIN="$REAL_HOME/.localvault-toolchain/node-v24.21.0-darwin-arm64/bin/node"
  fi
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "  ✗ 找不到 node"
  exit 1
fi

DRIVE="$FAKE_HOME/Documents/本地上下文云盘"
mkdir -p "$DRIVE/参考素材"
# 用一个不可能撞上的名字，免得「查到 1 条」是碰巧
UNIQ="端到端样本-$(date +%s)-$$"
printf '# %s\n\n这份文件是 drive-index-check 造的，用来证明云盘真的被索引了。\n' "$UNIQ" \
  > "$DRIVE/参考素材/$UNIQ.md"
# 再放一个「不该被读到」的对照：忽略目录里的文件
mkdir -p "$DRIVE/node_modules"
printf 'ignored\n' > "$DRIVE/node_modules/$UNIQ-ignored.md"

# ① 用**产品代码**登记根（不是手写 config.json）
REG="$(HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" "$OUT" --register-only)"
[ "$REG" = "registered" ] || { echo "  ✗ 登记返回：$REG（期望 registered）"; exit 1; }
echo "  ✓ 产品代码把云盘登记成了索引根"

# ② 真实索引器扫一遍
export HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME"
"$NODE_BIN" mcp-server/cli.js init >/dev/null 2>&1 || true
"$NODE_BIN" mcp-server/cli.js index >/dev/null 2>&1 || { echo "  ✗ 索引失败"; exit 1; }
echo "  ✓ 索引跑完"

# ③ 走**真实 MCP 协议**查（不是直接查 SQL）
#
# 直接查 SQL 只能证明「库里有这行」；而当初拒绝读的是 MCP 那一层
# （「路径不在任何已配置索引根内」）。所以必须从 MCP 这一层往回问一次。
query_mcp() {
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"notifications/initialized"}'
    printf '%s\n' "$1"
    sleep 2
  } | "$NODE_BIN" mcp-server/server.js 2>/dev/null | "$NODE_BIN" -e '
let buf = "";
process.stdin.on("data", (d) => { buf += d; });
process.stdin.on("end", () => {
  for (const line of buf.split("\n")) {
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 3) {
      const t = m.result && m.result.content && m.result.content[0] && m.result.content[0].text;
      process.stdout.write(t == null ? "" : t);
    }
  }
});
'
}

FIND_ARGS=$(printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_files","arguments":{"query":"%s","format":"json"}}}' "$UNIQ")
FIND_OUT="$(query_mcp "$FIND_ARGS")"
FIND_HITS="$(printf '%s' "$FIND_OUT" | "$NODE_BIN" -e '
let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{
  try{const j=JSON.parse(b);process.stdout.write(String((j.hits||[]).length));}catch(e){process.stdout.write("parse-error");}
});')"

if [ "$FIND_HITS" = "1" ]; then
  echo "  ✓ find_files 查到 $FIND_HITS 条（云盘里的文件，经真实 MCP）"
else
  echo "  ✗ find_files 查到 $FIND_HITS 条，期望 1 —— 云盘还是没被读到"
  printf '%s\n' "$FIND_OUT" | head -20 | sed 's/^/      /'
  exit 1
fi

# 命中路径必须真的在云盘里（不是别的根里的同名文件）
FIND_PATH="$(printf '%s' "$FIND_OUT" | "$NODE_BIN" -e '
let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{
  try{const j=JSON.parse(b);process.stdout.write(String((j.hits||[])[0]?.path||""));}catch(e){}
});')"
case "$FIND_PATH" in
  *"本地上下文云盘"*) echo "  ✓ 命中路径在云盘内：${FIND_PATH##*/}" ;;
  *) echo "  ✗ 命中的不是云盘里的文件：$FIND_PATH"; exit 1 ;;
esac

# ④ 正文要读得出来 —— 当初这里回的是「路径不在任何已配置索引根内，拒绝读取」
#
# 断言按 `read_text` 的**实际**返回契约写：JSON 里没有 `ok` 字段，
# 是 `indexed` + `content`。（按想当然的 `ok` 读会永远失败 —— 或者更糟，
# 永远通过。这里连正文内容一起验，免得「读到了」其实是读到了别的东西。）
READ_ARGS=$(printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_text","arguments":{"path":"%s","format":"json"}}}' "$FIND_PATH")
READ_OUT="$(query_mcp "$READ_ARGS")"
READ_OK="$(printf '%s' "$READ_OUT" | MARKER="$UNIQ" "$NODE_BIN" -e '
let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{
  let j; try { j=JSON.parse(b); } catch(e) { process.stdout.write("parse-error"); return; }
  if (j.indexed !== true) { process.stdout.write("not-indexed:"+JSON.stringify(j).slice(0,160)); return; }
  if (!String(j.content||"").includes(process.env.MARKER)) {
    process.stdout.write("content-mismatch:"+String(j.content||"").slice(0,80)); return;
  }
  process.stdout.write("yes");
});')"
case "$READ_OK" in
  yes) echo "  ✓ read_text 读得出正文，且内容就是那份文件（以前这里是「拒绝读取」）" ;;
  *)   echo "  ✗ read_text 失败：$READ_OK"; exit 1 ;;
esac

# ⑤ 忽略目录仍被排除 —— 登记根不能把忽略规则绕过去
IGNORED="$("$NODE_BIN" -e '
const {DatabaseSync}=require("node:sqlite");
const p=process.env.HOME+"/.localvault/vault.db";
const db=new DatabaseSync(p,{readOnly:true});
const r=db.prepare("SELECT count(*) c FROM files WHERE path LIKE ? AND gone=0").get("%node_modules%");
process.stdout.write(String(r.c));
')"
if [ "$IGNORED" = "0" ]; then
  echo "  ✓ node_modules 仍被忽略（0 行）—— 登记根没让忽略规则失效"
else
  echo "  ✗ node_modules 进了 $IGNORED 行 —— 忽略规则被绕过了"
  exit 1
fi

# ⑥ 真实库一个字节都没动 —— 这条检查全程只在临时目录里
if [ -n "$REAL_DB_BEFORE" ]; then
  REAL_DB_AFTER="$(stat -f '%z %m' "$REAL_DB")"
  if [ "$REAL_DB_BEFORE" = "$REAL_DB_AFTER" ]; then
    echo "  ✓ 真实索引库指纹未变（大小与 mtime 逐项相同）"
  else
    echo "  ✗ 真实索引库被动过：$REAL_DB_BEFORE → $REAL_DB_AFTER"
    exit 1
  fi
else
  echo "  ⚠️  没找到真实索引库，跳过指纹比对"
fi

# ⑦ 假主目录里那个库确实是这一轮建的（防止 ⑥ 是「什么都没跑」导致的假绿）
FAKE_DB="$FAKE_HOME/.localvault/vault.db"
if [ -f "$FAKE_DB" ]; then
  echo "  ✓ 假主目录里的库存在（本检查真的跑过一轮）"
else
  echo "  ✗ 假主目录里没有库 —— 上面可能什么都没跑，那几条「通过」不算数"
  exit 1
fi

echo ""
echo "  云盘在配置里是索引根了，agent 现在读得到。"
