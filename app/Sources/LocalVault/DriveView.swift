import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// ② 云盘 —— **被动行为**，按 DAM（数字资产）的方式管理。
///
/// 三栏：文件夹栏 / 资产区（网格 · 列表一键切） / 详情栏（大图 + 元数据）。
/// 三种放法照旧：拖到 Finder 里的云盘文件夹 / 拖进这个页面松手 / 点「选文件…」。
///
/// **当前状态说实话**：云端同步还没做 —— 左下角一行标出来。
struct DriveView: View {
    @ObservedObject var vault: VaultStore

    @State private var folders: [DriveFolder] = []
    @State private var picked: String?          // 选中的子文件夹名
    @State private var items: [DriveItem] = []
    @State private var filter: DriveFilter = .all
    @State private var sort: DriveSort = .date
    @State private var ascending = false        // 默认：最近改动的排前面
    @State private var mode: ViewMode = .waterfall
    @State private var selectedId: String?
    @State private var keyword = ""
    @State private var dropTargeted = false
    @State private var lastDrop = ""
    @State private var newFolderName = ""

    /// 放进去的目标。没选中任何文件夹时兜底说「根目录」（`DriveStore` 会落到第一个默认文件夹）
    private var targetName: String { picked ?? "根目录" }

    private var currentFolder: DriveFolder? { folders.first { $0.name == picked } }

    private var isFiltered: Bool { filter != .all || !keyword.isEmpty }

    /// 先筛选、再排序。顺序不许反 —— 排序只在这"看得见的一批"里做
    private var visible: [DriveItem] {
        let base = items.filter { it in
            guard !it.isDir else { return false }
            guard filter.matches(it.ext) else { return false }
            guard !keyword.isEmpty else { return true }
            return it.name.localizedCaseInsensitiveContains(keyword)
                || it.rel.localizedCaseInsensitiveContains(keyword)
        }
        return base.sorted(by: sort.lt(ascending))
    }

    /// 只统计**看得见的这一批** —— 全库归一的话，一个 14GB 的视频会把 2KB 的文档压成一根线
    private var visibleBytes: Int64 { visible.reduce(0) { $0 + $1.size } }

    private var selectedItem: DriveItem? { visible.first { $0.id == selectedId } }

    private var trimmedFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // 三栏：文件夹 / 资产 / 详情。HSplitView 而不是 NavigationSplitView ——
        // 窗口级导航侧栏只有一条（在外壳里），这里三栏都是 detail 内部的
        HSplitView {
            sidebar
            assetColumn
            DriveInspector(item: selectedItem,
                           folder: currentFolder,
                           visible: visible,
                           isFiltered: isFiltered,
                           onClear: { selectedId = nil })
                .frame(minWidth: DriveLayout.inspectorMin,
                       idealWidth: DriveLayout.inspectorIdeal,
                       maxWidth: DriveLayout.inspectorMax)
        }
        .onAppear { reload() }
        // 整页接收拖拽（和上一版一样）。**只留这一个 onDrop**：
        // 内外两层都注册的话，一次松手可能落进两次，文件会被复制成两份。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: 左：文件夹栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $picked) {
                Section("云盘文件夹") {
                    ForEach(folders) { f in
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(f.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text("\(f.count) 个 · \(f.sizeText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: "folder.fill")
                        }
                        .tag(f.name)
                    }
                }
            }
            // **不是** `.listStyle(.sidebar)`：窗口级导航侧栏只有一条（在外壳里）。
            // 这一栏是 detail 里的文件夹选择列表，用 `.sidebar` 会让两条侧栏并排
            // 出现两种材质色（实测 29,31,61 vs 39,43,83）。
            .listStyle(.inset)
            .onChange(of: picked) { _, new in
                if let new {
                    items = DriveStore.list(sub: new)
                    // 换了文件夹，旧选中项不属于这里了
                    selectedId = nil
                } else {
                    // 在侧栏空处点一下会取消选中 —— 回到第一个文件夹，别停在"没有目标"的状态
                    picked = folders.first?.name
                }
            }

            Divider()

            sidebarFooter
        }
        // 明确的窗口底色：这一栏和右边的内容区是同一层，只由一条分隔线切开
        .background(.background)
        .frame(minWidth: DriveLayout.folderMin,
               idealWidth: DriveLayout.folderIdeal,
               maxWidth: DriveLayout.folderMax)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                TextField("新建文件夹", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption)
                    .onSubmit { createFolder() }
                Button { createFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(trimmedFolderName.isEmpty)
                    .help("新建文件夹")
            }

            Button {
                NSWorkspace.shared.open(DriveStore.rootURL)
            } label: {
                Label("在 Finder 里打开", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("存哪：\(DriveStore.rootURL.path)")

            Divider()

            DriveSyncNotice()
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 中：资产区

    private var assetColumn: some View {
        VStack(spacing: 0) {
            // 拖拽区收成一条：这一页的主角现在是资产本身，不是"空盒子"
            DriveDropStrip(target: targetName, targeted: dropTargeted) { pickFiles() }
                .padding(Space.md)

            if !lastDrop.isEmpty { lastDropLine }

            Divider()

            toolbarBar

            Divider()

            assetBody
        }
        .frame(minWidth: DriveLayout.assetMin)
    }

    @ViewBuilder
    private var assetBody: some View {
        if visible.isEmpty {
            EmptyState(icon: keyword.isEmpty && filter == .all ? "folder" : "magnifyingglass",
                       title: emptyTitle,
                       message: emptyMessage)
        } else if mode == .waterfall {
            DriveGrid(items: visible, selectedId: $selectedId)
        } else {
            List(selection: $selectedId) {
                ForEach(visible) { it in
                    DriveRow(item: it)
                        .tag(it.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyTitle: String {
        if !keyword.isEmpty { return "没有匹配的文件" }
        if filter != .all { return "没有这个类型的文件" }
        return "这个文件夹还是空的"
    }

    private var emptyMessage: String {
        if isFiltered { return "换个关键词，或把筛选取回「全部」。" }
        return "拖到上面的区域，或点「选文件…」，文件就会出现在这里。"
    }

    /// 上一回落盘的结果。不用勾，靠颜色和文字说
    private var lastDropLine: some View {
        HStack(spacing: Space.xs) {
            Text(lastDrop)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.success)
            Spacer(minLength: Space.xs)
            Button { withAnimation(Motion.quick) { lastDrop = "" } } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("收起")
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.sm)
        .transition(.opacity)
    }

    // MARK: 工具条
    //
    // 两行。资产区最窄只有 ~400pt，挤成一行的话 Chip 和计数必然被压掉。

    private var toolbarBar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("在「\(targetName)」里搜文件名或路径", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .cardSurface(radius: Radius.sm)

            HStack(spacing: Space.xs) {
                filterMenu
                sortMenu
                orderButton

                Spacer(minLength: Space.xs)

                // 侧栏那个"3 个"是**整个文件夹**，这里是**筛选后这一批** ——
                // 同一屏上出现两个数，就得把口径写在数旁边（契约 8.2.2）
                Text(isFiltered
                     ? "筛选中 · \(visible.count) 个 · \(sizeText(visibleBytes))"
                     : "\(visible.count) 个 · \(sizeText(visibleBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ViewModePicker(mode: $mode)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
    }

    /// 文件类型是**筛选**，不是视图切换 —— 所以是下拉，不是 8 段 segmented
    private var filterMenu: some View {
        Menu {
            ForEach(DriveFilter.allCases) { f in
                Button(f.rawValue) { filter = f }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Chip(filter.rawValue,
                     filter == .all ? Palette.neutral : Palette.accent,
                     filled: filter != .all)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按文件类型筛选")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(DriveSort.allCases) { s in
                Button(s.rawValue) { sort = s }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Chip(sort.rawValue, Palette.neutral)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按什么排序")
    }

    private var orderButton: some View {
        Button { ascending.toggle() } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(ascending ? "升序（点一下反过来）" : "降序（点一下反过来）")
    }

    // MARK: 动作

    private func reload() {
        DriveStore.ensureStructure()
        folders = DriveStore.folders()
        if picked == nil { picked = folders.first?.name }
        items = DriveStore.list(sub: picked)
    }

    private func createFolder() {
        let n = trimmedFolderName
        guard !n.isEmpty else { return }
        DriveStore.createFolder(n)
        newFolderName = ""
        reload()
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选中的文件会复制一份放进「\(picked ?? "根目录")」"
        guard panel.runModal() == .OK else { return }
        ingest(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        // 拖拽回调在主线程；这里等一小会儿收集 URL，再把复制放到后台
        _ = group.wait(timeout: .now() + 3)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { ingest(urls) }
        return true
    }

    private func ingest(_ urls: [URL]) {
        let sub = picked
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DriveStore.ingest(urls, into: sub)
            DispatchQueue.main.async {
                reload()
                withAnimation(Motion.base) { lastDrop = r.message }
            }
        }
    }
}

// MARK: - 拖拽条
//
// 原来是一个大空盒子。资产区要留给网格，所以它收成一条：
// 图标 → 一句标题 → 一行说明 → 动作，边界和悬停反馈照旧。

private struct DriveDropStrip: View {
    let target: String
    let targeted: Bool
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title3.weight(.light))
                .foregroundStyle(targeted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                .scaleEffect(targeted ? 1.08 : 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(targeted ? "松手即放入「\(target)」" : "把文件拖到这里")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(targeted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.primary))
                Text("会复制一份放进「\(target)」，原文件不动。")
                    .faintText()
            }

            Spacer(minLength: Space.xs)

            Button { onPick() } label: { Text("选文件…") }
                .controlSize(.small)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(targeted ? AnyShapeStyle(Palette.accent.opacity(0.06))
                             : AnyShapeStyle(.background.secondary))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            // 实线。虚线是"待填表单"的语汇，macOS 的拖放区靠**材质 + 描边加重**说话
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(targeted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.separator),
                              lineWidth: targeted ? 2 : 1)
        }
        .animation(Motion.base, value: targeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("放入文件：把文件拖到这里，或用选文件按钮")
    }
}

// MARK: - 云端同步的诚实声明
//
// 这条必须留着。但它不该占据视线：常驻的只有一行字，
// 「存哪 / 脱敏边界」两件事点开才看。

private struct DriveSyncNotice: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button {
                withAnimation(Motion.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("云端同步：尚未接入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点开看两件还没定的事")

            if expanded {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("放进来只留在本机，不会上传到任何地方。接之前要先定两件事：")
                        .captionText()
                    Text("① 存哪 —— 用你已有的 COS，不新造一套。")
                        .faintText()
                    Text("② 脱敏边界 —— 哪些内容允许出本机，得由你先定规则；本机 config 里那份「不读的名单」就是第一步。")
                        .faintText()
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 列表一行

struct DriveRow: View {
    let item: DriveItem

    var body: some View {
        HStack(spacing: Space.xs) {
            TypeBadge(kind: item.infoKind, size: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.folderPath)
                    .faintText()
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Space.xs)

            // 类型名不在这里写 —— 契约：类型靠 TypeBadge 的形状和颜色辨，
            // 名字在详情栏里出现（`kindLabel` 的注释就是这么写的）
            Text(item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: DriveCol.size, alignment: .trailing)
            Text(item.dateText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: DriveCol.date, alignment: .trailing)
        }
        .padding(.vertical, Space.xxs)
        .contentShape(Rectangle())
        .help(item.name)
    }
}

/// 表格列的宽度。列要对齐，所以集中定义 —— 不许散落在每一行里
enum DriveCol {
    static let size: CGFloat = 68
    static let date: CGFloat = 76
    /// 类型分布那一行右侧的体量列
    static let distSize: CGFloat = 60
}

/// 结构尺寸：三栏的宽窄 + 网格格子 + 详情栏的预览。和 `DriveCol` 同类 ——
/// **这个文件里所有结构常量只该改这一处**（视觉变量一律走 `Theme`）
enum DriveLayout {
    static let folderMin: CGFloat = 190
    static let folderIdeal: CGFloat = 210
    static let folderMax: CGFloat = 250

    static let assetMin: CGFloat = 400

    static let inspectorMin: CGFloat = 240
    static let inspectorIdeal: CGFloat = 280
    static let inspectorMax: CGFloat = 360

    /// 网格格子：最小列宽 + 缩略图方块
    static let cellMin: CGFloat = 148
    static let thumbW: CGFloat = 132
    static let thumbH: CGFloat = 132

    /// 详情栏大图的最大高度；非图片文件的图标预览尺寸
    static let previewMaxHeight: CGFloat = 320
    static let iconPreview: CGFloat = 96

    /// 正文预览的两个上限。都是**本文件的策略**，不是索引的口径 ——
    /// 撞上限时详情栏必须说出来（契约 8.4）
    static let textReadMaxBytes: Int64 = 2 * 1024 * 1024
    static let textRenderMaxChars = 60_000
}

// MARK: - 筛选与排序

enum DriveFilter: String, CaseIterable, Identifiable {
    case all     = "全部"
    case doc     = "文档"
    case sheet   = "表格"
    case image   = "图片"
    case video   = "视频"
    case audio   = "音频"
    case archive = "压缩包"
    case code    = "代码"
    var id: String { rawValue }

    func matches(_ ext: String) -> Bool {
        let e = ext.lowercased()
        switch self {
        case .all:     return true
        case .doc:     return [".md", ".markdown", ".txt", ".rtf", ".doc", ".docx",
                               ".pdf", ".pages", ".ppt", ".pptx", ".key", ".epub"].contains(e)
        case .sheet:   return [".xlsx", ".xls", ".csv", ".tsv", ".numbers"].contains(e)
        case .image:   return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic",
                               ".heif", ".tiff", ".bmp", ".svg"].contains(e)
        case .video:   return [".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v", ".flv"].contains(e)
        case .audio:   return [".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"].contains(e)
        case .archive: return [".zip", ".tar", ".gz", ".tgz", ".7z", ".rar", ".xz"].contains(e)
        case .code:    return [".swift", ".js", ".ts", ".py", ".rb", ".go", ".rs", ".kt",
                               ".java", ".c", ".h", ".cpp", ".sh", ".html", ".css",
                               ".json", ".yaml", ".yml", ".toml", ".sql"].contains(e)
        }
    }
}

enum DriveSort: String, CaseIterable, Identifiable {
    case name = "名称"
    case size = "大小"
    case date = "修改时间"
    var id: String { rawValue }

    /// 排序谓词。升降序都在这里，视图里不写三份 switch。
    /// 相等时必须两个方向都返回 false —— 否则不是严格弱序，`sort` 的结果不可预期
    func lt(_ ascending: Bool) -> (DriveItem, DriveItem) -> Bool {
        { a, b in
            switch self {
            case .name:
                let c = a.name.localizedStandardCompare(b.name)
                return ascending ? c == .orderedAscending : c == .orderedDescending
            case .size:
                return ascending ? a.size < b.size : a.size > b.size
            case .date:
                return ascending ? a.mtime < b.mtime : a.mtime > b.mtime
            }
        }
    }
}

// MARK: - 数据结构

struct DriveFolder: Identifiable {
    let name: String
    let count: Int
    let size: Int64
    var id: String { name }

    var sizeText: String { LocalVault.sizeText(size) }
}

struct DriveItem: Identifiable {
    let id: String
    let name: String
    let rel: String
    let sub: String          // 所属子文件夹（顶层文件夹名）
    let ext: String
    let size: Int64
    let mtime: Date
    let isDir: Bool

    var sizeText: String { LocalVault.sizeText(size) }

    /// `id` 就是绝对路径（`DriveStore.list` 里给的），所以不用再拼
    var url: URL { URL(fileURLWithPath: id) }

    var folderPath: String {
        let parts = rel.split(separator: "/").dropLast()
        return parts.isEmpty ? sub : parts.joined(separator: "/")
    }

    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: mtime)
    }

    var dateTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: mtime)
    }

    /// 徽章要的形状和颜色。云盘不预先判断"值不值得了解"，
    /// 只回答"这是什么类型" —— 所以用同一套类型识别，不另起一套规则
    var infoKind: InfoKind {
        isDir ? .unknown
              : FileTriage.infoKind(name: name, ext: ext, rel: rel, kind: "")
    }

    /// 这两个判断**交给系统的类型数据库**（`UTType`），不再手写第三份扩展名表。
    /// 实测：png/jpg/heic → image；md/markdown → markdown，txt → plainText；
    /// swift/json 虽然是文本但不是这两者，所以不会被当成正文渲染。
    private var utType: UTType? { UTType(filenameExtension: ext) }

    /// Markdown 的类型。这个 SDK 里**没有** `UTType.markdown` 这个静态成员（编译不过），
    /// 所以按标识符取一次 —— 仍然不是扩展名表
    private static let markdownType = UTType("net.daringfireball.markdown")

    var isImage: Bool {
        !isDir && (utType?.conforms(to: .image) ?? false)
    }

    /// 只有 Markdown / txt 走 `MarkdownText` 渲染
    var rendersMarkdown: Bool {
        guard !isDir, let t = utType else { return false }
        if let md = DriveItem.markdownType, t.conforms(to: md) { return true }
        return t == .plainText
    }
}

// MARK: - 文件夹读写

/// 云盘文件夹的结构与读写。
///
/// 位置选在 `~/Documents/本地上下文云盘` —— 和你的文档在一起，天天看得见，
/// 而不是藏在应用数据目录里（那种地方你会忘）。
enum DriveStore {

    /// 默认子文件夹。**不同用途分开**，因为"你要 agent 读什么"本身就分不同性质。
    static let defaultFolders = ["我的文档", "项目资料", "参考素材"]

    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/本地上下文云盘")
    }

    static func ensureStructure(root: URL = rootURL) {
        let rootURL = root
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) {
            try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let readme = """
            # 本地上下文云盘

            把你想让 agent 了解的文件放进对应的文件夹。三种放法都行：

            1. 在 Finder 里拖进来
            2. **直接拖进 App 窗口**（会复制到当前选中的文件夹）
            3. 在 App 里点「选文件…」

            ## 三个默认文件夹

            - **我的文档** —— 关于你个人的：笔记、方案、简历、汇报
            - **项目资料** —— 跟具体项目有关的
            - **参考素材** —— 图片、音视频、参考资料（这类机器读不懂，但你可以归类）

            ## 现在还没有的功能

            **云端同步尚未接入。** 放进来只留在本机，不会上传到任何地方。
            接云端之前要先定两件事：存哪（建议用你已有的 COS），以及脱敏边界。

            生成时间：\(ISO8601DateFormatter().string(from: Date()))
            """
            try? readme.write(to: rootURL.appendingPathComponent("说明.md"),
                              atomically: true, encoding: .utf8)
        }
        for f in defaultFolders {
            let u = rootURL.appendingPathComponent(f)
            if !fm.fileExists(atPath: u.path) {
                try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            }
        }
    }

    static func createFolder(_ name: String, root: URL = rootURL) {
        // 文件名不能带路径分隔符，否则会跑到父目录去
        let clean = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, clean != ".", clean != ".." else { return }
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent(clean), withIntermediateDirectories: true)
    }

    /// 列出所有子文件夹及其统计
    static func folders() -> [DriveFolder] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        var out: [DriveFolder] = []
        for n in names.sorted() {
            var isDir: ObjCBool = false
            let p = rootURL.appendingPathComponent(n).path
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            let all = list(sub: n)
            out.append(DriveFolder(name: n,
                                   count: all.filter { !$0.isDir }.count,
                                   size: all.filter { !$0.isDir }.reduce(0) { $0 + $1.size }))
        }
        return out
    }

    /// 列某个子文件夹（或全部）下的文件
    static func list(sub: String?) -> [DriveItem] {
        let fm = FileManager.default
        let roots: [URL]
        if let sub, !sub.isEmpty {
            roots = [rootURL.appendingPathComponent(sub)]
        } else {
            roots = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
        }

        var out: [DriveItem] = []
        for r in roots {
            guard let en = fm.enumerator(
                at: r,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in en {
                guard out.count < 2000 else { break }
                let v = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let rel = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                out.append(DriveItem(
                    id: url.path,
                    name: url.lastPathComponent,
                    rel: rel,
                    sub: sub ?? rel.split(separator: "/").first.map(String.init) ?? "",
                    ext: url.pathExtension,
                    size: Int64(v?.fileSize ?? 0),
                    mtime: v?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                    isDir: v?.isDirectory ?? false
                ))
            }
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    /// 把文件**复制**进云盘。原文件不动 —— 这是只读承诺的一部分。
    @discardableResult
    static func ingest(_ urls: [URL], into sub: String?,
                       root: URL = rootURL) -> (ok: Int, failed: Int, message: String) {
        let fm = FileManager.default
        let destDir = root.appendingPathComponent(sub ?? defaultFolders[0])
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var ok = 0, failed = 0
        for u in urls {
            var dest = destDir.appendingPathComponent(u.lastPathComponent)
            // 重名不覆盖：加 -2、-3 …
            if fm.fileExists(atPath: dest.path) {
                let base = u.deletingPathExtension().lastPathComponent
                let ext = u.pathExtension
                var i = 2
                while fm.fileExists(atPath: dest.path), i < 999 {
                    let nm = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
                    dest = destDir.appendingPathComponent(nm)
                    i += 1
                }
            }
            do {
                try fm.copyItem(at: u, to: dest)
                ok += 1
            } catch {
                failed += 1
            }
        }
        let msg: String
        if ok > 0 && failed == 0 {
            msg = "已放入 \(ok) 个文件到「\(sub ?? defaultFolders[0])」"
        } else if ok > 0 {
            msg = "放入 \(ok) 个，\(failed) 个失败"
        } else {
            msg = "没能放入任何文件"
        }
        return (ok, failed, msg)
    }
}
