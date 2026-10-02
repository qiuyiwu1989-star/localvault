import Foundation
import SQLite3
import AppKit

/// 一条**条陈**（Claim）—— SPEC.md §2 的原语。
///
/// > 条陈：一条带来源链的断言。一个存储，五种 kind，每种一套策略。
/// > 每条条陈必带：source_ref、holder、signed_by（人名或机器策略名，**不可为空**）、ts。
///
/// 这个结构刻意逐字对 SPEC §2 实现，包括那 4 个不可为空字段。
struct Claim: Identifiable, Hashable {
    let id: Int64
    let kind: String          // event | material | fact | judgment | consequence
    let targetType: String    // file | dir | project
    let target: String
    let verdict: String?      // 判断态；非 judgment 类为 nil
    let note: String
    let sourceRef: String     // 指回矿场或上游条陈
    let holder: String        // 谁的
    let signedBy: String      // 人名或机器策略名，不可为空
    let actorType: String     // human | machine
    let authority: String     // L0 待签 | L1 已批
    let ts: Int64

    var isMachine: Bool { actorType == "machine" }

    var tsText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// 判断的四个词。**这些词是给人的，不是给工具的。**
enum Verdict: String, CaseIterable, Identifiable {
    case keep        = "保留"
    case review      = "待看"
    case archive     = "可归档"
    case discardable = "可清理"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .keep:        return "明确有价值，别再问"
        case .review:      return "还没看，先别动"
        case .archive:     return "不用了但先别删"
        case .discardable: return "可以删（**仍然不会自动删**）"
        }
    }
}

/// 撤回是一个**追加动作**，不是删除。
enum Retracted {
    static let verdict = "撤回"
}

/// 条陈的存储。
///
/// 两个不变量在这里是硬约束，不是注释：
///
/// - **I**：`signed_by` 与 `actor_type` 都 NOT NULL。人签的和机器写的一眼可分。
/// - **II**：**只追加**。没有任何 UPDATE，没有任何 DELETE。
///   当前判断是事件流的投影（取每个目标最新一条），可重放。
///   撤回 = 追加一条 `撤回` 条陈 + 留痕。
///
/// 它**刻意不写进 `vault.db`**：索引是可重建的派生物，判断不是。
/// 两个文件、两种生命周期。放在同一数据目录下，所以仍然只有一套数据。
final class ClaimStore: ObservableObject {

    private var db: OpaquePointer?
    let dbPath: String

    /// 全部条陈，按时间倒序。**永不删除，所以这是完整历史。**
    @Published var claims: [Claim] = []
    /// 当前状态 = 事件流的投影。目标 → 最新一条（撤回的不在内）。
    @Published var current: [String: Claim] = [:]
    @Published var error: String?

    /// 机器策略名。机器写的东西必须挂在一个可追溯的策略名下，而不是假装是人。
    static let machinePolicy = "policy:localvault-agent"

    /// 签字人。`signed_by` 不可为空，所以一定有值。
    /// 默认取 macOS 账户全名，用 `--signer <名字>` 改 —— 签名要能指向人，不能只是占位符。
    @Published private(set) var signer: String = "" 

    init(path: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = path ?? "\(home)/.localvault/claims.db"
        open()
        reload()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func open() {
        var handle: OpaquePointer?
        guard sqlite3_open(dbPath, &handle) == SQLITE_OK, let h = handle else {
            error = "打不开条陈库：\(dbPath)"
            return
        }
        db = h

        // 只增表：没有 UNIQUE 约束，因为同一目标本来就会有历史多条。
        // NOT NULL 直接写进 schema —— 不变量靠数据库强制，不靠调用方自觉。
        let ddl = """
            CREATE TABLE IF NOT EXISTS claims (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              kind         TEXT    NOT NULL,
              target_type  TEXT    NOT NULL,
              target       TEXT    NOT NULL,
              verdict      TEXT,
              note         TEXT    NOT NULL DEFAULT '',
              source_ref   TEXT    NOT NULL,
              holder       TEXT    NOT NULL,
              signed_by    TEXT    NOT NULL,
              actor_type   TEXT    NOT NULL CHECK(actor_type IN ('human','machine')),
              authority    TEXT    NOT NULL CHECK(authority IN ('L0','L1','L2')),
              ts           INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_claims_target ON claims(target_type, target, ts);
            CREATE INDEX IF NOT EXISTS idx_claims_kind   ON claims(kind, ts);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, ddl, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "未知错误"
            if let err { sqlite3_free(err) }
            error = "建表失败：\(m)"
        }
        loadSigner()
    }

    private func loadSigner() {
        guard let db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='signer'", -1, &stmt, nil) == SQLITE_OK,
           let s = stmt {
            defer { sqlite3_finalize(s) }
            if sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) {
                let v = String(cString: c)
                if !v.trimmingCharacters(in: .whitespaces).isEmpty { signer = v; return }
            }
        } else if let stmt { sqlite3_finalize(stmt) }
        // 没设过：用系统账户全名兜底并落库
        let full = NSFullUserName()
        setSigner(full.isEmpty ? NSUserName() : full)
    }

    /// 设置签字人。空值会被拒绝 —— 签不了名就不该签。
    func setSigner(_ name: String) {
        let v = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { error = "签字人不能为空"; return }
        signer = v
        guard let db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta(key,value) VALUES('signer',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        bind(s, [v])
        sqlite3_step(s)
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int64:  sqlite3_bind_int64(stmt, idx, v)
            default:              sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func reload() {
        guard let db else { return }
        let sql = """
            SELECT id,kind,target_type,target,verdict,note,source_ref,holder,
                   signed_by,actor_type,authority,ts
            FROM claims ORDER BY ts DESC, id DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }

        var out: [Claim] = []
        while sqlite3_step(s) == SQLITE_ROW {
            func t(_ c: Int32) -> String {
                sqlite3_column_text(s, c).map { String(cString: $0) } ?? ""
            }
            func opt(_ c: Int32) -> String? {
                sqlite3_column_text(s, c).map { String(cString: $0) }
            }
            out.append(Claim(
                id: sqlite3_column_int64(s, 0),
                kind: t(1), targetType: t(2), target: t(3),
                verdict: opt(4), note: t(5),
                sourceRef: t(6), holder: t(7), signedBy: t(8),
                actorType: t(9), authority: t(10),
                ts: sqlite3_column_int64(s, 11)
            ))
        }
        claims = out

        // 投影：每个目标取最新一条；被撤回的目标没有当前判断。
        //
        // `seen` 是必须的：不能靠「字典里已有就跳过」来去重。
        // 撤回的目标会从字典里消失，于是更旧的那条会被重新填回来 —— 撤回就白撤了。
        var proj: [String: Claim] = [:]
        var seen = Set<String>()
        for c in out {   // out 已按 ts DESC 排好，首次出现即最新
            guard !seen.contains(c.target) else { continue }
            seen.insert(c.target)
            if c.verdict == Retracted.verdict { continue }
            proj[c.target] = c
        }
        current = proj
    }

    // MARK: 写入（全部是追加）

    /// 人签一条判断。`signed_by` 是账户全名，不可能是空。
    func judge(targetType: String, target: String, verdict: Verdict, note: String = "") {
        append(
            kind: "judgment", targetType: targetType, target: target,
            verdict: verdict.rawValue, note: note,
            sourceRef: "vault://file/\(target)",
            holder: signer, signedBy: signer,
            actorType: "human", authority: "L1"
        )
    }

    /// 撤回。**不删行** —— 追加一条逆操作，旧判断留在历史里。
    func retract(targetType: String, target: String, reason: String = "") {
        append(
            kind: "judgment", targetType: targetType, target: target,
            verdict: Retracted.verdict, note: reason,
            sourceRef: "vault://file/\(target)",
            holder: signer, signedBy: signer,
            actorType: "human", authority: "L1"
        )
    }

    /// **机器写。** 只允许落 L0 待签。
    ///
    /// 这就是不变量 I 的具体实现：机器产出的东西挂在一个 `policy:` 名下，
    /// `actor_type='machine'`，权威级 L0。它在数据层就不可能被误读成人签的。
    func annotate(targetType: String, target: String, note: String, kind: String = "material") {
        append(
            kind: kind, targetType: targetType, target: target,
            verdict: nil, note: note,
            sourceRef: "vault://file/\(target)",
            holder: signer, signedBy: ClaimStore.machinePolicy,
            actorType: "machine", authority: "L0"
        )
    }

    private func append(kind: String, targetType: String, target: String,
                        verdict: String?, note: String, sourceRef: String,
                        holder: String, signedBy: String, actorType: String,
                        authority: String) {
        guard let db else { return }
        // 不可为空字段在这里再挡一次 —— 数据库有 NOT NULL，
        // 但空字符串能绕过 NOT NULL，所以调用点也要挡。
        guard !signedBy.trimmingCharacters(in: .whitespaces).isEmpty,
              !sourceRef.trimmingCharacters(in: .whitespaces).isEmpty,
              !holder.trimmingCharacters(in: .whitespaces).isEmpty,
              !target.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "条陈缺少必填字段（source_ref / holder / signed_by / target 不可为空）"
            return
        }
        // 机器只能写 L0。这条是硬的：越界直接拒绝。
        if actorType == "machine" && authority != "L0" {
            error = "机器只能写 L0 待签条陈（不变量 I）"
            return
        }

        let sql = """
            INSERT INTO claims
              (kind,target_type,target,verdict,note,source_ref,holder,signed_by,actor_type,authority,ts)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        bind(s, [kind, targetType, target, verdict, note, sourceRef, holder,
                 signedBy, actorType, authority, Int64(Date().timeIntervalSince1970)])
        if sqlite3_step(s) != SQLITE_DONE {
            error = "追加条陈失败"
        }
        reload()
    }

    // MARK: 读

    func verdict(for target: String) -> Claim? { current[target] }

    /// 全部条陈（含历史与机器条陈）—— 审计视图用
    func history(for target: String) -> [Claim] {
        claims.filter { $0.target == target }
    }

    func counts() -> [(Verdict, Int)] {
        Verdict.allCases.map { v in
            (v, current.values.filter { $0.verdict == v.rawValue }.count)
        }
    }

    var machineCount: Int { claims.filter(\.isMachine).count }
    var humanCount: Int { claims.filter { !$0.isMachine }.count }
}
