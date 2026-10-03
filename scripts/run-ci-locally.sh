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

# 先验 workflow 文件本身。语法错的 workflow 不会报错 —— GitHub 只是**从不运行它**，
# 而界面上一切照旧，看起来像「CI 是绿的」。文件本身出错，比某条测试失败更隐蔽。
# 所以这一条排在最前面：它要是红的，后面跑得再绿也不算数。
check_workflow() {
  # 验**每一个** workflow 文件，不是只验 ci.yml。
  #
  # 原来写死了 ci.yml —— 于是后来加的 publish.yml 就算坏了本地也发现不了，
  # 要等推上去、GitHub 拒绝、或者发布那一步才炸。
  # 「检查只覆盖了我恰好想起来的那个文件」，等于没有检查。
  local dir="$REPO/.github/workflows" n=0
  [ -d "$dir" ] || { echo "没有 .github/workflows/ —— 公开仓库上不会有 CI"; return 1; }
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    printf '   %-14s ' "$(basename "$f")"
    ruby -ryaml -e '
      d = YAML.load_file(ARGV[0])
      raise "缺少 on（那它就不会被触发）" unless d["on"] || d[true]
      raise "缺少 jobs" unless d["jobs"].is_a?(Hash) && !d["jobs"].empty?
      d["jobs"].each do |name, j|
        raise "#{name} 缺 runs-on" unless j["runs-on"]
        raise "#{name} 没有 steps" unless j["steps"].is_a?(Array) && !j["steps"].empty?
      end
      on = d["on"] || d[true]
      onk = on.is_a?(Hash) ? on.keys.join(",") : on.to_s
      puts "触发=#{onk} · job=#{d["jobs"].keys.join(",")}"
    ' "$f" || return 1
  done
  [ "$n" -gt 0 ] || { echo "workflows 目录里没有任何 yml"; return 1; }
}
step "CI 配置文件本身（语法 + 会不会被触发）" check_workflow

step "恒真断言扫描" python3 "$HERE/check-assertions.py"

# 如果本机装了 Node/npm（例如便携装的 ~/.localvault-toolchain），把它加进 PATH。
#
# 为什么：`package-integrity` 里有一条**真跑 `npm publish --dry-run`** 的检查。
# 没有 npm 时它会明确报「跳过」，而跳过不等于通过。让它在本地也真的跑，
# 才不会出现「本地全绿、CI 才发现」——这个差异今天已经咬过我一次了。
for _d in "$HOME"/.localvault-toolchain/node-*/bin; do
  [ -x "$_d/npm" ] && PATH="$_d:$PATH" && export PATH
done

# 测试直接跑 node —— 测试内容与 CI 完全一样。
# 加新测试时**这里和 package.json 的 test 脚本都要加**，两处必须一致。
run_tests() {
  local d="$REPO/mcp-server"
  for t in ignore-lists smoke clean-machine upstream mcp-handshake cli-args tool-honesty no-network scan-integrity package-integrity claims; do
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

# Swift 编译 —— **必须从零编**。
#
# 为什么：`swift build` 是增量的。改了一个文件，它只重编那个文件和依赖它的部分。
# 于是「本地编译通过」可能只意味着「我改的那几个文件编过了」，**其余文件根本没被看过**。
# 实测吃过这个亏：`SearchView.swift` 里的一个捕获 var 在 CI 上直接报错，
# 而本地一路绿灯 —— 因为那次我改的是 `VaultIndexer.swift`，`SearchView.swift` 压根没重编。
swift_step() {
  cd "$REPO/app" || return 1
  printf '   Swift: %s\n' "$(swift --version 2>&1 | sed -n 's/^Apple Swift version \([^ ]*\).*/\1/p')"
  rm -rf .build
  swift build -c release
}
step "Swift 编译（Release，从零）" swift_step

# ⚠️ 必须知道的一件事：**本机的 Swift 比 CI 的宽松，本地绿不等于 CI 绿。**
#
# 实测：本机 Swift 6.3.3，GitHub 的 macos-14 runner 是 Swift 5.10。
# 同一个「在并发闭包里捕获 var 再读」的写法，5.10 直接报错、6.3.3 只给警告
# （tools-version 5.9 走 Swift 5 语言模式）。仓库公开后 CI 会在每次 push 时真跑，
# **那才是严格度的那道门**；本地这一步只能保证「不是缓存骗了我」。
step "提醒：本地 Swift 与 CI 的版本差异" bash -c '
  printf "   本机 Swift 版本（见上）；CI 用 macos-14 → Swift 5.10。\n"
  printf "   两者严格度不同：本地绿 **不**代表 CI 绿。以 push 后的 CI 为准。\n"
' 

# 跨索引器对拍：同一棵语料树，CLI 和 App 各建一次索引，逐字段比。
#
# 它排在 Swift 编译之后 —— 需要那个二进制。也是唯一一条**会启动 App** 的检查
# （走 `--onboard auto` 让 App 自己建索引），所以比别的慢几秒；
# 但它守的正是那次「两套实现各写各的、谁都不报错」的分叉，值这个时间。
#
# ⚠️ 它必须跑在**源码二进制**上，也要能跑在出厂产物上（`APP_BIN=...`）。
# 发版前请额外对 dist/ 和 dmg 里的二进制各跑一次 —— 出过一次
# 「源码修了、dist/ 没重编」，产物因此内部自相矛盾。
step "跨索引器对拍（CLI vs App 逐字段）" sh "$HERE/cross-indexer-check.sh"

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
