import SwiftUI
import AppKit

/// ① 提炼 —— 应用的主页面。
///
/// 三栏（最左那条是外壳的全局侧栏）：**文件列表** + **全高的详情栏**。
/// 详情栏没选中文件时显示概览（原来占半屏的仪表盘），选中后换成
/// 元数据 + 判断依据 + 正文预览 —— 正文因此拿到整栏高度，不再是底部一条缝。
/// **卡片只给结论（形状 + 颜色），全部依据收进详情栏。**
struct ExtractView: View {
    @ObservedObject var vault: VaultStore
    @ObservedObject var claims: ClaimStore

    @State private var triaged: [TriagedFile] = []
    @State private var filterTriage: Triage? = nil
    @State private var loading = true
    @State private var tookMs = 0
    @State private var selected: TriagedFile?
    @State private var mode: ViewMode = .waterfall
    @State private var pageSize = Metrics.pageStep

    @State private var kinds: [(String, Int, Int64)] = []
    @State private var months: [(String, Int)] = []

    // MARK: - 派生数据

    private func count(_ t: Triage) -> Int { triaged.filter { $0.triage == t }.count }

    private var page: [TriagedFile] { Array(shown.prefix(pageSize)) }

    /// 看"全部"时先按判断分档（值得了解 → 待定 → 没用），再按信息密度 ——
    /// 只按信息密度排的话，「没用」里的 md 会插到「值得了解」的 md 前面。
    private var shown: [TriagedFile] {
        let base: [TriagedFile] = filterTriage.map { f in
            triaged.filter { $0.triage == f }
        } ?? triaged
        return base.sorted {
            if filterTriage == nil, $0.triage != $1.triage {
                return triageOrder($0.triage) < triageOrder($1.triage)
            }
            let a = FileTriage.rank($0), b = FileTriage.rank($1)
            if a != b { return a > b }
            return $0.file.mtime > $1.file.mtime
        }
    }

    /// `Triage` 自己现在就是有序的（`Comparable`，按 `rank`），不再在这里复述一遍顺序 ——
    /// 复述过一次，加第四档时就会漏改这里。
    private func triageOrder(_ t: Triage) -> Int { t.rank }

    private var recent3: Int { months.suffix(3).reduce(0) { $0 + $1.1 } }

    /// 圆环的数字和侧栏的"文件总数"会差一截：`VaultQuery.allFiles` 不取符号链接。
    /// 差多少必须当场说清楚，否则同一屏上两个"文件数"互相拆台。
    private var indexCaliber: String {
        let total = vault.totalFiles.formatted()
        let skipped = max(0, vault.totalFiles - triaged.count)
        guard skipped > 0 else { return "索引共 \(total) 个文件，全部参与了判断" }
        // 取满上限时，差额里还混着被截断的部分 —— 那时就不能说"就是符号链接"。
        let note = triaged.count >= Metrics.fileFetchLimit
            ? "\(skipped.formatted()) 个文件未参与判断（符号链接，或超出单次取数上限）"
            : "\(skipped.formatted()) 个符号链接未参与判断"
        return "索引共 \(total) 个文件，其中 \(note)"
    }

    /// 详情条里的"这到底是哪个文件"。
    private func fullPath(_ f: VaultFile) -> String {
        guard !f.root.isEmpty else { return f.rel }
        return f.root.hasSuffix("/") ? f.root + f.rel : f.root + "/" + f.rel
    }

    // MARK: - 主体

    var body: some View {
        HSplitView {
            fileColumn.frame(minWidth: Metrics.listMin)
            // 详情栏要**封顶**。不封顶时 HSplitView 会把多出来的宽度全给它：
            // 实测 1728pt 窗口下详情栏吃掉 1127pt，正文一行过长反而难读，
            // 而列表栏只剩 370pt —— 瀑布流一列，白扔掉一半屏幕。
            detailColumn.frame(minWidth: Metrics.detailMin,
                               idealWidth: Metrics.detailIdeal,
                               maxWidth: Metrics.detailMax)
        }
        .onAppear { if triaged.isEmpty { load() } }
        .onChange(of: filterTriage) { _, _ in
            // 筛选换了一批：原来选中的文件已经不在这一批里，就退回概览。
            if let s = selected, !shown.contains(where: { $0.file.id == s.file.id }) { selected = nil }
        }
    }

    // MARK: 左栏 —— 文件列表（占满剩余宽度，卡片因此能多排几列）

    private var fileColumn: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            listBar
            Divider()
            if loading {
                loadingView
            } else if shown.isEmpty {
                emptyBrowser
            } else {
                if mode == .waterfall { waterfall } else { listView }
            }
        }
    }

    // MARK: 右栏 —— 全高详情栏（概览 / 元数据 + 依据 + 正文）

    private var detailColumn: some View {
        Group {
            if loading && selected == nil {
                loadingView
            } else if let s = selected {
                fileDetail(s)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 没选中文件时的详情栏 —— 原来占半屏的仪表盘，窄栏里竖排。
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("概览").sectionTitle()
                    Text("没选中文件时这里放全局数字。点左边任意一张卡片，这里换成它的依据和正文。")
                        .captionText()
                        .fixedSize(horizontal: false, vertical: true)
                }
                triagePanel
                if months.count > 1 { trendPanel }
                kindPanel
                extractionPanel
                mapPanel
            }
            .padding(Space.content)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("机器人正在读你的电脑").sectionTitle()
                Text("扫描全部文件 → 判断类型 → 把值得了解的纳入检索库。每一条判断都带依据。")
                    .captionText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    Text("分类耗时 \(tookMs) ms").faintText()
                    Button("重新分类") { load() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, Space.content)
        .padding(.vertical, Space.sm)
    }

    /// 三个数字合成一个区块：环形图给比例，三条可点的数字给精确读数和筛选。
    /// 详情栏窄，所以圆环在上、三条数字竖排在下。
    private var triagePanel: some View {
        PanelBox("判断结果",
                 subtitle: "判断只回答「值不值得花时间读」，不回答「要不要删」。点一个数字只看这一类。") {
            VStack(spacing: Space.md) {
                VStack(spacing: Space.xs) {
                    TriageDonut(
                        slices: Triage.allCases.map {
                            DonutSlice(label: $0.rawValue, value: count($0), tint: triageColor($0))
                        },
                        center: "\(triaged.count)",
                        caption: "个文件已判断",
                        size: Metrics.donutSize
                    )
                    Text(indexCaliber)
                        .faintText()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: Metrics.donutSize)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: Space.xs) {
                    ForEach(Triage.allCases) { t in
                        MetricTile(
                            title: t.rawValue,
                            value: "\(count(t))",
                            caption: filterTriage == t ? "已筛选 · 再点一下取消" : triageHint(t),
                            tint: triageColor(t),
                            fraction: Double(count(t)) / Double(max(1, triaged.count)),
                            selected: filterTriage == t,
                            onTap: { filterTriage = (filterTriage == t) ? nil : t }
                        )
                    }
                }
            }
            .animation(Motion.count, value: triaged.count)
        }
    }

    private var trendPanel: some View {
        PanelBox("近 12 个月改动量",
                 subtitle: "按文件修改时间统计。没有文件的月份保留为空 —— 那是真的没人动过。",
                 trailing: {
                     StatPill(value: "\(recent3)", unit: "近 3 个月改动")
                 },
                 content: {
                     ActivityTrend(months: months.map { (key: $0.0, count: $0.1) },
                                   tint: Palette.accent)
                         .frame(height: Metrics.trendHeight)
                 })
    }

    /// 类型分布的数据点。
    /// **必须传真实 bytes** —— 右侧标注用它，条长刻度由 `KindBars` 内部负责，这里不预先开方。
    private var kindBars: [BarDatum] {
        kinds.map { k in
            BarDatum(name: indexKindLabel(k.0), count: k.1, bytes: k.2, tint: indexKindTint(k.0))
        }
    }

    /// 右边写着"13 种类型"，这里就得画满 13 条 —— 只画 9 条是两句话打架。
    private var kindSubtitle: String {
        let base = "按体量排，条长走平方根刻度 —— 视频那种十几 GB 的大户才不会把小类压成一根线。"
        guard !kinds.isEmpty else { return base }
        return base + "索引里的 \(kinds.count) 种类型全部画出来。"
    }

    private var kindPanel: some View {
        PanelBox("文件类型分布",
                 subtitle: kindSubtitle,
                 trailing: {
                     StatPill(value: "\(kinds.count)", unit: "种类型")
                 },
                 content: {
                     if kinds.isEmpty {
                         Text("索引里还没有类型统计。").captionText()
                     } else {
                         KindBars(items: kindBars)
                     }
                 })
    }

    private var extractionPanel: some View {
        let machineClaims = claims.claims.filter(\.isMachine)
        return PanelBox("提炼出的条目（\(machineClaims.count)）",
                        subtitle: "应用自己不读文件、也不猜 —— 条目由 agent 读完后写入。") {
            if machineClaims.isEmpty {
                // 面板里不放假空状态：`EmptyState` 带 maxHeight .infinity，会撑爆面板。
                Text(.init("还没有条目 —— 刚分类出 **\(count(.mustRead) + count(.readable))** 个「务必读 / 值得读」的文件，那一批就是该喂给 agent 的。"))
                    .captionText()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Space.xxs) {
                    ForEach(machineClaims) { c in
                        ClaimRow(claim: c)
                    }
                }
            }
        }
    }

    /// 地图**不再套一层 PanelBox** —— `MapPanel` 自己就有抬头和分组。
    /// 盒子里套盒子会让材质叠材质、描边叠描边，HIG 明确说不要这么做。
    private var mapPanel: some View {
        MapPanel(map: VaultMap.decode(vault.mapText), rawJSON: vault.mapText)
    }

    // MARK: 列表工具条

    private var listBar: some View {
        HStack(spacing: Space.xs) {
            if let f = filterTriage {
                FilterChip(text: f.rawValue, tint: triageColor(f), selected: true) {
                    filterTriage = nil
                }
                .help("点一下取消筛选")
            } else {
                SubHead("全部文件")
            }
            Text("\(shown.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: Space.xs)
            // 「概览」= 详情栏的"没选中"状态。没有这个入口，瀑布流里就点不回概览。
            FilterChip(text: "概览", tint: Palette.accent, selected: selected == nil) {
                selected = nil
            }
            .help("详情栏显示全局概览")
            ViewModePicker(mode: $mode)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .animation(Motion.base, value: filterTriage)
    }

    private var loadingView: some View {
        VStack(spacing: Space.sm) {
            ProgressView()
            Text("正在给文件分类…").captionText()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBrowser: some View {
        EmptyState(icon: "tray",
                   title: triaged.isEmpty ? "索引里还没有文件" : "这一类里没有文件",
                   message: triaged.isEmpty
                       ? "先在「设置」里确认索引根，再回来点「重新分类」。"
                       : "取消筛选就能看到全部 \(triaged.count) 个文件。") {
            if filterTriage != nil {
                Button("看全部") { filterTriage = nil }
            }
        }
    }

    private var waterfall: some View {
        // 体量条按**当前这一页**归一：按全库归一的话，一个 14GB 的视频会把所有 2KB 文档压成一根看不见的线。
        let items = page
        let pageMax = items.map(\.file.size).max() ?? 1
        return ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Metrics.cardMin), spacing: Space.sm)],
                spacing: Space.sm
            ) {
                ForEach(items) { t in
                    FileCard(item: t, selected: selected?.id == t.id, maxSize: pageMax)
                        .onTapGesture { selected = t }
                }
            }
            .padding(Space.sm)

            if shown.count > pageSize {
                HStack(spacing: Space.sm) {
                    Text("已显示 \(page.count) / \(shown.count)")
                        .captionText()
                        .monospacedDigit()
                    Spacer(minLength: Space.xs)
                    Button("再载入 \(min(Metrics.pageStep, shown.count - page.count)) 个") {
                        pageSize += Metrics.pageStep
                    }
                    .controlSize(.small)
                    Button("显示全部 \(shown.count) 个") { pageSize = shown.count }
                        .controlSize(.small)
                        .help("一次性布局全部文件，窗口出现会慢一些")
                }
                .padding(.vertical, Space.sm)
            }
        }
        .animation(Motion.base, value: mode)
    }

    private var listView: some View {
        List(shown, selection: listSelection) { t in
            FileRow(item: t).tag(t.id)
        }
        .listStyle(.inset)
    }

    private var listSelection: Binding<Int64?> {
        Binding<Int64?>(
            get: { selected?.id },
            set: { id in selected = id.flatMap { key in shown.first { $0.id == key } } }
        )
    }

    // MARK: 详情栏（选中文件） —— 元数据 + 依据 + 正文

    /// 三段竖排：头部与依据按内容高度，正文吃掉**剩下的全部**高度 ——
    /// 这正是本次改版的目的（原先是底部横条，正文只剩一条缝）。
    private func fileDetail(_ s: TriagedFile) -> some View {
        VStack(spacing: 0) {
            detailHead(s)
            Divider()
            reasonsPanel(s)
            Divider()
            previewSection(s)
        }
    }

    private func detailHead(_ s: TriagedFile) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.xs) {
                TypeBadge(kind: s.infoKind, size: Metrics.inspectorBadge)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(s.file.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(fullPath(s.file))
                        .pathText()
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.xs)
            }

            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Chip(s.infoKind.rawValue, kindColor(s.infoKind))
                Chip(s.triage.rawValue, triageColor(s.triage))
                Spacer(minLength: Space.xs)
                Text(triageHint(s.triage))
                    .faintText()
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: Space.md) {
                Label(s.file.sizeText, systemImage: "internaldrive")
                Label(s.file.mtimeText, systemImage: "calendar")
                Label(s.file.ageText, systemImage: "clock")
                Spacer(minLength: Space.xs)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reasonsPanel(_ s: TriagedFile) -> some View {
        PanelBox("判断依据") {
            if s.reasons.isEmpty {
                Text("这一条没带理由。判断必须给得出理由，否则它不该有颜色。").captionText()
            } else {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(Array(s.reasons.enumerated()), id: \.offset) { _, r in
                        ReasonRow(text: r)
                    }
                }
            }
        }
    }

    /// 正文区。**用共用组件**，不在这里另写一套 ——
    /// 检索库那边用的是同一个 `IndexedPreview`，口径必须只有一份。
    @ViewBuilder
    private func previewSection(_ s: TriagedFile) -> some View {
        IndexedPreview(fileId: s.file.id,
                       dbPath: vault.dbPath,
                       path: fullPath(s.file),
                       compact: true)
    }

    // MARK: - 数据

    private func load() {
        loading = true
        let dbPath = vault.dbPath
        let topDirs = vault.topDirNames
        Task {
            let t0 = Date()
            let result = await Task.detached(priority: .userInitiated) {
                (
                    rows: FileTriage.triage(VaultQuery.allFiles(dbPath: dbPath, limit: Metrics.fileFetchLimit),
                                            projectTopDirs: topDirs),
                    kinds: VaultQuery.kinds(dbPath: dbPath),
                    months: VaultQuery.monthlyActivity(dbPath: dbPath)
                )
            }.value
            triaged = result.rows
            kinds = result.kinds
            months = result.months
            tookMs = Int(Date().timeIntervalSince(t0) * 1000)
            loading = false
            // 不自动选中第一个文件：详情栏的静止态是**概览**。
            // `--pick <片段>` 照旧管用；选不中必须**出声** ——
            // 静默回落成第一个文件，会让截图看起来「通过」而其实挑的是别的文件。
            if selected == nil, !ContentView.initialPick.isEmpty {
                let want = ContentView.initialPick
                // 在**全部**判断结果里找，不只当前页 ——
                // `denied` 那类文件都很小，按大小排序永远进不了第一页，
                // 只搜当前页就等于这条分支永远验收不到。
                if let hit = triaged.first(where: {
                    $0.file.name.localizedCaseInsensitiveContains(want)
                }) {
                    selected = hit
                    if !shown.contains(where: { $0.file.id == hit.file.id }) {
                        pageSize = max(pageSize, triaged.count)
                    }
                } else {
                    FileHandle.standardError.write(
                        "--pick \"\(want)\" 没选中：\(triaged.count) 个已判断文件里没有匹配的名字\n"
                            .data(using: .utf8)!)
                    selected = shown.first
                }
            }
        }
    }
}

// MARK: - 结构性尺寸

/// 只放"布局框架"的数（栏宽、行高、图高），**不放间距** —— 间距一律走 `Space`。
private enum Metrics {
    static let pageStep = 180
    static let fileFetchLimit = 12000
    /// 两栏宽度。详情栏要放正文，下限就是"一行正文还读得下去"的宽度。
    static let listMin: CGFloat = 380
    static let detailMin: CGFloat = 420
    static let detailIdeal: CGFloat = 520
    /// 上限。超过约 760pt 正文一行太长，阅读反而变差（实测过 1127pt 的样子）。
    static let detailMax: CGFloat = 760
    static let cardMin: CGFloat = 186
    static let cardHeight: CGFloat = 164
    static let donutSize: CGFloat = 168
    static let trendHeight: CGFloat = 64
    static let triageBar: CGFloat = 3
    static let sizeColumn: CGFloat = 68
    static let ageColumn: CGFloat = 60
    static let inspectorBadge: CGFloat = 26
    static let reasonGlyph: CGFloat = 10
    static let reasonGlyphBox: CGFloat = 12
}

// MARK: - 详情条里的一条理由

/// 理由原文带 `✗` / `✓` 前缀（那是给工具看的），界面上换成克制的加减号。
private struct ReasonRow: View {
    let text: String

    private var isNoise: Bool { text.hasPrefix("✗") }

    private var label: String {
        var t = text
        if t.hasPrefix("✗") || t.hasPrefix("✓") { t.removeFirst(2) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: isNoise ? "minus" : "plus")
                .font(.system(size: Metrics.reasonGlyph, weight: .bold))
                .foregroundStyle(isNoise ? Palette.neutral : Palette.success)
                .frame(width: Metrics.reasonGlyphBox, alignment: .center)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 文件卡片（瀑布流）

/// 卡片一眼可辨：类型靠 `TypeBadge` 的形状与颜色，判断靠左边一条色条。
struct FileCard: View {
    let item: TriagedFile
    var selected: Bool = false
    var maxSize: Int64 = 1

    /// 最近 30 天改动过 —— 只染日期文字，不加圆点。
    private var isRecent: Bool { item.file.daysSince >= 0 && item.file.daysSince <= 30 }

    /// 对数刻度：线性刻度下，一个 14GB 的视频会把所有文档压成一条线。
    private var sizeWeight: Double {
        guard item.file.size > 0, maxSize > 1 else { return 0 }
        let a = log(1 + Double(item.file.size))
        let b = log(1 + Double(maxSize))
        return min(1, max(0.02, a / b))
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(triageColor(item.triage))
                .frame(width: Metrics.triageBar)

            VStack(alignment: .leading, spacing: Space.xs) {
                TypeBadge(kind: item.infoKind)

                Text(item.file.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.file.rel)
                    .pathText()
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)

                BarMeter(fraction: sizeWeight, tint: kindColor(item.infoKind))

                HStack(spacing: Space.xs) {
                    Text(item.file.sizeText)
                        .captionText()
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(item.file.ageText)
                        .font(.caption2)
                        .foregroundStyle(isRecent ? Palette.warning : Palette.neutral)
                }
            }
            .padding(Space.sm)
        }
        .frame(height: Metrics.cardHeight, alignment: .top)
        .cardSurface(selected: selected)
        .contentShape(Rectangle())
        .help(item.file.rel)
    }
}

// MARK: - 文件行（列表）

struct FileRow: View {
    let item: TriagedFile

    private var isRecent: Bool { item.file.daysSince >= 0 && item.file.daysSince <= 30 }

    var body: some View {
        HStack(spacing: Space.xs) {
            Rectangle()
                .fill(triageColor(item.triage))
                .frame(width: Metrics.triageBar)
                .clipShape(Capsule())
            TypeBadge(kind: item.infoKind, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.file.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.file.rel)
                    .pathText()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Space.xs)
            Text(item.file.sizeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Metrics.sizeColumn, alignment: .trailing)
            Text(item.file.ageText)
                .font(.caption2)
                .foregroundStyle(isRecent ? Palette.warning : Palette.neutral)
                .monospacedDigit()
                .frame(width: Metrics.ageColumn, alignment: .trailing)
        }
        .padding(.vertical, Space.xxs)
        .contentShape(Rectangle())
    }
}
