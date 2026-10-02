import Foundation
import SQLite3

/// 原生索引器：让 App 不装 Node、不拿 CLI 也能自己建出可检索的索引。
///
/// ## 为什么要它
/// dmg 里只有 `.app` 时，用户机器上可能既没有 Node 也没有 CLI。
/// 那时候「先装一套工具，才看得见自己本来就有的文件」不是这个产品该有的第一步 ——
/// 那台干净机器上就是死路，实测过。
///
/// ## 与 CLI 的关系（这份文件存在的代价，必须说清）
/// schema 与 `mcp-server/lib/store.js` 的 SCHEMA **逐字一致**；
/// 扫描与抽取规则照 `walk.js` / `extract.js` / `indexer.js` 移植。
/// 也就是说「扫盘 + 抽正文」这件事被实现了两遍，控制手段是 task-20 的对拍断言：
/// 同一棵树，App 建的库与 CLI 建的库必须给出同一批行。
///
/// 这里**不含任何判断逻辑**：`FileTriage` 那六级判断仍然只有 Swift 一份。
/// 索引只提供 path/name/ext/size/mtime/正文/标题这些事实。
///
/// ## 一条纪律
/// CLI 读库用 `mode=ro`；这里要写库，必须**读写**打开一个自己的连接，
/// 绝不复用 `VaultStore` 的只读连接 —— 「App 在物理上改不了索引」这条不能破。
enum VaultIndexer {

    // MARK: - 冻结接口（shell-dev 的向导按这几个类型调用，不要改）

    struct IndexRoot {
        let path: String
        let label: String
    }

    struct Progress {
        let scanned: Int
        let extracted: Int
        let currentPath: String
    }

    struct Report {
        let filesSeen: Int
        let dirsSeen: Int
        let skippedDirs: Int
        /// 本次新出现的路径数（库里原来没有这个 path）
        let added: Int
        /// 已存在但内容需要重写的路径数（大小/时间/类型/加密态变了，或原来只扫到一半）
        let updated: Int
        /// 本次扫描没再出现、被标成 `gone=1` 的路径数
        let removed: Int
        let errors: Int
        let elapsedMs: Int
    }

    enum Failure: LocalizedError {
        case open(String)
        case sql(String)

        var errorDescription: String? {
            switch self {
            case .open(let m): return "打不开索引库：\(m)"
            case .sql(let m):  return "索引写入失败：\(m)"
            }
        }
    }

    // MARK: - schema

    /// 建表语句，与 `mcp-server/lib/store.js:14-66` 的 `SCHEMA` 常量**逐字一致**。
    ///
    /// 为什么逐字：CLI 与 App 会交替写同一个库（今天用 App 建、明天用 CLI 增量），
    /// `CREATE TABLE IF NOT EXISTS` 只在第一次生效 —— 谁的文本先落库就是谁的。
    /// 列名/默认值/索引名不一致，会让「同一个库两种读法」变成事实。
    static func schemaSQL() -> String {
        [
            "",
            "CREATE TABLE IF NOT EXISTS meta (",
            "  key   TEXT PRIMARY KEY,",
            "  value TEXT",
            ");",
            "",
            "CREATE TABLE IF NOT EXISTS files (",
            "  id          INTEGER PRIMARY KEY,",
            "  root        TEXT NOT NULL,",
            "  path        TEXT NOT NULL UNIQUE,",
            "  rel         TEXT NOT NULL,",
            "  name        TEXT NOT NULL,",
            "  ext         TEXT DEFAULT '',",
            "  kind        TEXT DEFAULT 'other',",
            "  size        INTEGER DEFAULT 0,",
            "  mtime       INTEGER DEFAULT 0,",
            "  birthtime   INTEGER DEFAULT 0,",
            "  is_text     INTEGER DEFAULT 0,",
            "  is_symlink  INTEGER DEFAULT 0,",
            "  denied      INTEGER DEFAULT 0,",
            "  is_binary   INTEGER DEFAULT 0,",
            "  title       TEXT DEFAULT '',",
            "  headings    TEXT DEFAULT '',",
            "  body        TEXT DEFAULT '',",
            "  truncated   INTEGER DEFAULT 0,",
            "  scan_id     INTEGER DEFAULT 0,",
            "  gone        INTEGER DEFAULT 0",
            ");",
            "",
            "CREATE INDEX IF NOT EXISTS idx_files_root   ON files(root);",
            "CREATE INDEX IF NOT EXISTS idx_files_mtime  ON files(mtime);",
            "CREATE INDEX IF NOT EXISTS idx_files_size   ON files(size);",
            "CREATE INDEX IF NOT EXISTS idx_files_name   ON files(name);",
            "CREATE INDEX IF NOT EXISTS idx_files_kind   ON files(kind);",
            "CREATE INDEX IF NOT EXISTS idx_files_gone   ON files(gone);",
            "",
            "CREATE TABLE IF NOT EXISTS scan_runs (",
            "  id          INTEGER PRIMARY KEY,",
            "  started_at  INTEGER,",
            "  finished_at INTEGER,",
            "  root        TEXT,",
            "  files_seen  INTEGER DEFAULT 0,",
            "  files_added INTEGER DEFAULT 0,",
            "  files_updated INTEGER DEFAULT 0,",
            "  files_removed INTEGER DEFAULT 0,",
            "  dirs_seen   INTEGER DEFAULT 0,",
            "  skipped_dirs INTEGER DEFAULT 0,",
            "  errors      INTEGER DEFAULT 0,",
            "  elapsed_ms  INTEGER DEFAULT 0,",
            "  ok          INTEGER DEFAULT 1,",
            "  detail      TEXT",
            ");",
            "",
        ].joined(separator: "\n")
    }

    /// 与 `store.js:12` 的 `SCHEMA_VERSION = 1` 对齐
    private static let schemaVersion = 1

    // MARK: - 建库

    /// 建库 + 建表（已存在则不动）。不扫描、不写行，只保证结构可用。
    static func ensureDatabase(at dbPath: String) throws {
        let db = try openForWrite(dbPath)
        sqlite3_close(db)
    }

    private static func openForWrite(_ dbPath: String) throws -> OpaquePointer {
        let dir = (dbPath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        // 读写 + 可创建。绝不加 mode=ro —— 那会静默退化成"什么都不写"。
        let rc = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "错误码 \(rc)"
            if let handle { sqlite3_close(handle) }
            throw Failure.open(msg)
        }
        // 与 store.js 的三条 pragma 一致；busy_timeout 是这里加的：
        // App 可能在写库的同时用只读连接读同一个库，等一会儿比直接报错好。
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, schemaSQL(), nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw Failure.sql("建表：\(msg)")
        }
        // schema_version 只在缺失时写 —— 已有值说明这个库是别的版本建的，不该被降级覆盖
        if scalar(db, "SELECT value FROM meta WHERE key='schema_version'") == nil {
            exec(db, "INSERT INTO meta(key,value) VALUES('schema_version','\(schemaVersion)')")
        }
        return db
    }

    // MARK: - 扫描写入

    /// 扫描 + 写入。可在任意线程调用（每次自己开连接，没有共享状态）。
    ///
    /// `onProgress` 每 256 个条目回调一次，调用方负责切回主线程。
    /// 取消：循环里检查 `Task.isCancelled`，命中就抛 `CancellationError`。
    /// **抛之前会提交已完成的部分** —— 所以取消后库是「合法但不完整」，
    /// 不是半写坏的；下一次 `run` 走增量会把它补全（不需要删库重建）。
    static func run(roots: [IndexRoot], dbPath: String,
                    onProgress: @escaping (Progress) -> Void) throws -> Report {
        let settings = Settings.load()
        let startedAt = Date()
        let scanId = Int64(Date().timeIntervalSince1970 * 1000)   // CLI 用的是 Date.now()，单位毫秒
        let db = try openForWrite(dbPath)
        defer { sqlite3_close(db) }

        let writer = try Writer(db: db)
        defer { writer.finish() }

        var filesSeen = 0, dirsSeen = 0, skippedDirs = 0
        var added = 0, updated = 0, removed = 0, errors = 0
        var extractedTotal = 0
        var rootSummaries: [[String: Any]] = []

        for root in roots {
            try Task.checkCancellation()
            let rootPath = normalizePath(root.path)
            let rootStart = Date()
            let walked = walk(rootPath: rootPath, settings: settings)
            dirsSeen += walked.dirCount
            skippedDirs += walked.skippedDirs
            errors += walked.errors

            if walked.missing {
                // 根不存在：不写任何行、不标记消失 —— 把「盘没挂上」误判成「文件都没了」是最坏的一种错
                rootSummaries.append([
                    "root": rootPath, "label": root.label, "missing": true,
                    "files": 0, "errors": walked.errors,
                ])
                continue
            }

            // 增量基线：只取判断所需的小字段（正文不拉回来）
            var existing: [String: PrevRow] = [:]
            if let stmt = prepare(db, "SELECT path, size, mtime, is_text, denied FROM files WHERE root = ?") {
                bindText(stmt, 1, rootPath)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    existing[text(stmt, 0)] = PrevRow(size: sqlite3_column_int64(stmt, 1),
                                                     mtime: sqlite3_column_int64(stmt, 2),
                                                     isText: sqlite3_column_int64(stmt, 3) == 1,
                                                     denied: sqlite3_column_int64(stmt, 4) == 1)
                }
                sqlite3_finalize(stmt)
            }

            var rootAdded = 0, rootUpdated = 0
            var extracted = 0
            var reused = 0

            for entry in walked.entries {
                try Task.checkCancellation()
                filesSeen += 1
                let denied = settings.isDeniedRead(entry.name)

                if let prev = existing[entry.path], prev.matches(entry, denied: denied) {
                    // 没变：只刷元数据，正文原样留着（省 IO，也避免把已抽取的正文重写一遍）
                    if writer.touch(Record(entry: entry, root: rootPath, scanId: scanId, denied: denied)) {
                        reused += 1
                        if filesSeen % 256 == 0 {
                            onProgress(Progress(scanned: filesSeen, extracted: extractedTotal, currentPath: entry.path))
                        }
                        continue
                    }
                    // 行其实已经不在了 → 退到全量写入
                }

                var ex = Extracted()
                if !denied && entry.isText && entry.size > 0 && entry.size <= Int64(settings.maxTextBytes) {
                    ex = extractFile(entry.path, settings: settings)
                    if ex.ok {
                        if ex.isBinary { ex.body = ""; ex.title = ""; ex.headings = ""; ex.truncated = false }
                        extracted += 1
                        extractedTotal += 1
                    } else {
                        errors += 1
                    }
                }

                try writer.put(Record(entry: entry, root: rootPath, scanId: scanId, denied: denied, extracted: ex))
                if existing[entry.path] == nil { rootAdded += 1 } else { rootUpdated += 1 }

                if filesSeen % 256 == 0 {
                    onProgress(Progress(scanned: filesSeen, extracted: extractedTotal, currentPath: entry.path))
                }
            }

            try writer.commit()

            // 只有**扫完这个根**才允许标 gone。取消/中途抛错时走不到这里，
            // 所以没扫到的文件不会被误标成「已消失」。
            let goneCount = markGoneOlderThan(db, root: rootPath, scanId: scanId)
            removed += goneCount
            added += rootAdded
            updated += rootUpdated

            let elapsed = Int(Date().timeIntervalSince(rootStart) * 1000)
            recordScanRun(db, startedAt: Int64(rootStart.timeIntervalSince1970 * 1000),
                          finishedAt: Int64(Date().timeIntervalSince1970 * 1000),
                          root: rootPath, filesSeen: walked.entries.count,
                          filesAdded: extracted, filesUpdated: extracted,
                          filesRemoved: goneCount, dirsSeen: walked.dirCount,
                          skippedDirs: walked.skippedDirs, errors: walked.errors, elapsedMs: elapsed)
            rootSummaries.append([
                "root": rootPath, "label": root.label, "missing": false,
                "files": walked.entries.count, "extracted": extracted, "reused": reused,
                "removed": goneCount, "dirs": walked.dirCount, "skippedDirs": walked.skippedDirs,
                "errors": walked.errors, "elapsedMs": elapsed,
            ])
        }

        try writer.commit()
        let finishedAt = Date()
        let elapsedMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
        // last_scan_at 写在最后：它与「这次真的扫完了」同义。
        // 中途被取消就只留下 scan_runs 里的部分记录，`doctor` 会如实说「索引还没建过」。
        setMeta(db, "last_scan_at", String(Int64(finishedAt.timeIntervalSince1970 * 1000)))
        if let json = try? JSONSerialization.data(withJSONObject: [
            "finishedAt": Int64(finishedAt.timeIntervalSince1970 * 1000),
            "elapsedMs": elapsedMs,
            "filesSeen": filesSeen,
            "filesExtracted": extractedTotal,
            "filesReused": max(0, filesSeen - added - updated),
            "filesRemoved": removed,
            "errors": errors,
            "roots": rootSummaries,
        ], options: [.sortedKeys]) {
            setMeta(db, "last_scan_summary", String(decoding: json, as: UTF8.self))
        }

        onProgress(Progress(scanned: filesSeen, extracted: extractedTotal, currentPath: ""))

        return Report(filesSeen: filesSeen, dirsSeen: dirsSeen, skippedDirs: skippedDirs,
                      added: added, updated: updated, removed: removed,
                      errors: errors, elapsedMs: elapsedMs)
    }

    // MARK: - 遍历（照 walk.js 移植）

    private struct Entry {
        let path: String
        let rel: String
        let name: String
        let ext: String
        let kind: String
        let size: Int64
        let mtimeMs: Int64
        let birthtimeMs: Int64
        let isText: Bool
        let isSymlink: Bool
    }

    private struct WalkResult {
        var entries: [Entry] = []
        var errors = 0
        var dirCount = 0
        var skippedDirs = 0
        var missing = false
    }

    /// 迭代遍历（不用递归：本机深度很可能上百层）。
    ///
    /// 与 walk.js 逐条对齐的三件事：
    /// - **符号链接不跟随**，但仍记一条 `kind=symlink` 的元数据（否则「下载里那个软链指向哪」看不见）；
    /// - 目录型 bundle（`.app`/`.photoslibrary`…）记一条 `kind=bundle`，不展开内部成百上千个文件；
    /// - 机器生成目录（`node_modules`/`dist`/`.build`…）直接跳过，只计入 `skippedDirs`。
    private static func walk(rootPath: String, settings: Settings) -> WalkResult {
        var out = WalkResult()
        var st = stat()
        guard lstat(rootPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            out.missing = true
            out.errors = 1
            return out
        }

        var stack: [(dir: String, depth: Int)] = [(rootPath, 0)]
        while let cur = stack.popLast() {
            var names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: cur.dir)
            } catch {
                out.errors += 1
                continue
            }
            out.dirCount += 1

            for name in names {
                let full = cur.dir + "/" + name
                var e = stat()
                guard lstat(full, &e) == 0 else {
                    out.errors += 1
                    continue
                }
                let mode = e.st_mode & S_IFMT

                if mode == S_IFLNK {
                    out.entries.append(Entry(path: full, rel: relPosix(root: rootPath, full: full),
                                             name: name, ext: "", kind: "symlink",
                                             size: 0, mtimeMs: 0, birthtimeMs: 0,
                                             isText: false, isSymlink: true))
                    continue
                }

                if mode == S_IFDIR {
                    switch settings.skipReason(name) {
                    case .ignoredSuffix:
                        // 包本身值得被看见（"下载里有个解压出来的 App"），内部不值得
                        out.entries.append(Entry(path: full, rel: relPosix(root: rootPath, full: full),
                                                 name: name, ext: fileExtension(name), kind: "bundle",
                                                 size: 0, mtimeMs: mtimeMs(e), birthtimeMs: 0,
                                                 isText: false, isSymlink: false))
                        out.skippedDirs += 1
                    case .ignoredName:
                        out.skippedDirs += 1
                    case .none:
                        if cur.depth + 1 > settings.maxDepth {
                            out.skippedDirs += 1
                        } else {
                            stack.append((full, cur.depth + 1))
                        }
                    }
                    continue
                }

                guard mode == S_IFREG else { continue }
                if name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" { continue }

                let ext = fileExtension(name)
                out.entries.append(Entry(path: full, rel: relPosix(root: rootPath, full: full),
                                         name: name, ext: ext, kind: settings.kindOf(ext),
                                         size: e.st_size, mtimeMs: mtimeMs(e), birthtimeMs: birthtimeMs(e),
                                         isText: settings.isTextExt(ext), isSymlink: false))
            }
        }
        return out
    }

    /// **毫秒**，和 CLI 的 `Math.floor(st.mtimeMs)` 是同一个值。
    /// 用秒+纳秒做整数运算，而不是把 Date 来回乘 1000 —— 后者在毫秒边界上会差 1。
    private static func mtimeMs(_ st: stat) -> Int64 {
        Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec) / 1_000_000
    }

    private static func birthtimeMs(_ st: stat) -> Int64 {
        guard st.st_birthtimespec.tv_sec > 0 else { return 0 }
        return Int64(st.st_birthtimespec.tv_sec) * 1000 + Int64(st.st_birthtimespec.tv_nsec) / 1_000_000
    }

    private static func relPosix(root: String, full: String) -> String {
        if root == "/" { return String(full.dropFirst()) }
        if full.hasPrefix(root + "/") { return String(full.dropFirst(root.count + 1)) }
        return full
    }

    /// Node 的 `path.extname` 语义：开头只有一个点的隐藏文件（`.gitignore`）**没有扩展名**。
    private static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        if dot == name.startIndex { return "" }
        return String(name[dot...]).lowercased()
    }

    private static func normalizePath(_ p: String) -> String {
        var s = p
        if s == "~" { s = NSHomeDirectory() }
        else if s.hasPrefix("~/") { s = NSHomeDirectory() + String(s.dropFirst(1)) }
        if s.count > 1 && s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    // MARK: - 抽取（照 extract.js 移植）

    private struct Extracted {
        var title = ""
        var headings = ""
        var body = ""
        var truncated = false
        var isBinary = false
        var ok = true
    }

    /// 单文件正文上限 2MB、入库上限 400,000 字符（超出 → `truncated=1`），与 CLI 一致。
    private static func extractFile(_ path: String, settings: Settings) -> Extracted {
        var out = Extracted()
        guard let handle = FileHandle(forReadingAtPath: path) else {
            out.ok = false
            return out
        }
        defer { try? handle.close() }

        // 读满上限（Node 侧一次 readSync；这里循环读到 EOF 或读满 ——
        // 短读不该让「这个文件有没有被截断」变成随机结果）
        var data = Data()
        do {
            while data.count < settings.maxTextBytes {
                guard let chunk = try handle.read(upToCount: settings.maxTextBytes - data.count),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            out.ok = false
            return out
        }

        if looksBinary(data) {
            out.isBinary = true                 // 二进制：只留元数据，不假装有正文
            return out
        }

        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        out.truncated = data.count >= settings.maxTextBytes

        let ext = fileExtension((path as NSString).lastPathComponent)
        let isMd = ext == ".md" || ext == ".markdown" || ext == ".mdx"
        var frontmatter: [String: String] = [:]
        if isMd {
            let parsed = parseFrontmatter(text)
            frontmatter = parsed.frontmatter
            text = parsed.body
        }
        out.headings = isMd ? collectHeadings(text, limit: 60).joined(separator: "\n") : ""
        out.title = guessTitle(text, frontmatter: frontmatter, ext: ext)
        out.body = text

        // 截断按 **UTF-16 码元** 数 —— JS 的 String.length 就是这个口径。
        // 按 Character 数（grapheme cluster）会在 emoji 上和 CLI 差几个字符。
        if out.body.utf16.count > settings.maxStoredBodyChars {
            let cut = out.body.utf16.prefix(settings.maxStoredBodyChars)
            out.body = String(decoding: Array(cut), as: UTF16.self)
            out.truncated = true
        }
        return out
    }

    /// 前 8KB 见到 NUL 基本可判定为二进制（和 extract.js 同一判据）
    private static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        return head.contains(0)
    }

    private static func parseFrontmatter(_ text: String) -> (frontmatter: [String: String], body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return ([:], text) }
        let start = text.firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
        let rest = text[start...]
        guard let close = rest.range(of: "\n---") else { return ([:], text) }
        let block = rest[rest.startIndex..<close.lowerBound]
        var fm: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon])
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            else { continue }
            var value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            fm[key] = value
        }
        var after = close.upperBound
        if after < rest.endIndex, rest[after] == "\r" { after = rest.index(after: after) }
        if after < rest.endIndex, rest[after] == "\n" { after = rest.index(after: after) }
        return (fm, String(rest[after...]))
    }

    /// `#{1,6} xxx` 形式的标题，最多 60 条（extract.js 的 collectHeadings）
    private static func collectHeadings(_ body: String, limit: Int) -> [String] {
        var out: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.hasSuffix("\r") ? line.dropLast() : line
            var hashes = 0
            for ch in l {
                if ch == "#" { hashes += 1 } else { break }
            }
            guard hashes >= 1, hashes <= 6 else { continue }
            var rest = l.dropFirst(hashes)
            guard rest.first == " " || rest.first == "\t" else { continue }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            var title = String(rest)
            // 结尾的空白与可选的一组 `#` 不算标题内容
            title = title.trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            out.append(String(repeating: "#", count: hashes) + " " + title)
            if out.count >= limit { break }
        }
        return out
    }

    private static func guessTitle(_ body: String, frontmatter: [String: String], ext: String) -> String {
        if let t = frontmatter["title"], !t.isEmpty { return t.trimmingCharacters(in: .whitespaces) }
        if let n = frontmatter["name"], !n.isEmpty { return n.trimmingCharacters(in: .whitespaces) }
        let isMd = ext == ".md" || ext == ".markdown" || ext == ".mdx"
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var hashes = 0
            for ch in line {
                if ch == "#" { hashes += 1 } else { break }
            }
            if hashes >= 1, hashes <= 6 {
                var rest = line.dropFirst(hashes)
                if rest.first == " " || rest.first == "\t" {
                    rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                    return String(rest).trimmingCharacters(in: .whitespaces)
                }
            }
            if isMd, line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == "=" }) {
                continue
            }
            if let first = line.first, "<>{}[]()".contains(first), line.count < 8 { continue }
            // 140 也按 UTF-16 码元切，和 JS 的 slice(0,140) 同一个口径
            if line.utf16.count > 140 {
                return String(decoding: Array(line.utf16.prefix(140)), as: UTF16.self)
            }
            return line
        }
        return ""
    }

    // MARK: - 扫描规则（照 config.js 移植）

    private struct Settings {
        var ignoredDirs: Set<String>
        var ignoredDirSuffixes: [String]
        var denyGlobs: [String]
        var maxTextBytes: Int
        var maxStoredBodyChars: Int
        var maxDepth: Int

        enum Skip { case ignoredName, ignoredSuffix }

        func skipReason(_ name: String) -> Skip? {
            if ignoredDirs.contains(name) { return .ignoredName }
            let lower = name.lowercased()
            if ignoredDirSuffixes.contains(where: { lower.hasSuffix($0) }) { return .ignoredSuffix }
            return nil
        }

        func isTextExt(_ ext: String) -> Bool { Settings.textExtensions.contains(ext) }
        func kindOf(_ ext: String) -> String {
            if let k = Settings.kindByExt[ext] { return k }
            return Settings.codeExtensions.contains(ext) ? "code" : "other"
        }
        func isDeniedRead(_ name: String) -> Bool {
            denyGlobs.contains { globMatch($0, name) }
        }

        /// 默认值照 config.js 抄；**如果 `~/.localvault/config.json` 存在，就以它为准**。
        /// 为什么要读它：用户可能往 `ignoredDirs` 里加了自己的目录（或改了正文上限），
        /// CLI 会照着做。App 若只认自己的默认表，同一个库就会出现两种口径。
        static func load() -> Settings {
            var s = Settings(ignoredDirs: Set(defaultIgnoredDirs),
                             ignoredDirSuffixes: defaultIgnoredDirSuffixes,
                             denyGlobs: defaultDenyRead,
                             maxTextBytes: 2 * 1024 * 1024,
                             maxStoredBodyChars: 400_000,
                             maxDepth: 24)
            guard let data = try? Data(contentsOf: VaultConfig.defaultURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
            if let v = obj["ignoredDirs"] as? [String], !v.isEmpty { s.ignoredDirs = Set(v) }
            if let v = obj["ignoredDirSuffixes"] as? [String], !v.isEmpty { s.ignoredDirSuffixes = v }
            if let v = obj["denyRead"] as? [String], !v.isEmpty { s.denyGlobs = v }
            if let v = obj["maxTextBytes"] as? Int, v > 0 { s.maxTextBytes = v }
            if let v = obj["maxStoredBodyChars"] as? Int, v > 0 { s.maxStoredBodyChars = v }
            if let v = obj["maxDepth"] as? Int, v > 0 { s.maxDepth = v }
            return s
        }

        /// 与 config.js 的 DEFAULT_IGNORED_DIRS 同一份清单（顺序无关，这里是集合）
        static let defaultIgnoredDirs = [
            "node_modules", ".git", ".svn", ".hg", ".bzr",
            "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".nox",
            "dist", "build", ".next", ".nuxt", ".svelte-kit", ".output", ".turbo",
            ".parcel-cache", ".vite", ".rollup.cache", "coverage", ".nyc_output",
            "target", ".gradle", ".m2", ".cargo", ".rustup",
            ".idea", ".vs", "Pods", "Carthage", "DerivedData", ".swiftpm", ".dart_tool",
            ".cache", ".npm", ".pnpm-store", ".yarn", ".Trash", ".Trashes",
            ".terraform", ".serverless", ".aws-sam", "site-packages", ".ipynb_checkpoints",
            ".expo", ".angular", ".parcel-cache", ".eslintcache",
            ".ssh", ".gnupg", ".kube", ".docker", ".codex", ".claude", ".dsh",
            ".zsh_sessions", ".zsh_history", ".DS_Store", "Caches", "Containers",
        ]
        // 注意：`config.js` 的默认表里**没有 `.build`**（有 `dist`/`build`，没有 `.build`）。
        // 所以 CLI 是真的会把 SwiftPM 的 `.build/` 索引进去的（实测本机库里 204 行），
        // 这里绝不能"顺手"补一个 —— 那会让同一个库出现两种口径。
        // 想让它被跳过，正确的做法是往 `config.js` 的 DEFAULT_IGNORED_DIRS 里加，
        // 两边同时生效；`Settings.load()` 会尊重用户在 config.json 里的覆盖。

        static let defaultIgnoredDirSuffixes = [
            ".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace",
            ".photoslibrary", ".lproj", ".asar", ".plugin", ".kext", ".rtfd",
            ".download", ".noindex",
        ]

        static let defaultDenyRead = [
            ".env", ".env.*", "*.env", ".netrc", ".npmrc", ".pypirc",
            "*.pem", "*.key", "*.crt", "*.p12", "*.pfx", "*.jks", "*.keystore",
            "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
            "*credential*", "*secret*", "*password*", "*passwd*", "*.kdbx",
            "*-service-account*.json", "*token*.json", ".credentials.yaml",
            "*.mobileprovision", "*.ovpn", "*.kubeconfig",
        ]

        static let textExtensions: Set<String> = [
            ".md", ".markdown", ".mdx", ".txt", ".text", ".rst", ".org", ".adoc",
            ".json", ".json5", ".jsonc", ".ndjson", ".geojson",
            ".yml", ".yaml", ".toml", ".ini", ".cfg", ".conf", ".properties", ".env.example",
            ".xml", ".plist", ".csv", ".tsv", ".srt", ".vtt", ".log",
            ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".vue", ".svelte",
            ".py", ".rb", ".php", ".pl", ".lua", ".r",
            ".java", ".kt", ".kts", ".scala", ".groovy", ".clj",
            ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".go", ".rs", ".swift", ".m", ".mm", ".dart",
            ".sh", ".bash", ".zsh", ".fish", ".ps1", ".bat", ".cmd",
            ".sql", ".graphql", ".gql", ".proto", ".http",
            ".html", ".htm", ".xhtml", ".css", ".scss", ".sass", ".less", ".styl",
            ".tex", ".bib", ".diff", ".patch", ".gitignore", ".gitattributes", ".editorconfig",
        ]

        static let kindByExt: [String: String] = [
            ".md": "doc", ".markdown": "doc", ".mdx": "doc", ".txt": "doc", ".text": "doc",
            ".rst": "doc", ".org": "doc", ".adoc": "doc", ".rtf": "doc",
            ".pdf": "doc", ".doc": "doc", ".docx": "doc", ".pages": "doc", ".epub": "doc",
            ".xls": "sheet", ".xlsx": "sheet", ".numbers": "sheet", ".csv": "sheet", ".tsv": "sheet",
            ".ppt": "slide", ".pptx": "slide", ".key": "slide",
            ".png": "image", ".jpg": "image", ".jpeg": "image", ".gif": "image", ".webp": "image",
            ".svg": "image", ".heic": "image", ".tiff": "image", ".bmp": "image", ".ico": "image",
            ".psd": "image", ".ai": "image", ".sketch": "image", ".fig": "image", ".xd": "image",
            ".mp4": "video", ".mov": "video", ".mkv": "video", ".avi": "video", ".webm": "video",
            ".m4v": "video", ".flv": "video", ".wmv": "video",
            ".mp3": "audio", ".wav": "audio", ".m4a": "audio", ".flac": "audio", ".aac": "audio",
            ".ogg": "audio", ".aiff": "audio", ".opus": "audio",
            ".zip": "archive", ".tar": "archive", ".gz": "archive", ".tgz": "archive",
            ".rar": "archive", ".7z": "archive", ".dmg": "archive", ".pkg": "archive",
            ".iso": "archive", ".jar": "archive", ".war": "archive",
            ".html": "web", ".htm": "web", ".xhtml": "web", ".css": "web", ".scss": "web",
            ".sass": "web", ".less": "web", ".styl": "web",
            ".json": "data", ".json5": "data", ".ndjson": "data", ".geojson": "data",
            ".yml": "data", ".yaml": "data", ".toml": "data", ".ini": "data", ".conf": "data",
            ".xml": "data", ".plist": "data", ".sql": "data", ".db": "data", ".sqlite": "data",
        ]

        static let codeExtensions: Set<String> = [
            ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".vue", ".svelte",
            ".py", ".rb", ".php", ".pl", ".lua", ".r",
            ".java", ".kt", ".kts", ".scala", ".groovy", ".clj",
            ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".go", ".rs", ".swift", ".m", ".mm", ".dart",
            ".sh", ".bash", ".zsh", ".fish", ".ps1", ".bat", ".cmd",
        ]
    }

    /// `globToRegExp` 的语言：`*` = 任意非 `/` 序列，`?` = 一个非 `/` 字符，整串匹配，忽略大小写。
    /// 直接写匹配器而不是拼正则：deny 名单要对每个文件跑一遍，正则引擎没必要。
    private static func globMatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(name.lowercased())
        var pi = 0, si = 0
        var starPi = -1, starSi = 0
        while si < s.count {
            if pi < p.count && p[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
            } else if pi < p.count && (p[pi] == "?" ? s[si] != "/" : p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if starPi >= 0 {
                if s[starSi] == "/" { return false }
                starSi += 1
                si = starSi
                pi = starPi + 1
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - 写库

    private struct PrevRow {
        let size: Int64
        let mtime: Int64
        let isText: Bool
        let denied: Bool

        func matches(_ e: Entry, denied: Bool) -> Bool {
            size == e.size && mtime == e.mtimeMs && isText == e.isText && self.denied == denied
        }
    }

    private struct Record {
        let entry: Entry
        let root: String
        let scanId: Int64
        let denied: Bool
        var extracted = Extracted()
    }

    private static func markGoneOlderThan(_ db: OpaquePointer, root: String, scanId: Int64) -> Int {
        guard let stmt = prepare(db, "UPDATE files SET gone = 1 WHERE root = ? AND scan_id <> ? AND gone = 0") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, root)
        sqlite3_bind_int64(stmt, 2, scanId)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private static func recordScanRun(_ db: OpaquePointer, startedAt: Int64, finishedAt: Int64,
                                      root: String, filesSeen: Int, filesAdded: Int, filesUpdated: Int,
                                      filesRemoved: Int, dirsSeen: Int, skippedDirs: Int,
                                      errors: Int, elapsedMs: Int) {
        let sql = """
            INSERT INTO scan_runs (started_at, finished_at, root, files_seen, files_added, files_updated,
                                   files_removed, dirs_seen, skipped_dirs, errors, elapsed_ms, ok, detail)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,1,'')
            """
        guard let stmt = prepare(db, sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startedAt)
        sqlite3_bind_int64(stmt, 2, finishedAt)
        bindText(stmt, 3, root)
        sqlite3_bind_int64(stmt, 4, Int64(filesSeen))
        sqlite3_bind_int64(stmt, 5, Int64(filesAdded))
        sqlite3_bind_int64(stmt, 6, Int64(filesUpdated))
        sqlite3_bind_int64(stmt, 7, Int64(filesRemoved))
        sqlite3_bind_int64(stmt, 8, Int64(dirsSeen))
        sqlite3_bind_int64(stmt, 9, Int64(skippedDirs))
        sqlite3_bind_int64(stmt, 10, Int64(errors))
        sqlite3_bind_int64(stmt, 11, Int64(elapsedMs))
        sqlite3_step(stmt)
    }

    /// 写入器：一次扫描一批事务，而不是逐条提交（9,500 个文件逐条提交要几十秒）。
    private final class Writer {
        private let db: OpaquePointer
        private var putStmt: OpaquePointer?
        private var touchStmt: OpaquePointer?
        private var ops = 0
        private var inTx = false

        init(db: OpaquePointer) throws {
            self.db = db
            // 与 store.js 的 BatchWriter 同一组列、同一条 UPSERT（path 是 UNIQUE，冲突即更新）
            putStmt = prepare(db, """
                INSERT INTO files (root, path, rel, name, ext, kind, size, mtime, birthtime,
                                   is_text, is_symlink, denied, is_binary, title, headings, body,
                                   truncated, scan_id, gone)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
                ON CONFLICT(path) DO UPDATE SET
                  root = excluded.root, rel = excluded.rel, name = excluded.name, ext = excluded.ext,
                  kind = excluded.kind, size = excluded.size, mtime = excluded.mtime,
                  birthtime = excluded.birthtime, is_text = excluded.is_text,
                  is_symlink = excluded.is_symlink, denied = excluded.denied,
                  is_binary = excluded.is_binary, title = excluded.title,
                  headings = excluded.headings, body = excluded.body,
                  truncated = excluded.truncated, scan_id = excluded.scan_id, gone = 0
                """)
            // 未变化的文件只刷元数据列 —— 正文原样保留。**故意不更新 birthtime/is_symlink**，
            // 与 store.js 的 touchStmt 逐列一致（这两列在"没变"的行上本来也不该变）。
            touchStmt = prepare(db, """
                UPDATE files SET root = ?, rel = ?, name = ?, ext = ?, kind = ?,
                                 size = ?, mtime = ?, scan_id = ?, gone = 0, denied = ?
                WHERE path = ?
                """)
            guard putStmt != nil, touchStmt != nil else { throw Failure.sql("写入语句准备失败") }
        }

        func finish() {
            if inTx { sqlite3_exec(db, "COMMIT", nil, nil, nil); inTx = false }
            sqlite3_finalize(putStmt)
            sqlite3_finalize(touchStmt)
        }

        private func beginIfNeeded() {
            if !inTx {
                sqlite3_exec(db, "BEGIN", nil, nil, nil)
                inTx = true
            }
        }

        func commit() throws {
            if inTx {
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    inTx = false
                    throw Failure.sql(String(cString: sqlite3_errmsg(db)))
                }
                inTx = false
            }
        }

        func put(_ r: Record) throws {
            beginIfNeeded()
            guard let s = putStmt else { throw Failure.sql("写入语句已释放") }
            sqlite3_reset(s)
            let e = r.entry
            bindText(s, 1, r.root)
            bindText(s, 2, e.path)
            bindText(s, 3, e.rel)
            bindText(s, 4, e.name)
            bindText(s, 5, e.ext)
            bindText(s, 6, e.kind)
            sqlite3_bind_int64(s, 7, e.size)
            sqlite3_bind_int64(s, 8, e.mtimeMs)
            sqlite3_bind_int64(s, 9, e.birthtimeMs)
            sqlite3_bind_int64(s, 10, e.isText ? 1 : 0)
            sqlite3_bind_int64(s, 11, e.isSymlink ? 1 : 0)
            sqlite3_bind_int64(s, 12, r.denied ? 1 : 0)
            sqlite3_bind_int64(s, 13, r.extracted.isBinary ? 1 : 0)
            bindText(s, 14, r.extracted.title)
            bindText(s, 15, r.extracted.headings)
            bindText(s, 16, r.extracted.body)
            sqlite3_bind_int64(s, 17, r.extracted.truncated ? 1 : 0)
            sqlite3_bind_int64(s, 18, r.scanId)
            let rc = sqlite3_step(s)
            guard rc == SQLITE_DONE else { throw Failure.sql(String(cString: sqlite3_errmsg(db))) }
            ops += 1
            if ops % 2000 == 0 { rollOver() }
        }

        /// 返回 false 表示行不存在（调用方要退到 put）
        func touch(_ r: Record) -> Bool {
            beginIfNeeded()
            guard let s = touchStmt else { return false }
            sqlite3_reset(s)
            let e = r.entry
            bindText(s, 1, r.root)
            bindText(s, 2, e.rel)
            bindText(s, 3, e.name)
            bindText(s, 4, e.ext)
            bindText(s, 5, e.kind)
            sqlite3_bind_int64(s, 6, e.size)
            sqlite3_bind_int64(s, 7, e.mtimeMs)
            sqlite3_bind_int64(s, 8, r.scanId)
            sqlite3_bind_int64(s, 9, r.denied ? 1 : 0)
            bindText(s, 10, e.path)
            guard sqlite3_step(s) == SQLITE_DONE else { return false }
            // 先取值再 rollOver：COMMIT/BEGIN 之后 sqlite3_changes 的语义没必要去赌
            let changed = sqlite3_changes(db) > 0
            ops += 1
            if ops % 5000 == 0 { rollOver() }
            return changed
        }

        /// 定期提交，避免单个大事务把内存撑起来（WAL 会一直长）
        private func rollOver() {
            if inTx {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                sqlite3_exec(db, "BEGIN", nil, nil, nil)
            }
        }
    }

    // MARK: - SQLite 小工具

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private static func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) -> String? {
        guard let stmt = prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static func setMeta(_ db: OpaquePointer, _ key: String, _ value: String) {
        guard let stmt = prepare(db, "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
    }
}
