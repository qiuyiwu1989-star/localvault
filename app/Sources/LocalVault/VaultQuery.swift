import Foundation
import SQLite3

/// 线程安全的只读查询。
///
/// **为什么单独一层**：SQLite 连接不能跨线程共享，而界面查询必须放到**后台线程**。
/// 之前为了修一个 @State 不更新的 bug，我把查询留在了主线程（`@MainActor`）——
/// 结果是界面直接卡住。正确做法是两件事分开：
///   后台线程查询  +  主线程更新状态。
///
/// 每次调用开一个只读连接、查完即关，是 SQLite 的惯用做法：代价极小，换来彻底线程安全。
/// `VaultFile` 全是值类型，天然可跨线程传递。
enum VaultQuery {

    /// 开一个**只读**连接跑一段查询，结束即关。
    ///
    /// 打开方式必须走 `VaultStore.openReadOnly` —— **不要**在这里另写一遍 `mode=ro`。
    /// 原因是实测出来的：CLI 干净收尾后的库是 WAL 模式、且没有 `-shm`，只读连接
    /// 创建不了 wal-index，于是这里返回 nil、界面显示「0 个文件」，而 store 那边
    /// 明明读到了 9 个 —— 一个能读的库被这条路读成空的。同一个「只读打开」的判定
    /// 只允许有一处实现，否则修好一处、另一处继续制造假绿。
    private static func withConnection<T>(_ dbPath: String, _ body: (OpaquePointer) -> T) -> T? {
        guard let db = VaultStore.openReadOnly(dbPath).0 else { return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    private static func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
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

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    /// 预览用的正文，**连同它的两个诚实标记一起回来**。
    ///
    /// 为什么不能只取 `body`：`body` 空有三种完全不同的原因，界面必须说得清是哪一种，
    /// 否则就是把上限或策略当成事实——
    ///   · `truncated=1` —— 撞到单篇 40 万字符上限，索引里存的**不是全文**（本机 20 个）
    ///   · `denied=1`    —— 按规则不读正文，只有元数据（本机 16 个）
    ///   · 其余为空      —— 二进制、或文字类但超限未抽取（本机 2,202 个）
    struct BodyDetail {
        let body: String
        let truncated: Bool
        let denied: Bool
    }

    static func bodyDetail(dbPath: String, id: Int64) -> BodyDetail {
        let empty = BodyDetail(body: "", truncated: false, denied: false)
        return withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT body, truncated, denied FROM files WHERE id=?",
                                     -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return empty }
            defer { sqlite3_finalize(s) }
            bind(s, [id])
            guard sqlite3_step(s) == SQLITE_ROW else { return empty }
            return BodyDetail(body: text(s, 0),
                              truncated: sqlite3_column_int64(s, 1) == 1,
                              denied: sqlite3_column_int64(s, 2) == 1)
        } ?? empty
    }

    private static func runFiles(_ db: OpaquePointer, sql: String, params: [Any?]) -> [VaultFile] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s, params)
        var out: [VaultFile] = []
        while sqlite3_step(s) == SQLITE_ROW {
            out.append(VaultFile(
                id: sqlite3_column_int64(s, 0),
                root: text(s, 1), rel: text(s, 2), name: text(s, 3),
                ext: text(s, 4), kind: text(s, 5),
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

    private static let cols = """
        SELECT id, root, rel, name, ext, kind, size, mtime, is_text, title, substr(body,1,4000),
               length(body), truncated
        FROM files
        """

    /// 有正文的文字资产。
    ///
    /// 口径是 `length(body) > 0`，**不是** `body IS NOT NULL` ——
    /// 超限不抽取的大文件 body 存的是空字符串，用后者会虚高（本机 96 个）。
    static func textAssets(dbPath: String, limit: Int = 600) -> [VaultFile] {
        withConnection(dbPath) { db in
            runFiles(db, sql: "\(cols) WHERE gone=0 AND is_text=1 AND length(body)>0 AND is_binary=0 ORDER BY mtime DESC LIMIT \(limit)", params: [])
        } ?? []
    }

    /// 全部文件（含无正文的）—— 提炼页要看全貌
    static func allFiles(dbPath: String, limit: Int = 2000) -> [VaultFile] {
        withConnection(dbPath) { db in
            runFiles(db, sql: "\(cols) WHERE gone=0 AND is_symlink=0 ORDER BY size DESC LIMIT \(limit)", params: [])
        } ?? []
    }

    static func search(dbPath: String, keyword: String, limit: Int = 400) -> [VaultFile] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return textAssets(dbPath: dbPath, limit: limit) }
        let like = "%\(q)%"
        return withConnection(dbPath) { db in
            runFiles(db, sql: """
                \(cols) WHERE gone=0 AND (body LIKE ? OR name LIKE ? OR rel LIKE ?)
                ORDER BY CASE WHEN name LIKE ? THEN 0 ELSE 1 END, mtime DESC LIMIT \(limit)
                """, params: [like, like, like, like])
        } ?? []
    }

    static func fullBody(dbPath: String, id: Int64) -> String {
        withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT body FROM files WHERE id=?", -1, &stmt, nil) == SQLITE_OK,
                  let s = stmt else { return "" }
            defer { sqlite3_finalize(s) }
            bind(s, [id])
            if sqlite3_step(s) == SQLITE_ROW { return text(s, 0) }
            return ""
        } ?? ""
    }

    /// 每类 kind 的数量与体量
    static func kinds(dbPath: String) -> [(String, Int, Int64)] {
        withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            let sql = "SELECT kind, count(*), coalesce(sum(size),0) FROM files WHERE gone=0 GROUP BY kind ORDER BY sum(size) DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            var out: [(String, Int, Int64)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((text(s, 0), Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2)))
            }
            return out
        } ?? []
    }

    /// 顶层目录：名字、文件数、体量
    static func topLevelDirs(dbPath: String) -> [(String, Int, Int64)] {
        withConnection(dbPath) { db in
            let sql = """
                SELECT
                  CASE WHEN instr(rel,'/')>0 THEN substr(rel,1,instr(rel,'/')-1) ELSE '(根目录散文件)' END AS top,
                  count(*), coalesce(sum(size),0)
                FROM files WHERE gone=0
                GROUP BY top ORDER BY count(*) DESC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            var out: [(String, Int, Int64)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((text(s, 0), Int(sqlite3_column_int64(s, 1)), sqlite3_column_int64(s, 2)))
            }
            return out
        } ?? []
    }

    // MARK: 检索

    /// 一条命中。
    struct SearchHit: Identifiable {
        let file: VaultFile
        let snippet: String
        let matchedIn: String      // 文件名 / 正文 / 路径（兜底片段只说明"为何命中"，不再是一种命中位置）
        let hitCount: Int
        let score: Int
        var id: Int64 { file.id }
    }

    /// 检索的筛选条件
    // 显式 Sendable：成员全是值类型（Set<String> / String? / Int?），
    // 它要跨进 `Task.detached`。写明比依赖推断好 —— 推断不会在测试里留证据。
    struct SearchFilter: Sendable {
        var kinds: Set<String> = []          // 空 = 不限
        var topDir: String? = nil            // nil = 不限
        var sinceDays: Int? = nil            // nil = 不限

        var isActive: Bool {
            !kinds.isEmpty || topDir != nil || sinceDays != nil
        }
    }

    /// 检索。
    ///
    /// 比原来的 `LIKE` 多了四件事：
    /// 1. **命中片段** —— 取出关键词前后的一段正文，让你知道**为什么**命中
    /// 2. **命中位置** —— 文件名 / 正文 / 路径，排序依据
    /// 3. **相关度排序** —— 文件名命中 > 正文命中 > 路径命中，再看命中次数
    /// 4. **无正文文件也能被搜到** —— 无正文时片段换成一句说明（见 `fallbackSnippet`）。
    ///    本机有 **2,202** 个文件没有正文，口径是 `gone=0 AND length(body)=0`
    ///    （2026-10-01 实测；若按 `is_text=0` 算是 **2,106** 个 —— 差额 96 个是
    ///    文字类但超限没抽取、body 存空串的大文件。两个口径不是一个数，说哪个就得说清）。
    ///    原来这些文件只能靠文件名被找到。
    static func searchEx(dbPath: String, keyword: String, limit: Int = 300,
                         filter: SearchFilter = SearchFilter()) -> [SearchHit] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var where_: [String] = ["gone=0"]
        var params: [Any?] = []

        if !filter.kinds.isEmpty {
            let marks = filter.kinds.map { _ in "?" }.joined(separator: ",")
            where_.append("kind IN (\(marks))")
            params.append(contentsOf: filter.kinds.map { $0 as Any? })
        }
        if let top = filter.topDir {
            if top == "(根目录散文件)" {
                where_.append("instr(rel,'/')=0")
            } else {
                where_.append("rel LIKE ?")
                params.append(top + "/%")
            }
        }
        if let d = filter.sinceDays {
            where_.append("mtime > ?")
            params.append(Int64((Date().timeIntervalSince1970 - Double(d) * 86400) * 1000))
        }

        // 关键词要在三处之一命中
        where_.append("(instr(lower(name), lower(?))>0 OR instr(lower(body), lower(?))>0 OR instr(lower(rel), lower(?))>0)")
        let like = q.lowercased()
        params.append(contentsOf: [like as Any?, like as Any?, like as Any?])

        let sql = """
        SELECT id, root, rel, name, ext, kind, size, mtime, is_text, title,
          CASE
            WHEN instr(lower(body), lower(?)) > 0
              THEN substr(body, max(1, instr(lower(body), lower(?)) - 70), 200)
            ELSE NULL
          END AS snip,
          CASE
            WHEN instr(lower(name), lower(?)) > 0 THEN '文件名'
            WHEN instr(lower(body), lower(?)) > 0 THEN '正文'
            WHEN instr(lower(rel),  lower(?)) > 0 THEN '路径'
            ELSE '—'
          END AS where_,
          CASE
            WHEN length(?) > 0
              THEN (length(body) - length(replace(lower(body), lower(?), ''))) / length(?)
            ELSE 0
          END AS cnt,
          CASE
            WHEN instr(lower(name), lower(?)) > 0 THEN 100 ELSE 0
          END
          + CASE WHEN instr(lower(body), lower(?)) > 0 THEN 40 ELSE 0 END
          + CASE WHEN instr(lower(rel),  lower(?)) > 0 THEN 20 ELSE 0 END AS score,
          length(body) AS body_len
        FROM files
        WHERE \(where_.joined(separator: " AND "))
        ORDER BY score DESC, mtime DESC
        LIMIT \(limit)
        """

        // SELECT 子句里的占位符，**严格按出现顺序**：
        //   1 snip 条件   2 snip 截取起点   3 文件名   4 正文   5 路径
        //   6 cnt 的 length    7 cnt 的 replace   8 cnt 的除数
        //   9 文件名评分  10 正文评分  11 路径评分
        // 少一个都会让后面所有参数**整体错位**：
        // `kind IN (?)` 会收到搜索词而不是类型，于是筛选永远返回 0 条。
        // （无筛选时错位后收到的恰好都是同一个 like，所以能"正常"工作 —— 这就是它藏得住的原因。）
        let selectParams: [Any?] = [like, like, like, like, like, q, like, q, like, like, like]
        let all: [Any?] = selectParams + params

        // 自检：参数数量必须和占位符数量一致。
        // 这类错误不会报错，只会静默返回错的结果 —— 所以必须显式挡住。
        let placeholderCount = sql.filter { $0 == "?" }.count
        guard all.count == placeholderCount else {
            assertionFailure("检索 SQL 占位符 \(placeholderCount) 个，参数 \(all.count) 个 —— 对不上")
            return []
        }

        return withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            bind(s, all)

            // 计算出来的那几列（snip / where_ / cnt / score / oneliner）
            // **按列名取，不按位置取**。
            //
            // 位置取列已经错过一次，而且错得完全无声：
            //   · hitCount 读到了第 13 列（= score），于是界面把一个
            //     "100+40+20 三个我编的权重之和"显示成「命中 160 处」——
            //     看起来像一个事实，其实不是。在一个以「每句话都有据可依」
            //     为卖点的工具里，这等于伪造了一条事实。
            //   · 兜底片段那一列读到了越界列号（一共只有 15 列，它读第 17 列），永远为空 ——
            //     于是 2,202 个无正文文件的兜底从来没生效过。那一列已从 SQL 里移走，
            //     改用 `length(body) AS body_len`，说明语在 Swift 侧拼（见 fallbackSnippet）。
            //
            // SQLite 不会因为列号错位或越界而报错，它只会安静地给你另一个数。
            // 所以这里改成查 `sqlite3_column_name`：改了 SELECT 而没改这里，
            // 会直接炸，而不是给出一份看起来合理的错数据。
            func col(_ name: String) -> Int32 {
                for i in 0..<sqlite3_column_count(s) {
                    if String(cString: sqlite3_column_name(s, i)) == name { return i }
                }
                assertionFailure("检索 SQL 里没有列「\(name)」—— SELECT 被改过，列号已经漂移")
                return 0
            }
            let cSnip = col("snip"), cWhere = col("where_"), cCnt = col("cnt")
            let cScore = col("score"), cBodyLen = col("body_len")

            var out: [SearchHit] = []
            while sqlite3_step(s) == SQLITE_ROW {
                let file = VaultFile(
                    id: sqlite3_column_int64(s, 0),
                    root: text(s, 1), rel: text(s, 2), name: text(s, 3),
                    ext: text(s, 4), kind: text(s, 5),
                    size: sqlite3_column_int64(s, 6),
                    mtime: sqlite3_column_int64(s, 7),
                    isText: sqlite3_column_int64(s, 8) == 1,
                    title: sqlite3_column_text(s, 9).map { String(cString: $0) },
                    body: nil
                )
                let snipCol = sqlite3_column_text(s, cSnip).map { String(cString: $0) }
                let bodyLen = Int(sqlite3_column_int64(s, cBodyLen))
                out.append(SearchHit(
                    file: file,
                    // 正文里没命中时，片段换成一句**说明它为什么会被搜到**的话。
                    // 不再重拼 name · kind · rel：标题已经有 name、元信息行已经有 rel，
                    // 重拼只会让同一个片段在结果行里连着出现三次、零新信息（J3）。
                    snippet: snipCol ?? fallbackSnippet(kind: file.kind, hasBody: bodyLen > 0),
                    matchedIn: text(s, cWhere),
                    hitCount: Int(sqlite3_column_int64(s, cCnt)),
                    score: Int(sqlite3_column_int64(s, cScore))
                ))
            }
            return out
        } ?? []
    }

    /// 正文里没命中时，结果行的「片段」位置该写什么。
    ///
    /// **不再重拼 `name · kind · rel`**。那三段在结果行里已经各出现一次
    /// （标题 = name，类型徽章/中文类型名 = kind，元信息一行 = rel），
    /// 重拼出来的是一个 100% 重复、零新信息的假片段（J3）。
    /// 这里只回答一件事：**它为什么会被搜到** —— 这才是「片段」这个位置的职责。
    ///
    /// 类型名走 `indexKindLabel`（中文映射表只留 Theme.swift 那一份）。
    /// 曾经这条路径是在 SQL 里 `name || '  ·  ' || kind || '  ·  ' || rel`，
    /// 于是界面上会看到 `dsh-latest-macos-arm64.dmg · archive · …` 这种裸英文 key（J2）。
    private static func fallbackSnippet(kind: String, hasBody: Bool) -> String {
        hasBody
            ? "正文未出现；命中在文件名或路径"
            : "没有正文（\(indexKindLabel(kind))）；靠文件名或路径命中"
    }

    /// 最近改动的文件 —— 还没搜的时候给人一个起点
    static func recentFiles(dbPath: String, limit: Int = 12) -> [VaultFile] {
        withConnection(dbPath) { db in
            let sql = """
                SELECT id, root, rel, name, ext, kind, size, mtime, is_text, title
                FROM files WHERE gone=0 AND mtime > 946684800000
                ORDER BY mtime DESC LIMIT \(limit)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            var out: [VaultFile] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(VaultFile(
                    id: sqlite3_column_int64(s, 0),
                    root: text(s, 1), rel: text(s, 2), name: text(s, 3),
                    ext: text(s, 4), kind: text(s, 5),
                    size: sqlite3_column_int64(s, 6),
                    mtime: sqlite3_column_int64(s, 7),
                    isText: sqlite3_column_int64(s, 8) == 1,
                    title: sqlite3_column_text(s, 9).map { String(cString: $0) },
                    body: nil))
            }
            return out
        } ?? []
    }

    /// 一句话统计 —— 用 COUNT，不要把行拉回来再数
    static func scalar(dbPath: String, sql: String) -> Int64 {
        withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return 0 }
            defer { sqlite3_finalize(s) }
            if sqlite3_step(s) == SQLITE_ROW { return sqlite3_column_int64(s, 0) }
            return 0
        } ?? 0
    }

    /// 检索结果的类型分布 —— 用来给筛选器显示各类有多少
    static func kindCounts(dbPath: String) -> [(String, Int)] {
        withConnection(dbPath) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT kind, count(*) FROM files WHERE gone=0 GROUP BY kind ORDER BY count(*) DESC", -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            var out: [(String, Int)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((text(s, 0), Int(sqlite3_column_int64(s, 1))))
            }
            return out
        } ?? []
    }

    /// 近 N 个月的改动量 —— 趋势线用。返回按时间升序的 (年月, 文件数)。
    ///
    /// 下界用 2000-01-01：本机有 423 个文件的 mtime 是 500000000 秒（1985-10-26），
    /// 那是 zip / Android 解包的哨兵值。不排掉，趋势图的横轴会被从 2026 年拉到 1985 年。
    static func monthlyActivity(dbPath: String, months: Int = 12) -> [(String, Int)] {
        // 先拿到**有数据**的月份
        let raw: [(String, Int)] = withConnection(dbPath) { db in
            let sql = """
                SELECT strftime('%Y-%m', mtime/1000, 'unixepoch', 'localtime') AS m, count(*)
                FROM files
                WHERE gone=0 AND mtime > 946684800000
                GROUP BY m
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            var out: [(String, Int)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((text(s, 0), Int(sqlite3_column_int64(s, 1))))
            }
            return out
        } ?? []

        // 再补成**连续的** N 个月。
        // 原来直接取"最近 N 个有数据的月份"，本机只有 9 个不同月份，
        // 于是最左边落到 2008-01 —— 而折线图把它们当等距画，时间轴是假的。
        var byMonth: [String: Int] = [:]
        for (m, n) in raw { byMonth[m, default: 0] += n }

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM"
        let now = Date()
        guard let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) else {
            return raw.sorted { $0.0 < $1.0 }
        }
        var series: [(String, Int)] = []
        for back in stride(from: months - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .month, value: -back, to: thisMonth) else { continue }
            let key = fmt.string(from: d)
            series.append((key, byMonth[key] ?? 0))
        }
        return series
    }

    /// 某个顶层目录下的文件类型构成 —— 瀑布流里展开看
    static func kindsIn(dbPath: String, top: String) -> [(String, Int)] {
        let prefix = top == "(根目录散文件)" ? "" : top + "/"
        return withConnection(dbPath) { db in
            let sql: String
            let params: [Any?]
            if prefix.isEmpty {
                sql = "SELECT kind, count(*) FROM files WHERE gone=0 AND instr(rel,'/')=0 GROUP BY kind ORDER BY count(*) DESC"
                params = []
            } else {
                sql = "SELECT kind, count(*) FROM files WHERE gone=0 AND rel LIKE ? GROUP BY kind ORDER BY count(*) DESC"
                params = [prefix + "%"]
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return [] }
            defer { sqlite3_finalize(s) }
            bind(s, params)
            var out: [(String, Int)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                out.append((text(s, 0), Int(sqlite3_column_int64(s, 1))))
            }
            return out
        } ?? []
    }

    /// 按顶层目录取文件（提炼页展开用）
    static func files(dbPath: String, inTop dir: String, limit: Int = 500) -> [VaultFile] {
        let prefix = dir == "(根目录散文件)" ? "" : dir + "/"
        return withConnection(dbPath) { db in
            if prefix.isEmpty {
                return runFiles(db, sql: "\(cols) WHERE gone=0 AND instr(rel,'/')=0 ORDER BY size DESC LIMIT \(limit)", params: [])
            }
            return runFiles(db, sql: "\(cols) WHERE gone=0 AND rel LIKE ? ORDER BY size DESC LIMIT \(limit)", params: [prefix + "%"])
        } ?? []
    }
}
