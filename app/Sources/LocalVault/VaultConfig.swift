import Foundation

/// App 自己写 `~/.localvault/config.json` —— 也就是 CLI 的 `localvault init` 干的那件事。
///
/// ## 为什么写「最小一份」而不是照抄 CLI 的完整快照
/// CLI 的 `init` 会把 `defaultConfig()` 整份落盘（ignoredDirs / denyRead / policy / discover…）。
/// 在 Swift 里复制那份快照有两个坏处：
/// 1. 等于把 `config.js` 里那几张默认表在 App 侧存第二份，两边迟早分叉；
/// 2. 会把**当时**的默认值固化进用户的文件 —— 以后 CLI 改了默认忽略目录，
///    这台机器的库还按旧表扫，而 `loadConfig` 明明是从默认值 deepMerge 的。
///
/// 所以这里只写 `version` / `dataDir` / `roots` / `primaryRoot`，
/// 其余字段交给 `lib/config.js` 的 `deepMerge(defaultConfig(), fromFile)` 补齐 ——
/// 结果与完整快照等价，但不会替 CLI 记住默认值。
///
/// 路径按 CLI 的惯例写 `~/...`（`writeDefaultConfigIfMissing` 用 `compressHome`），
/// 读回来再展开；这样配置文件不随用户名变化，换机器也能用。
struct VaultConfig {

    struct Root {
        var path: String
        var label: String
    }

    /// 与 `config.js` 的 `DEFAULT_DATA_DIR` 一致
    static let defaultDataDir = "~/.localvault"

    /// `~/.localvault/config.json`
    static var defaultURL: URL {
        URL(fileURLWithPath: expandHome(defaultDataDir)).appendingPathComponent("config.json")
    }

    /// `~/.localvault/vault.db`
    ///
    /// 这个是**默认**库位置。`config.json` 里若写了别的 `dataDir`，
    /// CLI 会把库放在那里 —— 所以读库/写库前先看 `load()?.dataDir`。
    static var defaultDBPath: String {
        expandHome(defaultDataDir) + "/vault.db"
    }

    var dataDir: String = VaultConfig.defaultDataDir
    var roots: [Root] = []
    var primaryRoot: String = ""

    /// 一个「什么都没选」的实例：dataDir 走默认、roots 为空。
    ///
    /// 存在的理由：`load()` 在**文件不存在**时返回 nil 是刻意的（"读不到配置"和
    /// "配置里没有根"是两件事，不能混）。但调用方需要能凭空造一个再 save，
    /// 所以给一个默认值齐全的实例，而不是让每个调用点自己去拼 JSON。
    static var empty: VaultConfig { VaultConfig() }

    // MARK: - 读

    /// 读 `~/.localvault/config.json`。
    ///
    /// 返回 nil **仅当**文件不存在或不是合法 JSON —— 也就是"这份配置读不回来"。
    /// 文件存在但 `roots` 为空时返回的是「有配置、没有根」，不是 nil。
    static func load() -> VaultConfig? {
        guard let data = try? Data(contentsOf: defaultURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var cfg = VaultConfig()
        if let d = obj["dataDir"] as? String, !d.isEmpty { cfg.dataDir = d }
        if let pr = obj["primaryRoot"] as? String, !pr.isEmpty { cfg.primaryRoot = expandHome(pr) }

        if let rows = obj["roots"] as? [[String: Any]] {
            cfg.roots = rows.compactMap { row in
                guard let p = row["path"] as? String, !p.isEmpty else { return nil }
                let abs = expandHome(p)
                let label = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (abs as NSString).lastPathComponent
                return Root(path: abs, label: label)
            }
        } else if let rows = obj["roots"] as? [String] {
            // loadConfig 允许 roots 是纯字符串数组，`init` 之外手写的配置里出现过
            cfg.roots = rows.filter { !$0.isEmpty }.map {
                let abs = expandHome($0)
                return Root(path: abs, label: (abs as NSString).lastPathComponent)
            }
        }
        return cfg
    }

    // MARK: - 探测

    /// 只探测系统标准目录：`~/Desktop`、`~/Downloads`，**存在才给**。
    ///
    /// 三条都是刻意的，`test/clean-machine.js` 对 CLI 断言过同样的规矩：
    /// - 不默认索引整个主目录（那是几百万个文件，而且用户没同意）；
    /// - 不索引 `~/Documents` —— 要由用户显式指定（CLI 的断言原文：未默认索引 Documents）；
    /// - 不存在就不放进配置，免得 `doctor` 报"索引根不可用"。
    /// 顺序即优先级：桌面（最可能有待整理的散文件）在前，和 `defaultRoots()` 一致。
    static func probeSystemRoots() -> [Root] {
        let home = NSHomeDirectory()
        var out: [Root] = []
        for (name, label) in [("Desktop", "桌面"), ("Downloads", "下载")] {
            let path = home + "/" + name
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                out.append(Root(path: path, label: label))
            }
        }
        return out
    }

    // MARK: - 写

    /// 落盘到 `~/.localvault/config.json`。
    ///
    /// 原子写（`Data.write(.atomic)`：写同目录临时文件再 rename）——
    /// 向导在写一半时被杀掉，不该留下一个读不回来的配置。
    func save() throws {
        let url = VaultConfig.defaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let rootRows: [[String: String]] = roots.map { r in
            let label = r.label.isEmpty ? (r.path as NSString).lastPathComponent : r.label
            return ["path": VaultConfig.compressHome(r.path), "label": label]
        }
        var obj: [String: Any] = [
            "version": 2,
            "dataDir": dataDir.isEmpty ? VaultConfig.defaultDataDir : dataDir,
            "roots": rootRows,
        ]
        // primaryRoot：CLI 的语义是"多根时只用来当相对路径基准"，留空让它自己取第一个根
        let primary = primaryRoot.isEmpty ? (roots.first?.path ?? "") : primaryRoot
        obj["primaryRoot"] = primary.isEmpty ? "" : VaultConfig.compressHome(primary)

        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        var out = data
        out.append(0x0A)                      // 结尾换行，和 CLI 写出来的文件一样
        try out.write(to: url, options: .atomic)
    }

    // MARK: - 路径

    /// `~` / `~/x` → 绝对路径。空串原样返回（别把空串变成 cwd）。
    private static func expandHome(_ p: String) -> String {
        if p.isEmpty { return p }
        if p == "~" { return NSHomeDirectory() }
        if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
        return p
    }

    /// 绝对路径里的主目录压回 `~`，用于写配置（CLI 的 `compressHome` 同一套规则）。
    private static func compressHome(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + String(p.dropFirst(home.count)) }
        return p
    }
}
