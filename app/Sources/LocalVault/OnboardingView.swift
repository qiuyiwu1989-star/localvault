import SwiftUI
import AppKit

// MARK: - 首次运行向导
//
// 为什么要有它：之前「还没有可读的索引」是一张**死路牌** —— 它给你一条命令，
// 让你去读 Markdown 装 Node。真实反馈是这么来的：有人把 dmg 拷到另一台 Mac 上，
// 那台机器上 `localvault` 命令、CLI 源码、node 三样都没有，
// 于是四种答案**全是死路**，他只能看到一句「去读文档的 1.2 节」。
//
// 现在主路径是**原生索引器**（`VaultIndexer`，不依赖 Node / CLI）：
//   选目录 → 真实计数进度（不是转圈）→ 完成进主界面。
// 「已经有 CLI / 想接 agent」那套探测（`IndexCommandPlan`）没删，
// 但降级成折叠的备用路径 —— 它不该是大多数人看到的第一屏。

struct OnboardingView: View {

    /// 验收开关（`--onboard auto|enter`）。默认 nil = 正常人看到的向导。
    ///
    /// 理由和 `--query` / `--pick` 一样：**不能靠手点截图来回归**。
    ///   `auto`  —— 跳过「开始建立索引」，直接开扫（用来看「建立中」「完成」两态）
    ///   `enter` —— 在 auto 的基础上，扫完自动进主界面（用来验「进得去」）
    var automation: OnboardingAutomation? = nil

    /// 从主界面那条「索引不完整」横幅点进来的：库本来就在、能读，只是上次没扫完。
    /// 因此有两处不一样：
    ///   ① 按钮写着「继续建完」，所以进来就**接着上次存的目录开扫**（不是新猜的范围）
    ///   ② 取消时**必须**留一条回主界面的路 —— 否则又是一个「回不去」的死路
    var resumingExistingLibrary: Bool = false

    /// 索引建好之后通知外面**重新打开索引**。
    /// 必须由外面换掉那个只读句柄：它当初是以「打不开」打开失败的，
    /// 光调 `loadOverview()` 修不好它（`db` 还是 nil）。
    let onIndexed: () -> Void

    // MARK: 步骤

    private enum Step {
        case pick
        case running
        case cancelled
        case done(VaultIndexer.Report)
        case failed(String)
    }

    /// 一个待索引目录。`id` 用路径 —— 同一个目录不该出现两次。
    private struct Choice: Identifiable {
        let path: String
        var label: String
        var selected: Bool
        var id: String { path }
    }

    @State private var step: Step = .pick
    @State private var choices: [Choice] = []
    @State private var progress: VaultIndexer.Progress?
    @State private var startedAt = Date()
    @State private var runTask: Task<Void, Never>?
    @State private var cancelling = false
    @State private var showFallback = false
    /// 目录清单没写进 config.json 时的原样错误 —— 索引照建，但这件事得说出来
    @State private var configWarning: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var picked: [Choice] { choices.filter(\.selected) }

    private var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private var plan: IndexCommandPlan { CLIProbe.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            // 中间可滚、**底部固定** —— 滚动的界面不许把开始按钮顶出屏幕
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Space.sm)
            }
            footer
        }
        .padding(Space.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadChoices()
            // 验收开关：跳过手点「开始建立索引」。延一个 runloop，
            // 让上面那句 `choices` 的写入先生效。
            if automation != nil {
                DispatchQueue.main.async { start() }
            } else if resumingExistingLibrary {
                // 横幅上写的是「继续建完」，点进来就接着上次的目录往下扫。
                // 扫的是哪些目录、扫到哪一条，都在「建立中」那一屏如实显示，随时可取消。
                DispatchQueue.main.async { if !picked.isEmpty { start() } }
            }
        }
        // 关窗 / 向导被替换时别让扫描线程继续跑
        .onDisappear { runTask?.cancel() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                Text("先建一次索引，就能用了").sectionTitle()
            }
            Text("索引 = 把你选定目录里的**文件名、路径、正文**写进一个本机数据库。之后检索、提炼、判断都从这个库读。扫描全程只读：不移动、不修改、不上传任何文件。")
                .faintText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 三个步骤的内容

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .pick:                     pickStep
        case .running:                  runningStep
        case .cancelled:                cancelledStep
        case .done(let report):         doneStep(report)
        case .failed(let message):      failedStep(message)
        }
    }

    // ① 选目录

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PanelBox("要索引哪些目录？",
                     subtitle: "默认列出的都勾好了。加进来的才会被扫 —— 这是唯一一个你说了算的开关。") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if choices.isEmpty {
                        Text("没探到可以直接用的目录（`~/Desktop`、`~/Downloads` 都不存在）。用下面的「添加目录…」自己挑。")
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 不给体积/文件数预览：算体积要真走一遍目录树，
                    // 在下载目录这种地方可能就是几十秒 —— 「宁可没有预览也不要转圈」。
                    // 以后要加，也必须放到后台线程算，不能挂在选目录这一步。
                    ForEach($choices) { $choice in
                        Toggle(isOn: $choice.selected) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label).font(.callout)
                                Text(choice.path)
                                    .pathText()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }

                    if picked.contains(where: { $0.path == homePath }) {
                        Text("你把**主目录**也勾上了：它会扫很久（整棵用户目录树，包括各种缓存和依赖目录）。")
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Space.sm) {
                        Button {
                            addDirectories()
                        } label: {
                            Label("添加目录…", systemImage: "plus")
                        }
                        Button("全不选") {
                            for i in choices.indices { choices[i].selected = false }
                        }
                        .disabled(picked.isEmpty)
                    }
                }
            }

            PanelBox("不索引什么", subtitle: "这些是**刻意**排除的，不是漏了。") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Bullet("**不索引主目录**（`~` 本身）—— 整棵用户目录扫一遍又慢又没用。")
                    Bullet("**不索引「文稿」**（`~/Documents`）—— 那是你的工作区，除非你自己加进来。")
                    Bullet("机器生成的东西（`node_modules`、`.build`、缓存目录这类）扫描时会跳过，跳过多少个会如实写在结果里。")
                }
            }

            fallbackPanel
        }
    }

    /// 备用路径：保留 `IndexCommandPlan` 的探测结果，默认折叠。
    private var fallbackPanel: some View {
        DisclosureGroup(isExpanded: $showFallback) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("这条路径**不会**建索引 —— 它只说清命令行那条老路在这台机器上是什么样，给已经有 CLI、或者要给 agent / MCP 用的人看。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)

                if let command = plan.command {
                    if let pre = plan.prerequisite {
                        Text(.init(pre))
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CLICommandRow(command: command)
                }
                Text(.init(plan.note))
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)

                Text("CLI 的完整源码也在这个 dmg 里：`CLI/` 目录，不用再去 clone 仓库。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Shell.readingWidth, alignment: .leading)
            .padding(.top, Space.xs)
        } label: {
            Text("已经有 CLI，或者想给 agent / MCP 用？")
                .font(.callout.weight(.medium))
        }
        .padding(Space.md)
        .cardSurface(radius: Radius.lg)
    }

    // ② 建立中

    private var runningStep: some View {
        PanelBox("正在建立索引", subtitle: "第一次可能要几十秒到几分钟，取决于选了多少文件。") {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .top, spacing: Space.sm) {
                    MetricTile(title: "已扫描",
                               value: "\(progress?.scanned ?? 0)",
                               caption: "走过的文件 + 目录")
                    MetricTile(title: "已抽取正文",
                               value: "\(progress?.extracted ?? 0)",
                               caption: "有正文可搜的那些",
                               tint: Palette.success)
                    // 每秒跳一次的用时 —— 顺便证明界面真的在跑（没有假死）
                    TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                        MetricTile(title: "已用时",
                                   value: elapsed(ctx.date),
                                   caption: reduceMotion ? "计数在动" : "界面没卡住",
                                   tint: Palette.neutral)
                    }
                }

                if let p = progress, !p.currentPath.isEmpty {
                    Text(p.currentPath)
                        .pathText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // 这句原来写的是「再点一次会接着补全」—— 那时的界面上**没有**那个按钮，
                // 而且一旦进了主界面，App 内建的索引器不会自己接着扫：就是一句做不到的话。
                // 现在这句与真实存在的两条路对齐：这一屏的「继续建完」，以及主界面顶部的横幅入口。
                Text("取消不会弄坏东西：已经扫到的部分是**有效但可能不完整**的索引。App 内建的索引器不会在你进入主界面之后自己接着往下扫 —— 但主界面顶部会一直有「索引不完整 · 继续建完」的入口，随时能回来接着补。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(now.timeIntervalSince(startedAt).rounded())
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }

    // ③ 完成 / 失败 / 取消

    private func doneStep(_ r: VaultIndexer.Report) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PanelBox("索引建好了", subtitle: "下面每一个数字都是这次真扫出来的，没有估算。") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .top, spacing: Space.sm) {
                        MetricTile(title: "扫描文件", value: "\(r.filesSeen)",
                                   caption: "这次走到的文件", tint: Palette.accent)
                        MetricTile(title: "扫描目录", value: "\(r.dirsSeen)",
                                   caption: "这次走到的目录", tint: Palette.accent)
                        MetricTile(title: "跳过目录", value: "\(r.skippedDirs)",
                                   caption: "机器生成 / 明确不扫的", tint: Palette.neutral)
                    }
                    HStack(alignment: .top, spacing: Space.sm) {
                        MetricTile(title: "新增", value: "\(r.added)",
                                   caption: "库里原来没有的", tint: Palette.success)
                        MetricTile(title: "更新", value: "\(r.updated)",
                                   caption: "内容或时间变了的", tint: Palette.warning)
                        MetricTile(title: "标记移除", value: "\(r.removed)",
                                   caption: "这次没看到、标成已消失", tint: Palette.neutral)
                        MetricTile(title: "用时", value: ms(r.elapsedMs),
                                   caption: "扫描 + 写库", tint: Palette.neutral)
                    }
                    if r.errors > 0 {
                        Text("有 \(r.errors) 个条目读不了（多半是权限或文件正在被别的东西用）。索引**可用**，但这些文件的内容没进来。")
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning = configWarning {
                        Text("另外：这次选的目录清单**没能**写进 `~/.localvault/config.json`（\(warning)）。索引本身不受影响，但命令行那边看不到这份清单。")
                            .faintText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            PanelBox("索引放在哪", subtitle: "只读打开；这个应用不会写它。") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(VaultConfig.defaultDBPath)
                        .pathText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("命令行工具和这个应用读的是同一个库 —— 想接 agent / MCP 的话，dmg 里的 `CLI/` 是完整源码。")
                        .faintText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func failedStep(_ message: String) -> some View {
        EmptyState(icon: "exclamationmark.triangle",
                   title: "索引没建成",
                   message: message) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("上面是索引器**原样**报出来的错误。这次**没有**任何东西被写成「完成」。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)
                Text("常见原因：目录不存在了、没有读权限、磁盘满了。处理完再点「重试」。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Shell.readingWidth, alignment: .leading)
        }
    }

    private var cancelledStep: some View {
        PanelBox("已取消", subtitle: "这次**没有**跑完 —— 所以别把它当成建好了。") {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("已经写进索引的那部分是**有效**的（不是写坏了一半），但**可能不完整**。")
                    .faintText()
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: Space.sm) {
                    MetricTile(title: "取消前扫到", value: "\(progress?.scanned ?? 0)",
                               caption: "文件 + 目录", tint: Palette.neutral)
                    MetricTile(title: "其中抽到正文", value: "\(progress?.extracted ?? 0)",
                               caption: "不是最终数字", tint: Palette.neutral)
                }
                Bullet("**继续**会接着上次的进度往下补 —— 扫过的不白扫，也不需要删库。")
            }
        }
    }

    private func ms(_ elapsedMs: Int) -> String {
        let s = Double(elapsedMs) / 1000
        return s < 60 ? String(format: "%.1f 秒", s) : String(format: "%.0f 分", s / 60)
    }

    // MARK: 底部（固定）

    private var footer: some View {
        HStack(spacing: Space.sm) {
            Text("这个应用只读 —— 不会改动你的任何文件。")
                .faintText()
            Spacer(minLength: Space.sm)

            switch step {
            case .pick:
                if picked.isEmpty {
                    // 「至少勾一个」在**一个可选项都没有**的机器上是没法执行的指令
                    // （那台机器既没有 ~/Desktop 也没有 ~/Downloads）—— 分开说。
                    Text(choices.isEmpty ? "先用「添加目录…」选一个目录"
                                         : "至少勾一个目录")
                        .faintText()
                }
                Button("开始建立索引") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty)

            case .running:
                Button(cancelling ? "正在取消…" : "取消") { cancel() }
                    .disabled(cancelling)

            case .cancelled:
                Button("重新选目录") { withMotion { step = .pick } }
                // 一条都没扫到（取消得早）就**不放人进去**：
                // 库一旦存在，向导就再也不会出现了（外面的路由只看 `vault.db` 在不在），
                // 于是那会是个空库 + 再也回不到「继续建完」的死路。
                // 已经落了东西才给这条出口，并且如实写明它不完整。
                if (progress?.scanned ?? 0) > 0 {
                    Button("先这样用（已扫到 \(progress?.scanned ?? 0) 条，不完整）") { onIndexed() }
                        .help("这个索引不完整。进了主界面之后，顶部会一直有「索引不完整 · 继续建完」的入口，随时能回来接着补。")
                } else if resumingExistingLibrary {
                    // 一条都没扫到 + 库本来就是能用的（从横幅进来的）→ **必须**能回去，
                    // 否则这里就成了新的死路：向导进得来、出不去。
                    Button("回到主界面") { onIndexed() }
                        .help("库还在、还能正常用，只是仍然不完整；这次取消没有改动它。")
                }
                Button("继续建完") { start() }
                    .buttonStyle(.borderedProminent)

            case .done:
                Button("进入") { onIndexed() }
                    .buttonStyle(.borderedProminent)

            case .failed:
                Button("重新选目录") { withMotion { step = .pick } }
                Button("重试") { start() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, Space.xs)
    }

    // MARK: 动作

    private func withMotion(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(Motion.base) { change() }
        }
    }

    /// 候选目录：先放配置里已经选过的（上次建到一半），再补系统探到的。
    /// 都默认勾上 —— 点一下「开始」就行，不需要先做选择题。
    private func loadChoices() {
        guard choices.isEmpty else { return }
        var seen = Set<String>()
        var out: [Choice] = []
        if let cfg = VaultConfig.load() {
            for r in cfg.roots where !seen.contains(r.path) {
                seen.insert(r.path)
                out.append(Choice(path: r.path, label: r.label, selected: true))
            }
        }
        for r in VaultConfig.probeSystemRoots() where !seen.contains(r.path) {
            seen.insert(r.path)
            out.append(Choice(path: r.path, label: r.label, selected: true))
        }
        choices = out
    }

    private func addDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "加进来"
        panel.message = "选要索引的目录。只有加进来的才会被扫。"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !choices.contains(where: { $0.path == url.path }) {
            choices.append(Choice(path: url.path, label: url.lastPathComponent, selected: true))
        }
    }

    private func start() {
        let selected = picked
        guard !selected.isEmpty else { return }

        startedAt = Date()
        progress = nil
        cancelling = false
        configWarning = nil
        withMotion { step = .running }

        let dbPath = VaultConfig.defaultDBPath
        let roots = selected.map { VaultIndexer.IndexRoot(path: $0.path, label: $0.label) }

        // 记住这次选的目录，让 CLI 和 App 看到同一份清单。
        // 文件还不存在时从 `VaultConfig.empty` 起 —— 那是它给调用方的入口，
        // 不自己拼 JSON（等于把 config.js 的默认表在 App 侧存第二份，两边迟早分叉）。
        // 写不进去**不影响**建索引，但必须如实报出来，不能悄悄吞掉。
        do {
            var cfg = VaultConfig.load() ?? VaultConfig.empty
            cfg.roots = selected.map { VaultConfig.Root(path: $0.path, label: $0.label) }
            try cfg.save()
        } catch {
            configWarning = error.localizedDescription
        }

        // 关键：**必须**在 MainActor 之外跑。
        // 在 View 的方法里直接写 `Task { … }` 会继承 MainActor，
        // 而 `VaultIndexer.run` 是同步的 —— 主线程会被钉死，界面假死。
        runTask = Task.detached(priority: .userInitiated) {            let throttle = ProgressThrottle()
            do {
                try VaultIndexer.ensureDatabase(at: dbPath)
                let report = try VaultIndexer.run(roots: roots, dbPath: dbPath) { p in
                    // 回调来自扫描线程：进度必须切回主线程再动 UI
                    guard throttle.shouldForward() else { return }
                    DispatchQueue.main.async { progress = p }
                }
                await MainActor.run {
                    runTask = nil
                    cancelling = false
                    // 取消了就绝不报完成 —— 哪怕 run 已经把报告还给我了
                    if Task.isCancelled {
                        step = .cancelled
                    } else {
                        step = .done(report)
                        // `enter` 档位：扫完直接进主界面（验「进得去」这条路径）
                        if automation == .enter { onIndexed() }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    runTask = nil
                    cancelling = false
                    step = .cancelled
                }
            } catch {
                await MainActor.run {
                    runTask = nil
                    cancelling = false
                    step = .failed(error.localizedDescription)
                }
            }
        }

        // 验收档位：把「取消」也变成可回归的（否则这个状态永远只能靠手点去看）
        //   cancel      —— 立刻取消：**一条都没扫到**那条分支（不该给「先进去用」的出口）
        //   cancel-late —— 扫一会儿再取消：库里**已经落了东西**那条分支
        switch automation {
        case .cancel:     DispatchQueue.main.async { cancel() }
        case .cancelLate: DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cancel() }
        default:          break
        }
    }

    private func cancel() {
        cancelling = true
        // 不在这里改 step：让 `run` 抛了 CancellationError 再走 .cancelled ——
        // 这样「已取消」这句话是**真发生过**才出现的，而不是按了按钮就宣布。
        runTask?.cancel()
    }
}

// MARK: - 向导的验收档位

/// `--onboard auto|enter|cancel|cancel-late`。只有截图/自动化验收会用到，正常人看不到。
enum OnboardingAutomation: String {
    /// 跳过「开始建立索引」，直接开扫
    case auto
    /// 开扫 + 扫完自动进主界面
    case enter
    /// 开扫后**立刻**取消 —— 一条都没扫到时的取消态
    case cancel
    /// 开扫一会儿再取消 —— 库里已经落了东西时的取消态
    case cancelLate = "cancel-late"
}

// MARK: - 进度的节流
//
// 扫描线程可能每秒回调几千次；UI 每秒刷 60 次就够了。
// 只在扫描线程里用，所以没有加锁。
private final class ProgressThrottle {
    private var last = 0.0
    func shouldForward() -> Bool {
        let now = Date().timeIntervalSince1970
        if now - last < 0.05 { return false }
        last = now
        return true
    }
}

// MARK: - 命令行备用路径的探测
//
// 这套东西的主场从「索引缺失」挪到了向导的折叠区：
// 大多数人该走原生索引器，只有已经有 CLI 的人需要它。

enum CLIProbe {
    /// `localvault` 在不在 PATH 上
    static var hasLocalvault: Bool { which("localvault") != nil }
    /// 跑 CLI 源码要用到 node
    static var nodeOnPath: String? { which("node") }
    /// 从 .app 往上找仓库里的 CLI 源码
    static var cliScript: String? { findCLIScript() }

    static var plan: IndexCommandPlan {
        if hasLocalvault { return .installed }
        if let cli = cliScript { return .fromSource(script: cli, nodeMissing: nodeOnPath == nil) }
        return .unavailable
    }

    static func which(_ tool: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in env.split(separator: ":") where !dir.isEmpty {
            let p = String(dir) + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 找 CLI 源码，两处都找：
    /// 1. **App 旁边**的 `CLI/cli.js` —— dmg 里就是这个排布（`本地上下文.app` 和 `CLI/` 并排），
    ///    从 dmg 里直接跑、或者把 `CLI/` 一起拷到 `/Applications` 旁边，都对得上；
    /// 2. 再顺着 `.app` 往上找 `mcp-server/cli.js` —— 在仓库里（`app/dist/本地上下文.app`）三步就找到。
    ///
    /// 两处都没有 → nil：界面改成文字指路，而不是显示一条跑不通的命令。
    /// （dmg 里现在**带着** `CLI/`，所以第 1 条是"开箱就能接 agent"那句承诺的兑现点。）
    static func findCLIScript() -> String? {
        let bundleDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        let beside = bundleDir.appendingPathComponent("CLI/cli.js").path
        if FileManager.default.fileExists(atPath: beside) { return beside }

        var dir = bundleDir
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("mcp-server/cli.js").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

/// 命令行路径的三种情况。**不猜、不编**：给不出来就说给不出来。
enum IndexCommandPlan {
    /// PATH 上有 `localvault`
    case installed
    /// 没有 `localvault`，但找得到 CLI 源码；`nodeMissing` 表示这台机器还没有 node
    case fromSource(script: String, nodeMissing: Bool)
    /// 都没有 —— **不给命令**，指路到 dmg 里的《首次运行.md》
    case unavailable

    var command: String? {
        switch self {
        case .installed:
            return "localvault init && localvault index"
        case .fromSource(let script, _):
            return "node \"\(script)\" init && node \"\(script)\" index"
        case .unavailable:
            return nil
        }
    }

    /// 只重建「地图 + instructions」那条命令（不重扫磁盘）。
    /// 用于索引地图面板的缺口提示 —— 那里的指引必须是**真能做到**的一步。
    /// 注意：CLI 的 `map` 子命令**只打印、不写库**，真正写 `meta.map` 的是 `reindex-cache`。
    var mapCommand: String? {
        switch self {
        case .installed:            return "localvault reindex-cache"
        case .fromSource(let s, _): return "node \"\(s)\" reindex-cache"
        case .unavailable:          return nil
        }
    }

    /// 命令之前必须先补的一步。缺 node 时**先说这一步**，
    /// 而不是把一条会 command not found 的命令直接摆出来。
    var prerequisite: String? {
        switch self {
        case .fromSource(_, true):
            return "先补一步：CLI 要求 Node ≥ 22.5，而这台机器的 PATH 上没有 `node`。"
        default:
            return nil
        }
    }

    /// 说明这条命令是哪来的 —— 用户得能判断它对自己成不成立
    var note: String {
        switch self {
        case .installed:
            return "已在这台机器的 PATH 上找到 `localvault`（它要求 Node ≥ 22.5）。"
        case .fromSource(let script, false):
            // 卷上的那条：命令能跑，但卷一卸载路径就没了 —— 说清楚，别让人以为可以这么长久用
            if script.hasPrefix("/Volumes/") {
                return "这台机器上没有 `localvault` 命令 —— 它还没发布到 npm。这条用的是 **dmg 卷上**的 CLI 源码（只读卷，能用，但卸载后路径就没了）：想长久用，先把 `CLI/` 拷到别处。"
            }
            return "这台机器上没有 `localvault` 命令 —— 它还没发布到 npm。这里直接跑仓库里的 CLI 源码。"
        case .fromSource(_, true):
            return "这台机器上没有 `localvault` 命令 —— 它还没发布到 npm。dmg 里的 `CLI/` 有完整源码。"
        case .unavailable:
            return "这台机器上没找到 `localvault` 命令，也没在 App 旁边找到 CLI 源码。dmg 里的 `CLI/` 就是完整源码：把它拷到任意位置，用 `node cli.js init` / `node cli.js index` 跑（要求 Node ≥ 22.5）。"
        }
    }
}

/// 命令 + 复制按钮。**显示的就是复制到的**，所以长路径换行显示、不做截断。
struct CLICommandRow: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Text(command)
                .pathText()
                .fixedSize(horizontal: false, vertical: true)
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
    }
}
