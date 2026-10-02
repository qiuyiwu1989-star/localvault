#!/usr/bin/env bash
# 用**夹具数据**给 App 截图，落到 docs/。
#
# 为什么必须用夹具而不是真库：截图要进公开 README，而真库里是用户自己的
# 文件路径和文件名。那不是「截图」，那是把个人资料贴到公网上。
#
# 用法：sh scripts/screenshot.sh [输出目录]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="${1:-$REPO/docs}"
APP="$REPO/app/dist/本地上下文.app/Contents/MacOS/LocalVault"
NODE="$(command -v node || echo '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node')"

[ -x "$APP" ] || { echo "!! 先跑 app/scripts_build_app.sh 造出 .app"; exit 1; }
mkdir -p "$OUT"

# 窗口定位器（CGWindowListCopyWindowInfo）
WL="$HERE/.winlist"
if [ ! -x "$WL" ]; then
  swiftc -O "$HERE/winlist.swift" -o "$WL"
fi

HOME_DIR="$(mktemp -d)/home"
"$NODE" "$HERE/make-ci-fixture.mjs" "$HOME_DIR" >/dev/null
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$NODE" "$REPO/mcp-server/cli.js" init >/dev/null
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$NODE" "$REPO/mcp-server/cli.js" index >/dev/null
echo "夹具索引已建：$HOME_DIR"

shoot() {  # shoot <文件名> <外观> [其余参数...]
  local name="$1"; shift
  local appearance="$1"; shift
  HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" \
    "$APP" --appearance "$appearance" "$@" >/dev/null 2>&1 &
  local pid=$!
  local wid=""
  # 必须按 pid 找窗口。只按名字找会拍到**别的**实例 ——
  # 这台机器上就同时开着两个，实测拍错过一次（另一个实例、真库、浅色，
  # 而我要的是夹具、深色）。见 winlist.swift 顶部的说明。
  for _ in $(seq 1 40); do
    sleep 0.5
    wid="$("$WL" "$pid" 2>/dev/null | head -1 | cut -f1 || true)"
    [ -n "$wid" ] && break
  done
  if [ -z "$wid" ]; then
    echo "  !! $name：等不到窗口"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  sleep 1.5   # 等首屏数据加载完，否则截到空态
  screencapture -x -o -l "$wid" "$OUT/$name.png"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 0.5
  local dims
  dims="$(python3 -c "
import struct
d=open('$OUT/$name.png','rb').read(33)
w,h=struct.unpack('>II', d[16:24]); print(f'{w}x{h}')
")"
  echo "  ✓ $name.png  $dims"
}

# 概览态（不选文件）——给 README 用，能一眼看到「判断分布 + 每级多少」
shoot screenshot-overview-light light --tab 提炼
shoot screenshot-overview-dark  dark  --tab 提炼
# 详情态：选中一个文件，看「凭什么这么判」的证据
shoot screenshot-detail-light   light --tab 提炼 --pick README
shoot screenshot-detail-dark    dark  --tab 提炼 --pick README
# 检索态：带一个词进去，看命中与命中次数
shoot screenshot-search-light   light --tab 检索库 --query 本地上下文
shoot screenshot-search-dark    dark  --tab 检索库 --query 本地上下文

rm -rf "$(dirname "$HOME_DIR")"
echo "完成 → $OUT"
