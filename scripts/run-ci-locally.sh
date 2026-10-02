#!/usr/bin/env bash
# 在本地跑一遍 CI 做的事，顺序与 .github/workflows/ci.yml 一致。
#
# 为什么要有它：CI 只在推上去之后才跑，而「CI 能不能红」这件事必须当场能验。
# 一个从没红过的 CI 文件，和没有 CI 的区别只是多了一份 YAML。
#
#   sh scripts/run-ci-locally.sh            # 跑一遍
#   sh scripts/run-ci-locally.sh --verbose  # 连每步的输出一起看
#
# 退出码：0 全过；1 有步骤失败（打印是哪一步）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
VERBOSE="${1:-}"

# 这个仓库没有全局 node/npm（系统里就没装），一律用打包进 App 的那份运行时。
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  for cand in \
    "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node" \
    "$(ls -d /Applications/*/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node 2>/dev/null | head -1)"
  do
    [ -x "$cand" ] && { NODE="$cand"; break; }
  done
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
  echo "!! 找不到 node。CI 上用 actions/setup-node；本地请把 node 放进 PATH。" >&2
  exit 2
fi
echo "node: $NODE"

FAILED=""
step() {
  local name="$1"; shift
  printf '\n── %s\n' "$name"
  local log; log="$(mktemp)"
  if "$@" >"$log" 2>&1; then
    echo "   ✅ 通过"
    [ "$VERBOSE" = "--verbose" ] && sed 's/^/   /' "$log"
    rm -f "$log"; return 0
  fi
  echo "   ❌ 失败"
  sed 's/^/   /' "$log" | tail -30
  rm -f "$log"
  FAILED="$FAILED $name"
  return 1
}

step "恒真断言扫描" python3 "$HERE/check-assertions.py"

# 四个测试直接跑 node —— 本地没有 npm（CI 上有）。测试内容完全一样。
run_tests() {
  local d="$REPO/mcp-server"
  for t in ignore-lists smoke clean-machine upstream mcp-handshake; do
    printf '   %-15s ' "$t"
    if (cd "$d" && "$NODE" "test/$t.js" >/tmp/ci-$t.log 2>&1); then
      grep -E "^通过|通过 [0-9]+ 项" /tmp/ci-$t.log | tail -1
    else
      echo "退出码 $? —— 见 /tmp/ci-$t.log"
      return 1
    fi
  done
}
step "全部测试" run_tests

step "Swift 编译（Release）" bash -c "cd '$REPO/app' && swift build -c release"

# 自检那一步：造语料 → 建库 → 自检 → 比对数据目录指纹
selftest_step() {
  cd "$REPO/app" || return 1
  # 用 SwiftPM 自己的 --show-bin-path，不要 find .build/release
  #（那是个软链接，find 默认不跟随，会「成功但什么都不返回」）。
  local bin
  bin="$(swift build -c release --show-bin-path)/LocalVault"
  [ -x "$bin" ] || { echo "找不到自检二进制：$bin"; return 1; }

  local home; home="$(mktemp -d)/home"
  "$NODE" ../scripts/make-ci-fixture.mjs "$home" || return 1
  HOME="$home" CFFIXED_USER_HOME="$home" "$NODE" ../mcp-server/cli.js init >/dev/null || return 1
  HOME="$home" CFFIXED_USER_HOME="$home" "$NODE" ../mcp-server/cli.js index >/dev/null || return 1

  local data="$home/.localvault"
  local before after
  before="$(find "$data" -type f -exec stat -f '%N %z %m' {} \; | sort)"
  local out code
  out="$(HOME="$home" CFFIXED_USER_HOME="$home" "$bin" --selftest 2>&1)"; code=$?
  after="$(find "$data" -type f -exec stat -f '%N %z %m' {} \; | sort)"

  echo "$out" | grep -E "通过|自检"
  case "$code" in 0|3) ;; *) echo "自检有失败项（exit=$code）"; return 1 ;; esac
  echo "$out" | grep -q "失败 0" || { echo "自检报告里有失败项"; return 1; }
  echo "$out" | grep -q "跳过 1 " || { echo "跳过项数不是预期的 1 —— 语料没被吃进去"; return 1; }
  [ "$before" = "$after" ] || { echo "只读自检动了数据目录（大小或 mtime 变了）"; return 1; }
  echo "   （数据目录指纹逐个相同，含 mtime）"
}
step "App 只读自检（真语料 + 不留痕）" selftest_step

printf '\n────────────────────────────\n'
if [ -n "$FAILED" ]; then
  echo "CI 失败，问题出在：$FAILED"
  exit 1
fi
echo "CI 全过"
