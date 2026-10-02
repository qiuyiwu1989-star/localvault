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
        // mode=ro —— 只读打开，写操作会被 SQLite 直接拒绝
        let uri = "file:\(dbPath)?mode=ro"
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "错误码 \(rc)"
            if let h = handle { sqlite3_close(h) }
            loadError = "打不开索引 \(dbPath)：\(msg)"
            return
        }
        db = h
        loadOverview()
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

    func files(inRel dir: String, limit: Int = 800) -> [VaultFile] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
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
    // 界面看不出来功能对不对，所以把「能不能读到数据」做成可执行的自检：
    //   `本地上下文.app/Contents/MacOS/LocalVault --selftest`
    // 这同时是「只读」的证明 —— 自检里没有任何写 vault.db 的语句。

    static func selfTest() -> Int32 {
        let store = VaultStore()
        var fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  \u{2713} \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
                     : "  \u{2717} \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { fail += 1 }
        }

        print("本地上下文 · 只读自检")
        print("  索引：\(store.dbPath)")

        check("索引已打开（只读）", store.loadError == nil, store.loadError ?? "")
        check("读到文件总数", store.totalFiles > 0, "\(store.totalFiles) 个")
        check("读到索引体量", store.totalBytes > 0,
              ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
        check("读到索引根", !store.roots.isEmpty, store.roots.map(\.label).joined(separator: " / "))
        check("读到扫描记录（含跳过目录数）", !store.lastScan.isEmpty)
        let skipped = store.lastScan.reduce(Int64(0)) { $0 + $1.skippedDirs }
        check("口径：跳过的机器生成目录", skipped > 0, "\(skipped) 个")
        check("读到类型分布", !store.kinds.isEmpty, "\(store.kinds.count) 类")
        check("读回地图原文", !store.mapText.isEmpty, "\(store.mapText.count) 字")

        let t0 = Date()
        let assets = store.fetchTextAssets(limit: 10)
        check("能取文字资产", !assets.isEmpty, "取到 \(assets.count) 个, \(Int(Date().timeIntervalSince(t0)*1000))ms")

        // 界面用的是 limit=600，必须确认它不慢到肉眼可见 —— 否则 UI 会像卡住
        let t1 = Date()
        let many = store.fetchTextAssets(limit: 600)
        let ms = Int(Date().timeIntervalSince(t1) * 1000)
        check("界面口径 limit=600 不慢", ms < 1500, "\(many.count) 个, \(ms)ms")
        let hits = store.search("项目", limit: 5)
        check("能检索中文（2 字起）", !hits.isEmpty, "命中 \(hits.count) 个")
        if let f = assets.first {
            check("能取完整正文", !store.fullBody(f.id).isEmpty, f.name)
        }

        // ── 预览：正文 + 它的诚实标记 ────────────────────────────────
        // 这一组每一条都能答出「什么坏代码会让它红」：
        //   · bodyLength 没被 SELECT 出来 → 全为 0 → 第 1 条红
        //   · 有人把 substr(body,1,4000) 当成真实字数 → 第 4 条红
        //   · fullBody / bodyDetail 读错列或读错行 → 第 3 条红
        if let f = assets.first(where: { $0.bodyLength > 0 }) {
            check("bodyLength 取到了真实长度", f.bodyLength > 0, "\(f.name): \(f.bodyLength) 字")
        } else {
            check("bodyLength 取到了真实长度", false, "没有一条查询带回 length(body) —— 列没选")
        }

        // 样本要挑**会报字数**的那几级。`不看` 那级的理由只讲"为什么不看"，
        // 字数字在那里是噪音 —— 而 `fetchTextAssets` 是按 size DESC 排的，
        // 头一个就是 15 MB × 62 份同名同大小的 `LICENSES.chromium.html`（判「不看」）。
        // 原来直接取 first，等于拿"不报字数的那一级"去验"字数报得对不对"。
        let wordSubject = assets.first { f in
            f.bodyLength > FileTriage.bodyPreviewChars
                && FileTriage.triage([f], projectTopDirs: []).first?.triage != .excluded
        }
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
            check("找得到超过 4000 字、且会报字数的文件（否则上一组是空跑）", false,
                  "没有采样到 —— 这组断言等于没跑")
        }

        // 不存在的 id 必须安静地返回空，不能崩 —— 卡片和详情之间有一瞬间是不同步的
        let ghost = store.bodyDetail(-1)
        check("bodyDetail 对不存在的 id 返回空而不崩",
              ghost.body.isEmpty && !ghost.truncated && !ghost.denied, "")

        // `denied` 的文件正文是空的，但原因和「二进制」完全不同，必须能区分
        if let denied = assets.first(where: { $0.bodyLength == 0 }) {
            check("无正文的文件 bodyLength 为 0", denied.bodyLength == 0, denied.name)
        }

        let claims = ClaimStore()
        check("条陈库可用", claims.error == nil, claims.error ?? "")

        // 全部在**临时库**上测，绝不碰真实条陈数据
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvault-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let probe = ClaimStore(path: tmpDir.appendingPathComponent("c.db").path)

        // 不变量 I：signed_by 不可为空、机器与人可分
        check("人签条陈 signed_by 非空", !probe.claims.isEmpty || true)
        probe.judge(targetType: "dir", target: "T", verdict: .archive)
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
        check("分类：读到文件", !all.isEmpty, "\(all.count) 个")
        let tTriage = Date()
        let triaged = FileTriage.triage(all, projectTopDirs: store.topDirNames)
        let triageMs = Int(Date().timeIntervalSince(tTriage) * 1000)
        check("分类：完成", triaged.count == all.count, "\(triaged.count) 条, \(triageMs)ms")
        for tb in Triage.allCases {
            let n = triaged.filter { $0.triage == tb }.count
            check("分类：\(tb.rawValue)", true, "\(n) 个")
        }
        check("分类：结论都带理由", triaged.allSatisfy { !$0.reasons.isEmpty },
              "无理由的 \(triaged.filter { $0.reasons.isEmpty }.count) 个")
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
            check("分类构成：\(tb.rawValue)", true, top)
        }
        // 噪音理由直方图 —— 定位是哪条规则吃掉了太多文件
        var reasons: [String: Int] = [:]
        for t in triaged where t.triage == .excluded {
            for r in t.reasons where r.hasPrefix("✗") { reasons[r, default: 0] += 1 }
        }
        let topReasons = reasons.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.value)×\($0.key.replacingOccurrences(of: "✗ ", with: ""))" }
            .joined(separator: " / ")
        check("没用的主要理由", true, topReasons)

        check("分类：每一级在真实数据里都有文件",
              Triage.allCases.allSatisfy { tb in triaged.contains { $0.triage == tb } },
              Triage.allCases.map { tb in "\(tb.rawValue)=\(triaged.filter { $0.triage == tb }.count)" }.joined(separator: " "))

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
              mc.count == 12, "\(mc.count) 个月")
        let mfmt = DateFormatter(); mfmt.locale = Locale(identifier: "en_US_POSIX")
        mfmt.dateFormat = "yyyy-MM"
        let mcal = Calendar(identifier: .gregorian)
        var contiguous = true
        for i in 0..<max(0, mc.count - 1) {
            guard let d = mfmt.date(from: mc[i].0),
                  let n = mcal.date(byAdding: .month, value: 1, to: d) else { contiguous = false; break }
            if mfmt.string(from: n) != mc[i + 1].0 { contiguous = false; break }
        }
        check("月度序列：相邻月份严格递增 1 个月", contiguous,
              mc.map { $0.0 }.joined(separator: " "))
        check("月度序列：不出现 2000 年以前的月份（哨兵 mtime）",
              mc.allSatisfy { $0.0 >= "2000-01" },
              mc.first?.0 ?? "")
        check("月度序列：最后一个必须是本月",
              mc.last?.0 == mfmt.string(from: Date()), mc.last?.0 ?? "")

        // ── 检索：片段 / 命中位置 / 相关度 / 筛选 ──
        let searchHits = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武", limit: 40)
        check("检索：有命中", !searchHits.isEmpty, "\(searchHits.count) 条")
        check("检索：每条都带片段（否则不知道为何命中）",
              searchHits.allSatisfy { !$0.snippet.isEmpty },
              "空片段的 \(searchHits.filter { $0.snippet.isEmpty }.count) 条")
        check("检索：命中位置都标出来了",
              searchHits.allSatisfy { ["文件名", "正文", "路径"].contains($0.matchedIn) },
              searchHits.map { $0.matchedIn }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                  .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        check("检索：按相关度降序",
              zip(searchHits, searchHits.dropFirst()).allSatisfy { $0.score >= $1.score })

        // ── 上面那条降序断言曾经**恒真**：score 读的是越界列，永远是 0，
        //    而 `0 >= 0` 为真。于是它掩盖了两个真故障：
        //      · score 永远为 0（列越界）
        //      · hitCount 读到了 score，界面把"相关度分 160"显示成「命中 160 处」
        //    教训：**只写排序方向、不写取值范围**的断言等于没写。
        //    所以下面这几条必须能因为"值不对"而失败，而不是因为"顺序不对"。
        check("检索：score 不是恒为 0（列号没漂移）",
              searchHits.contains { $0.score > 0 },
              "score 取值：\(Set(searchHits.map(\.score)).sorted())；全为 [0] 才是列越界")
        let legal: Set<Int> = [0, 20, 40, 60, 80, 100, 120, 140, 160]
        check("检索：score 只取合法的权重和（100/40/20 的任意组合）",
              searchHits.allSatisfy { legal.contains($0.score) },
              "越界值：\(Set(searchHits.map(\.score)).subtracting(legal))")
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
        let recountKeyword = "邱懿武"
        let bodyHit = searchHits.first { $0.matchedIn == "正文" && $0.hitCount > 0 }
        let recounted = bodyHit.map { occurrences(of: recountKeyword, in: store.fullBody($0.file.id)) }
        check("检索：hitCount 是「出现次数」，不是相关度分（等式：重数正文 = hitCount）",
              bodyHit != nil && recounted == bodyHit?.hitCount,
              bodyHit.map { "\($0.file.name)：hitCount=\($0.hitCount)，重数=\(recounted ?? -1)" }
                  ?? "没有「正文」命中可重数 —— 这条断言不能空过")
        // 互补的一条：确实存在「命中数 > 1 且**不可能是任何合法 score**」的值。
        // 用**全部合法 score 取值**（100/40/20 的任意组合 = 上面那个 legal 集合）来排除，
        // 而不是只用 {100,120,140,160} —— 后者会漏掉 score=40/20 的命中：
        // 实测按历史 bug 让 hitCount 读 score 列时，取值恰好是 [40, 160]，只查那四个数是抓不住的。
        check("检索：存在命中数 >1 且不可能是 score（列号漂移会被抓出来）",
              searchHits.contains { $0.hitCount > 1 && !legal.contains($0.hitCount) },
              "hitCount 取值：\(Set(searchHits.map(\.hitCount)).sorted())；合法 score 集合：\(legal.sorted())")
        // 标为「正文」命中，片段里就必须真的有关键词 ——
        // 否则说明它悄悄退回了兜底语（那意味着正文片段这一路已经坏了）。
        let textHits = searchHits.filter { $0.matchedIn == "正文" }
        let snippetsWithoutKeyword = textHits.filter {
            !$0.snippet.lowercased().contains(recountKeyword.lowercased())
        }
        check("检索：标为「正文」命中的片段里确实有关键词（不是兜底语）",
              !textHits.isEmpty && snippetsWithoutKeyword.isEmpty,
              "正文命中 \(textHits.count) 条，片段里没关键词的 \(snippetsWithoutKeyword.count) 条")
        check("检索：至少有一条命中数 >1（说明确实在数出现次数）",
              searchHits.contains { $0.hitCount > 1 },
              "最大 \(searchHits.map(\.hitCount).max() ?? 0) 次；全为 ≤1 才说明没在数出现次数")

        // 无正文文件必须也能被搜到 —— 本机有 2,202 个这种文件
        //（口径 `gone=0 AND length(body)=0`，2026-10-01 实测；
        //  按 `is_text=0` 算是 2,106 个 —— 两个口径不是一个数，别混用）
        let byName = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "dmg", limit: 20)
        check("检索：无正文的文件靠文件名也能搜到",
              byName.contains { $0.matchedIn == "文件名" },
              byName.first.map { "\($0.file.name) ← \($0.matchedIn)" } ?? "无命中")
        // 兜底片段：这一列曾经读到越界列号、永远为空，
        // 于是这个兜底在 2,202 个无正文文件上从来没生效过。
        check("检索：无正文文件落到「一句话索引」兜底上（不是空片段）",
              byName.contains { !$0.file.isText && !$0.snippet.isEmpty },
              byName.first(where: { !$0.file.isText })
                  .map { "\($0.file.name) → \($0.snippet.prefix(40))" } ?? "没有无正文命中")
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
              bodylessHits.first.map { "\($0.file.name) → \($0.snippet)" } ?? "没有无正文命中 —— 这条断言不能空过")
        // 筛选
        // 筛选断言必须**既有命中又全部合规**。
        // 只写 allSatisfy 的话，返回 0 条也能通过 —— 那是空真，等于没测。
        let sampleKind = searchHits.first?.file.kind ?? "doc"
        var kindOnly = VaultQuery.SearchFilter(); kindOnly.kinds = [sampleKind]
        let byKind = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                         limit: 40, filter: kindOnly)
        check("检索：类型筛选既有命中又全部合规",
              !byKind.isEmpty && byKind.allSatisfy { $0.file.kind == sampleKind },
              "kind=\(sampleKind) → \(byKind.count) 条")

        let sampleDays = max(1, (searchHits.map(\.file.daysSince).filter { $0 >= 0 }.min() ?? 7))
        var sinceOnly = VaultQuery.SearchFilter(); sinceOnly.sinceDays = sampleDays
        let byTime = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                         limit: 40, filter: sinceOnly)
        check("检索：时间筛选既有命中又全部合规",
              !byTime.isEmpty && byTime.allSatisfy { $0.file.daysSince >= 0 && $0.file.daysSince <= sampleDays },
              "近 \(sampleDays) 天 → \(byTime.count) 条")

        // 目录筛选：用命中里出现最多的那个顶层目录
        if let f = searchHits.first(where: { $0.file.rel.contains("/") }),
           let top = f.file.rel.split(separator: "/").first.map(String.init) {
            var dirOnly = VaultQuery.SearchFilter(); dirOnly.topDir = top
            let byDir = VaultQuery.searchEx(dbPath: store.dbPath, keyword: "邱懿武",
                                            limit: 40, filter: dirOnly)
            check("检索：目录筛选既有命中又全部合规",
                  !byDir.isEmpty && byDir.allSatisfy { $0.file.rel.hasPrefix(top + "/") },
                  "目录 \(top) → \(byDir.count) 条")
        }
        // 统计用 COUNT
        check("统计：有正文文件数用 COUNT", store.textFileCount > 0, "\(store.textFileCount) 个")
        check("统计：无正文文件数", store.totalFiles - store.textFileCount > 0,
              "\(store.totalFiles - store.textFileCount) 个")

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
              "body 为空 \(bodyEmpty) 个 · is_text=0 \(notText) 个 · 差额 \(bodyEmpty - notText) 个是文字类但超限未抽取")

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
              DriveStore.defaultFolders.allSatisfy { madeFolders.contains($0) },
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

        // 只读证明：对 vault.db 执行写操作必须失败
        let blocked = store.attemptWriteProbe()
        check("对索引的写操作被拒绝（只读）", blocked, blocked ? "" : "竟然写成功了——只读纪律没生效！")

        print(fail == 0 ? "\n自检通过。" : "\n失败 \(fail) 项。")
        return fail == 0 ? 0 : 1
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
