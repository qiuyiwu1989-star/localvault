import AppKit
import Foundation
import UniformTypeIdentifiers

/// 从拖拽会话给的 `NSItemProvider` 里收集文件 URL。
///
/// ## 为什么单独一个文件
///
/// 因为它**曾经有一个查不出来的 bug**，而那个 bug 只有在不堵主线程时才看得见。
/// 逻辑放进 `DriveView` 里就只能靠手拖验证，而手拖验证不了「3 秒超时」这种时序问题。
/// 抽出来之后它可以被 `scripts/file-drop-check.sh` headless 跑，真断言。
///
/// ## 那个 bug（实测复现过）
///
/// 原来的写法在主线程上 `DispatchGroup.wait(timeout: .now() + 3)`：
///
/// ```swift
/// _ = group.wait(timeout: .now() + 3)     // ← 主线程被冻住 3 秒
/// guard !urls.isEmpty else { return false }
/// ```
///
/// 实测同一个 provider、同一个 `loadItem`，只换等待方式：
///
/// | 等待方式 | 回调 |
/// | --- | --- |
/// | 让 RunLoop 转 | 3 秒内到达（后台线程） |
/// | 主线程上死等 | **3 秒内从没来过** |
///
/// `NSItemProvider` 的回调要靠主线程的 run loop 投递。在主线程上等它，
/// 等于**堵住了自己正在等的那次投递** —— 必然超时，`urls` 为空，返回 `false`。
///
/// 界面上的表现：投放区亮了一下，松手什么都没发生；
/// 而且主线程正好在松手那一刻被冻住 3 秒，macOS 收不干净拖拽会话，
/// **拖拽的影子会卡在屏幕上不动**。
///
/// 所以这里用 `group.notify(queue: .main)`，一个线程都不等，
/// 立刻 `return true` 让 SwiftUI 接受这次投放、把拖拽会话正常结束掉。
enum FileDrop {

    /// 收集 URL。
    ///
    /// - Parameters:
    ///   - providers: `onDrop` 给的 provider 列表。
    ///   - completion: **一定**会在主线程被调用**恰好一次**。
    ///     `urls` 可能为空 —— 那代表拖进来的东西里没有可用的文件。
    ///     「一定被调用」是刻意保证的：调用方靠它给出「没读到内容」的提示，
    ///     少调一次就退回到「界面亮一下、然后什么都不说」的老毛病。
    /// - Returns: 是否至少有一个 provider 声称自己能给文件 URL。
    ///   `onDrop` 的同步返回值只用来告诉 SwiftUI「收不收这次投放」；
    ///   真正拿到几个文件是异步的，两者必须分开 —— 合成一个就会退回上面那个 bug。
    @discardableResult
    static func collectURLs(from providers: [NSItemProvider],
                            completion: @escaping ([URL]) -> Void) -> Bool {
        let wanted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !wanted.isEmpty else {
            // 同步就否掉这次投放，但**回调照给** —— 让调用方能说一句
            // 「这次拖进来的不是文件」。静默拒绝是用户最没法诊断的那种失败。
            DispatchQueue.main.async { completion([]) }
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for p in wanted {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                // 探针实测：`public.file-url` 的 item 是 `Data`（NSConcreteData）。
                // 但别的进程（不一定只有 Finder）可能给 `URL` 或 `NSURL`，
                // 三种都收下 —— 少收一种就是「某些来源拖进来没反应」。
                var url: URL?
                if let d = item as? Data {
                    url = URL(dataRepresentation: d, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let u = item as? NSURL {
                    url = u as URL
                } else if let s = item as? String {
                    url = URL(string: s)
                }
                guard let url else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }

        // **这里绝不能 wait。** 见上面那段实测表。
        group.notify(queue: .main) {
            // 所有 leave 都发生在 notify 之前，所以这里读 urls 是安全的。
            completion(urls)
        }
        return true
    }
}
