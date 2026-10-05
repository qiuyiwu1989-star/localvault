import Foundation

/// 让「云盘」真的被 agent 读到。
///
/// ## 为什么需要这个文件
///
/// 云盘自己的 `说明.md` 写着「**拖进来之后在被索引时会自动被读到**」，
/// App 的 README 也写着云盘是「你拖进去的 agent 就读得到」。**两句话都不成立。**
///
/// 云盘路径 `~/Documents/本地上下文云盘` 从不在 `config.json` 的 `roots` 里
/// （真实配置只有 工作区 / 桌面 / 下载 三个根），所以：
///
/// ```
/// find_files「AGENT-QUICKSTART」 → 0 条
/// read_text  → 「路径不在任何已配置索引根内，拒绝读取。」
/// ```
///
/// 这不是「功能没做」，是**承诺没实现**：用户把文件拖进去、界面里看得见、
/// 文件也在盘上，于是合理地认为通了 —— 而 agent 那侧一个字节都看不到。
/// 这类「打印出来的保证不成立」比没有保证更糟，因为它让人停止怀疑。
///
/// ## 那句承诺有两个条件，两件都要做
///
/// 1. **「在被索引时」** → 把云盘登记成索引根（`register`）。
/// 2. **「自动被读到」** → 登记之后、以及每次拖入之后，扫一次这个根（`reindex`）。
///
/// 只做 1：文件要等下一次全量扫描才进库，用户拖完当场问 agent 还是查不到。
/// 只做 2：扫出来的行 `root` 不在配置的根里，MCP 依旧拒绝读。
///
/// ## 为什么只扫云盘这一个根是安全的
///
/// `VaultIndexer.run` 的消失标记是 `markGoneOlderThan(db, root:scanId:)`，
/// SQL 是 `WHERE root = ?` —— **按根隔离**。传一个根进去，别的根一行都不会被动。
/// 这不是推断，是读 `VaultIndexer.swift` 确认过的；`scripts/drive-index-check.sh`
/// 会对它再验一次（对拍另一个根的行数与 `gone` 值不变）。
enum DriveIndex {

    /// 登记成索引根时用的标签。和 `说明.md` / 界面上的名字保持一致。
    static let label = "云盘"

    /// 登记云盘为索引根。返回**这次是不是真的加了**。
    ///
    /// 幂等：已经有了就什么都不做，也不会去动别的根。
    /// 配置写不进去时**抛错**，由调用方决定怎么报 —— 不吞。
    @discardableResult
    static func register(root: URL = DriveStore.rootURL) throws -> Bool {
        try VaultConfig.ensureRoot(path: root.path, label: label)
    }

    /// 扫云盘这一个根，让刚放进去的文件当场就能被找到。
    ///
    /// - 扫之前确保根已登记（否则扫了也白扫 —— 见文件头）。
    /// - `onProgress` 来自扫描线程，调用方要自己切回主线程再动 UI。
    /// - 返回报告；调用方据此说「扫到几个」。
    @discardableResult
    static func reindex(root: URL = DriveStore.rootURL,
                        dbPath: String = VaultConfig.defaultDBPath,
                        onProgress: @escaping (VaultIndexer.Progress) -> Void = { _ in })
        throws -> VaultIndexer.Report {
        try register(root: root)
        try VaultIndexer.ensureDatabase(at: dbPath)
        return try VaultIndexer.run(roots: [VaultIndexer.IndexRoot(path: root.path, label: label)],
                                    dbPath: dbPath,
                                    onProgress: onProgress)
    }
}
