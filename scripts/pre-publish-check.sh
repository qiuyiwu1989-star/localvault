#!/usr/bin/env bash
# 公开发布前的检查：跑一遍，告诉你**现在能不能发**、还差什么。
#
# 为什么要有它：这个仓库里装着「索引用户全部文件」的能力和一个上游 Token 的读取点。
# 推到公开仓库是不可逆的 —— 一旦推上去，历史里的任何东西都已经被抓走了。
# 所以「检查」必须是**一条命令**，而不是某次会话里我恰好跑过一遍。
#
#   sh scripts/pre-publish-check.sh
#
# 退出码：0 可以发（可能有需要确认的提示）；1 有必须处理的问题。
# 它**不改任何东西**，也不 push、不 publish —— 只报告。真发由人决定。
#
# 写这个脚本时踩到的：`$REG：` 这种「变量名后面紧跟全角冒号」在 bash 里会把
# 多字节冒号当成变量名的一部分，报 unbound variable。变量后面跟中文标点的地方
# 一律写 `${REG}`。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
cd "$REPO"

FAIL=0
WARN=0
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  ⚠️  %s\n' "$*"; WARN=$((WARN+1)); }

printf '════ 公开发布前检查 ════\n\n'

# ── 1. 全历史里的凭据形状字符串 ───────────────────────────────
# 必须查 `git log -p --all`，不能只查工作区：
# 工作区干净不代表历史干净，而推上去的是**历史**。
printf '1. 全历史凭据扫描\n'
SEEN=0
# 只看**新增行**（`^+`）。
#
# 理由不是「省事」，是语义：每一次「某行进入历史」都必然是某个 commit 里的
# 一行 `+`。带 `-` 的行是它被删掉的那一刻 —— 而它当初被加进来时，早已作为
# `+` 出现过一次。所以只看 `+` 不漏，反而去掉了大量噪声
# （删除行、上下文行、diff 头）。
scan_one() {
  local label="$1" pat="$2" hits
  # 豁免：AWS 官方文档里公开发布的那个示例 key。
  #
  # 它不是凭据 —— 它是 AWS 自己在文档里用来演示「access key 长什么样」的串，
  # 全世界的示例代码里都有。历史里出现过一次，是**本脚本早先版本的自检探针**。
  #
  # 这是**精确串**豁免（`grep -vF`），不是模式豁免：只滤掉这一个已知示例，
  # 任何别的 AWS 形状的串照样会被抓到。用「模式级」白名单才会开洞，这个不会。
  #
  # 为什么不去改历史：仓库还没有远端，改历史技术上可行，
  # 但会让所有已引用的 commit 哈希失效（多处文档和验收记录都引了哈希），
  # 而代价换来的是「让一个不是密钥的东西从历史里消失」—— 不划算。
  # 动态拼出来，免得源码自己又变成一条命中。
  local doc_key
  doc_key="AKIA$(printf 'IOSFODNN7EXAMPLE')"
  hits="$(git log -p --all --unified=0 2>/dev/null \
            | grep -E '^\+' | grep -vE '^\+\+\+' \
            | grep -vF "$doc_key" \
            | grep -nE "$pat" | head -5 || true)"
  if [ -n "$hits" ]; then
    bad "疑似 ${label}："
    printf '%s\n' "$hits" | sed 's/^/       /'
    SEEN=1
  fi
}
scan_one "AWS access key"  '(AKIA|ASIA)[0-9A-Z]{16}'
scan_one "GitHub token"    'gh[pousr]_[A-Za-z0-9]{36}'
scan_one "OpenAI 风格 key" 'sk-[A-Za-z0-9]{32}'
scan_one "npm token"       'npm_[A-Za-z0-9]{36}'
scan_one "Slack token"     'xox[baprs]-[A-Za-z0-9-]{10}'
scan_one "私钥文件头"       'BEGIN [A-Z ]*PRIVATE KEY'
scan_one "JWT"             'eyJhbGciOi[A-Za-z0-9_-]{20}'

# 反证：拿一个假密钥喂进**同一批模式**，必须命中。
# 否则「没命中」可能只是模式写错了 —— 一个从不报警的扫描器等于没有扫描器。
# ⚠️ 探针串**不能在源码里拼成完整的一串**，否则扫描器会扫到它自己，
# 把自检探针报成真凭据 —— 实测踩过：这一条让检查以
# 「疑似 AWS access key」为由阻断了发布，而命中的是它自己的第 54 行。
#
# 一个会对自身误报的扫描器，人会学着忽略它 —— 那比没有扫描器更坏。
# 所以拆成两段，运行时才拼起来：源码里不存在那个连续字符串，
# 而真正喂进去测的东西仍然是货真价实的 AWS 形状。
PROBE_KEY="AKIA$(printf 'IOSFODNN7EXAMPLE')"
PROBE_HIT="$(printf 'aws_key = %s\n' "$PROBE_KEY" | grep -cE '(AKIA|ASIA)[0-9A-Z]{16}' || true)"
if [ "${PROBE_HIT:-0}" -ge 1 ]; then
  ok "扫描器自检通过（喂假 AKIA 会命中，所以「没命中」才是真的干净）"
else
  bad "扫描器自检失败：假 AKIA 都扫不出来，上面那些「干净」不作数"
fi
if [ "$SEEN" -eq 0 ]; then
  ok "全历史没有看到高置信的密钥形状"
fi

CTX="$(git log -p --all 2>/dev/null | grep -nEi '(token|secret|password|api[_-]?key).{0,4}[:=].{0,4}[A-Za-z0-9/+_-]{24}' | head -5 || true)"
if [ -n "$CTX" ]; then
  warn "有「令牌名=长串」的写法，确认是示例不是真值："
  printf '%s\n' "$CTX" | sed 's/^/       /'
else
  ok "没有「令牌名=长串」的写法"
fi
printf '\n'

# ── 2. 体积 ───────────────────────────────────────────────────
printf '2. 体积\n'
BIG="$(git rev-list --objects --all 2>/dev/null \
  | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
  | awk '$1=="blob" && $3 > 1048576 {printf "       %.1fMB  %s\n", $3/1048576, $4}' | sort -rn | head -10 || true)"
if [ -n "$BIG" ]; then
  warn "历史里有 >1MB 的 blob（确认是否真该在仓库里）:"
  printf '%s\n' "$BIG"
else
  ok "历史里没有 >1MB 的 blob"
fi
printf '  工作区最大的几个已跟踪文件：\n'
git ls-files -z 2>/dev/null | xargs -0 du -k 2>/dev/null | sort -rn | head -5 | sed 's/^/       /'
printf '\n'

# ── 3. 敏感文件有没有被跟踪 ───────────────────────────────────
printf '3. 敏感文件是否被跟踪\n'
SECRETS="$(git ls-files 2>/dev/null | grep -E '(^|/)(\.env($|\.)|.*\.(pem|key|p12|pfx|jks|keystore)$|id_(rsa|dsa|ecdsa|ed25519)|.*credential.*|.*secret.*)' | head -10 || true)"
if [ -n "$SECRETS" ]; then
  bad "这些敏感文件被 git 跟踪了，立刻处理："
  printf '%s\n' "$SECRETS" | sed 's/^/       /'
else
  ok "没有敏感文件被跟踪"
fi
printf '\n'

# ── 4. 构建产物 ───────────────────────────────────────────────
printf '4. 构建产物\n'
CRUFT="$(git ls-files 2>/dev/null | grep -E '(^|/)(\.build|dist|node_modules|__pycache__)/' | head -5 || true)"
if [ -n "$CRUFT" ]; then
  bad "构建产物被跟踪了："
  printf '%s\n' "$CRUFT" | sed 's/^/       /'
else
  ok "没有构建产物被跟踪"
fi
printf '\n'

# ── 5. 远端 ───────────────────────────────────────────────────
printf '5. 远端\n'
if [ -n "$(git remote)" ]; then
  ok "已配置远端：$(git remote -v | head -1)"
  if git ls-remote --exit-code origin >/dev/null 2>&1; then
    ok "远端可达"
  else
    warn "远端配了但连不上（没网？地址错？权限不够？）"
  fi
else
  bad "没有配任何 remote —— 推不了。"
  printf '       你建好公开仓库后：\n'
  printf '         git remote add origin <你的仓库地址>\n'
  printf '         sh scripts/pre-publish-check.sh   # 再跑一遍确认\n'
  printf '         git push -u origin main\n'
fi
printf '\n'

# ── 6. npm 包名 ───────────────────────────────────────────────
printf '6. npm 包名可用性\n'
NAME="$(python3 -c "import json;print(json.load(open('mcp-server/package.json'))['name'])" 2>/dev/null || echo localvault)"
for REG in https://registry.npmjs.org https://registry.npmmirror.com; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${REG}/${NAME}" 2>/dev/null || echo '---')"
  case "$CODE" in
    404) ok "${REG}：${NAME} 还没被占用（404）" ;;
    200) warn "${REG}：${NAME} 已存在（200）—— 确认它是不是你的" ;;
    ---) warn "${REG}：连不上（离线？），跳过" ;;
    *)   warn "${REG}：返回 ${CODE}" ;;
  esac
done
printf '\n'

# ── 7. 本地等价 CI ────────────────────────────────────────────
printf '7. 本地测试与 CI 等价\n'
if [ -f "$HERE/run-ci-locally.sh" ]; then
  if sh "$HERE/run-ci-locally.sh" >/tmp/prepub-ci.log 2>&1; then
    ok "本地 CI 全过"
  else
    bad "本地 CI 没过 —— 先修它，别推。日志：/tmp/prepub-ci.log"
    tail -15 /tmp/prepub-ci.log | sed 's/^/       /'
  fi
else
  warn "没有 scripts/run-ci-locally.sh，跳过"
fi
printf '\n'

# ── 8. 真实索引库 ─────────────────────────────────────────────
printf '8. 真实索引库\n'
if [ -e "${HOME}/.localvault/vault.db" ]; then
  ok "存在：$(stat -f '%z 字节 · 改动时间 %Sm' "${HOME}/.localvault/vault.db")"
  printf '       （发布检查不该改它；这个时间应该是你自己上次建索引的时间）\n'
else
  ok "这台机器上没有真实索引库（干净）"
fi
printf '\n'

# ── 结论 ──────────────────────────────────────────────────────
printf '════════════════════════════\n'
if [ "$FAIL" -gt 0 ]; then
  printf '不能发：%d 个问题必须处理，%d 个要确认。\n' "$FAIL" "$WARN"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  printf '可以发，但有 %d 处要你确认一遍。\n' "$WARN"
  exit 0
fi
printf '干净，可以发。\n'
exit 0
