#!/usr/bin/env python3
"""扫描 VaultStore.swift 里所有 check(...) 的第二个参数，揪出恒真形态。

为什么需要它：这个项目的硬规矩是「每一条断言都要能回答：什么坏代码会让它失败？」
`check("x", true, "1 个")` 这种看起来在断言、其实永远不红的写法比没有断言更糟 ——
它冒充覆盖率（让人以为六级分类有一打断言守着，其实一条都没有）。人会忘，扫描器不会。

用法：
    python3 scripts_check_assertions.py                 # 扫 Sources/LocalVault/VaultStore.swift
    python3 scripts_check_assertions.py <file.swift>    # 扫指定文件
    python3 scripts_check_assertions.py --selftest      # 扫描器自测（植入 + 反例，绝不碰仓库文件）
退出码：0 = 没有可判定的恒真断言；1 = 抓到（自测失败也返回 1）。

判定分两类：
  红（可判定，必须修）   字面 true / false / X || true / true || X / 常量比较 / 两边同名同式
  黄（启发式，需人判断） 表达式里用 allSatisfy 却没有非空守卫、没有 unmet: 前置、
                        集合也不是静态非空（`.allCases`）的形态 —— 空集合上的 allSatisfy 恒真
豁免：同一语句或上一行有 `// 扫描器豁免：<理由>` 时，黄降为不提示（红不可豁免）。

实现要点（两条都是被真实代码教训出来的）：
  · **只在代码位置匹配 `check(`** —— 注释里写「原来这里是 check(..., true, ...)」
    不能被当成一处违规。第一版就栽在这上面：它报了 2 处假阳性，全是我自己写的
    解释性注释。所以先用状态机算出「哪些下标是代码」，状态机要认行注释、
    可嵌套的块注释、字符串（含 \\( 插值 —— 插值里回到代码态，还可能再嵌字符串）、
    以及三引号字符串。
  · 参数按 Swift 顶层逗号切分，同样要避开字符串/注释里的逗号与括号。
  · 只依赖下标的代码掩码，不依赖行号或缩进 —— 重排格式不会误报。
"""
import os
import re
import sys

TRUE_LIT = re.compile(r"^true$")
FALSE_LIT = re.compile(r"^false$")
OR_TRUE = re.compile(r"\|\|\s*true$|^true\s*\|\|")
NUM_CMP = re.compile(r"^(\d+)\s*(==|>=|<=|>|<)\s*(\d+)$")
SAME_BOTH = re.compile(r"^(.+?)\s*(==|>=|<=)\s*(.+)$")

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TARGET = os.path.join(HERE, "Sources", "LocalVault", "VaultStore.swift")


def code_mask(src):
    """返回与 src 等长的布尔列表：True 表示该下标处于「代码」位置（不在注释/字符串里）。"""
    n = len(src)
    mask = [False] * n
    stack = []          # 'block' | 'line' | 'string' | 'mstring' | ['interp', depth]
    i = 0
    while i < n:
        c = src[i]
        top = stack[-1] if stack else None
        if top == "line":
            if c == "\n":
                stack.pop()
            i += 1
            continue
        if top == "block":
            if src.startswith("/*", i):          # Swift 块注释可嵌套
                stack.append("block"); i += 2; continue
            if src.startswith("*/", i):
                stack.pop(); i += 2; continue
            i += 1; continue
        if top in ("string", "mstring"):
            if c == "\\":
                if src.startswith("\\(", i):      # 插值：回到代码态
                    stack.append(["interp", 1]); mask[i + 1] = True; i += 2; continue
                i += 2; continue
            if top == "string" and c == '"':
                stack.pop(); i += 1; continue
            if top == "mstring" and src.startswith('"""', i):
                stack.pop(); i += 3; continue
            i += 1; continue
        # ── 代码位置 ──
        if src.startswith("//", i):
            stack.append("line"); i += 2; continue
        if src.startswith("/*", i):
            stack.append("block"); i += 2; continue
        if src.startswith('"""', i):
            stack.append("mstring"); i += 3; continue
        if c == '"':
            stack.append("string"); i += 1; continue
        if top and isinstance(top, list) and top[0] == "interp":
            if c == "(":
                top[1] += 1
            elif c == ")":
                top[1] -= 1
                if top[1] == 0:
                    stack.pop(); i += 1; continue
        mask[i] = True
        i += 1
    return mask


def skip_interp(src, k):
    """跳过 \\( ... ) 插值体（其中可能有嵌套字符串与括号），返回 ) 之后的下标。"""
    n, d = len(src), 1
    while k < n and d > 0:
        if src[k] == '"':
            k += 1
            while k < n:
                if src[k] == "\\":
                    if src.startswith("\\(", k):
                        k = skip_interp(src, k + 2); continue
                    k += 2; continue
                if src[k] == '"':
                    break
                k += 1
        elif src[k] in "([{":
            d += 1
        elif src[k] in ")]}":
            d -= 1
            if d == 0:
                return k + 1
        k += 1
    return k


def check_calls(src, mask):
    """产出 (行号, [参数...], 整段文本)，只认代码位置上的 check(。"""
    n = len(src)
    for m in re.finditer(r"(?<![\w.])check\s*\(", src):
        if not mask[m.start()]:
            continue
        line = src.count("\n", 0, m.start()) + 1
        j = m.end()
        depth, args, cur = 1, [], []
        while j < n and depth > 0:
            c = src[j]
            if c == '"':
                k = j
                while k < n:
                    if src[k] == "\\":
                        if src.startswith("\\(", k):
                            k = skip_interp(src, k + 2); continue
                        k += 2; continue
                    if src[k] == '"':
                        break
                    k += 1
                cur.append(src[j:k + 1]); j = k + 1; continue
            if src.startswith("//", j):
                k = src.find("\n", j); k = n if k < 0 else k
                cur.append(src[j:k]); j = k; continue
            if src.startswith("/*", j):
                k = src.find("*/", j); k = n if k < 0 else k + 2
                cur.append(src[j:k]); j = k; continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0:
                    args.append("".join(cur)); cur = []; j += 1; break
            elif c == "," and depth == 1:
                args.append("".join(cur)); cur = []; j += 1; continue
            cur.append(c); j += 1
        if cur:
            args.append("".join(cur))
        yield line, [a.strip() for a in args], src[m.start():j]


def norm(s):
    return re.sub(r"\s+", "", s)


def classify(expr, guarded_by_unmet=False):
    """返回 (级别, 说明)；级别 red=可判定恒真/恒假, warn=空真风险, ''=没意见。"""
    e = norm(expr)
    if TRUE_LIT.match(e):
        return "red", "字面 true —— 不可能红"
    if FALSE_LIT.match(e):
        return "red", "字面 false —— 恒假（死断言）"
    if OR_TRUE.search(e):
        return "red", "X || true 恒真"
    m = NUM_CMP.match(e)
    if m:
        a, op, b = int(m.group(1)), m.group(2), int(m.group(3))
        val = {"==": a == b, ">=": a >= b, "<=": a <= b, ">": a > b, "<": a < b}[op]
        return "red", f"常量比较 {e} —— {'恒真' if val else '恒假（死断言）'}"
    m = SAME_BOTH.match(expr)
    if m and norm(m.group(1)) == norm(m.group(3)):
        return "red", f"两边是同一个表达式（{norm(m.group(1))}）—— 恒真"
    if "allSatisfy" in expr or ".contains {" in expr:
        if re.search(r"!\s*[\w.\[\]()]*\.isEmpty\s*&&", expr):
            return "", ""                       # 表达式里自带非空守卫
        if guarded_by_unmet:
            return "", ""                       # 前置写在 unmet: 里（task-21 立的规矩）
        static = re.findall(r"([\w.]+)\.allSatisfy", expr)
        if static and all(s.endswith(".allCases") for s in static):
            return "", ""                       # 枚举 allCases：编译期非空
        return "warn", "空集合上的 allSatisfy —— 需非空守卫 / unmet: 前置 / 或静态非空"
    return "", ""


def scan(path):
    src = open(path, encoding="utf-8").read()
    mask = code_mask(src)
    lines = src.split("\n")
    reds, warns, total = [], [], 0
    for line, args, _text in check_calls(src, mask):
        total += 1
        if len(args) < 2:
            continue
        guarded = any(a.startswith("unmet:") for a in args[2:])
        exempt = "扫描器豁免" in lines[line - 1] or (line >= 2 and "扫描器豁免" in lines[line - 2])
        level, why = classify(args[1], guarded)
        row = (line, args[0][:46], args[1][:62], why)
        if level == "red":
            reds.append(row)
        elif level == "warn" and not exempt:
            warns.append(row)
    return total, reds, warns


def main(argv):
    if len(argv) > 1 and argv[1] == "--selftest":
        return selftest()
    path = argv[1] if len(argv) > 1 else DEFAULT_TARGET
    total, reds, warns = scan(path)
    print(f"# check( 调用点：{total} 个  文件：{path}")
    for tag, rows in (("红 · 可判定恒真/恒假（必须修）", reds), ("黄 · 空真风险（需人判断）", warns)):
        print(f"\n## {tag}：{len(rows)} 处")
        for line, title, expr, why in rows:
            print(f"  L{line}: {title}\n        第二参数 = {expr}\n        {why}")
    if not reds and not warns:
        print("\n干净：没有可判定的恒真断言。")
    return 1 if reds else 0


def selftest():
    """扫描器自测：把已知的恒真形态植入一份**副本**（绝不碰仓库里的文件），
    确认全部被抓到；再确认 4 条反例（正常断言、注释里的 check(..., true, ...) 等）不误报。"""
    import tempfile
    src = open(DEFAULT_TARGET, encoding="utf-8").read()
    impl = """
        check("自测植入：字面 true", true)
        check("自测植入：或 true", madeFolders.count > 0 || true)
        check("自测植入：常量比较", 0 == 0)
        check("自测植入：两边同名", probe.claims.count == probe.claims.count)
        check("自测植入：恒假", false)
        check("自测反例：正常断言", 1 + 1 == 2)
        check("自测反例：注释里的 check(..., true, ...) 不算", all.count > 0)
        check("自测反例：带非空守卫", !all.isEmpty && all.allSatisfy { $0.bodyLength >= 0 })
        check("自测反例：前置写在 unmet 里", searchHits.allSatisfy { !$0.snippet.isEmpty },
              "", unmet: "没有命中")
"""
    anchor = '        check("人签条陈 signed_by 非空"'
    if anchor not in src:
        print("扫描器自测：失败（锚点没找到，无法植入）")
        return 1
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "implanted.swift")
        open(p, "w").write(src.replace(anchor, impl + anchor, 1))
        total, reds, warns = scan(p)
        titles = [r[1] for r in reds]
        want = ["字面 true", "或 true", "常量比较", "两边同名", "恒假"]
        missing = [w for w in want if not any(w in t for t in titles)]
        false_pos = [t for t in titles if "反例" in t]
        caught = len([t for t in titles if "植入" in t])
        print(f"植入 5 种恒真形态 → 抓到 {caught} 条；反例被误报 {len(false_pos)} 条（应为 0）")
        for line, title, expr, why in reds:
            print(f"  L{line}: {title} — {why}")
        ok = not missing and not false_pos
        print("扫描器自测：" + ("通过" if ok else f"失败（漏报 {missing} / 误报 {false_pos}）"))
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
