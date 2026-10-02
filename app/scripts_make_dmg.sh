#!/bin/sh
# 把 dist/本地上下文.app 打成可分发的 .dmg。
#
# 只用系统自带的 hdiutil —— 刻意不引入 create-dmg 之类的第三方工具
# （本机没装，也不想为一个 tar+mv 的动作多一个依赖）。
#
# 幂等：同名 dmg 先删；同卷名还挂着的先卸载。
#
# 用法：
#   sh scripts_make_dmg.sh                 # 打包 + 校验镜像
#   sh scripts_make_dmg.sh --mount-check   # 额外做一次 挂载 → 列内容 → 验签 → 卸载
#
# 诚实提醒（别把这句话删了）：
#   dmg 里的 App 是 **adhoc 签名**、**未公证**（本机 0 张开发者证书），
#   别的 Mac 上首次打开会被 Gatekeeper 拦。放行办法见 首次运行.md。
set -eu

cd "$(dirname "$0")"

APP_NAME="本地上下文"
BUNDLE="dist/${APP_NAME}.app"
VOL_NAME="本地上下文"

MOUNT_CHECK=0
if [ "${1:-}" = "--mount-check" ]; then
  MOUNT_CHECK=1
fi

if [ ! -d "$BUNDLE" ]; then
  echo "找不到 $BUNDLE"
  echo "先跑：sh scripts_build_app.sh"
  exit 1
fi

# ── 拒绝打包一个「旧 App + 新 CLI」的镜像 ───────────────────────────
#
# 这不是假想的：实测发生过。改了 `VaultIndexer.swift`（CR/CRLF 归一化）之后
# 只跑了 `swift build -c release`（更新 `.build/`），**没重跑本目录的
# scripts_build_app.sh** —— 于是 dist/ 里的 App 二进制停在改动之前，
# 而本脚本把新鲜的 `CLI/` 打进去，产出**新 CLI + 旧 App** 的 dmg。
#
# 后果不是「某个功能没生效」，而是**两套索引器对同一份文件给出不同结果**：
# 同一棵树，用 dmg 里的 App 建索引和用 dmg 里的 CLI 建索引，搜出来的东西不一样。
# 而两边各自都不报错。
#
# 所以：分包前比一次时间戳。App 二进制比任何 Swift 源码旧 → 直接拒绝。
# 宁可让人多跑一条命令，也不要发一个内部自相矛盾的包。
BIN="$BUNDLE/Contents/MacOS/${APP_NAME//本地上下文/LocalVault}"
if [ ! -f "$BIN" ]; then
  echo "找不到 $BIN —— dist/ 里的 .app 不完整，先跑：sh scripts_build_app.sh"
  exit 1
fi
NEWEST_SWIFT="$(find Sources -name '*.swift' -newer "$BIN" -print -quit 2>/dev/null || true)"
if [ -n "$NEWEST_SWIFT" ]; then
  echo "❌ 拒绝打包：dist/ 里的 App 比源码旧。"
  echo "   比它新的源码（例如 ${NEWEST_SWIFT}）"
  echo "   App 二进制时间：$(stat -f '%Sm' "$BIN")"
  echo ""
  echo "   先重跑：sh scripts_build_app.sh"
  echo "   （只跑 swift build 不够 —— 那只更新 .build/，不会重新组装 dist/）"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="0.0.0"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

# ── 幂等：先清上一次的痕迹 ─────────────────────────────────────────────
if [ -d "/Volumes/$VOL_NAME" ]; then
  echo "==> 卸载上一次还挂着的 /Volumes/$VOL_NAME"
  hdiutil detach "/Volumes/$VOL_NAME" >/dev/null 2>&1 ||
    hdiutil detach -force "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
fi
rm -f "$DMG"

STAGE="$(mktemp -d /tmp/lv-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT INT TERM

# ── 安装布局：App + 指向 /Applications 的软链 ─────────────────────────
echo "==> 准备安装布局（App + 指向 /Applications 的软链）"
# 用 ditto 而不是 cp -R：ditto 会保留代码签名与资源分叉
ditto "$BUNDLE" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
if [ -f "首次运行.md" ]; then
  # 打进 dmg：用户在"装的时候"就能看到该怎么放行，而不是装完再去翻仓库
  cp "首次运行.md" "$STAGE/首次运行.md"
fi

# ── CLI 源码：想接 agent / MCP 的人不用再 clone 仓库 ───────────────────
#
# 放 CLI/ 子目录。**不带** test/（那是开发期的烟测）、node_modules（本地没装）、
# .build（不存在，但顺手挡住以后误加）。
# 契约：CLI/ 里必须有 cli.js —— 少一个文件就等于给了一条跑不通的路径。
CLI_SRC="../mcp-server"
if [ ! -d "$CLI_SRC" ]; then
  echo "找不到 $CLI_SRC —— 这个 dmg 里就不会有 CLI 源码"
  echo "（如果你确实只要 App，那没关系；否则请从完整仓库里打包）"
else
  echo "==> 带上 CLI 源码 → CLI/（不含 test/、node_modules）"
  ditto "$CLI_SRC" "$STAGE/CLI"
  rm -rf "$STAGE/CLI/test" "$STAGE/CLI/node_modules" "$STAGE/CLI/.build"
  if [ ! -f "$STAGE/CLI/cli.js" ]; then
    echo "!! CLI/ 里没有 cli.js —— 打包错了，停止"
    exit 1
  fi
  if [ -d "$STAGE/CLI/test" ]; then
    echo "!! CLI/ 里混进了 test/ —— 停止"
    exit 1
  fi
  echo "    CLI/ 体积：$(du -sh "$STAGE/CLI" | awk '{print $1}')"
fi

# ── 生成 ────────────────────────────────────────────────────────────
echo "==> hdiutil create → $DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "==> 校验镜像完整性"
hdiutil verify "$DMG" >/dev/null

# ── 可选：真挂一次看看 ──────────────────────────────────────────────
if [ "$MOUNT_CHECK" = "1" ]; then
  echo "==> 挂载 → 列内容 → 验签 → 卸载"
  hdiutil attach "$DMG" -nobrowse -quiet
  ls -la "/Volumes/$VOL_NAME"
  # 挂载卷里的 App 必须仍然签名自洽 —— 否则是打包过程弄坏了包
  if codesign --verify --deep --strict "/Volumes/$VOL_NAME/${APP_NAME}.app" 2>/dev/null; then
    echo "    ✓ 挂载卷里的 App 签名自洽（codesign --verify 通过）"
  else
    echo "    !! 挂载卷里的 App 签名校验失败 —— 这个 dmg 不能用"
    hdiutil detach "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
  # CLI/ 也得真在卷上、且入口文件在
  if [ -f "/Volumes/$VOL_NAME/CLI/cli.js" ]; then
    echo "    ✓ CLI/ 在卷上（cli.js 在）"
  else
    echo "    !! 卷上没有 CLI/cli.js"
    hdiutil detach "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
  hdiutil detach "/Volumes/$VOL_NAME" >/dev/null
fi

echo
echo "完成：$DMG"
echo "体积：$(du -h "$DMG" | awk '{print $1}')"
echo "SHA-256：$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo
echo "提醒：adhoc 签名 + 未公证，别的 Mac 上首次打开会被 Gatekeeper 拦。"
echo "      放行办法（GUI / 终端各一条）见 首次运行.md —— 那里没有「双击即可」这种话。"
