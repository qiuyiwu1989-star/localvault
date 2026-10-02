import Foundation
import SQLite3

/// SQLite 要求我们告诉它字符串参数的生存期；这是官方推荐写法。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 记录模型（与 MCP 侧同一套契约）

struct VaultFile: Identifiable, Hashable {
    let id: Int64
    let root: String
    let rel: String
    let name: String
    let ext: String
    let kind: String
    let size: Int64
    let mtime: Int64
    let isText: Bool
    let title: String?
    let body: String?
    /// 索引里正文的**真实**字符数。
    ///
    /// 为什么不能直接用 `body?.count`：喂给列表的 SQL 是 `substr(body,1,4000)`，
    /// 所以 `body.count` 的上限就是 4000 —— 本机 7,428 个有正文的文件里有 **3,342 个
    /// 都会被报成同一个「4000 字」**（真实有 88,000 字的、400,000 字的，全报 4000）。
    /// 那是查询的上限，不是文件的字数，不能当事实说出去。
    /// 默认 0 = 这条查询没带真实长度，调用方必须退回 `body?.count` 并**按上限措辞**。
    var bodyLength: Int = 0
    /// 索引里的正文是否**撞到了 `maxStoredBodyChars` 上限**。
    /// 光有长度不够：`length(body) == 400000` 既可能是真的 40 万字，
    /// 也可能是被截断在 40 万 —— 这两个事实长得一模一样，必须靠 `truncated` 分开。
    var bodyTruncated: Bool = false

    var rootLabel: String { (root as NSString).lastPathComponent }

    var sizeText: String {
        if size <= 0 { return "0 字节" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    /// 索引里 `mtime` 存的是**毫秒**。
    /// 原来直接 `Date(timeIntervalSince1970: TimeInterval(mtime))` —— 毫秒当秒，
    /// 算出来是公元 58000 年，`daysSince` 变成 `max(0, 负数)`，于是满屏"0 天前"。
    var mtimeDate: Date { Date(timeIntervalSince1970: TimeInterval(mtime) / 1000) }

    /// 时间戳是否可信。
    /// 本机有 423 个文件的 mtime 恰好是 500000000 秒（1985-10-26）——
    /// 这是 zip/Android 解包常用的哨兵值，不是真实修改时间。
    /// 把它当真时间画进趋势图，横轴会被拉到 1985 年。
    var hasSaneMtime: Bool {
        let y = Calendar(identifier: .gregorian)
            .component(.year, from: mtimeDate)
        return y >= 2000 && y <= 2100
    }

    var mtimeText: String {
        guard hasSaneMtime else { return "时间未知" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: mtimeDate)
    }

    var daysSince: Int {
        guard hasSaneMtime else { return -1 }      // -1 = 时间不可信，界面要如实说
        return max(0, Int(Date().timeIntervalSince(mtimeDate) / 86400))
    }

    var ageText: String {
        if daysSince < 0 { return "时间未知" }
        if daysSince == 0 { return "今天" }
        if daysSince < 30 { return "\(daysSince) 天前" }
        if daysSince < 365 { return "\(daysSince / 30) 个月前" }
        return "\(daysSince / 365) 年前"
    }
}

struct ScanRun: Identifiable, Hashable {
    let id: Int64
    let root: String
    let filesSeen: Int64
    let dirsSeen: Int64
    let skippedDirs: Int64
    let errors: Int64
    let elapsedMs: Int64
    let finishedAt: Int64

    var rootLabel: String { (root as NSString).lastPathComponent }
}

struct RootSummary: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let label: String
    var files: Int = 0
    var bytes: Int64 = 0
    var skippedDirs: Int64 = 0
    var dirsSeen: Int64 = 0
    var coveredFiles: Int = 0
    var coveredBytes: Int64 = 0
}

// MARK: - 只读数据访问

/// 以**只读方式**打开 `vault.db`。
///
/// 这是刻意的：应用在物理上就不可能改动索引。
/// 「文件一步不挪」这条纪律不是靠自觉，是靠打开方式。
final class VaultStore: ObservableObject {

    enum Err: LocalizedError {
        case open(String)
        case query(String)

        var errorDescription: String? {
            switch self {
            case .open(let m): return "打不开索引：\(m)"
            case .query(let m): return "查询失败：\(m)"
            }
        }
    }

    private var db: OpaquePointer?
    let dbPath: String

    @Published var roots: [RootSummary] = []
    @Published var kinds: [(String, Int, Int64)] = []
    @Published var totalFiles: Int = 0
    @Published var totalBytes: Int64 = 0
    @Published var textFiles: Int = 0
    @Published var lastScan: [ScanRun] = []
    @Published var mapText: String = ""
    @Published var loadError: String?

    init(path: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = path ?? "\(home)/.localvault/vault.db"
        open()
    }

    private func open() {
        // 只读打开走**唯一入口**（后台查询的 `VaultQuery.withConnection` 也走它）。
        // 里面已经包含两件事：真读探针（拆掉 `sqlite3_open_v2` 的「懒打开」假绿）、
        // 以及 WAL 缺 -shm 时的 immutable 回退。为什么必须只有一处实现：
        // 上一版把它们写在 open() 里，`VaultQuery` 那条路还在用裸 `mode=ro`，
        // 于是 CLI 建的干净库被读成「0 个文件」—— 界面能开、数字全空，
        // 正是我们这一轮要打掉的那种假绿，只是换了个层。
        let (h, why) = VaultStore.openReadOnly(dbPath)
        guard let h else {
            // 两条路都不行：**原样**报第一次的错误，绝不静默降级成「空库」。
            loadError = "打不开索引 \(dbPath)：\(why)"
            return
        }
        db = h
        loadOverview()
    }

    /// **只读打开的唯一入口**：App 的 store 与后台查询共用。
    ///
    /// 顺序：先 `mode=ro`（对写者安全，能看见 WAL 里的新数据），
    /// 读不出来**且没有 `-wal`** 时才按 `immutable=1` 重开。
    /// 返回的句柄保证能读 `meta` 表（两条路都探过）；nil = 两条路都读不出来。
    /// 第二个返回值只在 nil 时有意义：`mode=ro` 那次的真实错误。
    ///
    /// 为什么需要回退：只读连接**不能创建 -shm**，而读 WAL 库必须有 wal-index。
    /// 所以一个 WAL 模式的 vault.db 只要 -shm 不在（`cli.js index` 干净收尾后只剩
    /// vault.db；或者用户按 MissingVaultView 的建议「先把 vault.db 复制一份出来」
    /// 再复制回来），`sqlite3_open_v2` 照样返回 OK，第一条语句却 CANTOPEN ——
    /// 连 CLI 都读得动，App 读不了。这时若 -wal 也不在，主文件就是一份**完整
    /// checkpoint**，可以按 immutable 读：SQLite 相信它不会再变，于是不需要 wal-index。
    ///
    /// 竞态（回退的**已知代价**，不是「无条件正确」）：上面那个「-wal 不存在」的检查
    /// 和真正打开之间，写者**可能刚好建出 -wal**；那一刻 immutable 让我们可能读到
    /// **陈旧数据**。最坏是旧内容，不会是损坏 —— 我们是只读方，从不写这个库、
    /// 也从不假装写成功。-wal 在的时候坚决不回退：那是「库正在被写」的信号，
    /// 宁可报错，也不能把旧数据当新的给出去。
    static func openReadOnly(_ dbPath: String,
                             probe: String = schemaProbeSQL) -> (OpaquePointer?, String) {
        var handle: OpaquePointer?
        var firstError = "打不开 \(dbPath)"
        if sqlite3_open_v2("file:\(dbPath)?mode=ro", &handle,
                           SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
           let h = handle {
            // 只读句柄也要等一会儿：默认 busy_timeout=0 时，恰好撞上别的进程
            // （CLI / 向导里的原生索引器）正在 checkpoint 的那一瞬间，读会立刻拿到
            // SQLITE_BUSY；而所有读都只是「悄悄返回 0」，症状是界面空。
            // 2 秒足够跨过 checkpoint 窗口，又短到不会让界面看起来卡住。
            sqlite3_busy_timeout(h, 2_000)
            if let e = probeError(h, probe) {
                firstError = e
                sqlite3_close(h)
            } else {
                return (h, "")
            }
        } else {
            firstError = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "错误码 \(firstError)"
            if let h = handle { sqlite3_close(h) }
        }
        guard !FileManager.default.fileExists(atPath: dbPath + "-wal"),
              let alt = openImmutable(dbPath, probe: probe) else { return (nil, firstError) }
        sqlite3_busy_timeout(alt, 2_000)
        return (alt, "")
    }

    /// immutable=1 只读打开 + **再探一次**。返回 nil = 这条路也读不出来。
    /// 调用方负责只在没有 `-wal` 时用它（原因见 `openReadOnly` 里的竞态说明）。
    private static func openImmutable(_ dbPath: String, probe: String) -> OpaquePointer? {
        var h: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle = h else {
            if let h { sqlite3_close(h) }
            return nil
        }
        guard probeError(handle, probe) == nil else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: 底层

    private func scalar(_ sql: String, _ params: [Any?] = []) -> Int64 {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return 0 }
        defer { sqlite3_finalize(s) }
        bind(s, params)
        defer { sqlite3_reset(s) }
        if sqlite3_step(s) == SQLITE_ROW { return sqlite3_column_int64(s, 0) }
        return 0
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int64:  sqlite3_bind_int64(stmt, idx, v)
            case let v as Int:    sqlite3_bind_int64(stmt, idx, Int64(v))
            default:              sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    // MARK: 概览

    func loadOverview() {
        guard db != nil else { return }

        totalFiles = Int(scalar("SELECT count(*) FROM files WHERE gone=0"))
        totalBytes = scalar("SELECT coalesce(sum(size),0) FROM files WHERE gone=0")
        // 口径与 coverage 一致：**空字符串不算有正文**。
        // 大文件（>2MB）不抽取，body 存的是 '' 而不是 NULL；
        // 用 `body IS NOT NULL` 会把它们算进来，虚高 96 个。
        textFiles  = Int(scalar("SELECT count(*) FROM files WHERE gone=0 AND is_text=1 AND length(body)>0"))

        // 索引范围：文件数、体量、**被跳过的目录数**（这一项以前没露出来过）
        var byRoot: [String: RootSummary] = [:]
        if let db {
            let sql = """
                SELECT f.root,
                       count(*)                        AS files,
                       coalesce(sum(f.size),0)         AS bytes,
                       sum(CASE WHEN f.is_text=1 AND length(f.body)>0 THEN 1 ELSE 0 END) AS covered,
                       sum(CASE WHEN f.is_text=1 AND length(f.body)>0 THEN f.size ELSE 0 END) AS covered_bytes
                FROM files f WHERE f.gone=0 GROUP BY f.root
                """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt {
                defer { sqlite3_finalize(s) }
                while sqlite3_step(s) == SQLITE_ROW {
                    let path = text(s, 0)
                    byRoot[path] = RootSummary(
                        path: path,
                        label: (path as NSString).lastPathComponent,
                        files: Int(sqlite3_column_int64(s, 1)),
                        bytes: sqlite3_column_int64(s, 2),
                        coveredFiles: Int(sqlite3_column_int64(s, 3)),
                        coveredBytes: sqlite3_column_int64(s, 4)
                    )
                }
            }

            // 跳过目录数来自 scan_runs —— 这是「我排除了什么」的唯一真相来源
            let runSQL = """
                SELECT root, files_seen, dirs_seen, skipped_dirs, errors, elapsed_ms, finished_at, id
                FROM scan_runs r
                WHERE id IN (SELECT max(id) FROM scan_runs GROUP BY root)
                ORDER BY files_seen DESC
                """
            var rs: OpaquePointer?
            if sqlite3_prepare_v2(db, runSQL, -1, &rs, nil) == SQLITE_OK, let s = rs {
                defer { sqlite3_finalize(s) }
                lastScan = []
                while sqlite3_step(s) == SQLITE_ROW {
                    let run = ScanRun(
                        id: sqlite3_column_int64(s, 7),
                        root: text(s, 0),
                        filesSeen: sqlite3_column_int64(s, 1),
                        dirsSeen: sqlite3_column_int64(s, 2),
                        skippedDirs: sqlite3_column_int64(s, 3),
                        errors: sqlite3_column_int64(s, 4),
                        elapsedMs: sqlite3_column_int64(s, 5),
                        finishedAt: sqlite3_column_int64(s, 6)
                    )
                    lastScan.append(run)
                    if var r = byRoot[run.root] {
                        r.skippedDirs = run.skippedDirs
                        r.dirsSeen = run.dirsSeen
                        byRoot[run.root] = r
                    }
                }
            }

            // 类型分布
            var ks: [(String, Int, Int64)] = []
            let kSQL = "SELECT kind, count(*), coalesce(sum(size),0) FROM files WHERE gone=0 GROUP BY kind ORDER BY sum(size) DESC"
            var kst: OpaquePointer?
            if sqlite3_prepare_v2(db, kSQL, -1, &kst, nil) == SQLITE_OK, let s = kst {
                defer { sqlite3_finalize(s) }
                while sqlite3_step(s) == SQLITE_ROW {
                    ks.append((text(s, 0), Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2)))
                }
            }
            kinds = ks

            // 地图原文（由 MCP 侧生成，直接复用，不重写一套）
            let mSQL = "SELECT value FROM meta WHERE key='map'"
            var mst: OpaquePointer?
            if sqlite3_prepare_v2(db, mSQL, -1, &mst, nil) == SQLITE_OK, let s = mst {
                defer { sqlite3_finalize(s) }
                if sqlite3_step(s) == SQLITE_ROW { mapText = text(s, 0) }
            }
        }

        // 保持配置里的顺序（roots 顺序有意义）
        roots = byRoot.values.sorted { $0.files > $1.files }
    }

    // MARK: 浏览与检索

    /// 文字资产：只取有正文的，这是「有价值的内容」里成本最低、密度最高的一层。
    func fetchTextAssets(limit: Int = 500) -> [VaultFile] {
        queryFiles(
            where: "gone=0 AND is_text=1 AND length(body)>0 AND is_binary=0",
            params: [],
            order: "size DESC",
            limit: limit
        )
    }

    func search(_ keyword: String, limit: Int = 300) -> [VaultFile] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return fetchTextAssets(limit: limit) }
        let like = "%\(q)%"
        return queryFiles(
            where: "(gone=0 AND (body LIKE ? OR name LIKE ? OR rel LIKE ?))",
            params: [like, like, like],
            order: "CASE WHEN name LIKE ? THEN 0 ELSE 1 END, mtime DESC",
            limit: limit
        )
    }

    /// 找一个**真的没有正文**的文件（口径 `gone=0 AND length(body)=0`）。
    /// 给自检当样本用：检索的断言不能把关键词硬编码成 "dmg" —— 那是在检验
    /// 「用户桌面有没有 dmg 文件」，语料里没有就报红（假红）。样本从语料里取。
    func firstBodylessFile() -> VaultFile? {
        queryFiles(where: "gone=0 AND length(body)=0", params: [],
                   order: "size DESC", limit: 1).first
    }

    /// 从语料里取一个**真的重复出现**的中文关键词（同一篇正文里出现 ≥ 2 次）。
    ///
    /// 自检原来把它硬编码成「邱懿武」：在**任何**一台不含这三个字的机器上，整节检索断言
    /// （四十多条）会整体跳过 —— 而它检验的从来不是「这台机器有没有『邱懿武』」。
    /// 取一个真存在、且重复出现的词，`hitCount > 1` 就是必然的，那段断言才真在跑。
    func repeatingKeywordSample() -> String? {
        var candidates = 0
        for asset in fetchTextAssets(limit: 8) {
            let body = String(fullBody(asset.id).prefix(4000))
            var run = ""
            var seen = Set<String>()
            for ch in body {
                let isCJK = ch.unicodeScalars.allSatisfy { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
                run = isCJK ? run + String(ch) : ""
                guard run.count == 2, !seen.contains(run) else { continue }
                seen.insert(run)
                candidates += 1
                if body.components(separatedBy: run).count - 1 >= 2 { return run }
                if candidates >= 60 { break }
            }
        }
        return nil
    }

    func files(inRel dir: String, limit: Int = 800) -> [VaultFile] {        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return queryFiles(
            where: "gone=0 AND rel LIKE ?",
            params: [prefix + "%"],
            order: "rel ASC",
            limit: limit
        )
    }

    private func queryFiles(where clause: String, params: [Any?], order: String, limit: Int) -> [VaultFile] {
        guard let db else { return [] }
        var orderParams: [Any?] = []
        let orderClause = order
        if order.contains("?") {
            orderParams = params          // 复用同一组参数（ORDER BY 里也用了 LIKE ?）
        }
        // ⚠️ 这份列清单和 `VaultQuery.cols` 是**重复的**，改一处必须改另一处。
        // 实测踩过：给 VaultQuery 加了 `length(body)` 却漏了这里，
        // 于是界面走的那条路 `bodyLength` 全是 0 —— 自检第 91 条当场抓红。
        // `length(body)` 必须留在最后一列，`runFiles`/这里的下标都按它定位。
        let sql = """
            SELECT id, root, rel, name, ext, kind, size, mtime, is_text, title,
                   substr(body, 1, 4000), length(body), truncated
            FROM files WHERE \(clause)
            ORDER BY \(orderClause) LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s, params + orderParams)

        var out: [VaultFile] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(VaultFile(
                id: sqlite3_column_int64(s, 0),
                root: text(s, 1),
                rel: text(s, 2),
                name: text(s, 3),
                ext: text(s, 4),
                kind: text(s, 5),
                size: sqlite3_column_int64(s, 6),
                mtime: sqlite3_column_int64(s, 7),
                isText: sqlite3_column_int64(s, 8) == 1,
                title: sqlite3_column_text(s, 9).map { String(cString: $0) },
                body: sqlite3_column_text(s, 10).map { String(cString: $0) },
                bodyLength: Int(sqlite3_column_int64(s, 11)),
                bodyTruncated: sqlite3_column_int64(s, 12) == 1
            ))
        }
        return out
    }

    /// 完整正文（列表里只取前 4000 字，看详情时再取全）
    func fullBody(_ id: Int64) -> String {
        guard let db else { return "" }
        var stmt: OpaquePointer?
        let sql = "SELECT body FROM files WHERE id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return "" }
        defer { sqlite3_finalize(s) }
        bind(s, [id])
        if sqlite3_step(s) == SQLITE_ROW { return text(s, 0) }
        return ""
    }

    /// 预览用：完整正文**连同它是不是全文一起回来**。
    /// 只取 body 的写法分不清「没有正文」和「有但被 40 万上限截了」，界面就只能猜。
    func bodyDetail(_ id: Int64) -> VaultQuery.BodyDetail {
        VaultQuery.bodyDetail(dbPath: dbPath, id: id)
    }

    /// 只读探针：真的试着往索引里写一次，必须失败。
    /// 这不是理论上的「打开方式是只读」，是**实测被拒绝**。
    func attemptWriteProbe() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "CREATE TABLE __probe__(x)", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            return true            // 连编译都过不了 → 确实只读
        }
        defer { sqlite3_finalize(s) }
        // ⚠️ 必须真的 step。prepare 只编译不执行 ——
        // 上一版探针就错在这里：prepare 成功被当成了写成功，
        // 于是「只读」这个断言其实什么都没验证。
        let rc = sqlite3_step(s)
        return rc != SQLITE_DONE
    }

    /// 有正文可搜的文件数。
    /// 口径是 `length(body) > 0` —— **不是** `body IS NOT NULL`：
    /// 超限不抽取的大文件 body 存的是空字符串，用后者会虚高（本机 96 个）。
    ///
    /// 用 COUNT 而不是拉全部行再数 —— 后者会把几万个文件的正文读进内存。
    var textFileCount: Int {
        Int(VaultQuery.scalar(
            dbPath: dbPath,
            sql: "SELECT count(*) FROM files WHERE gone=0 AND is_text=1 AND length(body)>0 AND is_binary=0"))
    }


    /// 顶层目录（名字、文件数、体量）—— 检索库页用
    var topLevelDirs: [(String, Int, Int64)] {
        VaultQuery.topLevelDirs(dbPath: dbPath)
    }

    /// 地图里的顶层目录名 —— 用来判断「文件是否在项目目录里」
    var topDirNames: Set<String> {
        guard let m = VaultMap.decode(mapText) else { return [] }
        return Set((m.topLevelDirs ?? []).map(\.name))
    }

    // MARK: 无头自检
    //
    /// 默认探针用「建库时必写」的那一行，用来分辨「空的索引」和「根本不是数据库的占位文件」。
    /// 为什么不能只看 `sqlite3_open_v2` 的返回值：它是**懒打开** —— 对纯文本文件照样
    /// 返回 SQLITE_OK，「file is not a database」要等到第一次读才暴露。
    static let schemaProbeSQL = "SELECT value FROM meta WHERE key='schema_version'"

    /// 在一个句柄上跑一条**只 prepare 不求值**的探针；返回 nil 表示这条语句能准备
    /// （也就是这个文件确实是个能用的库）。返回非 nil 是那条真实错误。
    private static func probeError(_ h: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &stmt, nil)
        let msg = rc == SQLITE_OK ? nil : String(cString: sqlite3_errmsg(h))
        if let stmt { sqlite3_finalize(stmt) }
        return msg
    }

    /// 索引库的探针（`open()` 与自检共用这一条）。返回 nil 表示这个句柄上的索引确实可读。
    private static func schemaProbeError(_ h: OpaquePointer) -> String? {
        probeError(h, schemaProbeSQL)
    }

    /// 从一段文本里取 `length` 个**连续**汉字，用作自检的检索关键词样本。
    /// 为什么需要它：自检原来把关键词硬编码成「项目」/ "dmg" —— 那检验的是
    /// 「用户数据里有没有这个词」，语料里没有就报红（假红），而且它根本
    /// 没有回答「中文 2 字起能不能搜」。关键词从语料里取，才不会喊狼来了。
    static func firstCJKRun(_ text: String, length: Int = 2) -> String? {
        var run = ""
        for ch in text {
            let isCJK = ch.unicodeScalars.allSatisfy { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            run = isCJK ? run + String(ch) : ""
            if run.count >= length { return run }
        }
        return nil
    }

    // 界面看不出来功能对不对，所以把「能不能读到数据」做成可执行的自检：
    //   `本地上下文.app/Contents/MacOS/LocalVault --selftest`
    // 这同时是「只读」的证明 —— 自检里没有任何写 vault.db 的语句。

    static func selfTest() -> Int32 {
        let store = VaultStore()
        // 三通道：**通过 / 跳过 / 失败**，一个都不许合并。
        // 为什么要有「跳过」这一路：这些断言依赖索引里的数据，在没有索引的机器
        // （刚下的 dmg、假 HOME、另一台新 Mac）上必然为假。把它们记成失败是喊狼来了，
        // 记成通过则是更坏的谎 —— **`0` 不等于「没检查」**。
        // 所以走第三条通道：显式跳过 + 写明是哪条前置不成立，并在末尾汇总里点名。
        var pass = 0
        var skip = 0
        var fail = 0
        /// `unmet` 非 nil 表示**前置不成立**：这条记为「跳过」并说出原因，`ok` 不参与判定。
        /// 为 nil 时才真的执行断言。数据依赖的断言一律走这个参数，
        /// 而不是把条件写成 `false` —— 那会把「这台机器还没建索引」误报成 App 的缺陷。
        func check(_ name: String, _ ok: Bool, _ detail: String = "", unmet: String? = nil) {
            if let unmet {
                skip += 1
                print("  \u{2298} \(name)  — 跳过：\(unmet)")
                return
            }
            print(ok ? "  \u{2713} \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
                     : "  \u{2717} \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if ok { pass += 1 } else { fail += 1 }
        }
        /// 只打印、不计数 —— 给**诊断直方图**用。
        /// 为什么要有它：把诊断塞进 `check(..., true, ...)`，同一条输出就同时扮演
        /// 「打印」和「断言」两个角色，而后者**永远不可能红** —— 空洞的断言比没有断言
        /// 更糟，因为它冒充覆盖率（让人以为六级分类有一打断言守着，其实一条都没有）。
        /// 拆开之后：诊断照样看得见，「通过」里不再有假货。
        func note(_ text: String) { print("  \u{00B7} \(text)") }
        /// 显式记一次「跳过」——**不**拿一个假谓词占位。
        /// 用在「这里根本没东西可查」的分支上：写成 `check(..., false, unmet: x)` 看着像
        /// 一条会红的断言，但 `unmet` 非 nil 时那个 `false` 永远不会被判定 ——
        /// 扫描器（`scripts_check_assertions.py`）会把它当死代码抓出来，抓得对。
        func skipCheck(_ name: String, _ reason: String) {
            skip += 1
            print("  \u{2298} \(name)  — 跳过：\(reason)")
        }

        print("本地上下文 · 只读自检")
        print("  索引：\(store.dbPath)")

        // 数据类断言共同的前置。打不开 / 空库都**不构成本次通过**，
        // 但也不该记成失败：那是这台机器的状态，不是 App 的缺陷。
        // 如果索引文件**在**却打不开（损坏 / 权限 / 占位文件），下面第一条会红 ——
        // 所以跳过永远不等于把故障藏起来：那条红的断言就是故障本身。
        let indexFileExists = FileManager.default.fileExists(atPath: store.dbPath)
        // 只信 `loadError` —— 它是唯一收口点。
        //
        // 这里**曾经**自检再探一次表（task-21 加的），因为当时 `open()` 还只在
        // `sqlite3_open_v2` 的返回值上设 loadError，而它是懒打开：一个被文本文件占位的
        // vault.db 会被报成「✓ 索引已打开」+ 一片跳过。那是**旁路**：它让这条断言不再被骗，
        // 可 loadError 仍然是假的，任何读它的地方（界面路由）照旧被骗。等 `open()` 内部
        // 自己做了真读探针之后，这个旁路只剩坏处 —— 它用**自己的**打开方式（裸 `mode=ro`），
        // 于是 CLI 建好、缺 `-shm` 的干净库会被它单方面判死，而 App 其实靠 `immutable=1`
        // 回退读得好好的：一条假红。同一个「只读打开」的判定，只能有一处实现。
        let noIndex: String? = {
            if let e = store.loadError {
                return indexFileExists
                    ? "索引打不开（\(e)）—— 见上面那条失败的断言"
                    : "还没有索引文件（全新机器，还没建过索引）"
            }
            return store.totalFiles == 0 ? "索引里一条文件记录都没有（还没建过索引）" : nil
        }()
        // 「还没有索引」与「索引在、却打不开 / 根本不是数据库」是两件事：
        // 前者是全新机器的常态（跳过），后者必须红。
        check("索引已打开（只读）", store.loadError == nil,
              store.loadError ?? "",
              unmet: store.loadError != nil && !indexFileExists
                  ? "还没有索引文件（全新机器，还没建过索引）" : nil)
        check("读到文件总数", store.totalFiles > 0, "\(store.totalFiles) 个", unmet: noIndex)
        check("读到索引体量", store.totalBytes > 0,
              ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file),
              unmet: noIndex)
        check("读到索引根", !store.roots.isEmpty, store.roots.map(\.label).joined(separator: " / "),
              unmet: noIndex)
        check("读到扫描记录（含跳过目录数）", !store.lastScan.isEmpty, "", unmet: noIndex)
        let skipped = store.lastScan.reduce(Int64(0)) { $0 + $1.skippedDirs }
        // 「跳过了机器生成的目录」的前提是「语料里本来就该有机器生成的目录」。
        // 一个只有 9 个文件的桌面里一个都没有 —— 那时报红是假红（正常看起来像坏掉）。
        // 前提不成立就走第三通道，并把缺的前提说清楚：不是「跳过数为 0」，是「语料太小」。
        // 判据用与六级梯子同一个口径（语料下限 300），别为了消一条红另造一把尺子。
        let machineDirPremise: String? = noIndex
            ?? (store.totalFiles < 300
                ? "语料太小（\(store.totalFiles) 个文件）—— 这样一堆文件里本来就不该有"
                    + "机器生成的目录（node_modules / .git / build 之类），跳过口径无从检验" : nil)
        check("口径：跳过的机器生成目录", skipped > 0, "\(skipped) 个", unmet: machineDirPremise)
        check("读到类型分布", !store.kinds.isEmpty, "\(store.kinds.count) 类", unmet: noIndex)
        // 地图由建索引的那一步生成，**原生索引器不写它**（已知缺口，见 CHANGELOG）。
        // 所以「索引是 App 自己建的」时这一条是「没这项东西可读」而不是缺陷。
        let noMap: String? = noIndex ?? (store.mapText.isEmpty
            ? "索引里没有地图（meta.map）—— 原生索引器不生成它，属已知缺口" : nil)
        check("读回地图原文", !store.mapText.isEmpty, "\(store.mapText.count) 字", unmet: noMap)

        let t0 = Date()
        let assets = store.fetchTextAssets(limit: 10)
        check("能取文字资产", !assets.isEmpty, "取到 \(assets.count) 个, \(Int(Date().timeIntervalSince(t0)*1000))ms",
              unmet: noIndex)
        let noAssets: String? = noIndex
            ?? (assets.isEmpty ? "索引里取不到文字资产（limit=10）" : nil)

        // 界面用的是 limit=600，必须确认它不慢到肉眼可见 —— 否则 UI 会像卡住
        let t1 = Date()
        let many = store.fetchTextAssets(limit: 600)
        let ms = Int(Date().timeIntervalSince(t1) * 1000)
        check("界面口径 limit=600 不慢", ms < 1500, "\(many.count) 个, \(ms)ms", unmet: noAssets)
        // 关键词从**语料里取**，不再硬编码「项目」。
        // 硬编码关键词是**对用户数据内容的假设**：语料里没有这个词就报红，而它检验的
        // 其实是「有没有『项目』这个词」，不是「中文 2 字起能不能搜」。
        // 取一个真存在、且长度 ≥ 2 的词；取不到才跳过，并把缺的前提说清楚。
        let corpusKeyword = assets.compactMap { store.fullBody($0.id) }
            .compactMap { VaultStore.firstCJKRun($0, length: 2) }.first
        let noKeyword: String? = noIndex
            ?? (corpusKeyword == nil
                ? "语料里找不到两个连续汉字可作关键词 —— 「2 字起能不能搜」在这台机器上无从检验"
                : nil)
        let hits = corpusKeyword.map { store.search($0, limit: 5) } ?? []
        check("能检索中文（2 字起）", !hits.isEmpty,
              corpusKeyword.map { "「\($0)」→ 命中 \(hits.count) 个" } ?? "", unmet: noKeyword)
        let firstAsset = assets.first
        check("能取完整正文", firstAsset.map { !store.fullBody($0.id).isEmpty } ?? false,
              firstAsset?.name ?? "", unmet: noAssets)

        // ── 预览：正文 + 它的诚实标记 ────────────────────────────────
        // 这一组每一条都能答出「什么坏代码会让它红」：
        //   · bodyLength 没被 SELECT 出来 → 全为 0 → 第 1 条红
        //   · 有人把 substr(body,1,4000) 当成真实字数 → 第 4 条红
        //   · fullBody / bodyDetail 读错列或读错行 → 第 3 条红
        let lengthSample = assets.first { $0.bodyLength > 0 }
        // 采样不到 → 跳过；**采到了而 length(body) 全为 0** 仍然是硬失败（列没选出来）。
        check("bodyLength 取到了真实长度", lengthSample != nil,
              lengthSample.map { "\($0.name): \($0.bodyLength) 字" }
                  ?? "没有一条查询带回 length(body) —— 列没选",
              unmet: noAssets)

        // 样本要挑**会报字数**的那几级。`不看` 那级的理由只讲"为什么不看"，
        // 字数字在那里是噪音 —— 而 `fetchTextAssets` 是按 size DESC 排的，
        // 头一个就是 15 MB × 62 份同名同大小的 `LICENSES.chromium.html`（判「不看」）。
        // 原来直接取 first，等于拿"不报字数的那一级"去验"字数报得对不对"。
        let wordSubject = assets.first { f in
            f.bodyLength > FileTriage.bodyPreviewChars
                && FileTriage.triage([f], projectTopDirs: []).first?.triage != .excluded
        }
        // 这一组的前提是「采样到一个会报字数的文件」。采不到就不检查 ——
        // 但要在汇总里算成「未检查」，既不能悄悄消失，也不能记成通过。
        let noWordSubject: String? = noAssets ?? (wordSubject == nil
            ? "索引里没有「正文超过 \(FileTriage.bodyPreviewChars) 字、且会报字数」的文件可采样"
            : nil)
        if let f = wordSubject {
            let previewCount = f.body?.count ?? 0
            check("列表里的正文确实被截到 4000 以内",
                  previewCount <= FileTriage.bodyPreviewChars,
                  "\(f.name): 列表里 \(previewCount) 字")
            let full = store.fullBody(f.id)
            check("完整正文比列表预览长", full.count > previewCount,
                  "完整 \(full.count) vs 预览 \(previewCount)")
            let d = store.bodyDetail(f.id)
            check("bodyDetail 与 fullBody 取到同一份正文", d.body == full && !d.body.isEmpty,
                  "\(d.body.count) vs \(full.count)")

            // 最关键的一条：依据里**不许**把 4000 这个查询上限当字数说出去。
            // 修复前本机 3,342 个文件会同时显示「有可读正文（4000 字）」。
            let reasons = FileTriage.triage([f], projectTopDirs: []).first?.reasons ?? []
            let charReason = reasons.first { $0.contains("字") }
            check("依据用的是真实字数，不是 4000 上限",
                  !(charReason?.contains("（4000 字）") ?? false),
                  charReason ?? "没有字数依据")
            check("依据里报的字数与 bodyLength 一致",
                  charReason?.contains("\(f.bodyLength)") ?? false,
                  charReason ?? "没有字数依据")

            // 撞了 maxStoredBodyChars 的文件，`length(body)` 就是上限本身 ——
            // 这时报确定数字等于把上限说成事实，必须报「以上」。
            if f.bodyTruncated {
                check("撞存储上限的正文报「以上」而不是确定数",
                      charReason?.contains("以上") ?? false,
                      charReason ?? "没有字数依据")
            }

            // 反向：没撞上限的必须报确定数。一律加「以上」等于把数字废掉。
            if let exact = assets.first(where: {
                $0.bodyLength > FileTriage.bodyPreviewChars && !$0.bodyTruncated
            }) {
                let r = FileTriage.triage([exact], projectTopDirs: [])
                    .first?.reasons.first { $0.contains("字") } ?? ""
                check("没撞上限的报确定字数（不带「以上」）",
                      !r.contains("以上") && r.contains("\(exact.bodyLength)"), r)
            }
        } else {
            // 没有样本 ⇒ 这一组等于没跑：走第三通道显式说清，
            // 不拿 `false` 假装是断言（那种写法永远不会被判定）。
            skipCheck("找得到超过 4000 字、且会报字数的文件（否则上一组是空跑）",
                      noWordSubject ?? "没有采样到 —— 这组断言等于没跑")
        }

        // 不存在的 id 必须安静地返回空，不能崩 —— 卡片和详情之间有一瞬间是不同步的
        let ghost = store.bodyDetail(-1)
        check("bodyDetail 对不存在的 id 返回空而不崩",
              ghost.body.isEmpty && !ghost.truncated && !ghost.denied, "")

        // `denied` 的文件正文是空的，但原因和「二进制」完全不同，必须能区分
        if let denied = assets.first(where: { $0.bodyLength == 0 }) {
            check("无正文的文件 bodyLength 为 0", denied.bodyLength == 0, denied.name)
        }

        // 真实条陈库只能**只读**碰。
        //
        // 这里原来是 `let claims = ClaimStore()` —— 而 `ClaimStore.init` 是**读写**打开
        // 并跑 `CREATE TABLE IF NOT EXISTS`。在真实 HOME 上跑一次自检，就等于让「只读自检」
        // 去写用户的真实数据：今天侥幸没写（schema 没变，SQLite 不动文件），但哪天 schema
        // 一改，自检就会顺手迁移真实库。自检对真实数据只读，不能靠运气。
        // 现在：文件不在就是「还没有条陈库」（跳过，且**不创建**），在就用只读句柄真读一次。
        let claimsPath = ((VaultConfig.defaultDBPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("claims.db")
        let claimsExists = FileManager.default.fileExists(atPath: claimsPath)
        let claimsError = claimsExists
            ? VaultStore.openReadOnly(claimsPath, probe: "SELECT count(*) FROM claims").1 : ""
        check("条陈库可用（只读打开）", !claimsExists || claimsError.isEmpty,
              claimsExists ? claimsError : "还没有条陈库",
              unmet: !claimsExists
                  ? "还没有条陈库（全新机器，还没写过条陈）—— 这不是「打不开」，自检也不会去建它" : nil)

        // 全部在**临时库**上测，绝不碰真实条陈数据
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvault-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let probe = ClaimStore(path: tmpDir.appendingPathComponent("c.db").path)

        // 不变量 I：signed_by 不可为空、机器与人可分。
        // 顺序：先写一条，再断言「已经写进去的每一条都有签名」。
        // 原来这条排在 judge 之前、写作 `!probe.claims.isEmpty || true` —— 恒真式：
        // 空库也打印 ✓，等于什么都没测（和当初 J1「!isEmpty || true」是同一种病）。
        // 现在：没有条陈可检查就进「跳过」，不是恒真通过。
        probe.judge(targetType: "dir", target: "T", verdict: .archive)
        let unsigned = probe.claims.filter { $0.signedBy.isEmpty }
        check("人签条陈 signed_by 非空", unsigned.isEmpty,
              "共 \(probe.claims.count) 条，无签名的 \(unsigned.count) 条",
              unmet: probe.claims.isEmpty ? "还没有任何条陈可检查" : nil)
        let human = probe.claims.first { $0.target == "T" }
        check("人签的条陈有 signed_by", (human?.signedBy.isEmpty == false), probe.signer)
        check("人签标记为 human / L1", human?.actorType == "human" && human?.authority == "L1")

        // 不变量 II：只增不改 —— 同一目标判两次 = 两条历史，当前态取最新
        probe.judge(targetType: "dir", target: "T", verdict: .keep)
        let hist = probe.history(for: "T")
        check("只增不改：判两次 = 两条条陈", hist.count == 2, "\(hist.count) 条")
        check("当前态取最新", probe.verdict(for: "T")?.verdict == Verdict.keep.rawValue)

        // 不变量 II：撤回是追加，不是删除
        probe.retract(targetType: "dir", target: "T", reason: "自检")
        check("撤回后无当前判断", probe.verdict(for: "T") == nil)
        check("撤回是追加，历史变 3 条", probe.history(for: "T").count == 3,
              "\(probe.history(for: "T").count) 条")
        check("撤回不把旧判断放回来", probe.verdict(for: "T") == nil)

        // 不变量 I：机器只能写 L0
        probe.annotate(targetType: "file", target: "A.md", note: "机器候选")
        let mach = probe.claims.first { $0.target == "A.md" }
        check("机器条陈标记为 machine / L0",
              mach?.actorType == "machine" && mach?.authority == "L0",
              "\(mach?.actorType ?? "nil")/\(mach?.authority ?? "nil")")
        check("机器条陈的 signed_by 是策略名", mach?.signedBy.hasPrefix("policy:") == true,
              mach?.signedBy ?? "nil")
        check("人签与机器写可分", probe.humanCount > 0 && probe.machineCount > 0,
              "人 \(probe.humanCount) / 机器 \(probe.machineCount)")

        try? FileManager.default.removeItem(at: tmpDir)

        // ── 主动提炼的分类逻辑（新逻辑必须有断言）──
        let all = VaultQuery.allFiles(dbPath: store.dbPath, limit: 12000)
        check("分类：读到文件", !all.isEmpty, "\(all.count) 个", unmet: noIndex)
        let tTriage = Date()
        let triaged = FileTriage.triage(all, projectTopDirs: store.topDirNames)
        let triageMs = Int(Date().timeIntervalSince(tTriage) * 1000)
        // 这一节全都要有文件才有意义：没有文件时 `triaged.count == all.count`（0 == 0）
        // 和 `allSatisfy`（空集为真）都会**空真通过** —— 那正是「0 被当成通过」。
        check("分类：完成", triaged.count == all.count, "\(triaged.count) 条, \(triageMs)ms", unmet: noIndex)
        // 每一级的文件数：**既是诊断输出，也是真断言**。
        // 原来写作 `check("分类：\(tb.rawValue)", true, "\(n) 个")` —— 永远不可能红，
        // 等于用 6 行「✓」冒充了六级梯子的覆盖率。现在写成 `n > 0`：
        // 哪一级塌成空集，哪一级当场变红（分级退化 = 这个工具最值钱的部分坏了）。
        //
        // 「每一级都必须有文件」这个前提只在**语料够丰富**时成立：CLI 刚在一个只有
        // 9 个文件的桌面上建好库时，某几级为空是正常的 —— 那时报红就是喊狼来了。
        // 前提不成立就按第三通道跳过（不是通过，也不是失败）。阈值取 300：
        // 本机真实语料 9841，远在其上；比它小的语料本来也说明不了「六级是否都该出现」。
        let ladderCorpusFloor = 300
        let thinCorpus: String? = noIndex
            ?? (all.count < ladderCorpusFloor
                ? "语料太小（\(all.count) 个文件）—— 六级是否都出现，要够丰富的一堆文件才说明得了问题"
                : nil)
        let levelCounts: [(Triage, Int)] = Triage.allCases.map { tb in
            (tb, triaged.filter { $0.triage == tb }.count)
        }
        for (tb, n) in levelCounts {
            check("分类：\(tb.rawValue)（这一级在真实索引里必须有文件）", n > 0,
                  "\(n) 个", unmet: thinCorpus)
        }
        // 六级之和 = 被判断的文件总数。它守的不是 triage 本身（那由「分类：完成」守），
        // 而是**上面这个直方图的算法**：谓词写错（多一个 / 少一个条件）时，
        // 和会立刻不等于总数。
        let judgedTotal = levelCounts.reduce(0) { $0 + $1.1 }
        check("分类：六级之和 = 被判断的文件总数", judgedTotal == all.count,
              "\(judgedTotal) vs \(all.count)", unmet: noIndex)
        check("分类：结论都带理由", triaged.allSatisfy { !$0.reasons.isEmpty },
              "无理由的 \(triaged.filter { $0.reasons.isEmpty }.count) 个", unmet: noIndex)
        // 机器命名的识别：本机 239GB 相册就是这种
        check("机器命名：纯数字串", FileTriage.isMachineNamed("1000002066.jpg"))
        check("机器命名：base64 名字", FileTriage.isMachineNamed("eyJwIjoiXC9zdG9yYWdlXC9lbXVsYXRlZFwvMFwvRENJTVwvQ2FtZXJhXC9WSURfMjAyNjA5MThf.jpg"))
        check("机器命名：相机前缀", FileTriage.isMachineNamed("IMG_20260918_143726.mp4"))
        check("人类命名：中文", !FileTriage.isMachineNamed("项目台账.md"))
        check("人类命名：英文词", !FileTriage.isMachineNamed("README.md"))
        check("构建产物识别", FileTriage.isBuildArtifact("app/output/releases/foo.app/x.js"))
        // 文件**装的是什么** —— 第一版漏掉这一维，把 .dmg 判成了值得了解
        check("类型：.dmg 是安装包",
              FileTriage.infoKind(name: "ChatGPT.dmg", ext: ".dmg", rel: "Downloads/ChatGPT.dmg", kind: "other") == .installer)
        check("类型：.safetensors 是模型权重",
              FileTriage.infoKind(name: "model.safetensors", ext: ".safetensors", rel: "a/model.safetensors", kind: "data") == .model)
        check("README 是项目自己的入口文档，不是第三方资产",
              FileTriage.infoKind(name: "README.md", ext: ".md", rel: "smart_editing/README.md", kind: "doc") == .prose)

        // 通讯记录那一条原本用裸子串匹配 `"im"`，`IMG_3188.PNG` 的 `im`（来自 `img`）
        // 就被判成「通讯记录」—— 而 `.comms` 评分 95，会顶到「值得了解」最前面。
        // 实测本机 21 个文件因此误判，其中 3 个是图片。
        //
        // 四条断言各守一个失败模式。**每条都做过反证**（故意改坏 → 必须变红）：
        //   ① 守顺序：`wechat` 是长词，按子串一定会命中；若 comms 判断挪回 media 之前，
        //      这个 PNG 就会变成 .comms。用 `IMG_3188.PNG` 是**守不住**的 ——
        //      词边界修好后它压根不匹配 `im`，反证时果然没红，所以换成这条。
        //   ② 守词边界：裸 `contains` 会让 `simple` 命中 `im`。
        //   ③④ 守词表本身：把 commsTokens 清空或删掉 `im` 都能让 ①② 变绿，
        //      所以必须有正例。③ 走长词快路径，④ 走短词的词边界路径。
        check("①扩展名赢过名字猜测：名字带 wechat 的 PNG 仍是图片",
              FileTriage.infoKind(name: "wechat-export.png", ext: ".png", rel: "x/wechat-export.png", kind: "image") == .media)
        check("②短词要落在词边界上：simple 不算通讯",
              FileTriage.infoKind(name: "simple-notes.bin", ext: ".bin", rel: "x/simple-notes.bin", kind: "other") != .comms)
        check("③真的通讯记录仍然认得出（wechat 是长词，按子串走）",
              FileTriage.infoKind(name: "wechat-export.bin", ext: ".bin", rel: "x/wechat-export.bin", kind: "other") == .comms)
        check("④短词在词边界上仍认得出（im_2026 里的 im 两边都是边界）",
              FileTriage.infoKind(name: "im_2026.bin", ext: ".bin", rel: "x/im_2026.bin", kind: "other") == .comms)
        check("⑤原始事故现场：IMG_3188.PNG 是图片不是通讯记录",
              FileTriage.infoKind(name: "IMG_3188.PNG", ext: ".png", rel: "参考素材/IMG_3188.PNG", kind: "image") == .media)

        // `ext` 有两种传法：索引带点（`.png`），`URL.pathExtension` 不带点（`PNG`）。
        // 云盘走的是后者。原来只认带点的，于是云盘里**所有扩展名判断全部落空** ——
        // 每个文件都只剩名字启发式，`IMG_3188.PNG` 因此被名字里的 `im` 判成了通讯记录。
        // 两条都要有：只留带点的那条，回归了也测不出来。
        check("ext 带点：.png 是图片",
              FileTriage.infoKind(name: "a.png", ext: ".png", rel: "x/a.png", kind: "other") == .media)
        check("ext 不带点：URL.pathExtension 给的是 PNG，同样是图片",
              FileTriage.infoKind(name: "a.png", ext: "PNG", rel: "x/a.png", kind: "other") == .media)
        check("ext 不带点也要认出安装包（不是只有图片这一条路）",
              FileTriage.infoKind(name: "ChatGPT.dmg", ext: "dmg", rel: "x/ChatGPT.dmg", kind: "other") == .installer)
        check("供应商目录里的 README 是第三方资产",
              FileTriage.infoKind(name: "README.md", ext: ".md", rel: "x/node_modules/y/README.md", kind: "doc") == .vendor)
        check("NOTICE/LICENSE 是第三方资产",
              FileTriage.infoKind(name: "NOTICE.txt", ext: ".txt", rel: "a/platform-tools/NOTICE.txt", kind: "doc") == .vendor)
        check(".conf 是配置文件，不是文档",
              FileTriage.infoKind(name: "nginx.conf", ext: ".conf", rel: "同学社区/web/nginx.conf", kind: "code") == .config)
        check("认不出的扩展名不冒充文档",
              FileTriage.infoKind(name: "x.weird", ext: ".weird", rel: "a/x.weird", kind: "other") == .unknown)
        check("类型：.md 是文档笔记",
              FileTriage.infoKind(name: "README.md", ext: ".md", rel: "README.md", kind: "doc") == .prose)
        check("类型：.mp4 是媒体",
              FileTriage.infoKind(name: "trial.mp4", ext: ".mp4", rel: "a/trial.mp4", kind: "video") == .media)
        check("类型：.swift 是源代码",
              FileTriage.infoKind(name: "App.swift", ext: ".swift", rel: "x/App.swift", kind: "code") == .code)
        // 一票否决：安装包无论多新都不该是"值得了解"
        let dmgFile = VaultFile(id: 999999, root: "/tmp", rel: "Downloads/ChatGPT.dmg",
                                name: "ChatGPT.dmg", ext: ".dmg", kind: "other",
                                size: 300_000_000, mtime: Int64(Date().timeIntervalSince1970),
                                isText: false, title: nil, body: nil)
        let dmgTriage = FileTriage.triage([dmgFile]).first!
        check("安装包被判为不看（不因体积大/时间新而升值）",
              dmgTriage.triage == .excluded, dmgTriage.triage.rawValue)
        check("项目文件不误判为构建产物", !FileTriage.isBuildArtifact("项目管理/项目台账.json"))
        // 分类结果必须三种都出现，否则规则退化成"全归一类"
        // 分布诊断：三种各自的构成，便于判断规则是否退化
        for tb in Triage.allCases {
            var by: [String: Int] = [:]
            for t in triaged where t.triage == tb { by[t.infoKind.rawValue, default: 0] += 1 }
            let top = by.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let histSum = by.values.reduce(0, +)
            let n = levelCounts.first { $0.0 == tb }?.1 ?? 0
            // 构成直方图的**内部一致性**：各 infoKind 的计数之和必须等于该级文件数。
            // 它守的是这一段的谓词 —— 有人给这个 `where` 多加一个条件，和就会小于 n，红。
            // 诊断内容（top 4 构成）作为 detail 保留：「打印」和「断言」各归各位，
            // 不再由一个 `check` 兼职。
            check("分类构成：\(tb.rawValue)（各类型之和 = 该级文件数）", histSum == n,
                  "\(top) · 和 \(histSum)/\(n)", unmet: noIndex)
        }
        // 噪音理由直方图 —— 定位是哪条规则吃掉了太多文件
        var reasons: [String: Int] = [:]
        for t in triaged where t.triage == .excluded {
            for r in t.reasons where r.hasPrefix("✗") { reasons[r, default: 0] += 1 }
        }
        let topReasons = reasons.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.value)×\($0.key.replacingOccurrences(of: "✗ ", with: ""))" }
            .joined(separator: " / ")
        // 诊断，不是断言：这是「不看」级理由的分布，用来定位哪条规则吃掉了太多文件。
        // 它答不出「什么坏代码会让它失败」，所以不该出现在「通过」的计数里。
        if noIndex == nil {
            note("没用的主要理由：\(topReasons.isEmpty ? "（不看级没有任何 ✗ 理由）" : topReasons)")
        }

        check("分类：每一级在真实数据里都有文件",
              Triage.allCases.allSatisfy { tb in triaged.contains { $0.triage == tb } },
              Triage.allCases.map { tb in "\(tb.rawValue)=\(triaged.filter { $0.triage == tb }.count)" }.joined(separator: " "),
              unmet: thinCorpus)

        // ── 六级梯子：顺序 + 每级各由什么证据定 ─────────────────────
        check("梯子：rank 从 0 连续到 5，没有跳号",
              Triage.allCases.map(\.rank).sorted() == Array(0..<Triage.allCases.count),
              Triage.allCases.map { "\($0.rawValue)=\($0.rank)" }.joined(separator: " "))
        check("梯子：allCases 的声明顺序就是 rank 顺序（界面按下标渲染）",
              Triage.allCases.map(\.rank) == Triage.allCases.map(\.rank).sorted())
        check("梯子：只有前三级占注意力",
              Triage.allCases.filter { $0.drawsAttention }.map(\.rawValue) == ["务必读", "值得读", "值得扫"],
              Triage.allCases.filter { $0.drawsAttention }.map(\.rawValue).joined(separator: "/"))
        check("梯子：每级都有一句依据说法", Triage.allCases.allSatisfy { !$0.basis.isEmpty })

        // 六级梯子必须**逐级**能被构造出来的文件命中，且不串级。
        // 少了这段，任何一级退化成"永远为空"都不会有人发现 —— 那和没分级一样。
        var probeSeq = 0
        func mk(_ name: String, _ ext: String, _ rel: String, _ bodyLen: Int) -> VaultFile {
            probeSeq += 1
            let body = bodyLen > 0 ? String(repeating: "字", count: min(bodyLen, 4000)) : nil
            return VaultFile(id: Int64(900_000 + probeSeq), root: "/probe", rel: rel, name: name,
                             ext: ext, kind: "other",
                             size: Int64(bodyLen) + 10 * Int64(probeSeq),   // 各自不同，避免被判重复
                             mtime: Int64(Date().timeIntervalSince1970 * 1000),
                             isText: body != nil, title: nil, body: body,
                             bodyLength: bodyLen, bodyTruncated: bodyLen > 4000)
        }
        let ladder: [(String, VaultFile, Triage)] = [
            ("入口文档 → 务必读",                  mk("README.md", ".md", "proj/README.md", 3000), .mustRead),
            ("有实质正文的笔记 → 值得读",           mk("笔记.md", ".md", "proj/笔记.md", 3000), .readable),
            ("正文太短的笔记 → 值得扫",             mk("待办.md", ".md", "proj/待办.md", 40), .skimmable),
            ("源码 → 只检索",                      mk("main.py", ".py", "proj/main.py", 3000), .searchOnly),
            ("照片 → 待定（机器读不懂）",           mk("IMG_1.jpg", ".jpg", "proj/IMG_1.jpg", 0), .unreadable),
            ("安装包 → 不看",                      mk("X.dmg", ".dmg", "Downloads/X.dmg", 0), .excluded),
            ("依赖目录里的 md → 不看（名字再好也不算）", mk("guide.md", ".md", "proj/node_modules/p/guide.md", 3000), .excluded),
        ]
        for (label, f, want) in ladder {
            let got = FileTriage.triage([f]).first?.triage
            check("梯子：\(label)", got == want, "实得 \(got?.rawValue ?? "nil")")
        }

        // 三个新信号各自单独成立 —— 否则上面那条端到端断言可能被别的规则"顺带"修好
        check("信号：.md 的 README 算入口文档",
              FileTriage.isEntryDoc(name: "README.md", ext: ".md", rel: "p/README.md"))
        // 实测事故：`Mac操作说明 完全指南.pdf`（别人的教程）因为名字含「说明」混进了务必读
        check("信号：PDF 不算入口文档（.pdf 不能被继续编辑，是成品不是入口）",
              !FileTriage.isEntryDoc(name: "Mac操作说明 完全指南.pdf", ext: ".pdf", rel: "x/Mac操作说明 完全指南.pdf"))
        check("信号：归档目录里的台账不算入口文档",
              !FileTriage.isEntryDoc(name: "01-项目台账.md", ext: ".md", rel: "归档/项目管理-备份/项目管理/01-项目台账.md"))
        check("信号：依赖目录识别", FileTriage.inDependency("a/node_modules/b/x.js"))
        check("信号：项目目录名里含 build 的**路径段**才算构建产物，`构建` 不算",
              !FileTriage.inDependency("项目管理/项目台账.json"))
        check("信号：归档识别", FileTriage.isArchived("归档/2026/旧方案.md"))

        // ── 月度序列：必须连续 ──
        let mc = VaultQuery.monthlyActivity(dbPath: store.dbPath)
        check("月度序列：正好 12 个月（缺的补 0，不能只取有数据的）",
              mc.count == 12, "\(mc.count) 个月", unmet: noIndex)
        let mfmt = DateFormatter(); mfmt.locale = Locale(identifier: "en_US_POSIX")
        mfmt.dateFormat = "yyyy-MM"
        let mcal = Calendar(identifier: .gregorian)
        var contiguous = true
        for i in 0..<max(0, mc.count - 1) {
            guard let d = mfmt.date(from: mc[i].0),
                  let n = mcal.date(byAdding: .month, value: 1, to: d) else { contiguous = false; break }
            if mfmt.string(from: n) != mc[i + 1].0 { contiguous = false; break }
        }
        // 序列的**形状**由函数自己生成，所以在空库上也能成立；但「这个月有多少文件」
        // 在空库上恒为 0 —— 一律记成未检查，免得把空库的 12 个零当成通过。
        check("月度序列：相邻月份严格递增 1 个月", contiguous,
              mc.map { $0.0 }.joined(separator: " "), unmet: noIndex)
        check("月度序列：不出现 2000 年以前的月份（哨兵 mtime）",
              mc.allSatisfy { $0.0 >= "2000-01" },
              mc.first?.0 ?? "", unmet: noIndex)
        check("月度序列：最后一个必须是本月",
              mc.last?.0 == mfmt.string(from: Date()), mc.last?.0 ?? "", unmet: noIndex)

        // ── 检索：片段 / 命中位置 / 相关度 / 筛选 ──
        // 关键词从语料里取（真存在且重复出现），不再硬编码「邱懿武」。
        let searchKeyword = store.repeatingKeywordSample()
        let searchHits = searchKeyword
            .map { VaultQuery.searchEx(dbPath: store.dbPath, keyword: $0, limit: 40) } ?? []
        // 检索这一节的前提是「有个真能在语料里命中的词」。取不到样本、或 0 条命中时，
        // 下面那些 `allSatisfy` 全是**空真**（空集恒真）—— 看起来一片绿，其实什么也没测。
        // 注意这里报的是**缺什么前提**（没有可用的关键词样本），不是「你这台机器有问题」。
        let noHits: String? = noIndex
            ?? (searchKeyword == nil
                ? "语料里找不到「同一篇正文里出现 ≥ 2 次」的中文词可作关键词"
                    + "—— 检索这一节（片段 / 相关度 / 筛选）在这台机器上无从检验"
                : (searchHits.isEmpty
                    ? "检索「\(searchKeyword ?? "")」在这个索引里 0 条命中，片段/相关度/筛选都无从检查"
                    : nil))
        // 前提就是「有可用的关键词样本、且真能命中」—— 两样都写在 noHits 里。
        // 一台机器上的正文如果都短到抽不出样本，这里该跳过，不该报红。
        check("检索：有命中", !searchHits.isEmpty, "\(searchHits.count) 条", unmet: noHits)
        check("检索：每条都带片段（否则不知道为何命中）",
              searchHits.allSatisfy { !$0.snippet.isEmpty },
              "空片段的 \(searchHits.filter { $0.snippet.isEmpty }.count) 条", unmet: noHits)
        check("检索：命中位置都标出来了",
              searchHits.allSatisfy { ["文件名", "正文", "路径"].contains($0.matchedIn) },
              searchHits.map { $0.matchedIn }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                  .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "), unmet: noHits)
        check("检索：按相关度降序",
              zip(searchHits, searchHits.dropFirst()).allSatisfy { $0.score >= $1.score }, "",
              unmet: noHits)

        // ── 上面那条降序断言曾经**恒真**：score 读的是越界列，永远是 0，
        //    而 `0 >= 0` 为真。于是它掩盖了两个真故障：
        //      · score 永远为 0（列越界）
        //      · hitCount 读到了 score，界面把"相关度分 160"显示成「命中 160 处」
        //    教训：**只写排序方向、不写取值范围**的断言等于没写。
        //    所以下面这几条必须能因为"值不对"而失败，而不是因为"顺序不对"。
        check("检索：score 不是恒为 0（列号没漂移）",
              searchHits.contains { $0.score > 0 },
              "score 取值：\(Set(searchHits.map(\.score)).sorted())；全为 [0] 才是列越界",
              unmet: noHits)
        let legal: Set<Int> = [0, 20, 40, 60, 80, 100, 120, 140, 160]
        check("检索：score 只取合法的权重和（100/40/20 的任意组合）",
              searchHits.allSatisfy { legal.contains($0.score) },
              "越界值：\(Set(searchHits.map(\.score)).subtracting(legal))", unmet: noHits)
        // J1：hitCount 必须是**关键词在正文里出现的次数**。
        // 原来的断言是 `hitCount <= 5_000` —— 恒真：相关度权重和只可能是
        // 100/120/140/160，全都 ≤ 5000。它挡不住它标题里声称要挡的那件事，
        // 和之前那条 `score >= score` 是同一种病：**看起来在断言，其实什么都没测**。
        //
        // 现在改成**等式**：另查一次完整正文（searchEx 返回的 VaultFile.body 是 nil，
        // 它不取正文），用和 SQL 完全相同的口径（lower + 非重叠出现次数）重数一遍，
        // 逐条相等才算过。值不对（例如读到了 score 列）就一定失败。
        func occurrences(of needle: String, in haystack: String) -> Int {
            guard !needle.isEmpty else { return 0 }
            return max(0, haystack.lowercased().components(separatedBy: needle.lowercased()).count - 1)
        }
        let recountKeyword = searchKeyword ?? ""
        let bodyHit = searchHits.first { $0.matchedIn == "正文" && $0.hitCount > 0 }
        let recounted = bodyHit.map { occurrences(of: recountKeyword, in: store.fullBody($0.file.id)) }
        check("检索：hitCount 是「出现次数」，不是相关度分（等式：重数正文 = hitCount）",
              bodyHit != nil && recounted == bodyHit?.hitCount,
              bodyHit.map { "\($0.file.name)：hitCount=\($0.hitCount)，重数=\(recounted ?? -1)" }
                  ?? "没有「正文」命中可重数 —— 这条断言不能空过",
              unmet: noHits)
        // 互补的一条：确实存在「命中数 > 1 且**不可能是任何合法 score**」的值。
        // 用**全部合法 score 取值**（100/40/20 的任意组合 = 上面那个 legal 集合）来排除，
        // 而不是只用 {100,120,140,160} —— 后者会漏掉 score=40/20 的命中：
        // 实测按历史 bug 让 hitCount 读 score 列时，取值恰好是 [40, 160]，只查那四个数是抓不住的。
        check("检索：存在命中数 >1 且不可能是 score（列号漂移会被抓出来）",
              searchHits.contains { $0.hitCount > 1 && !legal.contains($0.hitCount) },
              "hitCount 取值：\(Set(searchHits.map(\.hitCount)).sorted())；合法 score 集合：\(legal.sorted())",
              unmet: noHits)
        // 标为「正文」命中，片段里就必须真的有关键词 ——
        // 否则说明它悄悄退回了兜底语（那意味着正文片段这一路已经坏了）。
        let textHits = searchHits.filter { $0.matchedIn == "正文" }
        let snippetsWithoutKeyword = textHits.filter {
            !$0.snippet.lowercased().contains(recountKeyword.lowercased())
        }
        check("检索：标为「正文」命中的片段里确实有关键词（不是兜底语）",
              !textHits.isEmpty && snippetsWithoutKeyword.isEmpty,
              "正文命中 \(textHits.count) 条，片段里没关键词的 \(snippetsWithoutKeyword.count) 条",
              unmet: noHits)
        check("检索：至少有一条命中数 >1（说明确实在数出现次数）",
              searchHits.contains { $0.hitCount > 1 },
              "最大 \(searchHits.map(\.hitCount).max() ?? 0) 次；全为 ≤1 才说明没在数出现次数",
              unmet: noHits)

        // 无正文文件必须也能被搜到 —— 本机有 2,202 个这种文件
        //（口径 `gone=0 AND length(body)=0`，2026-10-01 实测；
        //  按 `is_text=0` 算是 2,106 个 —— 两个口径不是一个数，别混用）
        //
        // 关键词同样从语料里取：原来是硬编码 "dmg"。改成先找一个**真的没有正文**的文件，
        // 拿它名字里的一段去搜 —— 样本保证存在，断言才是在检验「无正文能不能被搜到」。
        let bodylessFile = store.firstBodylessFile()
        let bodylessKeyword: String? = bodylessFile.flatMap { f -> String? in
            let stem = (f.name as NSString).deletingPathExtension
            return stem.count >= 2 ? stem : nil
        }
        // 前提不成立（语料里没有无正文文件）⇒ 跳过，而且原因要说清是**没有这种文件**，
        // 不是「搜不到」——「搜不到」是故障，「没有样本」不是。
        let noBodyless: String? = noIndex
            ?? (bodylessFile == nil
                ? "这个语料里没有无正文的文件（口径 gone=0 且 length(body)=0）"
                    + "—— 无正文这个场景在这台机器上无从检验"
                : (bodylessKeyword == nil
                    ? "无正文文件的名字短于 2 个字，没法按文件名搜" : nil))
        let byName = bodylessKeyword
            .map { VaultQuery.searchEx(dbPath: store.dbPath, keyword: $0, limit: 20) } ?? []
        check("检索：无正文的文件靠文件名也能搜到",
              byName.contains { $0.matchedIn == "文件名" },
              byName.first.map { "「\(bodylessKeyword ?? "")」→ \($0.file.name) ← \($0.matchedIn)" } ?? "无命中",
              unmet: noBodyless)
        // 兜底片段：这一列曾经读到越界列号、永远为空，
        // 于是这个兜底在 2,202 个无正文文件上从来没生效过。
        check("检索：无正文文件落到「一句话索引」兜底上（不是空片段）",
              byName.contains { !$0.file.isText && !$0.snippet.isEmpty },
              byName.first(where: { !$0.file.isText })
                  .map { "\($0.file.name) → \($0.snippet.prefix(40))" } ?? "没有无正文命中",
              unmet: noBodyless)
        // J2/J3：兜底片段必须是「一句说明」，不是把 name · kind · rel 重拼一遍。
        // 断言逐项等于实现约定，任何一项改了都会失败：
        //   · 前缀「没有正文（」+ 中文类型名 —— 不许出现裸英文 kind
        //   · 后缀「）；靠文件名或路径命中」—— 说明它为什么会被搜到
        //   · 不含 rel（路径）和裸 kind —— 那两样结果行自己已经显示了，重拼 = 零新信息
        let bodylessHits = byName.filter { !$0.file.isText }
        check("检索：无正文文件的兜底片段不重拼 rel / 裸 kind（J2/J3）",
              !bodylessHits.isEmpty && bodylessHits.allSatisfy { h in
                  h.snippet.hasPrefix("没有正文（")
                      && h.snippet.hasSuffix("）；靠文件名或路径命中")
                      && !h.snippet.contains(h.file.rel)
                      && !h.snippet.contains(h.file.kind)
              },
              bodylessHits.first.map { "\($0.file.name) → \($0.snippet)" } ?? "没有无正文命中",
              unmet: noBodyless)
        // 筛选
        // 筛选断言必须**既有命中又全部合规**。
        // 只写 allSatisfy 的话，返回 0 条也能通过 —— 那是空真，等于没测。
        let sampleKind = searchHits.first?.file.kind ?? "doc"
        var kindOnly = VaultQuery.SearchFilter(); kindOnly.kinds = [sampleKind]
        let byKind = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                         limit: 40, filter: kindOnly)
        check("检索：类型筛选既有命中又全部合规",
              !byKind.isEmpty && byKind.allSatisfy { $0.file.kind == sampleKind },
              "kind=\(sampleKind) → \(byKind.count) 条",
              unmet: noIndex ?? (byKind.isEmpty ? "kind=\(sampleKind) 筛不出任何命中，合规无从检查" : nil))

        let sampleDays = max(1, (searchHits.map(\.file.daysSince).filter { $0 >= 0 }.min() ?? 7))
        var sinceOnly = VaultQuery.SearchFilter(); sinceOnly.sinceDays = sampleDays
        let byTime = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                         limit: 40, filter: sinceOnly)
        check("检索：时间筛选既有命中又全部合规",
              !byTime.isEmpty && byTime.allSatisfy { $0.file.daysSince >= 0 && $0.file.daysSince <= sampleDays },
              "近 \(sampleDays) 天 → \(byTime.count) 条",
              unmet: noIndex ?? (byTime.isEmpty ? "近 \(sampleDays) 天筛不出任何命中，合规无从检查" : nil))

        // 目录筛选：用命中里出现最多的那个顶层目录
        let dirSample = searchHits.first { $0.file.rel.contains("/") }
        let topDir = dirSample.flatMap { $0.file.rel.split(separator: "/").first.map(String.init) }
        var byDirOK = false
        var byDirCount = 0
        if let topDir {
            var dirOnly = VaultQuery.SearchFilter(); dirOnly.topDir = topDir
            let byDir = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                            limit: 40, filter: dirOnly)
            byDirCount = byDir.count
            byDirOK = !byDir.isEmpty && byDir.allSatisfy { $0.file.rel.hasPrefix(topDir + "/") }
        }
        check("检索：目录筛选既有命中又全部合规", byDirOK,
              "目录 \(topDir ?? "—") → \(byDirCount) 条",
              unmet: noHits ?? (topDir == nil ? "命中里没有带目录的文件可取样" : nil))
        // 统计用 COUNT
        // 「无正文」这两条的前提是「语料里真有不是文字的文件」。
        // 判据用**扩展名**，不用 `is_text`/`body` —— 那两个正是被检查的列，
        // 拿它们当前提就成了「断言自己证明自己」（按 is_text 判 premise 时，
        // 这个列一旦坏掉，前提也跟着假掉，于是跳过、永远不红）。
        let textExts: Set<String> = ["md", "markdown", "txt", "text", "swift", "js", "mjs", "cjs",
                                     "ts", "tsx", "jsx", "json", "csv", "tsv", "html", "htm", "css",
                                     "scss", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh",
                                     "yaml", "yml", "xml", "plist", "rtf", "log", "sql", "toml", "ini"]
        // 注意 `ext` 在库里带点（实测是 ".md"），别拿它直接和集合比 —— 差一个点就会
        // 把「纯文本文档的语料」判成「有二进制文件」，于是前提假成立、又变回一条假红。
        let extKey: (String) -> String = { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let corpusHasBinary = all.contains { !textExts.contains(extKey($0.ext)) }
        let noBinaryInCorpus: String? = noIndex
            ?? (corpusHasBinary ? nil
                : "这个语料里每个文件都是文本类（按扩展名看）—— 「无正文文件数」"
                    + "和两个口径的差额在这台机器上无从检验")
        check("统计：有正文文件数用 COUNT", store.textFileCount > 0, "\(store.textFileCount) 个",
              unmet: noIndex)
        check("统计：无正文文件数", store.totalFiles - store.textFileCount > 0,
              "\(store.totalFiles - store.textFileCount) 个", unmet: noBinaryInCorpus)

        // J4：「无正文」有两个口径，不是一个数，说哪个就必须说清是哪个。
        //   body 为空 = `gone=0 AND length(body)=0` —— 2026-10-01 实测 2,202 个
        //   is_text=0 = `gone=0 AND is_text=0`        —— 2026-10-01 实测 2,106 个
        // 差额 96 个是「是文字类但超限没抽取、body 存空串」的大文件。
        // 下面的断言把两个数都打出来（用真值，不写死），并守住它们的包含关系。
        let bodyEmpty = Int(VaultQuery.scalar(
            dbPath: store.dbPath,
            sql: "SELECT count(*) FROM files WHERE gone=0 AND length(body)=0"))
        let notText = Int(VaultQuery.scalar(
            dbPath: store.dbPath,
            sql: "SELECT count(*) FROM files WHERE gone=0 AND is_text=0"))
        check("口径：无正文有两个数（body 为空 / is_text=0），必须说清用哪个",
              bodyEmpty >= notText && notText > 0,
              "body 为空 \(bodyEmpty) 个 · is_text=0 \(notText) 个 · 差额 \(bodyEmpty - notText) 个是文字类但超限未抽取",
              unmet: noBinaryInCorpus)

        // mtime 单位：索引里是毫秒。错当秒会让满屏都是"0 天前"。
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fresh = VaultFile(id: 1, root: "/tmp", rel: "a.txt", name: "a.txt", ext: ".txt",
                              kind: "doc", size: 10, mtime: nowMs, isText: true, title: nil, body: "x")
        check("mtime：毫秒被正确解释（今天）", fresh.daysSince == 0, "\(fresh.daysSince) 天")
        let old = Int64((Date().timeIntervalSince1970 - 86_400 * 10) * 1000)
        let tenDays = VaultFile(id: 2, root: "/tmp", rel: "b.txt", name: "b.txt", ext: ".txt",
                                kind: "doc", size: 10, mtime: old, isText: true, title: nil, body: "x")
        check("mtime：10 天前算得出来", tenDays.daysSince == 10, "\(tenDays.daysSince) 天")
        let sentinel = VaultFile(id: 3, root: "/tmp", rel: "c.txt", name: "c.txt", ext: ".txt",
                                 kind: "doc", size: 10, mtime: 500_000_000_000,
                                 isText: true, title: nil, body: "x")
        check("哨兵时间戳（1985-10-26）被识别为不可信",
              !sentinel.hasSaneMtime && sentinel.daysSince == -1, sentinel.mtimeText)

        // ── 云盘：复制不移动、重名不覆盖（在临时目录里测，不碰真实云盘）──
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lv-drive-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        DriveStore.ensureStructure(root: tmp)
        let madeFolders = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        check("云盘：建出默认子文件夹",
              // 非空守卫：`allSatisfy` 在空集合上恒真。`defaultFolders` 现在是 3 个字面量、
              // 不可能为空，但那要靠**看代码**才知道；写进断言才是可判定的（扫描器也才没话说）。
              !DriveStore.defaultFolders.isEmpty
                  && DriveStore.defaultFolders.allSatisfy { madeFolders.contains($0) },
              madeFolders.sorted().joined(separator: " / "))

        // 造一个源文件
        let src = tmp.appendingPathComponent("来源-不要在云盘里.txt")
        try? "原始内容".write(to: src, atomically: true, encoding: .utf8)
        let srcRel = src.path

        let r1 = DriveStore.ingest([src], into: DriveStore.defaultFolders[0], root: tmp)
        check("云盘：放入成功", r1.ok == 1 && r1.failed == 0, r1.message)
        check("云盘：**原文件还在**（是复制不是移动）",
              FileManager.default.fileExists(atPath: srcRel))
        let d1 = tmp.appendingPathComponent("\(DriveStore.defaultFolders[0])/来源-不要在云盘里.txt")
        check("云盘：目标位置有文件", FileManager.default.fileExists(atPath: d1.path))

        // 再放一次同名文件 —— 不能覆盖
        let r2 = DriveStore.ingest([src], into: DriveStore.defaultFolders[0], root: tmp)
        check("云盘：重名第二次也能放入", r2.ok == 1, r2.message)
        let d2 = tmp.appendingPathComponent("\(DriveStore.defaultFolders[0])/来源-不要在云盘里-2.txt")
        check("云盘：重名不覆盖，改名为 -2",
              FileManager.default.fileExists(atPath: d2.path))
        let still = (try? String(contentsOf: d1, encoding: .utf8)) ?? ""
        check("云盘：第一个文件内容未被改动", still == "原始内容")

        // 路径注入防护
        DriveStore.createFolder("../逃逸尝试", root: tmp)
        let escaped = tmp.deletingLastPathComponent().appendingPathComponent("逃逸尝试")
        check("云盘：文件夹名里的 .. 不会逃出根目录",
              !FileManager.default.fileExists(atPath: escaped.path))

        try? FileManager.default.removeItem(at: tmp)

        // 只读证明：对 vault.db 执行写操作必须失败。
        // 但探针要先有句柄才谈得上「证明只读」：索引没打开时它返回 false，
        // 那不是「写成功了」，而是**没有可执行的对象** —— 记跳过，不记失败。
        let blocked = store.attemptWriteProbe()
        check("对索引的写操作被拒绝（只读）", blocked, blocked ? "" : "竟然写成功了——只读纪律没生效！",
              unmet: store.loadError != nil ? "索引没打开，写探针没有可执行的对象" : nil)

        // 汇总必须三分量，且**跳过不许被读成通过**。
        print("")
        print("通过 \(pass) · 跳过 \(skip) · 失败 \(fail)"
              + (skip > 0 ? " —— 有 \(skip) 项未检查，不构成本次通过" : ""))
        // 退出码三态，任何两个都不许混：
        //   0 = 全通过（一个跳过都没有）
        //   1 = 有失败（沿用原来的码，CI 与脚本一直这么认）
        //   3 = 没失败但有未检查 —— 非 0，所以任何把「非 0 当失败」的脚本也不会漏掉
        if fail > 0 {
            print("自检未通过：\(fail) 项失败。")
            return 1
        }
        if skip > 0 {
            print("自检未完成：\(skip) 项没检查 —— 这不等于通过。")
            return 3
        }
        print("自检通过。")
        return 0
    }

    /// 顶层目录（用于浏览树）
    func topMaps() -> [(String, Int, Int64)] {
        guard let db else { return [] }
        let sql = """
            SELECT replace(substr(rel,1,instr(rel||'/','/')-1), rtrim(substr(rel,1,instr(rel||'/','/')-1),'/'), '') AS top,
                   count(*), coalesce(sum(size),0)
            FROM files WHERE gone=0 GROUP BY top ORDER BY count(*) DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [(String, Int, Int64)] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let t = text(s, 0)
            if t.isEmpty { continue }
            out.append((t, Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2)))
        }
        return out
    }
}
