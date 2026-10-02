import CoreGraphics
import Foundation

/// 列出屏幕上某个进程的窗口：`winlist <pid>`，输出「窗口id \t x \t y \t w \t h」。
///
/// 为什么要按 pid 过滤，而不是「找名字叫 LocalVault 的窗口」：
/// 实测踩过。这台机器上同时开着两个实例（一个是早先深/浅两态验收留下的），
/// 而截图脚本取的是**屏幕上第一个**匹配窗口 —— 于是「深色 + 夹具数据」那张图
/// 实际拍到了另一个实例的窗口：真库、浅色。**两个维度同时错，却看起来很正常。**
/// 只按可见窗口找，等于把「拍到哪个」交给运气。
///
/// 用 Swift 而不是 osascript：System Events 要辅助功能权限（实测被拒，错误码 -1719），
/// 而 CGWindowListCopyWindowInfo 是公开 API，有屏幕录制权限就够。
let wantPid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil

let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }

for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    if let want = wantPid, pid != want { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let x = (b["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (b["Y"] as? NSNumber)?.doubleValue ?? 0
    let ww = (b["Width"] as? NSNumber)?.doubleValue ?? 0
    let hh = (b["Height"] as? NSNumber)?.doubleValue ?? 0
    // 太小的多半是工具条/浮层，不是主窗口
    if ww < 200 || hh < 200 { continue }
    print("\(num)\t\(Int(x))\t\(Int(y))\t\(Int(ww))\t\(Int(hh))")
}
