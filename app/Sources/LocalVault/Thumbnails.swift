import SwiftUI
import QuickLookThumbnailing

// MARK: - 磁盘文件的缩略图
//
// 用系统自带的 QuickLook 生成缩略图，**不引入任何依赖**。
// 支持 PNG/JPG/HEIC/RAW/PDF/视频/Keynote 等 —— 苹果已经写好了，没必要重写。
//
// 三个必须自己扛的事：
//   ① **不要同步生成**。`QLThumbnailGenerator` 慢（几十到几百毫秒），
//      在主线程等它出图，网格滚动会一顿一顿。
//   ② **要缓存**。滚动时同一个格子会被反复求值，不缓存就会反复生成。
//   ③ **尺寸要给定**，不能"按需"。同一个文件在网格（大）和列表（小）里
//      是两个不同的缓存键 —— 所以键是 `路径@宽x高`，不是路径。

@MainActor
final class Thumbnails: ObservableObject {

    static let shared = Thumbnails()

    /// 出图后 `objectWillChange` 会打一次，视图自己重画。
    private var cache: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    /// 明确失败的不再重试 —— 否则每次重画都要再问一次系统，白烧 CPU。
    private var failed: Set<String> = []

    private init() {}

    func cached(_ url: URL, size: CGSize) -> NSImage? {
        cache[key(url, size: size)]
    }

    /// 要图。有缓存立即返回，没有就排一个后台任务，出图后视图会自己刷新。
    func request(_ url: URL, size: CGSize) {
        let k = key(url, size: size)
        guard cache[k] == nil, !inflight.contains(k), !failed.contains(k) else { return }
        inflight.insert(k)

        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            // 回调在后台线程，回主线程改状态
            Task { @MainActor in
                guard let self else { return }
                self.inflight.remove(k)
                if let img = rep?.nsImage {
                    self.cache[k] = img
                } else {
                    self.failed.insert(k)
                }
                self.objectWillChange.send()
            }
        }
    }

    private func key(_ url: URL, size: CGSize) -> String {
        "\(url.path)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// 一个会自动去要缩略图的格子。取不到就退回系统文件图标 ——
/// **永远不显示空白**：空白会让人以为文件坏了。
struct Thumbnail: View {
    let url: URL
    let size: CGSize
    /// 不是图片也要出缩略图（PDF、视频、Keynote 都能出）。关掉它就得图标。
    var preferThumbnail = true

    @ObservedObject private var store = Thumbnails.shared

    var body: some View {
        Group {
            if preferThumbnail, let img = store.cached(url, size: size) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size.width * 0.18)
                    .opacity(preferThumbnail ? 0.55 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { if preferThumbnail { store.request(url, size: size) } }
    }
}

extension NSImage {
    /// 本文只用来给云盘做「多大」的判断，不做视觉处理。
    var pixelSize: CGSize {
        guard let rep = representations.first else { return .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
