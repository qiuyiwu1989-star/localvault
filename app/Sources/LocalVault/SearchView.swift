import SwiftUI
import AppKit

/// ③ 检索库 —— 原来的「记忆库」。
///
/// 左边：搜索 + 筛选 + 命中的文件（片段 / 高亮 / 命中位置）。
/// 右边：**全高详情栏**，在「我的判断」和「文件详情」之间切 ——
/// 判断不再挤在底部横条里，也不再和结果列表抢高度。
///
/// 为什么签字单元必须这么小：`qiuyiwu-site/SPEC.md:76`
/// 「**签字单元必须小到两秒能判：一句话、一个窗口、两个按钮。
/// 实测：两秒单元完成率 67%，档案单元 0%。**」
/// 上一版是一张 33 行 × 4 个按钮的表（132 个按钮），签字数 0 ——
/// 那不是用户懒，是这个单元设计必然的结果。
struct SearchView: View {
    @ObservedObject var vault: VaultStore
    @ObservedObject var claims: ClaimStore
    var initialQuery: String = ""

    // MARK: 检索状态

    @State private var keyword = ""
    /// 上一次**真正检索过**的词。高亮按它算，而不是按正在输入的内容算。
    @State private var lastQuery = ""
    @State private var hits: [VaultQuery.SearchHit] = []
    @State private var searching = false
    @State private var tookMs = 0
    @State private var searched = false

    // MARK: 筛选（nil = 不限）

    @State private var kindFilter: String? = nil
    @State private var sinceDays: Int? = nil
    @State private var dirFilter: String? = nil

    // MARK: 旁侧数据

    @State private var kinds: [(String, Int)] = []
    @State private var topDirs: [(String, Int, Int64)] = []
    @State private var recent: [VaultFile] = []
    @State private var mode: ViewMode = .list

    // MARK: 右栏状态

    @State private var sidePane: SidePane = .judgments
    @State private var selectedHitId: Int64? = nil
    /// 两秒单元的游标：指向 `targets` 里当前推的那一个。越界 = 这批判完了。
    @State private var cursor = 0
    /// 跳过的目标。**跳过不写条陈，所以它不算签字。**
    @State private var skipped: Set<String> = []
    @State private var primed = false

    /// 建议词**从索引里推**，不写死常量。
    ///
    /// 以前这里硬编码了六个词（其中两个是作者的业务项目名）。后果有两层：
    /// 那是私有信息进了公开源码；而且换台机器点这些词一条都搜不到 ——
    /// 越点越像工具坏了。这里改成「这个库里真有的东西」：顶层目录名。
    /// 目录名本身就在文件路径里，所以点了**必有命中**；
    /// 推不出来（索引是空的）就返回空数组，界面**不显示那一排**，
    /// 而不是显示一排点了没反应的死词。
    private var suggestions: [String] {
        Array(topDirs.sorted { $0.1 > $1.1 }.prefix(6).map { $0.0 })
    }

    /// 建议词按字数折行 —— 顶层目录名长短差得远（「项目管理」对
    /// 「content-distribution-desk」），一行硬塞会挤在一起变形。
    /// 折行口径和 `FlexibleChips` 保持一致。
    private var suggestionRows: [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var len = 0
        for w in suggestions {
            if len + w.count > 24, !row.isEmpty { rows.append(row); row = []; len = 0 }
            row.append(w)
            len += w.count + 2
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// 一排可点的建议词。`suggestions` 为空时**什么都不渲染**。
    @ViewBuilder
    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(suggestionRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Space.xxs) {
                    ForEach(row, id: \.self) { w in
                        FilterChip(text: w, tint: Palette.accent, selected: false) {
                            keyword = w
                            run()
                        }
                    }
                }
            }
        }
    }

    private static let timePresets: [(String, Int?)] = [
        ("不限时间", nil), ("近 7 天", 7), ("近 30 天", 30), ("近 365 天", 365),
    ]

    private var filtersActive: Bool { kindFilter != nil || sinceDays != nil || dirFilter != nil }
    private var typed: String { keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var daysLabel: String? { sinceDays.map { "近 \($0) 天" } }
    /// 输入框里的词还没检索过 —— 提示一句「回车检索」，不然人不知道要不要按
    private var queryIsStale: Bool { searched && !typed.isEmpty && typed != lastQuery }

    /// 结果打满了上限 —— 真实命中数只会更多（实测「记忆」432、「邱懿武」522）。
    private var truncated: Bool { searched && hits.count >= SearchLayout.searchLimit }
    /// 命中数文案。被截断时必须把截断说出来，不能把上限伪装成事实。
    private var countText: String {
        truncated
            ? "命中 \(hits.count)+ 个 · 只列出前 \(hits.count) 个 · \(tookMs) ms"
            : "命中 \(hits.count) 个 · \(tookMs) ms"
    }

    /// 待签：机器写的最新一条，且人还没覆盖它。
    private var pending: [Claim] {
        var latest: [String: Claim] = [:]
        for c in claims.claims where c.isMachine && c.authority == "L0" {
            if latest[c.target] == nil { latest[c.target] = c }
        }
        return latest.values
            .filter { claims.current[$0.target] == nil || claims.current[$0.target]?.isMachine == true }
            .sorted { $0.ts > $1.ts }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterBar
                Divider()
                results
            }
            .frame(maxWidth: .infinity)

            Divider()

            sidebar
                .frame(minWidth: SearchLayout.sideMin,
                       idealWidth: SearchLayout.sideIdeal,
                       maxWidth: SearchLayout.sideMax)
        }
        .searchable(text: $keyword, placement: .toolbar, prompt: "搜正文、文件名或路径")
        .onSubmit(of: .search) { run() }
        .onChange(of: keyword) { _, v in
            // 清空输入 = 回到空状态
            guard searched, v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            hits = []; searched = false; lastQuery = ""; selectedHitId = nil
        }
        .onAppear(perform: prime)
    }

    // MARK: 首次出现

    private func prime() {
        if topDirs.isEmpty { topDirs = vault.topLevelDirs }
        // 一进来就停在第一个**还没判**的目标上，而不是从头再来一遍
        if !primed {
            primed = true
            cursor = firstPendingIndex ?? targets.count
        }
        // --query <词>：带着词进来，自动检索一次
        if !initialQuery.isEmpty, !searched { keyword = initialQuery; run() }
        if kinds.isEmpty || recent.isEmpty {
            let dbPath = vault.dbPath
            Task {
                let r = await Task.detached(priority: .userInitiated) {
                    (k: VaultQuery.kindCounts(dbPath: dbPath),
                     rec: VaultQuery.recentFiles(dbPath: dbPath, limit: 12))
                }.value
                if kinds.isEmpty { kinds = r.k }
                recent = r.rec
            }
        }
    }

    // MARK: 筛选栏

    /// 一行筛选：三个下拉（类型 / 时间 / 目录）+ 清空 + 命中数 + 视图切换。
    private var filterBar: some View {
        HStack(spacing: Space.xs) {
            // 显示一律走 indexKindLabel：SQL 里的 kind 是 `sheet`/`slide`/`bundle`
            // 这种裸英文 key，不能直接出现在给人看的界面里。
            FilterMenu(title: "类型", value: kindFilter.map(indexKindLabel), tint: Palette.accent) {
                Button("全部类型") { kindFilter = nil; rerun() }
                Divider()
                ForEach(kinds, id: \.0) { k, n in
                    Button("\(indexKindLabel(k))  (\(n))") { kindFilter = k; rerun() }
                }
            }

            FilterMenu(title: "时间", value: daysLabel, tint: Palette.accent) {
                ForEach(SearchView.timePresets, id: \.0) { label, days in
                    Button(label) { sinceDays = days; rerun() }
                }
            }

            FilterMenu(title: "目录", value: dirFilter, tint: Palette.accent) {
                Button("全部目录") { dirFilter = nil; rerun() }
                Divider()
                // 不 truncate：少列一个目录，就等于让人没法用它筛
                ForEach(topDirs, id: \.0) { d in
                    Button("\(d.0)  (\(d.1))") { dirFilter = d.0; rerun() }
                }
            }

            if filtersActive {
                FilterChip(text: "清空筛选", tint: Palette.accent, selected: true) { clearFilters() }
            }

            Spacer(minLength: Space.xs)

            if searching { ProgressView().controlSize(.small) }

            if searched {
                Text(countText)
                    .monospacedDigit()
                    .faintText()
                if queryIsStale { Chip("回车检索", Palette.accent) }
                ViewModePicker(mode: $mode)
            }
        }
        .padding(.horizontal, Space.content)
        .padding(.vertical, Space.xs)
    }

    // MARK: 结果

    @ViewBuilder
    private var results: some View {
        if !searched {
            emptyStart
        } else if hits.isEmpty {
            noHits
        } else if mode == .waterfall {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HitCardMetrics.minWidth), spacing: Space.sm)],
                          spacing: Space.sm) {
                    ForEach(hits) { h in
                        HitCard(hit: h, keyword: lastQuery, selected: selectedHitId == h.id) { select(h) }
                    }
                }
                .padding(Space.content)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(hits) { h in
                        HitRow(hit: h, keyword: lastQuery, selected: selectedHitId == h.id) { select(h) }
                        Divider().padding(.leading, Space.content)
                    }
                }
                .padding(.vertical, Space.xxs)
            }
        }
    }

    /// 搜了但没有 —— 必须给一条**能立刻做**的下一步
    private var noHits: some View {
        EmptyState(icon: "magnifyingglass",
                   title: "没有命中",
                   message: filtersActive
                       ? "「\(lastQuery)」在当前的筛选条件下没有结果。条件本身可能太窄了。"
                       : "「\(lastQuery)」在这个索引里搜不到。换个更短的关键词 —— 中文两个字就能命中。") {
            if filtersActive {
                Button("放宽筛选：清空全部条件") { clearFilters() }
                    .buttonStyle(.borderedProminent)
            } else {
                // 推不出建议词时这一排是空的 —— 那就不显示，不拿死词凑数
                suggestionChips
            }
        }
    }

    // MARK: 空状态（还没搜的时候）

    /// 还没搜的时候，把「能搜什么、怎么搜、最近改了什么」一次说清，并且填满整块。
    private var emptyStart: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                coveragePanel
                suggestionPanel
                noBodyPanel
                recentPanel
            }
            .padding(Space.content)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bodyless: Int { max(0, vault.totalFiles - vault.textFileCount) }

    /// 四个数字：两个口径 + 两条占比。
    /// 占比按**这一屏这一批**归一（就是索引全量），不按体量归一 ——
    /// 体量归一的话一个 14GB 的视频会把几万个文档压成一根看不见的线。
    private var coveragePanel: some View {
        PanelBox("这个索引里现在能搜到什么",
                 subtitle: "搜索走三处：正文 / 文件名 / 路径。中文两个字就能命中。") {
            HStack(alignment: .top, spacing: Space.sm) {
                MetricTile(title: "文件已索引",
                           value: "\(vault.totalFiles)",
                           caption: "扫描范围内的全部文件",
                           tint: Palette.accent)
                MetricTile(title: "合计体量",
                           value: sizeText(vault.totalBytes),
                           caption: "索引记的磁盘占用",
                           tint: Palette.accent)
                MetricTile(title: "有正文可搜",
                           value: "\(vault.textFileCount)",
                           caption: percent(vault.textFileCount, vault.totalFiles),
                           tint: Palette.success,
                           fraction: Double(vault.textFileCount) / Double(max(1, vault.totalFiles)))
                MetricTile(title: "只有一句话索引",
                           value: "\(bodyless)",
                           caption: "靠文件名 + 类型 + 路径兜底",
                           tint: Palette.neutral,
                           fraction: Double(bodyless) / Double(max(1, vault.totalFiles)))
            }
        }
    }

    @ViewBuilder
    private var suggestionPanel: some View {
        // 建议词来自索引里的顶层目录；推不出来就整块不显示
        if !suggestions.isEmpty {
            PanelBox("试试搜这些", subtitle: "点一下直接检索。这些词是这个索引里的顶层目录，点了**必有命中**。") {
                suggestionChips
            }
        }
    }

    private var noBodyPanel: some View {
        PanelBox("无正文的文件怎么搜？",
                 subtitle: "\(bodyless) 个文件没有正文 —— 它们不会被漏掉。") {
            VStack(alignment: .leading, spacing: Space.xs) {
                Bullet("文件名、类型、路径被拼成了一句索引，所以**仍然搜得到**。")
                Bullet("命中位置会标成「文件名」或「路径」，片段就是那一句话索引。")
                Bullet("索引是只读的 —— 这个应用不会挪动、改写或删除任何文件。")
            }
        }
    }

    private var recentPanel: some View {
        PanelBox("最近改动",
                 subtitle: "点一行，用它的文件名去搜。还没想起搜什么的时候，从这里进。",
                 // 这里只取最近 12 个（查询上限），所以徽章写「最近 N 个」而不是「共 N 个」
                 trailing: { Chip("最近 \(recent.count) 个", Palette.neutral) }) {
            if recent.isEmpty {
                Text("正在读最近的改动…").captionText()
            } else {
                VStack(spacing: Space.xxs) {
                    ForEach(recent, id: \.id) { f in
                        RecentRow(file: f) { keyword = f.name; run() }
                    }
                }
            }
        }
    }

    // MARK: 右栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidePane) {
                ForEach(SidePane.allCases) { p in Text(p.rawValue).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)

            Divider()

            Group {
                switch sidePane {
                case .judgments: judgmentSidebar
                case .file:      fileSidebar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 右栏 · 我的判断（两秒单元）

    private var judgmentSidebar: some View {
        // 整栏可滚：窗口矮、或条陈多的时候不至于把底部裁掉。
        // 里面不再嵌第二个纵向 ScrollView（嵌套滚动会抢滚轮）。
        ScrollView {
            VStack(spacing: Space.sm) {
                PanelBox("我的判断",
                         subtitle: "签名 **\(claims.signer)** —— 一句话、一个窗口、两个按钮，两秒能判。",
                         trailing: {
                             if !pending.isEmpty { Chip("\(pending.count) 条机器提议待签", Palette.machine) }
                         },
                         content: {
                             if topDirs.isEmpty {
                                 Text("这次索引里没有顶层目录 —— 没有可判的目标。")
                                     .captionText()
                             } else if let t = currentTarget {
                                 twoSecondUnit(t)
                             } else {
                                 closingState
                             }
                         })
                .frame(minHeight: SearchLayout.unitMin)

                // 机器的提议：一屏也只推一条，认完自动换下一条。没有就不出现。
                if let c = pending.first {
                    machineProposalPanel(c)
                }

                if !claims.claims.isEmpty {
                    historyPanel
                }
            }
            .padding(Space.sm)
        }
    }

    /// 两秒单元：一个目标 + 一句话依据 + 两个按钮。
    private func twoSecondUnit(_ t: DirTarget) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            progressBlock

            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundStyle(Palette.accent)
                    Text(t.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                }

                Text(evidenceLine(t))
                    .font(.callout)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)

                Text(whyLine(t))
                    .captionText()
                    .fixedSize(horizontal: false, vertical: true)

                if let v = claims.verdict(for: t.name)?.verdict {
                    HStack(spacing: Space.xxs) {
                        Chip(v, verdictColor(v))
                        Text("已有你的判断 —— 再判一次是**追加**一条，旧的不删。").faintText()
                    }
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Button("保留") { judge(t, .keep) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .help(Verdict.keep.hint)

                    Button("可清理") { judge(t, .discardable) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(verdictColor(Verdict.discardable.rawValue))
                        .frame(maxWidth: .infinity)
                        .help(Verdict.discardable.hint)
                }

                HStack(spacing: Space.sm) {
                    Button("跳过") { skip(t) }
                        .controlSize(.small)
                        .help("跳过不写条陈 —— 跳过不算签字。")
                    Button("上一条") { back() }
                        .controlSize(.small)
                        .disabled(cursor == 0)
                        .help("回到上一条，可以重判或撤回")
                    Spacer(minLength: 0)
                    if claims.verdict(for: t.name) != nil {
                        Button("撤回这条判断") { retractDir(t) }
                            .controlSize(.small)
                            .help("撤回是追加一条撤回条陈，不删历史")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Text("已判 \(judgedCount) / \(topDirs.count)")
                    .monospacedDigit()
                    .captionText()
                Spacer(minLength: Space.xs)
                if !skipped.isEmpty {
                    Text("跳过 \(skipped.count)")
                        .monospacedDigit()
                        .faintText()
                }
            }
            BarMeter(fraction: progressFraction, tint: Palette.accent)
        }
    }

    /// 没有待判的了。**数字必须真** —— 还有没判的就不许说"完成"。
    private var closingState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(remainingCount == 0 ? "这一批都有你的签名了" : "这一轮没有待判的了")
                .sectionTitle()

            Text(closingLine)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.sm) {
                if remainingCount > 0, let i = firstPendingIndex {
                    Button("回到没判的（\(remainingCount) 个）") {
                        withAnimation(Motion.base) { cursor = i }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("从头再看一遍") {
                    withAnimation(Motion.base) { cursor = 0 }
                }
                .help("逐条回看，重判会追加条陈；撤回不删历史")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var closingLine: String {
        var s = "已判 \(judgedCount) 个，还有 \(remainingCount) 个没判。"
        if !skipped.isEmpty { s += "其中 \(skipped.count) 个是你跳过的 —— 跳过不写条陈，不算签字。" }
        if remainingCount > skipped.count {
            s += "剩下的没判目标还在队列里。"
        }
        return s
    }

    /// 机器只能写 L0；人认了才是 L1。一屏一条，认完自动换下一条。
    private func machineProposalPanel(_ c: Claim) -> some View {
        PanelBox("机器的提议（\(pending.count) 条待签）",
                 subtitle: "机器只能写 L0 待签；**认了才升到 L1**。条陈只增不改。") {
            VStack(alignment: .leading, spacing: Space.sm) {
                ClaimRow(claim: c)

                HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("不认") {
                        claims.retract(targetType: c.targetType, target: c.target,
                                       reason: "打回：\(c.note)")
                    }
                    .controlSize(.small)
                    Button("认") {
                        claims.judge(targetType: c.targetType, target: c.target,
                                     verdict: .review, note: c.note)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if pending.count > 1 {
                    Text("还有 \(pending.count - 1) 条在后面 —— 认完这条自动换下一条。")
                        .monospacedDigit()
                        .faintText()
                }
            }
        }
    }

    private var historyPanel: some View {
        PanelBox("签过的（\(claims.claims.count) 条 · 只增不改）",
                 trailing: {
                     HStack(spacing: Space.xxs) {
                         Chip("人签 \(claims.humanCount)", Palette.human)
                         Chip("机器 \(claims.machineCount)", Palette.machine)
                     }
                 },
                 content: {
                     VStack(alignment: .leading, spacing: Space.xxs) {
                         ForEach(claims.claims.prefix(SearchLayout.historyRows)) { c in
                             ClaimRow(claim: c)
                         }
                         // 表头写的是总条数，这里只画最新几条 —— 说清楚，别让人以为就这么多
                         if claims.claims.count > SearchLayout.historyRows {
                             Text("只列出最新 \(SearchLayout.historyRows) 条，另有 \(claims.claims.count - SearchLayout.historyRows) 条在历史里。")
                                 .monospacedDigit()
                                 .faintText()
                         }
                     }
                     .frame(maxWidth: .infinity, alignment: .leading)
                 })
    }

    // MARK: 右栏 · 文件详情

    private var fileSidebar: some View {
        Group {
            if let h = selectedHit {
                VStack(spacing: 0) {
                    identityBlock(h)
                    Divider()
                    IndexedPreview(fileId: h.file.id,
                                   dbPath: vault.dbPath,
                                   path: fullPath(h.file),
                                   compact: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelSurface(radius: Radius.md)
                .padding(Space.sm)
            } else if selectedHitId != nil {
                // 换了一次检索，原来选中的那条不在结果里了 —— 如实说，别留一个空栏
                EmptyState(icon: "doc.text.magnifyingglass",
                           title: "这条已经不在结果里",
                           message: "重新检索之后，原先选中的那条不在这一批命中里了。") {
                    Button("回到我的判断") { withAnimation(Motion.base) { sidePane = .judgments } }
                }
            } else {
                EmptyState(icon: "doc.text.magnifyingglass",
                           title: "点一条结果",
                           message: "这里显示它的全部依据，以及索引里存着的正文。正文只从索引读，不读原文件。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 身份条：一眼知道这是哪个文件、它命中在哪、多大、多久没动过。
    private func identityBlock(_ h: VaultQuery.SearchHit) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                TypeBadge(kind: inferKind(h.file), size: SearchLayout.detailBadge)
                VStack(alignment: .leading, spacing: 0) {
                    Text(h.file.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fullPath(h.file))
                        .pathText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.xs)
                Button {
                    withAnimation(Motion.base) { sidePane = .judgments }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("切回我的判断")
            }

            HStack(spacing: Space.md) {
                Label(h.file.sizeText, systemImage: "internaldrive")
                Label(h.file.mtimeText, systemImage: "calendar")
                Label(h.file.ageText, systemImage: "clock")
                Spacer(minLength: Space.xs)
                Chip(h.matchedIn, matchedColor(h.matchedIn))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    // MARK: 判断 · 队列

    /// 一屏只有一个目标。`topDirs` 本身按文件数降序，rank 就是它在这批里的位置。
    private var targets: [DirTarget] {
        topDirs.enumerated().map { i, d in
            DirTarget(name: d.0, files: d.1, bytes: d.2, rank: i + 1, rankTotal: topDirs.count)
        }
    }

    private var currentTarget: DirTarget? {
        targets.indices.contains(cursor) ? targets[cursor] : nil
    }

    private func isPending(_ t: DirTarget) -> Bool {
        claims.verdict(for: t.name) == nil && !skipped.contains(t.name)
    }

    private var firstPendingIndex: Int? {
        targets.indices.first { isPending(targets[$0]) }
    }

    /// 下一个待判：先往后找，没有再从头找；都没有 → 越界（收尾态）。
    private func advance() {
        let after = targets.indices.first { $0 > cursor && isPending(targets[$0]) }
        cursor = after ?? firstPendingIndex ?? targets.count
    }

    private var judgedCount: Int { topDirs.filter { claims.verdict(for: $0.0) != nil }.count }
    private var remainingCount: Int { max(0, topDirs.count - judgedCount) }
    private var progressFraction: Double {
        topDirs.isEmpty ? 0 : Double(judgedCount) / Double(topDirs.count)
    }

    /// 一句话依据 —— 数字都是索引里真有的。
    private func evidenceLine(_ t: DirTarget) -> String {
        "\(t.files) 个文件 · \(sizeText(t.bytes)) · 占全库 \(percent(t.files, vault.totalFiles))"
    }

    private func whyLine(_ t: DirTarget) -> String {
        "它是按文件数排第 \(t.rank) / \(t.rankTotal) 的顶层目录。给它一句话，整个目录就有了归属 —— 下面不用逐个看。"
    }

    private func judge(_ t: DirTarget, _ v: Verdict) {
        // note 里带上这次的依据：条陈是给人看的，得回答"凭什么这么判"
        claims.judge(targetType: "dir", target: t.name, verdict: v,
                     note: "顶层目录 · \(t.files) 个文件 · \(sizeText(t.bytes))")
        withAnimation(Motion.base) { advance() }
    }

    private func skip(_ t: DirTarget) {
        // 跳过**不写条陈** —— 它不产生任何签字
        skipped.insert(t.name)
        withAnimation(Motion.base) { advance() }
    }

    private func back() {
        let last = targets.count - 1
        guard last >= 0 else { return }
        withAnimation(Motion.base) { cursor = cursor > last ? last : max(0, cursor - 1) }
    }

    private func retractDir(_ t: DirTarget) {
        claims.retract(targetType: "dir", target: t.name, reason: "在检索库里撤回")
    }

    // MARK: 选中

    private var selectedHit: VaultQuery.SearchHit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    private func select(_ h: VaultQuery.SearchHit) {
        selectedHitId = h.id
        if sidePane != .file { withAnimation(Motion.base) { sidePane = .file } }
    }

    private func fullPath(_ f: VaultFile) -> String {
        guard !f.root.isEmpty else { return f.rel }
        return f.root.hasSuffix("/") ? f.root + f.rel : f.root + "/" + f.rel
    }

    // MARK: 动作

    private func run() {
        let q = typed
        guard !q.isEmpty else { return }
        searching = true
        let dbPath = vault.dbPath
        var f = VaultQuery.SearchFilter()
        if let k = kindFilter { f.kinds = [k] }
        f.sinceDays = sinceDays
        f.topDir = dirFilter

        Task {
            let t0 = Date()
            let r = await Task.detached(priority: .userInitiated) {
                VaultQuery.searchEx(dbPath: dbPath, keyword: q, limit: SearchLayout.searchLimit, filter: f)
            }.value
            hits = r
            tookMs = Int(Date().timeIntervalSince(t0) * 1000)
            lastQuery = q
            searched = true
            searching = false
        }
    }

    private func rerun() { if searched { run() } }

    private func clearFilters() {
        kindFilter = nil; sinceDays = nil; dirFilter = nil
        rerun()
    }
}

// MARK: - 右栏的两块

private enum SidePane: String, CaseIterable, Identifiable {
    case judgments = "我的判断"
    case file      = "文件详情"

    var id: String { rawValue }
}

/// 一个待判的顶层目录 —— 两秒单元需要的那几样东西。
private struct DirTarget: Identifiable {
    let name: String
    let files: Int
    let bytes: Int64
    /// 按文件数排的位置（`topDirs` 已按文件数降序）
    let rank: Int
    let rankTotal: Int

    var id: String { name }
}

// MARK: - 筛选下拉

/// 一个筛选入口。外观和 `FilterChip` 同一套：没生效是中性灰，生效了是强调色实心。
///
/// 用 `Chip` 当 Menu 的 label，而不是把 `FilterChip` 塞进去 ——
/// Menu 的 label 里放 Button，点击会被内层按钮吃掉，菜单打不开。
private struct FilterMenu<Options: View>: View {
    let title: String
    let value: String?
    let tint: Color
    let options: Options

    init(title: String, value: String?, tint: Color, @ViewBuilder options: () -> Options) {
        self.title = title
        self.value = value
        self.tint = tint
        self.options = options()
    }

    private var active: Bool { value != nil }

    var body: some View {
        Menu {
            options
        } label: {
            HStack(spacing: Space.xxs) {
                Chip(value.map { "\(title) · \($0)" } ?? title,
                     active ? tint : Palette.neutral,
                     filled: active)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(active ? "按\(title)筛选：\(value ?? "")（点开可改）" : "按\(title)筛选")
    }
}

// MARK: - 空状态里的最近改动行

private struct RecentRow: View {
    let file: VaultFile
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            TypeBadge(kind: inferKind(file), size: 20)
            Text(file.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.xs)
            Text(file.rel)
                .pathText()
                .lineLimit(1)
                .truncationMode(.head)
            Text(file.ageText)
                .monospacedDigit()
                .faintText()
                .frame(width: Space.xxl + Space.md, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("点一下，用这个文件名去搜")
    }
}

// MARK: - 命中高亮

/// 命中词加粗 + 强调色。颜色走 `Palette`，不写死 —— 深浅色都能看。
private func highlighted(_ text: String, _ kw: String) -> Text {
    let k = kw.trimmingCharacters(in: .whitespaces)
    guard !k.isEmpty, text.range(of: k, options: .caseInsensitive) != nil else { return Text(text) }
    var out = Text("")
    var rest = Substring(text)
    while let r = rest.range(of: k, options: .caseInsensitive) {
        out = out + Text(String(rest[rest.startIndex..<r.lowerBound]))
        out = out + Text(String(rest[r])).bold().foregroundStyle(Palette.accent)
        rest = rest[r.upperBound...]
    }
    out = out + Text(String(rest))
    return out
}

// MARK: - 结果：列表行

private struct HitRow: View {
    let hit: VaultQuery.SearchHit
    let keyword: String
    var selected: Bool = false
    var onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            TypeBadge(kind: inferKind(hit.file), size: 22)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    highlighted(hit.file.name, keyword)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    if hit.hitCount > 1 {
                        // 说清楚"数的是什么"：hitCount 只数**正文**里的出现次数，
                        // 不含文件名和路径。含糊的"N 处"会被读成"到处都提到了"。
                        Text("正文 \(hit.hitCount) 处").monospacedDigit().faintText()
                    }
                    Chip(hit.matchedIn, matchedColor(hit.matchedIn))
                }

                highlighted(hit.snippet, keyword)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.xs) {
                    Text(hit.file.rel)
                        .pathText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    Text(hit.file.sizeText).monospacedDigit().faintText()
                    Text(hit.file.ageText).monospacedDigit().faintText()
                }
            }
        }
        .padding(.horizontal, Space.content)
        .padding(.vertical, Space.xs)
        .background(selected ? Palette.soft(Palette.accent) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("点一下：右栏看它的正文")
    }
}

// MARK: - 结果：卡片

private struct HitCard: View {
    let hit: VaultQuery.SearchHit
    let keyword: String
    var selected: Bool = false
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                TypeBadge(kind: inferKind(hit.file), size: 22)
                Spacer(minLength: Space.xs)
                // 和 HitRow 保持同一套信息量：同一个结果不该有两种说法
                if hit.hitCount > 1 {
                    Text("正文 \(hit.hitCount) 处").monospacedDigit().faintText()
                }
                Chip(hit.matchedIn, matchedColor(hit.matchedIn))
            }

            highlighted(hit.file.name, keyword)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            highlighted(hit.snippet, keyword)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: Space.xs) {
                Text(hit.file.sizeText).monospacedDigit().faintText()
                Spacer(minLength: 0)
                Text(hit.file.ageText).monospacedDigit().faintText()
            }
        }
        .padding(Space.sm)
        .frame(height: HitCardMetrics.height, alignment: .top)
        .cardSurface(selected: selected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("点一下：右栏看它的正文")
    }
}

/// 卡片高度与最小列宽。行数由字数决定，所以只能是数字 ——
/// 但仍然用 4pt 栅格拼出来，不引入新的散值。
private enum HitCardMetrics {
    static let height: CGFloat = Space.xxl * 3 + Space.xs   // 152
    static let minWidth: CGFloat = Space.xxl * 5            // 240
}

/// 页面的结构尺寸（pt）。结构尺寸不是设计变量，
/// 但集中在这里，body 里就不出现散值。
private enum SearchLayout {
    /// 右栏宽度区间：够放一句正文，又不至于把结果挤没。
    static let sideMin: CGFloat = 440
    static let sideIdeal: CGFloat = 480
    static let sideMax: CGFloat = 520
    /// 右栏里「我的判断」的最小高度：矮窗口下它仍然像一个"窗口"，而不是被压扁。
    static let unitMin: CGFloat = 440
    /// 身份条上的类型徽章。
    static let detailBadge: CGFloat = 26

    /// 一次检索最多取回多少条。**这是上限，不是事实。**
    /// 实测「记忆」真实命中 432、「邱懿武」522 —— 打满时必须把截断说出来。
    /// 放在这里而不是 `SearchView` 里：View 是 main actor 隔离的，
    /// 而它要被 `Task.detached` 里的检索调用。
    static let searchLimit = 300
    /// 「签过的」一次画多少条。超出部分如实说明。
    static let historyRows = 5
}

/// 索引用的是粗粒度 kind（doc/code/image…），这里映射到 InfoKind 好复用配色与形状
private func inferKind(_ f: VaultFile) -> InfoKind {
    FileTriage.infoKind(name: f.name, ext: f.ext, rel: f.rel, kind: f.kind)
}

/// 命中位置 → 颜色。只用调色板里的语义色：文件名（最相关）走强调色，
/// 正文走成功色，路径和其余走中性灰 —— 不拿警告色去标一个不是警告的东西。
private func matchedColor(_ m: String) -> Color {
    switch m {
    case "文件名": return Palette.accent
    case "正文":   return Palette.success
    default:      return Palette.neutral
    }
}
