#!/bin/sh
# 生成 bundle 的 cordis.patch.yml，并打印安装说明。
#
# 补丁内容**唯一来源**是 `localvault setup-dsh`（mcp-server/cli.js）。
# 这个脚本只是它的薄包装，不自己拼 YAML —— 拼两份必然漂移。
#
# bundle 不会被自动安装：安装走 DSH GUI 的 Plugins 页面，由官方通道执行，
# 可以随时在界面上卸载。
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

# 优先用 DSH 内置运行时；没有就退回 PATH 上的 node。
NODE=""
for cand in \
  "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node" \
  "$(command -v node 2>/dev/null || true)"
do
  if [ -n "$cand" ] && [ -x "$cand" ]; then NODE="$cand"; break; fi
done

if [ -z "$NODE" ]; then
  echo "找不到可用的 Node（需要 >= 22.5，内置 node:sqlite）。" >&2
  exit 1
fi

"$NODE" "$here/mcp-server/cli.js" setup-dsh --out "$here/bundle"

echo
echo "接下来（在 DSH 界面里操作）："
echo "  1. 侧边栏打开 Plugins（插件）"
echo "  2. Add plugin / 安装插件 → 填入这个绝对路径："
echo "     $here/bundle"
echo "  3. 安装完成后 Enable now（立即启用）"
echo
echo "启用后模型会多出 mcp__localvault__* 系列工具，"
echo "系统提示词里也会出现自动生成的本地上下文。"
echo
echo "验证：让 Agent 调一次 vault_map；"
echo "      或在解码后的 workspace bundle 里查 cordis_inspect_query 的 localvault-mcp 行。"
echo
echo "如需卸载：在同一页面上删除 localvault-mcp 这个 bundle。"
