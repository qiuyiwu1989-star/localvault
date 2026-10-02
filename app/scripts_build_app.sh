#!/bin/sh
# 把 SwiftPM 产物包成一个可双击的 .app
set -e
cd "$(dirname "$0")"

APP_NAME="本地上下文"
BUNDLE="dist/${APP_NAME}.app"

# 先删旧包：构建失败时**绝不能留下一个看起来有效的陈旧 .app** ——
# 否则测试会跑在旧代码上，"通过"是假的。（这个坑刚才真踩到了。）
rm -rf "$BUNDLE"

echo "==> 编译（release）"
swift build -c release || { echo "!! 编译失败，已清掉旧包，不留陈旧产物"; exit 1; }

BIN="$(swift build -c release --show-bin-path)/LocalVault"
[ -x "$BIN" ] || { echo "找不到产物 $BIN"; exit 1; }

echo "==> 组装 ${BUNDLE}"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/LocalVault"

# ── 图标 ────────────────────────────────────────────────────────────
# 两条路都要走，缺一不可：
#   · AppIcon.icns  —— 老系统的兜底
#   · Assets.car + CFBundleIconName —— macOS 26 只认这条
# 实测（macOS 26.6）：只给 icns 的话，系统把它当 legacy 图标，
# 在图形外面**再套一圈浅色底板**，变成双层圆角。Terminal / Notes 都有
# Assets.car，所以没有底板。用 actool 把 xcassets 编成 Assets.car 即可。
ACTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
if [ -f "icon/AppIcon.icns" ]; then
  cp "icon/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [ -x "$ACTOOL" ] && [ -d "Assets.xcassets" ]; then
  rm -rf /tmp/lv-assets && mkdir -p /tmp/lv-assets
  if "$ACTOOL" Assets.xcassets --compile /tmp/lv-assets \
       --platform macosx --minimum-deployment-target 14.0 \
       --app-icon AppIcon --output-partial-info-plist /tmp/lv-assets/partial.plist \
       >/dev/null 2>&1; then
    cp /tmp/lv-assets/Assets.car "$BUNDLE/Contents/Resources/Assets.car"
  else
    echo "（actool 失败，本次只有 .icns —— macOS 26 上图标会多一圈底板）"
  fi
else
  echo "（缺 actool 或 Assets.xcassets，本次只有 .icns）"
fi

# ── 版本：单一来源是 ../mcp-server/package.json ─────────────────────
# 以前这里写死 0.1.0，而 CLI 的 package.json 是 1.1.0 —— 公开仓库里
# 「App 与 CLI 同版本发布」这句话当场对不上，而且没人会去核。
# 现在只读一个地方：升版本只改 mcp-server/package.json。
#
# 规则（写清楚，别靠猜）：
#   CFBundleShortVersionString = package.json 的 version
#   CFBundleVersion            = 同一个值（语义化版本本身就单调递增，
#                                所以不手写构建号，避免第二个会漂移的地方）
PKG_JSON="../mcp-server/package.json"
if [ ! -f "$PKG_JSON" ]; then
  echo "!! 找不到 $PKG_JSON —— 版本只有一个来源，读不到就不打包（不猜、不写死默认值）"
  exit 1
fi
APP_VERSION="$(/usr/bin/plutil -extract version raw -o - "$PKG_JSON" 2>/dev/null || true)"
case "$APP_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "!! $PKG_JSON 里的 version 读不出来或格式不对：'$APP_VERSION'"; exit 1 ;;
esac
echo "==> 版本 ${APP_VERSION}（来源 ${PKG_JSON}）"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>本地上下文</string>
  <key>CFBundleDisplayName</key>       <string>本地上下文</string>
  <key>CFBundleExecutable</key>        <string>LocalVault</string>
  <key>CFBundleIdentifier</key>        <string>local.localvault.app</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundleIconName</key>          <string>AppIcon</string>
  <!-- @APP_VERSION@ 由上面那段从 mcp-server/package.json 读出后替换 —— 见 sed 那一行 -->
  <key>CFBundleShortVersionString</key><string>@APP_VERSION@</string>
  <key>CFBundleVersion</key>           <string>@APP_VERSION@</string>
  <!-- 与 Package.swift 的 .macOS(.v14) 对齐。之前写 13.0 是错的：
       用了 SectorMark / overflowResolution 这些 14 才有的 API，
       在 13 上会崩，而 plist 却告诉系统「我能跑」。-->
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <!-- 只读应用：不声明任何文件写入用途 -->
  <key>NSHumanReadableCopyright</key>  <string>只读。不会改动你的任何文件。</string>
</dict>
</plist>
PLIST

# 用哨兵而不是未加引号的 heredoc：以后哪怕 plist 里出现 $ 或反引号也不会被 shell 吃掉
/usr/bin/sed -i '' "s/@APP_VERSION@/$APP_VERSION/g" "$BUNDLE/Contents/Info.plist"

V_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
V_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist")"
echo "    CFBundleShortVersionString=$V_SHORT · CFBundleVersion=$V_BUILD"

# ── 签名 ────────────────────────────────────────────────────────────
# 这里是 **adhoc 签名**（`--sign -`）。它只做一件事：让**本机**信任这个包，
# 让 `codesign --verify` 自洽。它**不是**分发签名，也不带 TeamIdentifier。
#
# 旧注释写的是"临时签名，避免首次打开被拦"—— 那是错的：
# adhoc 签名**不能**避免别的 Mac 上被拦，它只让本机信任。
# 本机 `security find-identity -v -p codesigning` = 0 valid identities，
# 也就是说一张 Apple 开发者证书都没有。后果（2026-10-02 实测）：
#   $ spctl -a -vvv --type execute dist/本地上下文.app
#   dist/本地上下文.app: rejected
#   $ xcrun stapler validate dist/本地上下文.app
#   本地上下文.app does not have a ticket stapled to it.
# 拷到别的 Mac，首次打开就会被 Gatekeeper 拦（「无法验证开发者」/「已损坏」），
# 用户必须手动放行 —— 两条办法见 首次运行.md。
# 想真正做到"双击即可"：Apple Developer 证书 → 用那张证书签 → notarytool 提交公证
# → stapler staple。这不是改这一行能解决的。
if codesign --force --deep --sign - "$BUNDLE" >/dev/null; then
  SIG="$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^Signature=//p' | head -1)"
  TEAM="$(codesign -dvv "$BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  echo "    签名：${SIG:-未知} · TeamIdentifier：${TEAM:-not set}"
  echo "    （adhoc：只在本机受信，别的 Mac 会被 Gatekeeper 拦 —— 见 首次运行.md）"
else
  echo "!! adhoc 签名失败：这个包在本机也可能被拦（签名不完整）"
fi

echo "==> 完成：$BUNDLE"
du -sh "$BUNDLE" | awk '{print "    体积: "$1}'
echo "    分发：sh scripts_make_dmg.sh  →  dist/本地上下文-<版本>.dmg"
