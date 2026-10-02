#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
恒真断言扫描器 —— 防止 `check(..., true, ...)` 这类「穿了断言衣服的诊断打印」再写进来。

## 为什么需要它

这个项目有一条硬规矩：

> **每一条断言都要能回答「什么坏代码会让它失败？」—— 空洞的断言比没有断言更糟。**

因为它**冒充覆盖率**。一条永远不可能变红的 `✓`，会让人以为「六级分类有一打断言守着」，
实际上一条都没有。而六级梯子是这工具最值钱的部分。

task-22 把已知的十几条拆成了「只打印的诊断（`note`）」+「真断言」，
但**拆一次不等于以后不会再写**。所以这里做一道静态闸门。

## 为什么不能靠肉眼 / 为什么先剥注释

写这个扫描器之前，我（Lead）自己用手写的一次性脚本数过一遍，
它报出「2 条恒真」——**全是假的**：那两个 `check(..., true, ...)` 出现在
**解释这个问题的注释文字里**。注释里写着 `check(..., true, ...)`，
朴素的 `find('check(')` 就把它当成真的调用。

所以这个扫描器**第一步就把注释和字符串字面量换成空白**（保留行号），
然后才找调用。被注释骗过一次的工具没有资格叫检查。

## 判定为恒真的形态

| 形态 | 例子 |
| --- | --- |
| 字面真 | `check("x", true)` |
| 短路恒真 | `check("x", cond || true)` |
| 自反等式 | `check("x", n == n)`、`check("x", 0 == 0)` |
| 空集合恒真 | `check("x", list.allSatisfy { ... })` —— 空集合上恒真（单独归类，需人工判断） |

以及一类**反过来的**问题：

| 形态 | 说明 |
| --- | --- |
| 不可达的 `false` | `check("x", false, unmet: r)` —— `unmet` 非 nil 时根本不判谓词。看着像会红的断言，其实一行都不执行。 |

## 用法

```sh
python3 scripts/check_assertions.py          # 扫默认位置
python3 scripts/check_assertions.py --json   # 机器可读
```

退出码：`0` 没发现；`1` 发现恒真断言。
"""

import io
import json
import os
import re
import sys

SCAN_TARGETS = [
    ("app/Sources/LocalVault", "*.swift"),
    ("mcp-server/test", "*.js"),
]

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


# ---------------------------------------------------------------- 预处理

def strip_comments_and_strings(src, lang):
    """
    把注释和字符串字面量换成等长空白（保留换行与列位置）。

    这是整个扫描器存在的意义所在：不这么做，注释里写一句
    `check(..., true, ...)` 就会被当成真的调用。这一点是**实测踩出来的**。
    """
    out = []
    i = 0
    n = len(src)
    line_comment = "//" if lang in ("swift", "js") else None

    while i < n:
        c = src[i]

        # 行注释
        if line_comment and src.startswith(line_comment, i):
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue

        # 块注释
        if src.startswith("/*", i):
            out.append("  ")
            i += 2
            while i < n and not src.startswith("*/", i):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
            continue

        # 字符串字面量（含 Swift 的 """ 多行）
        if src.startswith('"""', i):
            out.append("   ")
            i += 3
            while i < n and not src.startswith('"""', i):
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("   ")
                i += 3
            continue
        if c == '"':
            out.append(" ")
            i += 1
            while i < n:
                ch = src[i]
                if ch == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if ch == '"':
                    out.append(" ")
                    i += 1
                    break
                # Swift 字符串插值 \(...) —— 里面的代码也算字符串的一部分（它是值不是谓词）
                if ch == "\n":
                    out.append("\n")
                    i += 1
                    continue
                out.append(" ")
                i += 1
            continue

        # JS 的单引号、模板字符串
        #
        # ⚠️ 这一支是**必需的，不是锦上添花**：不加的话 `'vault://file/'` 里那个 `//`
        # 会被上面那个「行注释」分支当成注释起点，把行尾的 `)));` 一起吃掉 ——
        # 括号配对随即散架，`check` 的第二个实参就会一路延伸进后面几行。
        # 实测症状：`smoke.js` 里一条普通断言被误报成「空集合风险」，
        # 而它打印出来的「条件」里混着下一行的代码。**剥离写错，扫描器就在撒谎。**
        if lang == "js" and c in ("'", "`"):
            quote = c
            out.append(" ")
            i += 1
            while i < n:
                ch = src[i]
                if ch == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if ch == quote:
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out)


def find_calls(src, fname):
    """找 `fname(` 并按括号配对取出实参（返回 [(行号, 实参字符串), ...]）。"""
    calls = []
    i = 0
    while True:
        j = src.find(fname + "(", i)
        if j < 0:
            break
        # 前面不能是标识符字符（避免匹配 `mycheck(`）
        if j > 0 and (src[j - 1].isalnum() or src[j - 1] in "_"):
            i = j + 1
            continue
        k = j + len(fname) + 1
        depth = 1
        start = k
        while k < len(src) and depth > 0:
            ch = src[k]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        inner = src[start:k]
        line = src[:j].count("\n") + 1
        calls.append((line, inner))
        i = k
    return calls


def split_args(inner):
    """按**顶层**逗号切实参（括号/花括号内的逗号不算）。"""
    parts = []
    depth = 0
    cur = []
    for ch in inner:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts]


# ---------------------------------------------------------------- 判定

def normalize(expr):
    return re.sub(r"\s+", "", expr)


def is_vacuous_true(expr):
    """
    判定恒真。返回 (是否恒真, 理由)。
    只认**保守**的形态：拿不准的一律不报，避免把工具变成噪音源。
    """
    e = normalize(expr)
    if e == "true":
        return True, "字面量 true"
    if re.fullmatch(r"true\|\|.+", e) or re.fullmatch(r".+\|\|true", e):
        return True, "短路恒真（… || true）"
    lit = re.fullmatch(r"(-?\d+)(\.\d+)?==\1(\.\d+)?", e)
    if lit:
        return True, "自反等式（同一字面量比较）"
    m = re.fullmatch(r"([A-Za-z_][\w.\[\]!?]*|\"[^\"]*\")==\1", e)
    if m:
        return True, f"自反等式（{m.group(1)} == 自己）"
    if e in ("!false", "!!true"):
        return True, "双重否定恒真"
    return False, ""


def _unguarded_every(expr):
    """
    找出**没有非空前提**的 `.every(` / `.all(` / `.allSatisfy(`。

    为什么要做得这么细：第一版只要看见 `.every(` 就报，结果在一份 8 条的清单里
    **误报了 2 条**（`cfg.roots.length === 2 && cfg.roots.every(...)` 明明有前提）。
    一个会喊狼来了的检查，结局是没人读它 —— 那比没有检查更糟，因为大家会以为有。

    规则：对每个 `.every(` 找出它左边那个接收者表达式，然后看**同一段谓词里、
    它之前**有没有一句「接收者.length 比较」把非空钉住。钉住了就不报。
    """
    e = normalize(expr)
    hits = []
    for m in re.finditer(r"\.(allSatisfy|all|every)\(", e):
        pos = m.start()
        # 向左取接收者：允许 `a.b.c` / `a.b[0].c` 这种链
        j = pos
        depth = 0
        while j > 0:
            ch = e[j - 1]
            if ch in "])":
                depth += 1
                j -= 1
                continue
            if ch in "[(":
                depth -= 1
                j -= 1
                if depth < 0:
                    break
                continue
            if depth == 0 and (ch.isalnum() or ch in "_.!?$"):
                j -= 1
                continue
            break
        recv = e[j:pos]
        if not recv:
            hits.append(True)          # 拿不准接收者 → 报，宁可吵
            continue
        prefix = e[:pos]
        guard = re.search(
            re.escape(recv) + r"(?:\.length|\.size|\.count)\s*(?:>|>=|===|!==|!=)\s*"
            r"(?:0|1|2|3|4|5|6|7|8|9|10)\b", prefix)
        hits.append(not bool(guard))
    return any(hits)


def all_satisfy_on_collection(expr):
    """`X.allSatisfy {}` / `X.every(...)` 在**空集合**上恒真，且没有非空前提。"""
    return _unguarded_every(expr)


# ---------------------------------------------------------------- 扫描

def scan_swift(path):
    src = io.open(path, encoding="utf-8").read()
    clean = strip_comments_and_strings(src, "swift")
    findings = []
    for line, inner in find_calls(clean, "check"):
        args = split_args(inner)
        if len(args) < 2:
            continue
        cond = args[1]
        name = args[0].strip().strip('"')
        detail = args[2] if len(args) > 2 else ""
        has_unmet = any(a.startswith("unmet") for a in args)

        vac, why = is_vacuous_true(cond)
        if vac:
            findings.append(dict(file=path, line=line, kind="恒真", why=why, name=name, cond=cond))
            continue
        if normalize(cond) == "false":
            if has_unmet:
                findings.append(dict(file=path, line=line, kind="不可达的 false",
                                     why="带 unmet：谓词根本不判，看着像会红其实一行都不执行",
                                     name=name, cond=cond))
            else:
                findings.append(dict(file=path, line=line, kind="恒假",
                                     why="字面量 false —— 这条永远失败，多半是写错了",
                                     name=name, cond=cond))
            continue
        if all_satisfy_on_collection(cond):
            findings.append(dict(file=path, line=line, kind="空集合风险",
                                 why="allSatisfy/all 在空集合上恒真，确认集合非空（或改用 unmet 挡住）",
                                 name=name, cond=cond))
    return findings


def scan_js(path):
    src = io.open(path, encoding="utf-8").read()
    clean = strip_comments_and_strings(src, "js")
    findings = []
    for line, inner in find_calls(clean, "check"):
        args = split_args(inner)
        if len(args) < 2:
            continue
        cond = args[1]
        name = args[0].strip().strip('"\'`')
        vac, why = is_vacuous_true(cond)
        if vac:
            findings.append(dict(file=path, line=line, kind="恒真", why=why, name=name, cond=cond))
            continue
        if normalize(cond) == "false":
            findings.append(dict(file=path, line=line, kind="恒假", why="字面量 false —— 永远失败",
                                 name=name, cond=cond))
            continue
        if all_satisfy_on_collection(cond):
            findings.append(dict(file=path, line=line, kind="空集合风险",
                                 why=".every()/.all() 在空数组上恒真 —— 先断言 length > 0",
                                 name=name, cond=cond))
    return findings


def main():
    as_json = "--json" in sys.argv
    all_findings = []
    scanned = 0

    for rel, pattern in SCAN_TARGETS:
        d = os.path.join(REPO, rel)
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            if ".build" in root:
                continue
            for f in sorted(files):
                if not f.endswith(pattern.lstrip("*")):
                    continue
                p = os.path.join(root, f)
                scanned += 1
                if p.endswith(".swift"):
                    all_findings += scan_swift(p)
                elif p.endswith(".js"):
                    all_findings += scan_js(p)

    rel = lambda p: os.path.relpath(p, REPO)

    if as_json:
        print(json.dumps({"scanned": scanned, "findings": [
            {**f, "file": rel(f["file"])} for f in all_findings]}, ensure_ascii=False, indent=2))
        # JSON 模式必须**只**输出 JSON —— 后面那些摘要会把它污染成不可解析。
        # （写第一版时就踩了：打完 JSON 继续往下走，`json.load` 报 Extra data。）
        hard_only = [f for f in all_findings
                     if f["kind"] in ("恒真", "恒假", "不可达的 false")]
        return 1 if hard_only else 0

    print("恒真断言扫描")
    print("")
    print(f"  扫描了 {scanned} 个文件")
    print("")

    vac = [f for f in all_findings if f["kind"] == "恒真"]
    hard = [f for f in all_findings if f["kind"] in ("恒假", "不可达的 false")]
    soft = [f for f in all_findings if f["kind"] == "空集合风险"]

    if not all_findings:
        print("  ✓ 没有发现恒真断言、恒假断言或不可达谓词。")
    else:
        for f in vac + hard:
            print(f"  ✗ [{f['kind']}] {rel(f['file'])}:{f['line']}")
            print(f"      {f['name']}")
            print(f"      条件 = {f['cond']}")
            print(f"      {f['why']}")
        for f in soft:
            print(f"  ! [空集合风险] {rel(f['file'])}:{f['line']}  {f['name']}")
            print(f"      条件 = {f['cond'][:120]}")
        print("")
        print(f"  恒真 {len(vac)} · 恒假/不可达 {len(hard)} · 空集合风险 {len(soft)}")

    print("")
    if any(f["kind"] in ("恒真", "恒假", "不可达的 false") for f in all_findings):
        print("有断言不能回答「什么坏代码会让它失败？」—— 这是硬失败。")
        return 1
    print("每一条断言都能回答「什么坏代码会让它失败？」")
    return 0


if __name__ == "__main__":
    sys.exit(main())
