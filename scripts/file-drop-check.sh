#!/bin/sh
# 拖拽收集的 headless 检查。
#
# 它守的是一个**手拖验不出来**的 bug：在主线程上 `DispatchGroup.wait` 等
# `NSItemProvider` 的回调。回调要靠主线程的 run loop 投递，在主线程等它
# 等于堵住自己 —— 必然超时。界面表现是「投放区亮一下，松手没反应」，
# 外加拖拽的影子卡在屏幕上。
#
# 手拖看到「没反应」时，能想到的原因有十几种；这个检查把它压成两条可断言的：
#   1. 同步调用必须立刻返回；
#   2. 回调必须真的到达并带着 URL。
#
# 跑法：sh scripts/file-drop-check.sh

set -eu
cd "$(dirname "$0")/.."

SRC="app/Sources/LocalVault/FileDrop.swift"
TEST="app/test/FileDropCheck/main.swift"
OUT="$(mktemp -d)/file-drop-check"

for f in "$SRC" "$TEST"; do
  if [ ! -f "$f" ]; then
    echo "  ✗ 缺文件：$f"
    exit 1
  fi
done

if ! command -v xcrun >/dev/null 2>&1; then
  echo "  ✗ 找不到 xcrun（这个检查需要 Xcode 命令行工具）"
  exit 1
fi

# -O 是故意的：不优化的话，编译器可能把「同步调用耗时为 0」优化成更假的 0。
# 这条断言量的是**有没有阻塞**，不是性能，所以优化级别要跟发布版一致。
# 编译输出只在失败时才展示 —— 通过了还刷一屏警告，会让人以为出事了。
if ! xcrun swiftc -O "$SRC" "$TEST" -o "$OUT" > "$OUT.log" 2>&1; then
  echo "  ✗ 编译失败："
  sed 's/^/    /' "$OUT.log"
  exit 1
fi
if [ -x "$OUT" ]; then :; else
  echo "  ✗ swiftc 报了成功但没产出可执行文件"
  exit 1
fi

# 有警告就明说（上面那段故意不隐藏），但不算失败
if grep -q "warning:" "$OUT.log"; then
  echo "  ⚠️  编译有警告（不阻断）："
  grep "warning:" "$OUT.log" | sed 's/^/    /'
  echo ""
fi

"$OUT"
