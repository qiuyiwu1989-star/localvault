import AppKit
import Foundation
import UniformTypeIdentifiers

// 拖拽收集的 headless 测试。
//
// 跑法：sh scripts/file-drop-check.sh
//
// 为什么要有它：这个 bug（在主线程上 `DispatchGroup.wait` 等 NSItemProvider 的回调）
// **手拖是验不出来的** —— 手拖只会看到「没反应」，而没反应可能是十几种原因。
// 这里把两件可断言的事分开测：
//   1. 同步调用**必须立刻返回**（不阻塞主线程）；
//   2. 回调**必须真的到达**并带着 URL。
// 只测第 2 条不够：返回 false 的实现也能让第 2 条通过（超时算失败，但看不出是为什么）。

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
    else { fail += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
}

/// 转主线程 run loop，直到条件成立或超时。
///
/// 用 run loop 而不是 `Thread.sleep`：`Thread.sleep` 会把投递一起堵死 ——
/// 那正是被测代码原来的毛病，测试再用一次就等于用 bug 去测 bug。
func pump(until done: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return done()
}

// ── 夹具 ────────────────────────────────────────────────────────
let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("lvfiledrop-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmpRoot) }

let fileA = tmpRoot.appendingPathComponent("甲.txt")
let fileB = tmpRoot.appendingPathComponent("乙.md")
let folder = tmpRoot.appendingPathComponent("一个文件夹")
FileManager.default.createFile(atPath: fileA.path, contents: Data("a".utf8))
FileManager.default.createFile(atPath: fileB.path, contents: Data("b".utf8))
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

print("拖拽收集（FileDrop）")
print("")

// ── 1. 单个文件 ─────────────────────────────────────────────────
// 这一节同时量「同步返回耗时」：原来那版在主线程 wait 3 秒，
// 所以这条断言是专门为那个 bug 立的。
do {
    var got: [URL] = []
    let t0 = Date()
    let returned = FileDrop.collectURLs(from: [NSItemProvider(contentsOf: fileA)!]) { got = $0 }
    let syncElapsed = Date().timeIntervalSince(t0)

    check("单个文件：同步返回 true（SwiftUI 靠它决定收不收这次投放）", returned,
          returned ? "" : "返回 false，界面会直接无视这次拖拽")
    check("单个文件：同步调用立刻返回、不阻塞主线程",
          syncElapsed < 0.1,
          String(format: "%.3fs（改回主线程 wait 会是 3.000s）", syncElapsed))

    let arrived = pump(until: { !got.isEmpty }, timeout: 3)
    check("单个文件：回调到达", arrived, arrived ? "" : "3 秒内没来 —— 回调被卡住了")
    check("单个文件：正好 1 个 URL 且路径正确",
          got.count == 1 && got.first?.resolvingSymlinksInPath().path == fileA.resolvingSymlinksInPath().path,
          got.map { $0.lastPathComponent }.joined(separator: ", "))
}

// ── 2. 多个文件 ─────────────────────────────────────────────────
do {
    var got: [URL] = []
    _ = FileDrop.collectURLs(from: [NSItemProvider(contentsOf: fileA)!,
                                    NSItemProvider(contentsOf: fileB)!]) { got = $0 }
    let arrived = pump(until: { got.count >= 2 }, timeout: 3)
    check("多个文件：两个都收齐", arrived && got.count == 2,
          got.map { $0.lastPathComponent }.sorted().joined(separator: ", "))
}

// ── 3. 文件夹 ───────────────────────────────────────────────────
// 拖文件夹进来也该给一个 URL。`DriveStore.ingest` 会 copyItem，
// 文件夹照样能复制 —— 所以这一条不能因为「是目录」就被过滤掉。
do {
    var got: [URL] = []
    _ = FileDrop.collectURLs(from: [NSItemProvider(contentsOf: folder)!]) { got = $0 }
    let arrived = pump(until: { !got.isEmpty }, timeout: 3)
    check("文件夹：也收得到（复制文件夹是允许的）",
          arrived && got.count == 1 && got.first?.lastPathComponent == "一个文件夹",
          got.map { $0.lastPathComponent }.joined(separator: ", "))
}

// ── 4. 空列表 / 非文件 provider ─────────────────────────────────
do {
    var got: [URL] = [URL(fileURLWithPath: "/should-not-stay")]
    let returned = FileDrop.collectURLs(from: []) { got = $0 }
    check("空列表：同步返回 false（这次投放不该被接受）", returned == false)
    let called = pump(until: { got.isEmpty }, timeout: 1)
    check("空列表：回调仍然被调用一次，且是空数组（不是永远不回）", called,
          "不回的话界面会一直停在「正在放入」的状态")

    // 一个只能给纯文本、给不了 fileURL 的 provider
    let textOnly = NSItemProvider(object: "只是文字" as NSString)
    var got2: [URL] = []
    let r2 = FileDrop.collectURLs(from: [textOnly]) { got2 = $0 }
    check("非文件 provider：同步返回 false", r2 == false,
          "它给不了 fileURL，接受这次投放等于骗用户")
    _ = pump(until: { true }, timeout: 0.2)   // 让上面那次 async 回调跑完
    check("非文件 provider：回调也照给（调用方要说得出「这不是文件」）", got2.isEmpty,
          "拿到 \(got2.count) 个 URL")
}

// ── 5. 汇总 ─────────────────────────────────────────────────────
print("")
print("通过 \(pass) · 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
