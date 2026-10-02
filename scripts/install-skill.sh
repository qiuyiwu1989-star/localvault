#!/bin/sh
# 把 skill 安装到用户级 skill 目录（~/.agents/skills）。
# 安装后新会话的 skill 目录里就会出现 local-context-mcp，无需重启。
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
src="$here/skill/local-context-mcp"
dest="${AGENTS_HOME:-$HOME/.agents}/skills/local-context-mcp"

if [ ! -f "$src/SKILL.md" ]; then
  echo "找不到 skill 源文件：$src/SKILL.md" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$dest")"
rm -rf "$dest"
mkdir -p "$dest"
cp "$src/SKILL.md" "$dest/SKILL.md"

echo "已安装 skill："
echo "  $dest/SKILL.md"
echo
echo "验证：在 DSH 里新开一个会话，问一句涉及本机文件的问题，"
echo "      或直接说「本地上下文」，看 local-context-mcp 是否出现在 skill 目录里。"
