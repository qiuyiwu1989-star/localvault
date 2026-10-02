import Foundation

/// 对文件的**分类判断**：没用的 / 值得了解的 / 待定。
///
/// 这是"主动行为"的第一步。之前整个系统只会**陈列**文件，从不**判断**。
///
/// **设计约束**：分类必须给出理由，且理由要能被推翻。
/// 工具没有资格宣布"这个文件没用"——它只能说"因为这是个 .dmg 安装包，装完就没用了"。
/// 所以每条判定都带 `reasons`，界面上永远和结论一起显示。
/// 注意力优先级 —— **一条有序的梯子**，从"务必读"到"不看"。
///
/// 之前是三档平铺（值得了解 / 待定 / 没用）。实测下来「值得了解」不是被**选**出来的，
/// 是**过网的默认值**：过了硬件滤网的 2,829 个里有 2,363 个（83.5%）判「值得了解」，
/// 而四条正面信号里三条在全库和这一档的命中率几乎相同 ——
///   「90 天内改动」99.8% vs 99.9% · 「在项目目录里」100% vs 100% · 「人类命名」94.3% vs 93.7%
/// 它们没在筛选，只是在复述"这个文件不是垃圾"。
///
/// 所以现在每一级都必须拿得出**真能把它和上一级分开**的证据，
/// 依据是实测区分度（这条信号在这一级 vs 全库的命中率倍数）：
///   项目入口文档 **3.08×** · 文档笔记+实质正文 **2.30×** · 文档笔记 **2.14×**
/// 而这几条**不配当证据**（< 1.3×），已从理由里删掉：
///   正文含第一人称「我」1.23× · 正文含判断/认为/决定 1.26× · 正文长度 1.25× · 正文成段 1.10×
///
/// `allCases` 的顺序**就是**梯子顺序，界面按下标渲染。
enum Triage: String, CaseIterable, Identifiable, Comparable {
    case mustRead   = "务必读"
    case readable   = "值得读"
    case skimmable  = "值得扫"
    case unreadable = "待定"
    case searchOnly = "只检索"
    case excluded   = "不看"

    var id: String { rawValue }

    /// 梯子顺序。声明顺序即顺序，但显式写出来，免得有人重排枚举时把界面搞乱。
    var rank: Int {
        switch self {
        case .mustRead:   return 0
        case .readable:   return 1
        case .skimmable:  return 2
        case .unreadable: return 3
        case .searchOnly: return 4
        case .excluded:   return 5
        }
    }
    static func < (a: Triage, b: Triage) -> Bool { a.rank < b.rank }

    /// 这一级会不会占用你的注意力。前三级会，后三级不会。
    var drawsAttention: Bool { rank <= Triage.skimmable.rank }

    /// 这一级的证据强度说法 —— 界面上要能一眼看出"凭什么排这么前"。
    var basis: String {
        switch self {
        case .mustRead:   return "项目入口文档，或你签过字的"
        case .readable:   return "文档笔记，正文有实质内容"
        case .skimmable:  return "可读，但没什么判断内容"
        case .unreadable: return "机器读不懂这类内容，不冒充结论"
        case .searchOnly: return "agent 需要时搜得到，但不占你注意力"
        case .excluded:   return "安装包、依赖、构建产物、重复件这类"
        }
    }
}

/// 文件**装的是什么**。
///
/// 第一版分类器只看了"名字像不像人起的"和"最近改过没有"，结果把
/// `ChatGPT.dmg`、`model.safetensors`、`kimi_3.2.9.dmg` 全判成了"值得了解" ——
/// 因为下载下来的安装包当然名字正常、时间也新。
///
/// **漏掉的那一维是：这个文件里装的是什么。** 安装包和模型权重里
/// 不含任何"关于主人的信息"，无论它多新、名字多正常。
enum InfoKind: String {
    case prose      = "文档笔记"
    case structured = "结构化数据"
    case code       = "源代码"
    case comms      = "通讯记录"
    case media      = "图片音视频"
    case asset      = "设计资产"
    case unknown    = "未识别类型"
    case installer  = "安装包/压缩包"
    case model      = "模型权重"
    case binary     = "可执行/库文件"
    case config     = "配置文件"
    case vendor     = "第三方资产"
    case junk       = "系统杂项"

    /// 这类文件里**可能含有"关于主人的信息"**吗？
    var canRevealOwner: Bool {
        switch self {
        case .prose, .structured, .code, .comms: return true
        case .media, .asset:                     return false   // 需要 OCR/转录才知道
        case .installer, .model, .binary, .junk: return false
        case .config, .vendor, .unknown: return false
        }
    }
}

struct TriagedFile: Identifiable {
    let file: VaultFile
    let triage: Triage
    let infoKind: InfoKind
    let reasons: [String]
    var id: Int64 { file.id }
}

enum FileTriage {
    /// 必须与 `VaultQuery.cols` 里的 `substr(body,1,4000)` 保持一致。
    /// 两处不一致，依据里的数字就会开始说谎。
    static let bodyPreviewChars = 4000


    // MARK: 文件装的是什么

    /// 通讯记录的词表。
    ///
    /// **不含裸 `"im"`** —— 实测（2026-10-02）本机 21 个文件仅因名字里含 `im`
    /// 被判成「通讯记录」，其中 3 个是 PNG/JPEG：`IMG_3188.PNG` 的 `im` 来自 `img`。
    /// 而这个分类的评分是 95，会把这些图片顶到「值得了解」最前面。
    private static let commsTokens = ["chat", "wechat", "weixin", "message", "email", "mail", "im", "conversation"]

    /// 词边界匹配：短词（< 5 字符）左右不能紧挨字母数字。
    ///
    /// 长词（`wechat` / `conversation`）按子串匹配就够特异，走快路径。
    /// 短词不行：`im` 会命中 `img`、`simple`、`time`。
    private static func hasToken(_ n: String, _ t: String) -> Bool {
        if t.count >= 5 { return n.contains(t) }
        var search = n[...]
        while let r = search.range(of: t) {
            let before = r.lowerBound == n.startIndex ? nil : n[n.index(before: r.lowerBound)]
            let after = r.upperBound == n.endIndex ? nil : n[r.upperBound]
            let boundaryBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let boundaryAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if boundaryBefore && boundaryAfter { return true }
            search = n[r.upperBound...]
        }
        return false
    }

    static func infoKind(name: String, ext: String, rel: String, kind: String) -> InfoKind {
        // `ext` 有两种传法，**必须在这里统一**：
        //   索引侧存的是带点的（`.png`，见 VaultStore/VaultQuery 读的 DB 列）
        //   `URL.pathExtension` 不带点（`PNG`）
        //
        // 原来只认带点的那种，于是云盘传 `PNG` 时**下面每一条扩展名判断全部落空**，
        // 只剩名字启发式在跑 —— 这才是 `IMG_3188.PNG` 被判成「通讯记录」的直接原因
        // （名字里的 `im` 来自 `img`，而图片那条根本轮不到）。
        // 放在这个收口处统一，而不是在调用方：多一个调用方就多一次踩坑的机会。
        let raw = ext.lowercased()
        let e = raw.isEmpty ? "" : (raw.hasPrefix(".") ? raw : "." + raw)
        let n = name.lowercased()

        // 系统杂项
        if n == ".ds_store" || n == "thumbs.db" || n == "desktop.ini" { return .junk }

        // 第三方/供应商资产 —— 有内容，但不是关于主人的
        if isVendorAsset(name: name, rel: rel) { return .vendor }

        // 配置文件
        if isConfigExt(e) || e == ".ini" || e == ".conf" || e == ".cfg" { return .config }

        // 安装包 / 压缩包 —— 装完就没用，不含任何关于主人的信息
        if [".dmg", ".pkg", ".mpkg", ".iso", ".msi", ".deb", ".rpm", ".appimage"].contains(e) {
            return .installer
        }
        if [".zip", ".tar", ".gz", ".tgz", ".7z", ".rar", ".xz", ".bz2"].contains(e) {
            return .installer
        }

        // 模型权重 —— 是模型，不是内容
        if [".safetensors", ".gguf", ".ckpt", ".onnx", ".pt", ".pth", ".h5", ".mlmodel", ".tflite"].contains(e) {
            return .model
        }

        // 可执行 / 库
        if [".dylib", ".so", ".dll", ".exe", ".node", ".a", ".o", ".class", ".jar", ".wasm"].contains(e) {
            return .binary
        }
        if rel.lowercased().contains(".app/") { return .binary }

        // 文档笔记
        if [".md", ".markdown", ".txt", ".rtf", ".doc", ".docx", ".pdf", ".pages",
            ".ppt", ".pptx", ".key", ".epub"].contains(e) { return .prose }
        if e.isEmpty && !n.contains(".") { return .prose }   // 无扩展名的纯文本，多半是笔记

        // 结构化数据
        if [".json", ".yaml", ".yml", ".toml", ".csv", ".tsv", ".xml",
            ".xlsx", ".xls", ".numbers", ".db", ".sqlite", ".parquet"].contains(e) { return .structured }

        // 源代码
        if [".swift", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".rb", ".go",
            ".rs", ".kt", ".kts", ".java", ".c", ".h", ".cpp", ".hpp", ".m", ".mm",
            ".sh", ".bash", ".zsh", ".fish", ".ps1", ".sql", ".php", ".lua", ".r",
            ".html", ".htm", ".css", ".scss", ".vue", ".svelte"].contains(e) { return .code }

        // 图片音视频 —— **必须排在「通讯记录」之前**。
        //
        // 原来是反的，于是名字里带 `im` 的图片全被判成「通讯记录」。
        // 「这个文件是 PNG」是硬事实，「名字里出现了某个词」是软猜测，硬事实赢。
        if [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tiff", ".bmp",
            ".mp4", ".mov", ".avi", ".mkv", ".flv", ".wmv", ".webm", ".m4v",
            ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"].contains(e) { return .media }

        // 设计资产
        if [".sketch", ".fig", ".xd", ".psd", ".ai", ".eps", ".svg", ".indd", ".afdesign"].contains(e) {
            return .asset
        }

        // 通讯记录 —— 放在扩展名判断**之后**，只对剩下的文件生效
        if commsTokens.contains(where: { hasToken(n, $0) }) { return .comms }
        if e == ".eml" || e == ".msg" { return .comms }

        if kind == "video" || kind == "audio" || kind == "image" { return .media }
        if kind == "code" { return .code }
        if kind == "doc" || kind == "web" { return .prose }

        // 认不出来的扩展名：**不要再默认算"文档笔记"**。
        // 原来这样写，于是 .conf / .ini 全挤到"值得了解"最前面。
        return .unknown
    }

    // MARK: 机器命名识别

    /// 形如 `1000002066.jpg`、`IMG_20260918_143726`、`eyJwIjoi...`（base64 编码名）——
    /// 这些都是**机器生成的名字**，名字里不含任何关于内容的信息。
    /// 人类给文件起名会说人话，机器不会。
    static func isMachineNamed(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        guard !base.isEmpty else { return true }

        // 纯数字（含长数字串）
        if base.allSatisfy(\.isNumber), base.count >= 6 { return true }

        // base64 编码名 —— 本机「视频内容」239GB 就是这样：
        // 文件名的 base64 解出来是 {"p":"/storage/emulated/0/DCIM/Camera/..."}
        if base.hasPrefix("eyJ"), base.count > 24 { return true }

        // 纯十六进制（长度较长）
        let hexish = base.filter { $0.isHexDigit }
        if base.count >= 16, hexish.count == base.count { return true }

        // 常见相机/截图/导出命名
        let upper = base.uppercased()
        for p in ["IMG_", "DSC_", "DSCN", "VID_", "MVIMG", "PXL_", "SCREENSHOT", "MMEXPORT", "WX_CAMERA"] {
            if upper.hasPrefix(p) { return true }
        }

        // 中文占比 —— 人类命名常带中文
        let cjk = base.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        if cjk > 0 { return false }

        // 有意义的英文单词
        let letters = base.filter(\.isLetter)
        if letters.count >= 3 { return false }

        return true
    }

    /// 构建产物目录（这些本来就大多被索引跳过了，但 `output/releases` 这类会漏进来）
    static func isBuildArtifact(_ rel: String) -> Bool {
        let lower = rel.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let markers: Set<String> = [
            "releases", "dist", "build", "out", "target", "node_modules",
            ".git", "coverage", "deriveddata", ".build", "pods", "vendor",
            "__pycache__", ".venv", "venv", "site-packages"
        ]
        if parts.contains(where: { markers.contains($0) }) { return true }
        if lower.hasSuffix(".app") || lower.contains(".app/") { return true }
        return false
    }

    /// 第三方/供应商资产 —— NOTICE、LICENSE、模型词表、platform-tools。
    /// 这些文件确实有内容，但内容是**供应商写的**，不是关于主人的。
    static func isVendorAsset(name: String, rel: String) -> Bool {
        let lower = rel.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let vendorDirs: Set<String> = [
            "models", "platform-tools", "sdk", "third_party", "thirdparty",
            "extern", "external", "deps", "vendor", "node_modules", "site-packages"
        ]
        if parts.contains(where: { vendorDirs.contains($0) }) { return true }
        let base = (name as NSString).deletingPathExtension.lowercased()
        // 注意：**readme 不在这个名单里**。
        // README 是项目自己的入口文档，是这个工作区导航的骨架 ——
        // 把它当第三方资产会把最有价值的一类文件全判错。（这条是断言抓出来的。）
        // 只有"供应商目录里的 README"才算第三方，那由上面的目录规则管。
        let vendorNames: Set<String> = [
            "notice", "license", "licenses", "licence", "copying", "copyright",
            "merges", "vocab", "changelog", "authors", "contributors"
        ]
        return vendorNames.contains(base)
    }

    /// 配置文件
    static func isConfigExt(_ e: String) -> Bool {
        [".conf", ".cfg", ".ini", ".properties", ".env", ".plist", ".lock",
         ".sum", ".editorconfig", ".gitignore", ".dockerignore", ".npmrc"].contains(e)
    }

    static func isSystemJunk(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == ".ds_store" || n == "thumbs.db" || n == "desktop.ini"
    }

    /// 被下载下来的东西：下载目录里，或者名字里带版本号的安装包
    static func looksDownloaded(_ rel: String, _ name: String, _ ik: InfoKind) -> Bool {
        let lower = rel.lowercased()
        if lower.hasPrefix("downloads/") || lower.contains("/downloads/") {
            return ik == .installer || ik == .model || ik == .binary
        }
        // 名字里带版本号且是安装包/模型
        if ik == .installer || ik == .model {
            let n = name.lowercased()
            let hasVersion = n.contains(where: \.isNumber)
            return hasVersion
        }
        return false
    }

    // MARK: 各级的判别信号

    /// 一个文件**最容易被当成入口**的候选名。
    ///
    /// 限定可编辑文本文档，`.pdf` 不算 —— 实测 `Mac操作说明 完全指南.pdf`
    /// （别人的视频教程配套手册，167 MB）就因为名字含「说明」混进了「务必读」。
    /// 判的是**它的角色**（能被继续编辑的项目入口），不是它能不能读。
    private static let entryTokens = ["readme", "spec", "agents", "claude", "index",
                                      "契约", "台账", "规则", "规范", "说明", "背景",
                                      "章程", "原则", "指南", "总览", "对应", "方案", "复盘"]
    private static let entryExts: Set<String> = [".md", ".markdown", ".txt", ".rst", ""]

    /// 依赖目录 —— 里面是别人写的代码和文档，不是主人的内容。
    /// 实测旧机制漏了 268 个（`isBuildArtifact` 没覆盖 venv/site-packages 这类）。
    private static let depDirs = ["node_modules/", "/.build/", "/venv/", "/.venv/",
                                  "/site-packages/", "/pods/", "/dist/", "/build/",
                                  "/__pycache__/", "/vendor/", "/.next/", "/target/",
                                  "/deriveddata/", "/.gradle/", "/.cargo/"]
    static func inDependency(_ rel: String) -> Bool {
        let r = "/" + rel.lowercased()
        return depDirs.contains { r.contains($0) }
    }

    /// 归档件：还在索引里，但已经**被替代**。
    /// 不判"不看"（它没坏），但也不该和正本抢注意力 —— 实测 141 个，
    /// 其中 2 个（归档目录里的项目台账副本）原本和正本一起判「务必读」。
    static func isArchived(_ rel: String) -> Bool {
        rel.hasPrefix("归档/") || rel.contains("/归档/")
            || rel.lowercased().contains("/archive/")
            || rel.contains("备份-")
    }

    /// 项目入口文档：一个项目里**别人（或未来的你）该先读**的那一份。
    /// 实测区分度 **3.08×** —— 这套机制里最强的单个信号。
    static func isEntryDoc(name: String, ext: String, rel: String) -> Bool {
        guard entryExts.contains(ext.lowercased()) else { return false }
        guard !inDependency(rel), !isArchived(rel) else { return false }
        let n = name.lowercased()
        return entryTokens.contains { n.contains($0) }
    }

    // MARK: 主判定

    static func triage(_ files: [VaultFile], projectTopDirs: Set<String> = []) -> [TriagedFile] {
        // `projectTopDirs` 保留是为了不破坏调用方。实测「在项目目录里」的区分度是
        // **1.00×**（全库 100%、这一档 100%）—— 它不配当证据，所以不再进理由。
        _ = projectTopDirs

        // 廉价重复探测：同名 + 同大小 → 大概率重复。
        // （精确做法是算 sha256，那要读全部文件；这里先用索引里现成的字段。）
        var seen: [String: Int] = [:]
        var duplicateOf: [Int64: String] = [:]
        for f in files {
            let key = "\(f.name)\u{1}\(f.size)"
            if let firstId = seen[key], firstId != f.id {
                duplicateOf[f.id] = key
            } else {
                seen[key] = Int(f.id)
            }
        }

        return files.map { f -> TriagedFile in
            let ik       = infoKind(name: f.name, ext: f.ext, rel: f.rel, kind: f.kind)
            let archived = isArchived(f.rel)
            let inDeps   = inDependency(f.rel)
            let entry    = isEntryDoc(name: f.name, ext: f.ext, rel: f.rel)
            let len      = f.bodyLength > 0 ? f.bodyLength : (f.body ?? "").count

            // ── 第 5 级 不看 ─────────────────────────────────
            var no: [String] = []
            let unrevealing = !ik.canRevealOwner && ik != .media && ik != .asset
            // 未识别的扩展名但索引里**有正文** → 不判"不看"。判的是内容，不是后缀。
            if unrevealing && !(ik == .unknown && len > 0) {
                no.append("类型是「\(ik.rawValue)」—— 里面不含关于你的信息")
            }
            if ik == .vendor { no.append("第三方资产（别人的代码或文档）") }
            if isSystemJunk(f.name) { no.append("系统杂项文件") }
            if isBuildArtifact(f.rel) { no.append("在构建产物目录里") }
            if inDeps { no.append("在依赖目录里 —— 这是别人的代码，不是你的内容") }
            if f.size == 0 { no.append("空文件（0 字节）") }
            if let key = duplicateOf[f.id] {
                let nm = key.split(separator: "\u{1}").first.map(String.init) ?? ""
                no.append("与另一个文件同名同大小（\(nm)），大概率是重复的")
            }
            if !no.isEmpty {
                return TriagedFile(file: f, triage: .excluded, infoKind: ik,
                                   reasons: no.map { "✗ \($0)" })
            }

            // ── 第 3 级 待定：机器读不懂，不冒充结论 ────────────
            if ik == .media || ik == .asset {
                return TriagedFile(file: f, triage: .unreadable, infoKind: ik, reasons: [
                    "这类内容机器读不懂（照片、音视频、设计稿），索引里没有它的正文",
                    "不是「没用」—— 照片里当然有你，只是这里判不了",
                    "文件名和路径仍然可搜",
                ].map { "· \($0)" })
            }

            // 正文长度这条理由**每一级都要说**（只要索引里有正文）。
            // 它单独不构成证据（实测区分度 1.25×），但"这个文件有多长"是事实，
            // 卡片上不显示就不是分级问题，是信息缺失 —— 自检抓到过一次。
            let bodyReason: String? = {
                if len == 0 { return nil }
                if f.bodyTruncated { return "· 正文 \(len) 字以上，索引据此截断" }
                return "· 正文 \(len) 字"
            }()

            // ── 第 0 级 务必读 ───────────────────────────────
            // 入口文档即使躺在代码目录里也算 —— 判的是**角色**，不是它装的东西。
            if entry {
                var mustReasons = [
                    "✓ 看名字是项目入口文档（\(f.name)）—— 别人或未来的你该先读的就是它",
                    "✓ 实测这类文件的区分度 3.08×，是这套机制里最强的信号",
                ]
                if let br = bodyReason { mustReasons.append(br) }
                if archived { mustReasons.append("· 在归档目录里，可能已被替代") }
                return TriagedFile(file: f, triage: .mustRead, infoKind: ik, reasons: mustReasons)
            }

            // ── 第 4 级 只检索 ───────────────────────────────
            if ik == .code || ik == .structured || ik == .config {
                // 撞了存储上限的必须报「以上」。这里漏过一次：`len` 那时就等于上限本身，
                // 直接报数字等于**把上限说成事实** —— 本机 18 个文件是这种情况，
                // 自检里那条「撞存储上限的正文报『以上』」专门守它。
                let searchBody: String
                if len == 0 {
                    searchBody = "· 没索引到正文，只能按名字搜"
                } else if f.bodyTruncated {
                    searchBody = "· 有正文 \(len) 字以上（索引据此截断），可搜"
                } else {
                    searchBody = "· 有正文 \(len) 字，可搜"
                }
                return TriagedFile(file: f, triage: .searchOnly, infoKind: ik, reasons: [
                    "· \(ik.rawValue)：agent 需要时搜得到，但不值得占你的注意力",
                    searchBody,
                ])
            }

            // ── 第 1/2 级 文档笔记 ───────────────────────────
            var yes = ["✓ \(ik.rawValue)：这类文件里会有关于你的信息"]
            if len >= 200 {
                yes.append(f.bodyTruncated
                           ? "✓ 有实质正文（\(len) 字以上，索引据此截断）"
                           : "✓ 有实质正文（\(len) 字）")
            } else if len > 0 {
                yes.append("· 正文很短（\(len) 字），像占位或清单")
            } else {
                yes.append("· 索引里没有正文")
            }
            if archived { yes.append("· 在归档目录里，可能已被替代") }

            let t: Triage = ((ik == .prose || ik == .comms) && len >= 200 && !archived)
                ? .readable : .skimmable
            return TriagedFile(file: f, triage: t, infoKind: ik, reasons: yes)
        }
    }

    /// 排序权重：值得了解的应该按**信息密度**排，不是按体积。
    /// 第一版按体积降序，于是最大的安装包排在最前面。
    static func rank(_ t: TriagedFile) -> Int {
        switch t.infoKind {
        case .prose:      return 100
        case .comms:      return 95
        case .structured: return 80
        case .code:       return 70
        case .config:     return 40
        case .media:      return 30
        case .asset:      return 25
        default:          return 0
        }
    }
}
