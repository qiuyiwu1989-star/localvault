import SwiftUI
import AppKit

// MARK: - 窗口结构尺寸
//
// `Theme.swift` 管的是「界面长什么样」（颜色 / 间距 / 圆角 / 字号）。
// 窗口和侧边栏的**结构尺寸**是另一类变量，Theme 里没有对应的 token，
// 所以集中收在这里 —— body 里不出现裸数字。
// 如果 Lead 决定给 Theme 加一套 Layout token，改这一处就够。

enum Shell {
    static let sidebarMin: CGFloat = 190
    static let sidebarIdeal: CGFloat = 210
    static let sidebarMax: CGFloat = 260

    static let windowWidth: CGFloat = 1320
    static let windowHeight: CGFloat = 860
    static let windowMinWidth: CGFloat = 1080
    static let windowMinHeight: CGFloat = 700

    /// 窄栏文字的最大阅读宽度 —— 长句子超过这个宽度就该折行
    static let readingWidth: CGFloat = 460
}

@main
struct LocalVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("本地上下文") {
            ContentView()
                .frame(minWidth: Shell.windowMinWidth, minHeight: Shell.windowMinHeight)
        }
        .defaultSize(width: Shell.windowWidth, height: Shell.windowHeight)
        // 统一工具栏：让工具栏和内容区共用一条材质，而不是两根横条叠着
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无头自检：不进界面，直接验证能不能读到索引、不变量是否成立
        if CommandLine.arguments.contains("--selftest") {
            exit(VaultStore.selfTest())
        }
        // --signer <名字>：设置签字人。signed_by 不可为空，所以这个必须有办法设。
        if let i = CommandLine.arguments.firstIndex(of: "--signer") {
            let args = CommandLine.arguments
            guard i + 1 < args.count else {
                FileHandle.standardError.write("用法：LocalVault --signer <名字>\n".data(using: .utf8)!)
                exit(2)
            }
            let store = ClaimStore()
            store.setSigner(args[i + 1])
            if let e = store.error {
                FileHandle.standardError.write("\(e)\n".data(using: .utf8)!)
                exit(1)
            }
            print("签字人已设为：\(store.signer)")
            exit(0)
        }
        // SwiftPM 可执行文件默认是后台进程；作为 .app 启动时要显式变成前台应用
        // --appearance light|dark：**只强制这个进程**的外观，用来在深/浅两态下截图验收。
        //
        // 为什么需要这个开关：macOS 26 的外观只认系统设置，
        // 命令行 `-AppleInterfaceStyle Light` 和 per-app 偏好域（defaults write）
        // 都**不生效**（实测过），而"为了截图去改用户的系统外观"是不可接受的。
        // 有了它，深色和浅色都能在不动用户任何设置的前提下验证。
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"),
           i + 1 < CommandLine.arguments.count {
            let want = CommandLine.arguments[i + 1]
            NSApp.appearance = NSAppearance(named: want == "light" ? .aqua : .darkAqua)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @StateObject private var vault = VaultStore()
    @StateObject private var claims = ClaimStore()

    @State private var tab: Tab = ContentView.initialTab ?? .extract

    /// 直接读 `CommandLine`。
    /// 之前走 delegate 里的全局变量，结果 @State 初值比 delegate 先求值 —— 参数不生效。
    /// 时序依赖是这种 bug 的温床，索性不留。
    /// `--query <词>` —— 直接带着检索词进检索库。
    /// 既是截图/自动化测试的手段，也是真需要的能力：
    /// 以后 skill 或浏览器可以一条命令把某个词丢进来。
    static var initialQuery: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--query"), i + 1 < args.count else { return "" }
        return args[i + 1]
    }

    static var initialTab: Tab? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return nil }
        return Tab(rawValue: args[i + 1]) ?? .extract
    }

    /// `--pick <名字片段>` —— 启动时选中第一个名字含该片段的文件。
    /// 和 `--query` 同一个用途：**让「必须先选中才看得到」的界面能被验收**。
    /// 详情条的正文预览就属于这类 —— 没有这个开关，它只能靠手点截图，不可回归。
    static var initialPick: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pick"), i + 1 < args.count else { return "" }
        return args[i + 1]
    }

    /// `--raw` —— 正文默认以「原文」而不是渲染态打开。
    /// 同上：渲染/原文两种呈现都要能被截图验收，不能只验一种。
    static var initialRaw: Bool { CommandLine.arguments.contains("--raw") }

    /// 三个板块，对应你描述的三件事。
    /// `rawValue` 是中文且**不许改** —— `--tab` 按它匹配。
    enum Tab: String, CaseIterable, Identifiable {
        case extract = "提炼"
        case drive   = "云盘"
        case search  = "检索库"
        var id: String { rawValue }

        var title: String { rawValue }

        var icon: String {
            switch self {
            case .extract: return "sparkle.magnifyingglass"
            case .drive:   return "folder.badge.plus"
            case .search:  return "magnifyingglass.circle"
            }
        }

        var hint: String {
            switch self {
            case .extract: return "主动：机器人自己扫描、判断、提炼"
            case .drive:   return "被动：你拖进去的东西"
            case .search:  return "检索：在这个索引里找东西 + 下判断"
            }
        }
    }

    var body: some View {
        Group {
            if let err = vault.loadError {
                MissingVaultView(message: err)
            } else {
                shell
            }
        }
    }

    // MARK: 窗口结构
    //
    // 侧边栏 + 详情，用系统自己的 `NavigationSplitView`：
    // 半透明材质、选中态胶囊、工具栏折叠、窗口缩放全部由系统给，
    // 不需要我们拿一个居中的 segmented 控件去假装导航。

    private var shell: some View {
        NavigationSplitView {
            Sidebar(tab: $tab, vault: vault)
                .navigationSplitViewColumnWidth(min: Shell.sidebarMin,
                                                ideal: Shell.sidebarIdeal,
                                                max: Shell.sidebarMax)
        } detail: {
            detail
                .navigationTitle(tab.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            vault.loadOverview()
                        } label: {
                            Label("重读索引", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("只重新读一遍索引库；不会扫描磁盘，也不会改动任何文件")
                    }
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .extract: ExtractView(vault: vault, claims: claims)
        case .drive:   DriveView(vault: vault)
        case .search:  SearchView(vault: vault, claims: claims, initialQuery: ContentView.initialQuery)
        }
    }
}

// MARK: - 侧边栏

struct Sidebar: View {
    @Binding var tab: ContentView.Tab
    @ObservedObject var vault: VaultStore

    var body: some View {
        List(selection: $tab) {
            Section {
                ForEach(ContentView.Tab.allCases) { t in
                    Label(t.title, systemImage: t.icon)
                        .tag(t)
                        .help(t.hint)
                }
            } header: {
                Text("板块").faintText()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatus(vault: vault)
        }
    }
}

// MARK: - 侧边栏底部：机器索引概况
//
// 这一块回答「我到底索引了多大一片地方」。
// 刻意只放事实（文件数 / 体量 / 索引根数 / 上次扫描），不放建议 ——
// 「下一步该干什么」属于各页自己的抬头。

struct SidebarStatus: View {
    @ObservedObject var vault: VaultStore

    private var filesLine: String {
        "\(vault.totalFiles.formatted()) 个文件 · \(sizeText(vault.totalBytes))"
    }

    private var rootsLine: String {
        "\(vault.roots.count.formatted()) 个索引根"
    }

    /// 索引里存的是毫秒时间戳；年份不合常理时宁可不显示，也不显示一个假日期。
    private var lastScanText: String? {
        let runs = vault.lastScan.filter { $0.finishedAt > 0 }
        guard let newest = runs.max(by: { $0.finishedAt < $1.finishedAt }) else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(newest.finishedAt) / 1000)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        guard (2000...2100).contains(year) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Divider()
            line("internaldrive", filesLine)
            line("square.stack.3d.up", rootsLine)
            // 日期单独一行。挤在「索引根」后面时侧栏只放得下「上次扫描 2026-10-…」，
            // 一个被截断的日期等于没给 —— 所以把标签和值一起挪到自己这一行
            if let d = lastScanText {
                line("clock", "上次扫描 \(d)")
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .help("索引以只读方式打开：这个应用不会改动任何文件")
    }

    /// 一行图标 + 一条事实。侧边栏窄，所以文字一律单行截断。
    private func line(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: Space.md)
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - 索引缺失
//
// 索引还没建的时候，说清楚该做什么 —— 而不是给一个空白窗口。
// 结构按契约：图标（淡）→ 标题 → 一句说明 → 动作。

struct MissingVaultView: View {
    let message: String

    /// 与 `VaultStore` 的默认库路径保持一致（应用只读，不去建它）
    private var indexDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".localvault").path
    }

    private var indexDirExists: Bool {
        FileManager.default.fileExists(atPath: indexDir)
    }

    private var command: String { "npx localvault init && npx localvault index" }

    var body: some View {
        EmptyState(icon: "externaldrive.badge.questionmark",
                   title: "还没有可读的索引",
                   message: message) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("下一步：在终端里建一次索引")
                    .captionText()

                HStack(spacing: Space.xs) {
                    Text(command)
                        .pathText()
                        .lineLimit(1)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, Space.xxs)
                        .cardSurface(radius: Radius.sm)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(command, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .help("复制这条命令")
                }

                Text("建完后重启这个应用即可读到。`npx localvault doctor` 可以先自检一遍。")
                    .faintText()

                HStack(spacing: Space.sm) {
                    if indexDirExists {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: indexDir)])
                        } label: {
                            Label("在 Finder 里看索引", systemImage: "folder")
                        }
                    }
                    Text("这个应用只读，不会改动任何文件。")
                        .faintText()
                }
            }
            .frame(maxWidth: Shell.readingWidth, alignment: .leading)
        }
    }
}
