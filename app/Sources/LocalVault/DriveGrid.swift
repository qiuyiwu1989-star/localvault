import SwiftUI
import AppKit

// MARK: - 资产网格（DAM 的那一半）
//
// 网格只负责"一眼看一片"，不看细节 —— 细节在右边的详情栏。
// 缩略图一律走共用的 `Thumbnail`（QuickLook + 缓存 + 失败退回文件图标），
// 这里不重写一套。

struct DriveGrid: View {
    let items: [DriveItem]
    @Binding var selectedId: String?

    private let columns = [GridItem(.adaptive(minimum: DriveLayout.cellMin),
                                    spacing: Space.sm)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: Space.sm) {
                ForEach(items) { it in
                    DriveGridCell(item: it, selected: it.id == selectedId) {
                        // 再点一次 = 取消选中，详情栏回到文件夹概览
                        selectedId = (selectedId == it.id) ? nil : it.id
                    }
                }
            }
            .padding(Space.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: 一个格子

private struct DriveGridCell: View {
    let item: DriveItem
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Thumbnail(url: item.url,
                          size: CGSize(width: DriveLayout.thumbW, height: DriveLayout.thumbH))
                    .frame(maxWidth: .infinity)

                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.sizeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Space.xs)
            .cardSurface(radius: Radius.md, selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.name)
    }
}

// MARK: - 详情栏
//
// 选中资产时给「大图 + 元数据 + 正文」，没选中时给「这个文件夹的概览」。
// 一栏两态，不留空白 —— 空着的右栏会让人以为界面坏了。

struct DriveInspector: View {
    /// 选中的资产。nil → 显示文件夹概览
    let item: DriveItem?
    let folder: DriveFolder?
    /// 当前筛选项内看得见的一批（概览的数量/体量/分布都以它为口径）
    let visible: [DriveItem]
    let isFiltered: Bool
    let onClear: () -> Void

    @State private var preview: NSImage?
    @State private var bodyText = ""
    @State private var bodyTruncated = false
    @State private var bodyLoading = false

    private var bytes: Int64 { visible.reduce(0) { $0 + $1.size } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                if let item {
                    asset(item)
                } else {
                    overview
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: item?.id) { await load() }
    }

    // MARK: 选中：一个大图 + 元数据

    @ViewBuilder
    private func asset(_ it: DriveItem) -> some View {
        previewArea(it)

        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(it.name)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.xs)
            Button { onClear() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("取消选中，回到文件夹概览")
        }

        Text(it.folderPath)
            .faintText()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: Space.xxs) {
            CaliberRow(label: "体量", value: it.sizeText)
            CaliberRow(label: "类型", value: kindLabel(it.infoKind))
            if let px = pixelText { CaliberRow(label: "像素", value: px) }
            CaliberRow(label: "修改", value: it.dateTimeText)
        }

        HStack(spacing: Space.xs) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([it.url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .help("只揭示位置；这个 App 不会改动文件")

            Button {
                NSWorkspace.shared.open(it.url)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }
            .help("用系统默认程序打开")
        }
        .controlSize(.small)

        VStack(alignment: .leading, spacing: Space.xxs) {
            SubHead("路径")
            Text(it.rel)
                .pathText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(it.url.path)

        if it.rendersMarkdown { markdownSection(it) }
    }

    /// 大图：图片用 `NSImage`，等比缩放**不拉变形**；其它文件给系统文件图标
    @ViewBuilder
    private func previewArea(_ it: DriveItem) -> some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: DriveLayout.previewMaxHeight)
        } else {
            VStack(spacing: Space.sm) {
                Thumbnail(url: it.url,
                          size: CGSize(width: DriveLayout.iconPreview, height: DriveLayout.iconPreview),
                          preferThumbnail: false)
                Text(it.isImage ? "这张图读不出来" : "这类文件没有大图预览")
                    .faintText()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.md)
            .cardSurface(radius: Radius.md)
        }
    }

    /// 像素尺寸。取不到就不显示 —— 不编一个 0 × 0
    private var pixelText: String? {
        guard let px = preview?.pixelSize, px.width > 0, px.height > 0 else { return nil }
        return "\(Int(px.width)) × \(Int(px.height))"
    }

    // MARK: 正文
    //
    // 云盘里的文件是**用户自己放进来的真文件**，所以这里读磁盘原文，
    // 和索引侧的 `IndexedPreview` 不是一条路。两个上限都如实说出来。

    @ViewBuilder
    private func markdownSection(_ it: DriveItem) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                SubHead("正文")
                if bodyLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }

            if bodyText.isEmpty && !bodyLoading {
                Text(bodyEmptyNote(it))
                    .captionText()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if bodyTruncated {
                    Text("这个文件更长 —— 下面只渲染了前 \(DriveLayout.textRenderMaxChars.formatted()) 字。")
                        .faintText()
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                MarkdownText(bodyText)
                    .textSelection(.enabled)
            }
        }
    }

    private func bodyEmptyNote(_ it: DriveItem) -> String {
        if it.size > DriveLayout.textReadMaxBytes {
            return "文件超过 \(sizeText(DriveLayout.textReadMaxBytes))，预览不做全文渲染。"
        }
        return "读不出文本内容 —— 可能不是 UTF-8 编码。"
    }

    // MARK: 未选中：文件夹概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                SubHead("当前文件夹")
                Text(folder?.name ?? "云盘")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }

            MetricTile(title: "文件数",
                       value: "\(visible.count)",
                       caption: "个文件",
                       tint: Palette.accent)

            VStack(alignment: .leading, spacing: Space.xxs) {
                CaliberRow(label: "体量", value: sizeText(bytes))
                if isFiltered, let folder {
                    // 筛选时多给一个口径：整个文件夹是多少
                    CaliberRow(label: "整个文件夹", value: "\(folder.count) 个 · \(folder.sizeText)")
                }
            }

            Text(isFiltered
                 ? "口径：数量与体量只算当前筛选项内看得见的这一批，不是整个文件夹。"
                 : "口径：这一个文件夹里的文件（子目录本身不计）。")
                .faintText()
                .fixedSize(horizontal: false, vertical: true)

            distribution
        }
    }

    private var distribution: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SubHead("按类型分布")
            if groups.isEmpty {
                Text("这里还没有文件。").captionText()
            } else {
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.xs) {
                            TypeBadge(kind: g.kind, size: 20)
                            Text(kindLabel(g.kind))
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: Space.xs)
                            Text("\(g.count) 个")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(sizeText(g.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: DriveCol.distSize, alignment: .trailing)
                        }
                        // 占比按"这一批文件数"归一（契约 8 之 8）
                        BarMeter(fraction: g.fraction, tint: kindColor(g.kind))
                    }
                }
            }
        }
    }

    /// 按 `InfoKind` 分组 —— 不新写扩展名表，用 `DriveItem.infoKind` 那一份
    private var groups: [TypeGroup] {
        let total = max(1, visible.count)
        var byKind: [InfoKind: (count: Int, bytes: Int64)] = [:]
        for it in visible {
            let k = it.infoKind
            let cur = byKind[k] ?? (0, 0)
            byKind[k] = (cur.count + 1, cur.bytes + it.size)
        }
        return byKind
            .map { TypeGroup(kind: $0.key, count: $0.value.count, bytes: $0.value.bytes,
                             fraction: Double($0.value.count) / Double(total)) }
            .sorted { $0.count > $1.count }
    }

    private struct TypeGroup: Identifiable {
        let kind: InfoKind
        let count: Int
        let bytes: Int64
        let fraction: Double
        var id: String { kind.rawValue }
    }

    // MARK: 取值
    //
    // 大图与正文都按 `item?.id` 重新加载；切文件时先清空，
    // 免得旧文件的大图/正文在新文件上闪一下。

    private func load() async {
        preview = nil
        bodyText = ""
        bodyTruncated = false
        bodyLoading = false

        guard let item else { return }

        if item.isImage {
            // `NSImage` 是惰性解码的：这里只把文件读成图像对象，
            // 真正的解码发生在绘制那一刻，所以不会卡在主线程
            preview = NSImage(contentsOf: item.url)
        }

        guard item.rendersMarkdown,
              item.size > 0,
              item.size <= DriveLayout.textReadMaxBytes else { return }

        bodyLoading = true
        let url = item.url
        let raw: String = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        bodyLoading = false

        if raw.count > DriveLayout.textRenderMaxChars {
            bodyText = String(raw.prefix(DriveLayout.textRenderMaxChars))
            bodyTruncated = true
        } else {
            bodyText = raw
        }
    }
}
