import Foundation
import SwiftUI

/// `meta.map` 里那份 JSON 的结构化版本。
///
/// 之前界面直接把 JSON 原文贴出来 —— 我当时的理由是"人和 agent 看到同一份事实，逐字不改"。
/// 那是**误把手段当成了目的**：同一份事实不等于同一种呈现。agent 读 JSON，人读界面。
struct VaultMap: Codable {
    struct Root: Codable {
        var path: String
        var label: String
        var priority: Int?
        var exists: Bool?
        var files: Int
        var bytes: Int64
        var bytesText: String?
        var latestDate: String?
    }

    struct TopDir: Codable {
        var name: String
        var files: Int
        var bytes: Int64
        var bytesText: String?
        var date: String?
        var note: String?
        var noteSource: String?
        var isRootLoose: Bool?
    }

    struct KindCount: Codable {
        var kind: String
        var files: Int
        var bytes: Int64
    }

    struct EntryDoc: Codable {
        var rel: String
        var path: String?
        var title: String?
        var origin: String?
        var size: Int64?
        var date: String?
    }

    struct Rules: Codable {
        var file: String?
        var exists: Bool?
        var origin: String?
        var rules: [String]?
    }

    struct Discovery: Codable {
        var configFile: String?
        var sources: [String: String]?
        var entryDocsSkippedDeeper: Int?
        var canonicalDocsFromConfig: Int?
        var dirNotesFromConfig: Int?
        var ledgerRel: String?
        var ledgerShape: String?
        var rulesRel: String?
    }

    struct Ledger: Codable {
        var file: String?
        var baseline: String?
        var projectCount: Int?
        var groups: [String]?
        var mtime: Int64?
    }

    var generatedDate: String?
    var tookMs: Int?
    var dataDir: String?
    var primaryRoot: String?
    var roots: [Root]?
    var totalFiles: Int?
    var totalBytes: Int64?
    var totalBytesText: String?
    var lastScanDate: String?
    var topLevelDirs: [TopDir]?
    var kinds: [KindCount]?
    var entryDocs: [EntryDoc]?
    var rules: Rules?
    var discovery: Discovery?
    var ledger: Ledger?

    static func decode(_ raw: String) -> VaultMap? {
        guard let d = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VaultMap.self, from: d)
    }
}

// MARK: - 地图面板
//
// 「来源」是这四个字整个产品的信誉所在：
// 界面上的每一个数字、每一条规则、每一份入口文档，都要能回答**"这是哪来的"**。
// 所以这里的分组不是装饰 —— 每个 PanelBox 的 subtitle 都要说清"这一块回答什么问题"。

/// 地图的**人读版**。agent 拿到的仍是同一份 JSON。
struct MapPanel: View {
    let map: VaultMap?
    let rawJSON: String

    @State private var showRaw = false

    var body: some View {
        if let m = map {
            VStack(alignment: .leading, spacing: Space.md) {
                summaryPanel(m)
                if showRaw {
                    rawPanel
                } else {
                    rootsSection(m)
                    topDirsSection(m)
                    entryDocsSection(m)
                    ledgerSection(m)
                    rulesSection(m)
                    provenanceFooter(m)
                }
            }
            .animation(Motion.base, value: showRaw)
        } else {
            PanelBox("索引地图", subtitle: "没读到地图数据。这不是「索引没建」—— 索引本身可以正常用，缺的只是这一份地图。") {
                // 面板里不放假空状态：`EmptyState` 带 maxHeight .infinity，会撑爆面板。
                //
                // 这里原来写的是「**先让索引跑一次**，再回到这里」—— 那是句做不到的话：
                // App 内建的（原生）索引器**永远不写 `meta.map`**，用户跑一百次也不会变，
                // 而「地图由建索引那一步生成」这个印象会把缺口说成用户没听话。
                // 与自检里那条诚实的说法对齐（`VaultStore`：「原生索引器不生成它，属已知缺口」），
                // 并且只给**真能落地的一步**。
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("**这份地图不由 App 内建的索引器生成**（已知缺口）：它只写索引本身（文件名 / 路径 / 正文），所以在 App 里跑多少次索引，这里都不会有地图。")
                        .captionText()
                        .fixedSize(horizontal: false, vertical: true)

                    if let cmd = CLIProbe.plan.mapCommand {
                        Text("想要地图（以及给 agent 用的 instructions）：用 CLI 刷一次缓存 —— 它只重建这份地图，**不重扫磁盘**。")
                            .captionText()
                            .fixedSize(horizontal: false, vertical: true)
                        if let pre = CLIProbe.plan.prerequisite {
                            Text(pre).faintText().fixedSize(horizontal: false, vertical: true)
                        }
                        CLICommandRow(command: cmd)
                        Text(CLIProbe.plan.note)
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("这台机器上没有 `localvault` 命令，App 旁边也没找到 CLI 源码。dmg 里的 `CLI/` 就是完整源码：拷到任意位置后用 `node cli.js reindex-cache` 跑一次（要求 Node ≥ 22.5）。")
                            .captionText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 抬头 —— 这份地图是什么、什么时候生成的、原始 JSON 在哪

    private func summaryPanel(_ m: VaultMap) -> some View {
        PanelBox(
            "索引地图",
            subtitle: "这一块回答：索引收了什么、覆盖了几个位置、什么时候生成的。原始 JSON 可以随时切出来看。",
            trailing: {
                Toggle("看原始 JSON", isOn: $showRaw)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            },
            content: {
                HStack(spacing: Space.xs) {
                    Chip("\(m.totalFiles ?? 0) 个文件", Palette.accent).monospacedDigit()
                    Chip(m.totalBytesText ?? sizeText(m.totalBytes ?? 0), Palette.accent).monospacedDigit()
                    Chip("\(m.roots?.count ?? 0) 个索引根", Palette.accent).monospacedDigit()
                    if let d = m.generatedDate {
                        Chip("生成于 \(d)", Palette.neutral).monospacedDigit()
                    }
                    if let ms = m.tookMs {
                        Chip("耗时 \(ms) ms", Palette.neutral).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if let d = m.lastScanDate {
                        Text("最近扫描 \(d)").faintText().monospacedDigit()
                    }
                }
            }
        )
    }

    /// agent 看到的就是这一段，逐字不改 —— 所以它必须能一键切出来
    private var rawPanel: some View {
        PanelBox("原始 JSON", subtitle: "交给 agent 的就是这一段原文，逐字不改。") {
            Text(rawJSON)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 索引根

    private func rootsSection(_ m: VaultMap) -> some View {
        let roots = m.roots ?? []
        return PanelBox(
            "索引根",
            subtitle: "这一块回答：索引到底覆盖了这台机器上的哪些位置，每个位置有多少文件。"
        ) {
            if roots.isEmpty {
                Text("没有读到索引根，所以这一块没有可证明的东西。").captionText()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roots, id: \.path) { r in
                        MapRow(
                            icon: "externaldrive.fill",
                            title: r.label,
                            path: r.path,
                            tag: r.exists == false ? ("未找到", Palette.warning) : nil,
                            trailing: {
                                HStack(spacing: MapCol.gap) {
                                    MetricColumn(value: "\(r.files)", width: MapCol.count)
                                    MetricColumn(value: r.bytesText ?? sizeText(r.bytes), width: MapCol.size)
                                    MetricColumn(value: r.latestDate ?? "—", width: MapCol.date, faint: true)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: 顶层目录

    private func topDirsSection(_ m: VaultMap) -> some View {
        let dirs = m.topLevelDirs ?? []
        return PanelBox(
            "顶层目录",
            subtitle: "这一块回答：工作区里每个顶层目录装的是什么 —— 说明文字来自各目录自己的 README。"
        ) {
            if dirs.isEmpty {
                Text("没有读到顶层目录，所以这一块没有可证明的东西。").captionText()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(dirs, id: \.name) { d in
                        MapRow(
                            icon: d.isRootLoose == true ? "doc" : "folder",
                            title: d.name,
                            subtitle: d.note,
                            noteSource: d.noteSource,
                            tag: d.isRootLoose == true ? ("根目录散落", Palette.neutral) : nil,
                            trailing: {
                                HStack(spacing: MapCol.gap) {
                                    MetricColumn(value: "\(d.files)", width: MapCol.count)
                                    MetricColumn(value: d.bytesText ?? sizeText(d.bytes), width: MapCol.size)
                                    MetricColumn(value: d.date ?? "—", width: MapCol.date, faint: true)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: 入口文档 —— 每份都标来源

    private func entryDocsSection(_ m: VaultMap) -> some View {
        let docs = m.entryDocs ?? []
        let skipped = m.discovery?.entryDocsSkippedDeeper ?? 0
        return PanelBox(
            "入口文档（\(docs.count) 份）",
            subtitle: "先看这些 —— 它们是你自己指定、或者索引自动认出来的导航入口。点来源标记可以在 Finder 里打开原文。"
        ) {
            VStack(alignment: .leading, spacing: Space.sm) {
                if docs.isEmpty {
                    Text("没有读到入口文档，所以这一块没有可证明的东西。").captionText()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(docs, id: \.rel) { e in
                            MapRow(
                                icon: "doc.text.fill",
                                iconTint: Palette.accent,
                                title: e.title ?? e.rel,
                                path: e.rel,
                                trailing: {
                                    HStack(alignment: .firstTextBaseline, spacing: MapCol.gap) {
                                        MetricColumn(value: e.size.map(sizeText) ?? "—",
                                                     width: MapCol.size, faint: true)
                                        MetricColumn(value: e.date ?? "—",
                                                     width: MapCol.date, faint: true)
                                        SourceTag(origin: e.origin, file: e.path)
                                            .frame(width: MapCol.source, alignment: .trailing)
                                    }
                                }
                            )
                        }
                    }
                }
                if skipped > 0 {
                    Text("另有 **\(skipped)** 份更深层的 README / 导航文件未计入 —— 它们不是入口，只是沿途的说明。")
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 项目台账

    private func ledgerSection(_ m: VaultMap) -> some View {
        PanelBox(
            "项目台账",
            subtitle: "这一块回答：这台机器上有多少个项目、分成几组、这份清单是哪天的口径。台账是项目状态的唯一入口。"
        ) {
            if let l = m.ledger, let n = l.projectCount {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .top, spacing: Space.sm) {
                        MetricTile(title: "项目", value: "\(n)",
                                   caption: "台账里的项目总数", tint: Palette.accent)
                        MetricTile(title: "分组", value: "\(l.groups?.count ?? 0)",
                                   caption: "台账自己的分组口径", tint: Palette.accent)
                    }
                    // 「已盘点」是状态词，不占大数字位 —— 大数字位只给真正的数量。
                    let baseline = l.baseline
                    CaliberRow(label: "清单状态",
                               value: baseline.map { "已盘点 · 基线 \($0)" } ?? "已盘点 · 基线未知",
                               tint: baseline == nil ? Palette.warning : Palette.success)
                    if let f = l.file {
                        CaliberRow(label: "台账文件", value: f)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let ms = l.mtime {
                        CaliberRow(label: "最后改动", value: dateText(ms))
                    }
                    let groups = l.groups ?? []
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            SubHead("分组")
                            FlexibleChips(items: groups, tint: Palette.accent)
                        }
                    }
                }
            } else {
                Text("没读到台账，所以这一块没有可证明的东西。").captionText()
            }
        }
    }

    // MARK: 文件管理规则

    private func rulesSection(_ m: VaultMap) -> some View {
        let rules = m.rules?.rules ?? []
        return PanelBox(
            "文件管理规则（\(rules.count) 条）",
            subtitle: "这一块回答：整理文件时按哪些规则执行。原文在规则文件里，这里只是排版，不改一个字。",
            trailing: {
                SourceTag(origin: m.rules?.origin, file: m.rules?.file)
            },
            content: {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if let f = m.rules?.file {
                        Text(f).pathText().lineLimit(1).truncationMode(.middle)
                    }
                    if m.rules?.exists == false {
                        Chip("规则文件不存在", Palette.warning)
                    }
                    if rules.isEmpty {
                        Text("没读到规则，所以这一块没有可证明的东西。").captionText()
                    } else {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(Array(rules.enumerated()), id: \.offset) { i, r in
                                let parts = splitRule(r)
                                HStack(alignment: .top, spacing: Space.xs) {
                                    Chip("\(i + 1)", Palette.accent, filled: true).monospacedDigit()
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(parts.head).font(.callout.weight(.semibold))
                                        if !parts.body.isEmpty {
                                            Text(parts.body)
                                                .captionText()
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    /// 规则原文是「规则名。 说明」的形式，拆成粗体名 + 说明
    private func splitRule(_ raw: String) -> (head: String, body: String) {
        for sep in ["。", ". "] {
            if let r = raw.range(of: sep) {
                let head = String(raw[raw.startIndex..<r.lowerBound])
                let body = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return (head + "。", body) }
            }
        }
        return (raw, "")
    }

    // MARK: 来源脚注 —— "有据可依"的落点

    private func provenanceFooter(_ m: VaultMap) -> some View {
        let sources: [(String, String?)] = [
            ("配置文件", m.discovery?.configFile),
            ("台账文件", m.ledger?.file),
            ("规则文件", m.rules?.file),
            ("数据目录", m.dataDir)
        ]
        return PanelBox(
            "来源",
            subtitle: "这一块回答：上面每一条结论是从哪个文件读出来的。"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sources, id: \.0) { label, path in
                    if let path {
                        MapRow(icon: "doc.text", title: label, path: path, trailing: { EmptyView() })
                    }
                }
                if let s = m.discovery?.sources, !s.isEmpty {
                    Text("发现方式：" + s.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "  "))
                        .faintText()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }
            }
        }
    }

    private func dateText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

// MARK: - 地图表格的行与列
//
// 列定义**全文件唯一**。上一版每处 HStack 各自猜一个 `.frame(width: 52)`，
// 结果三张"表格"的列互相对不齐，同一列的数字竖着看是锯齿。
//
//   图标 18（前导）｜内容列（弹性、左对齐）｜数值列（固定宽、右对齐、等宽数字）
//
// 数值列的宽度是**给同一类数字用的固定值**，不是随手写的间距。

private enum MapCol {
    static let icon: CGFloat = 18     // 前导图标
    static let count: CGFloat = 56    // 文件数
    static let size: CGFloat = 76     // 体量
    static let date: CGFloat = 84     // 日期
    static let source: CGFloat = 92   // 来源标记
    static let gap: CGFloat = Space.sm
}

/// 一个数值列：固定宽、右对齐、等宽数字 —— 同一列数字竖着看是一条线。
private struct MetricColumn: View {
    let value: String
    let width: CGFloat
    var faint: Bool = false

    var body: some View {
        Text(value)
            .font(faint ? .caption2 : .caption)
            .monospacedDigit()
            .foregroundStyle(faint ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// 地图里的一行：图标 + 主文字（可带一个短标签）+ 说明 / 路径 + 右侧数值列（或来源标记）。
///
/// 行内所有元素按**首行基线**对齐，所以图标、标题、右侧数字永远在同一条线上。
/// 行自带纵向内边距，所以外面列表用 `spacing: 0` —— 行距只在 `Space.xs` 这一处定义。
private struct MapRow<Trailing: View>: View {
    let icon: String
    var iconTint: Color = .secondary
    let title: String
    /// 说明文字（中文散文，可能带 markdown）
    var subtitle: String? = nil
    /// 路径 —— 走 `.pathText()`，等宽、可选中、太长从中间截断
    var path: String? = nil
    /// 说明文字的来源（"据 xxx"）
    var noteSource: String? = nil
    /// 一个短标签，比如"未找到""根目录散落"
    var tag: (text: String, tint: Color)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MapCol.gap) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(iconTint)
                .frame(width: MapCol.icon, alignment: .leading)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let tag { Chip(tag.text, tag.tint) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(.init(subtitle))
                        .captionText()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let path {
                    Text(path).pathText().lineLimit(1).truncationMode(.middle)
                }
                if let noteSource {
                    Text("据 \(noteSource)")
                        .faintText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: MapCol.gap)
            trailing
        }
        .padding(.vertical, Space.xs)
    }
}
