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
    /// 两个库句柄装在一个可整体替换的盒子里。
    ///
    /// 为什么要换：首次运行向导建好索引之后，那个**以失败打开的**只读句柄必须换掉
    /// ——它当初 `open()` 就失败了（`db` 还是 nil），`loadOverview()` 救不回来
    /// （它开头就 `guard db != nil`）。用 `@StateObject` 装一个盒子，
    /// 比给 `@StateObject` 自己重新赋值可靠。
    @StateObject private var session = AppSession()

    @State private var tab: Tab = ContentView.initialTab ?? .extract

    private var vault: VaultStore { session.vault }
    private var claims: ClaimStore { session.claims }

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

    /// `--onboard auto|enter` —— 让**首次运行向导**本身能被验收。
    /// 理由和上面三个开关完全一样：不能靠手点截图来回归。
    ///
    /// 注意：**不动 AppDelegate 里那几个开关的解析**，这个开关只在这里读，
    /// 和 `--tab` / `--query` / `--pick` / `--raw` 是一个模式。
    static var onboardingAutomation: OnboardingAutomation? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--onboard"), i + 1 < args.count else { return nil }
        return OnboardingAutomation(rawValue: args[i + 1])
    }

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
                if needsOnboarding {
                    // 库里**还没有**东西 → 首次运行向导（主路径）
                    OnboardingView(automation: ContentView.onboardingAutomation) { session.reopen() }
                } else {
                    // 库在但打不开 → 真错误态，别拿向导糊上去
                    MissingVaultView(message: err)
                }
            } else {
                shell
            }
        }
    }

    /// 索引库**文件都不存在** → 首次运行。
    /// 库在、只是打不开（损坏 / 权限 / 被锁）→ 那不是「首次运行」，
    /// 弹向导等于劝人重建，可能把已有数据盖掉。
    private var needsOnboarding: Bool {
        !FileManager.default.fileExists(atPath: VaultConfig.defaultDBPath)
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

// MARK: - 会话（两个库句柄）

/// 索引句柄 + 判断条陈的句柄。向导建完索引后**整体换新**。
final class AppSession: ObservableObject {
    @Published var vault: VaultStore
    @Published var claims: ClaimStore

    init() {
        vault = VaultStore()
        claims = ClaimStore()
    }

    /// 索引刚建好：重新打开。
    ///
    /// `vault` 必须**新建**：句柄当初 `open()` 就失败了，`db` 是 nil，
    /// 而 `loadOverview()` 开头就是 `guard db != nil` —— 调它等于什么都没做。
    /// `claims` 也重建：在全新的机器上，`~/.localvault/` 可能在向导跑完之前
    /// 还不存在，它那时候的开库动作是失败的。
    func reopen() {
        claims = ClaimStore()
        vault = VaultStore()
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

// MARK: - 索引存在但打不开（真错误态）
//
// 注意：**索引库不存在**时不再走这里 —— 那是「首次运行」，走 `OnboardingView` 向导。
// 这里只处理「库在，但打不开」：文件损坏、权限不对、被别的进程锁着。
// 这种时候**不该**劝用户「重建一次索引」（那可能把已有数据盖掉），
// 所以只给真实错误 + 命令行那条路，用来排查或自己决定怎么办。
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

    /// 命令行那条路的实况（探测在 `OnboardingView.swift` 的 `CLIProbe`）
    private var plan: IndexCommandPlan { CLIProbe.plan }

    var body: some View {
        EmptyState(icon: "exclamationmark.triangle",
                   title: "索引打不开",
                   message: message) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("库文件在，但没打开。**这不是**「还没建索引」—— 那种情况会直接给你首次运行向导。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)

                if let command = plan.command {
                    Text("想自己排查或重建的话，命令行这条路在这台机器上是：")
                        .captionText()
                    if let pre = plan.prerequisite {
                        Text(.init(pre))
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CLICommandRow(command: command)
                    Text(.init(plan.note))
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                    Text("提醒：这条命令会碰到**现有的库**。不想让它改，先把 `~/.localvault/vault.db` 复制一份出来。")
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(.init(plan.note))
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                }

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
