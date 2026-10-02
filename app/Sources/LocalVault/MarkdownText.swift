import SwiftUI

// MARK: - 块模型
//
// 为什么自己解析块级，而不是直接 `AttributedString(markdown:)`：
// **那个 API 会把块级结构压平** —— `# 标题` 和 `- 列表` 到了它手里都变成一段普通文字，
// 只剩粗体/斜体/行内代码这些行内格式还留着。所以块级必须自己切，行内才交给它。

struct MarkdownListItem: Equatable {
    /// 0 = 顶层，1 = 嵌套一层。再深的不再区分缩进 —— 预览面板里看不出差别，只是白占宽度。
    let indent: Int
    let marker: String
    let text: String
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, lines: [String])
    case quote([String])
    case rule
    case table(header: [String], rows: [[String]])
}

// MARK: - 解析

enum MarkdownParser {

    /// 纯粹的行扫描状态机。抽成纯函数是为了能脱离 SwiftUI 单独跑测试 ——
    /// 渲染结果没法在命令行看，但解析结果能。
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { i += 1; continue }

            // ① 围栏代码块。必须最先判 —— 代码块里的 `#` 和 `---` 是内容，不是标题和分隔线。
            //    未闭合的围栏按「一直到文件结尾都是代码」处理，不报错。
            if let fence = fenceMarker(line) {
                let language = String(line.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }   // 吃掉闭合围栏
                blocks.append(.code(language: language.isEmpty ? nil : language, lines: body))
                continue
            }

            // ② 分隔线。`---` / `***` / `___`，可带空格，至少三个。
            if isRule(line) { blocks.append(.rule); i += 1; continue }

            // ③ 标题。GFM 要求 `#` 后有空格（或行尾）—— 所以 `#tag` 不是标题。
            if let h = heading(line) { blocks.append(h); i += 1; continue }

            // ④ 引用块
            if line.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    body.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(body))
                continue
            }

            // ⑤ 表格。必须先确认第二行是分隔行，否则 `| a | b |` 只是一段普通文字。
            if let t = table(lines, from: i) {
                blocks.append(t.block)
                i = t.next
                continue
            }

            // ⑥ 列表
            if listItem(raw) != nil {
                var items: [MarkdownListItem] = []
                while i < lines.count, let it = listItem(lines[i]) {
                    items.append(it)
                    i += 1
                    // 列表项下的续行（缩进但没有标记）并进上一项
                    while i < lines.count {
                        let l = lines[i]
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { break }
                        if listItem(l) != nil { break }
                        if leadingSpaces(l) >= 2, let last = items.popLast() {
                            items.append(MarkdownListItem(indent: last.indent,
                                                          marker: last.marker,
                                                          text: last.text + " " + t))
                        }
                        i += 1
                    }
                }
                blocks.append(.list(items))
                continue
            }

            // ⑦ 段落：连续非空行合并。行内换行保留 —— 原文怎么断，预览就怎么断。
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if fenceMarker(t) != nil || isRule(t) || heading(t) != nil || t.hasPrefix(">") {
                    break
                }
                if listItem(l) != nil { break }
                para.append(t)
                i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
            else { i += 1 }
        }

        return blocks
    }

    // MARK: 识别小工具

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    /// 返回围栏本身（``` 或 ~~~，可能更长），不是围栏返回 nil。
    private static func fenceMarker(_ line: String) -> String? {
        for ch in ["`", "~"] where line.hasPrefix(String(repeating: ch, count: 3)) {
            var n = 0
            for c in line { if String(c) == ch { n += 1 } else { break } }
            // ``` 后面紧跟文字（如 ```swift）是合法的语言标注；但行内代码 `x` 不算围栏。
            return String(repeating: ch, count: n)
        }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        let kinds: Set<Character> = ["-", "*", "_"]
        guard let first = compact.first, kinds.contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0 else { return nil }
        // `#tag` 不是标题：`#` 之后必须是空格或行尾
        if !rest.isEmpty, rest.first != " " { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        // `#` 独占一行（空标题）不画 —— 画出来是个空行，没有信息
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func listItem(_ raw: String) -> MarkdownListItem? {
        let indent = leadingSpaces(raw) >= 2 ? 1 : 0
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.count >= 2 else { return nil }

        // 无序：`- ` / `* ` / `+ `
        let first = line.first!
        if ["-", "*", "+"].contains(first), line.dropFirst().first == " " {
            return MarkdownListItem(indent: indent, marker: "•",
                                    text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        }

        // 有序：`1. ` / `12) `
        var digits = ""
        for c in line {
            if c.isNumber, digits.count < 4 { digits.append(c) } else { break }
        }
        if !digits.isEmpty {
            let after = line.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                return MarkdownListItem(indent: indent, marker: "\(digits).",
                                        text: String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// GFM 管道表。**必须第二行是分隔行才认**，否则 `| a | b |` 只是普通段落 ——
    /// 这条判断不做，任何含竖线的正文都会被画成一张坏表。
    private static func table(_ lines: [String], from start: Int)
        -> (block: MarkdownBlock, next: Int)? {
        guard start + 1 < lines.count else { return nil }
        let head = lines[start].trimmingCharacters(in: .whitespaces)
        let sep = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard head.contains("|"), sep.contains("|") else { return nil }
        guard isTableSeparator(sep) else { return nil }

        let header = splitRow(head)
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            guard l.contains("|"), !l.isEmpty else { break }
            rows.append(splitRow(l))
            i += 1
        }
        return (.table(header: header, rows: rows), i)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            let core = t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 1 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - 行内格式

private enum MDInline {

    /// 行内交给 AttributedString，但**必须**指定 `.inlineOnlyPreservingWhitespace`：
    /// 默认模式会顺手把换行和缩进吃掉，段落里的软换行就没了。
    /// 解析失败退回纯文本 —— 预览里出现乱码比出现原文更糟。
    static func make(_ source: String, codeFont: Font) -> Text {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        guard var attr = try? AttributedString(markdown: source, options: opts) else {
            return Text(source)
        }
        // 先收 range 再改 —— 边遍历 runs 边写 attr 是未定义行为
        let codeRanges = attr.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for r in codeRanges { attr[r].font = codeFont }
        return Text(attr)
    }
}

// MARK: - 行数估算
//
// 放在文件作用域而不是 View 的方法里：它要在**后台任务**里被调用，
// 而成 View 的方法默认是 main actor 隔离的 —— 挂进 View 会编译成警告，
// Swift 6 语言模式下直接是错误。

private func blockLineCount(_ b: MarkdownBlock) -> Int {
    switch b {
    case .code(_, let lines): return lines.count
    case .list(let items): return items.count
    case .quote(let lines): return lines.count
    case .table(_, let rows): return rows.count + 1
    case .heading, .paragraph, .rule: return 1
    }
}

// MARK: - 视图

/// 把一段 Markdown 正文排成 SwiftUI 视图。
///
/// 只做块级渲染；行内格式交给 `AttributedString`。三条硬约束写在下面，改之前先读。
struct MarkdownText: View {

    /// 结构性尺寸放这里。设计契约允许「文件局部 enum」承载这类常量，
    /// 但颜色和字号**必须**走 Theme 与系统语义字号，不许在这里写字面量。
    private enum MD {
        /// 最多渲染多少个块。**索引用 `maxStoredBodyChars = 400000` 截断**，
        /// 本机真的有 40 万字符的文件；全量铺成 Text 会卡死滚动。
        static let maxBlocks = 400
        static let maxLines = 12_000
        static let ruleWidth: CGFloat = 3
        static let quoteBar: CGFloat = 3
        static let nestIndent: CGFloat = 18
        static let codeRule: CGFloat = 1
    }

    let source: String

    init(_ source: String) {
        self.source = source
    }

    @State private var blocks: [MarkdownBlock] = []
    @State private var totalBlocks = 0
    @State private var parsed = false

    var body: some View {
        Group {
            if source.isEmpty {
                Text("索引里没有正文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !parsed {
                // 解析放后台：一段 40 万字符的正文在主线程上切块会掉帧
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if blocks.isEmpty {
                Text("正文里没有可排版的内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                        blockView(b)
                    }
                    if totalBlocks > blocks.count {
                        Text("只显示前 \(blocks.count) 个块（共 \(totalBlocks) 个）—— 正文在索引里是完整的")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, Space.xxs)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .task(id: source) {
            parsed = false
            let src = source
            let (shown, total) = await Task.detached(priority: .userInitiated) {
                let all = MarkdownParser.parse(src)
                var lines = 0
                var cut = all.count
                for (idx, b) in all.enumerated() {
                    lines += blockLineCount(b)
                    if idx + 1 > MD.maxBlocks || lines > MD.maxLines { cut = idx + 1; break }
                }
                return (Array(all.prefix(cut)), all.count)
            }.value
            guard !Task.isCancelled else { return }
            blocks = shown
            totalBlocks = total
            parsed = true
        }
    }

    @ViewBuilder
    private func blockView(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let text):
            MDInline.make(text, codeFont: codeFont)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? Space.xxs : 0)

        case .paragraph(let text):
            MDInline.make(text, codeFont: codeFont)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .list(let items):
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(it.marker)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        MDInline.make(it.text, codeFont: codeFont)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(it.indent) * MD.nestIndent)
                }
            }

        case .code(let language, let lines):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Space.xs)
                        .padding(.top, Space.xxs)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            // 代码行**必须原样输出**：走 Markdown 会被当行内格式吃掉 `*` `_`
                            Text(l.isEmpty ? " " : l)
                                .font(codeFont)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(Space.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: Radius.sm))

        case .quote(let lines):
            HStack(alignment: .top, spacing: Space.sm) {
                RoundedRectangle(cornerRadius: MD.quoteBar / 2)
                    .fill(.tertiary)
                    .frame(width: MD.quoteBar)
                MDInline.make(lines.joined(separator: "\n"), codeFont: codeFont)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(.quaternary)
                .frame(height: MD.codeRule)
                .padding(.vertical, Space.xxs)

        case .table(let header, let rows):
            // 用 Grid 而不是自己拼 HStack：列宽由内容自动对齐，
            // 手动拼的表格在中文和英文混排时一定歪。
            Grid(alignment: .leading, horizontalSpacing: Space.sm,
                 verticalSpacing: Space.xxs) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, c in
                        MDInline.make(c, codeFont: codeFont)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Rectangle().fill(.quaternary).frame(height: MD.codeRule)
                    .gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, c in
                            MDInline.make(c, codeFont: codeFont)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var codeFont: Font { .system(.caption, design: .monospaced) }

    /// 字号只用系统语义字号 —— 设计契约禁止 `.system(size:)`。
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        case 3: return .callout.weight(.semibold)
        default: return .callout.weight(.medium)
        }
    }
}
