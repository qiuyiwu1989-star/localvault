import Foundation

// 云盘登记成索引根的 headless 测试。
//
// 跑法：sh scripts/drive-index-check.sh
//
// 它守的是**一句承诺**：云盘 `说明.md` 写着「拖进来之后在被索引时会自动被读到」，
// 而真实配置里云盘从来不在 roots 中 —— 于是那句话永远是假的。
// 这里断言的是「登记」这一步的性质；「登记完 agent 真的读得到」在
// scripts/drive-index-check.sh 里用真实索引 + 真实 MCP 查询接着验。

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
    else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
}

// ── 拒跑闸门 ──────────────────────────────────────────────────────
//
// 这个测试**会写 config.json**。真实配置里有用户手写的 policy / ignoredDirs /
// denyRead，被这个测试覆盖掉是不可接受的。
//
// 而 `NSHomeDirectory()` 只认 `CFFIXED_USER_HOME`，**不认 `HOME`** ——
// 实测：只设 HOME 时它照样返回 /Users/Apple。所以「我设了 HOME」不是安全保证，
// 必须直接检查结果值。（这个仓库真的出过一次：漏设 CFFIXED_USER_HOME，
// 覆盖了真实 config.json。）
//
// 让它走不通，而不是靠记得。
let home = NSHomeDirectory()
let looksTemporary = home.hasPrefix("/var/folders/") || home.hasPrefix("/tmp/")
if !looksTemporary {
    print("  ✗ 拒跑：NSHomeDirectory() = \(home)")
    print("    这不是临时主目录，而本测试会写 config.json。")
    print("    请设 CFFIXED_USER_HOME（只设 HOME 无效），或显式设 LV_ALLOW_REAL_HOME=1。")
    exit(2)
}

let fm = FileManager.default
let configURL = VaultConfig.defaultURL
let dataDir = configURL.deletingLastPathComponent()

// ── 驱动模式 ────────────────────────────────────────────────────
//
// `--register-only`：只走一次**产品代码**（`VaultConfig.ensureRoot`）就退出，
// 供 `scripts/drive-index-check.sh` 的端到端部分当驱动用 ——
// 那段要验的是「登记完 agent 真的读得到」，需要先由产品代码写好配置，
// 再交给真实索引器与真实 MCP 查询。
//
// 直接用 shell 手写 config.json 是不行的：那样验的是「配置长这样就能读到」，
// 而没验「App 写出来的配置就是这个样子」。差一步，就少测一条。
if CommandLine.arguments.contains("--register-only") {
    let p = home + "/Documents/本地上下文云盘"
    do {
        let added = try VaultConfig.ensureRoot(path: p, label: "云盘")
        print(added ? "registered" : "already-registered")
    } catch {
        print("register-failed: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

func writeConfig(_ text: String) {
    try! fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try! text.write(to: configURL, atomically: true, encoding: .utf8)
}
func readConfig() -> [String: Any] {
    let d = try! Data(contentsOf: configURL)
    return (try! JSONSerialization.jsonObject(with: d)) as! [String: Any]
}
func reset() {
    try? fm.removeItem(at: dataDir)
}

let drivePath = home + "/Documents/本地上下文云盘"

print("云盘登记成索引根（VaultConfig.ensureRoot）")
print("  假主目录：\(home)")
print("")

// ── 1. 全新机器：没有配置文件 ────────────────────────────────────
do {
    reset()
    let added = try VaultConfig.ensureRoot(path: drivePath, label: "云盘")
    check("没有配置文件时：登记成功并返回 true", added)
    let obj = readConfig()
    let roots = (obj["roots"] as? [[String: Any]]) ?? []
    check("新文件里正好一个根，且是云盘", roots.count == 1
          && (roots[0]["path"] as? String) == "~/Documents/本地上下文云盘",
          (roots[0]["path"] as? String) ?? "无")
    check("路径按 ~ 压缩写盘（换机器也能用）",
          ((roots.first?["path"] as? String) ?? "").hasPrefix("~/"),
          (roots.first?["path"] as? String) ?? "无")
    check("primaryRoot 被填上，不留空", ((obj["primaryRoot"] as? String) ?? "").isEmpty == false)
}

// ── 2. 已有配置：不能丢掉用户手写的键 ───────────────────────────
// 这是这个仓库真出过的事故形态（一次向导续跑把 16 键写成 4 键）。
do {
    reset()
    writeConfig("""
    {
      "version": 2,
      "dataDir": "~/.localvault",
      "primaryRoot": "~/Documents/邱懿武03",
      "roots": [
        {"path": "~/Documents/邱懿武03", "label": "工作区", "priority": 10},
        {"path": "~/Desktop", "label": "桌面", "priority": 20}
      ],
      "ignoredDirs": ["node_modules", ".build"],
      "denyRead": ["**/密钥*"],
      "policy": {"inboxDir": "待整理", "inboxStaleDays": 30},
      "canonicalDocs": {"工作区": "00-从这里开始.md"}
    }
    """)
    let before = readConfig()
    let added = try VaultConfig.ensureRoot(path: drivePath, label: "云盘")
    let after = readConfig()

    check("已有配置时：登记成功并返回 true", added)
    check("roots 从 2 个变 3 个", ((after["roots"] as? [[String: Any]]) ?? []).count == 3,
          String(((after["roots"] as? [[String: Any]]) ?? []).count))

    // 逐个键对拍：**一个都不能少**
    for key in ["ignoredDirs", "denyRead", "policy", "canonicalDocs"] {
        let b = before[key] != nil
        let a = after[key] != nil
        check("用户手写的 `\(key)` 还在", b && a, a ? "" : "**被冲掉了**")
        if let bj = try? JSONSerialization.data(withJSONObject: before[key] as Any, options: [.sortedKeys]),
           let aj = try? JSONSerialization.data(withJSONObject: after[key] as Any, options: [.sortedKeys]) {
            check("`\(key)` 的内容逐字节没变", bj == aj, bj == aj ? "" : "值被改动了")
        }
    }

    let roots = (after["roots"] as? [[String: Any]]) ?? []
    let work = roots.first { ($0["path"] as? String) == "~/Documents/邱懿武03" }
    check("已有根的 priority 被继承，没丢", (work?["priority"] as? Int) == 10,
          String(describing: work?["priority"]))
    check("已有根的 label 没被改", (work?["label"] as? String) == "工作区")
    check("已有根的位置没被挪（云盘追加在末尾）",
          (roots.last?["path"] as? String) == "~/Documents/本地上下文云盘",
          (roots.last?["path"] as? String) ?? "无")
    check("primaryRoot 没被改成云盘",
          (after["primaryRoot"] as? String) == "~/Documents/邱懿武03",
          (after["primaryRoot"] as? String) ?? "无")
    check("version 仍是 2", (after["version"] as? Int) == 2)
}

// ── 3. 幂等：再调一次不能变成两个云盘 ───────────────────────────
do {
    let added = try VaultConfig.ensureRoot(path: drivePath, label: "云盘")
    let roots = (readConfig()["roots"] as? [[String: Any]]) ?? []
    check("第二次调用返回 false（这次没加）", added == false)
    check("roots 仍然是 3 个，没有重复项", roots.count == 3, String(roots.count))
    check("云盘只出现一次",
          roots.filter { ($0["path"] as? String) == "~/Documents/本地上下文云盘" }.count == 1)
}

// ── 4. 路径等价性：写成绝对路径也不该重复登记 ───────────────────
do {
    let added = try VaultConfig.ensureRoot(path: drivePath, label: "云盘")
    check("用绝对路径再登记一次 → 仍是 false（按展开后的路径比）", added == false)
}

// ── 5. 配置读不懂时：抛错，绝不覆盖 ─────────────────────────────
// 「与其把不认识的内容覆盖掉，不如失败」—— 这条要是失守，
// 用户的配置会在一次「加个索引根」里被静默清空。
do {
    reset()
    writeConfig("{ 这不是 JSON ")
    var threw = false
    do { _ = try VaultConfig.ensureRoot(path: drivePath, label: "云盘") }
    catch { threw = true }
    check("配置读不懂时抛错", threw, threw ? "" : "**没有抛错**")
    let raw = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    check("读不懂的文件内容原样没动", raw.contains("这不是 JSON"),
          raw.contains("这不是 JSON") ? "" : "**被覆盖了**")
}

// ── 6. 读回来：展开成绝对路径 ───────────────────────────────────
do {
    reset()
    writeConfig("""
    {"version":2,"dataDir":"~/.localvault","primaryRoot":"~/x",
     "roots":[{"path":"~/x","label":"X"}]}
    """)
    _ = try VaultConfig.ensureRoot(path: drivePath, label: "云盘")
    let cfg = VaultConfig.load()
    check("load() 读回来是 2 个根", cfg?.roots.count == 2, String(cfg?.roots.count ?? -1))
    check("云盘读回来是绝对路径",
          cfg?.roots.contains { $0.path == drivePath } == true,
          cfg?.roots.map { $0.path }.joined(separator: " | ") ?? "无")
}

try? fm.removeItem(at: dataDir)

print("")
print("通过 \(pass) · 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
