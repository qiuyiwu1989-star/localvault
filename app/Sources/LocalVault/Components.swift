import SwiftUI
import AppKit

// MARK: - 共用组件
//
// 这个文件是**跨视图的契约**。三个视图（提炼 / 云盘 / 检索库）共用这里的每一个组件。
// 视图里**不允许**自己画面板、自己定徽章样式 —— 那会让三个页面长得像三个应用。
//
// 所有视觉数值来自 Theme.swift，这个文件里不出现魔法数字。

// MARK: 面板
//
// 全应用**唯一**的分组容器。一个标题行 + 内容。
// 原来的 `SectionCard` 已并入这里（`trailing` 传空即为原来的用法）。

struct PanelBox<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let content: Content

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).sectionTitle()
                    if let subtitle {
                        Text(.init(subtitle))
                            .captionText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.xs)
                trailing
            }
            content
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}

extension PanelBox where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

// MARK: 小标题

struct SubHead: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View { Text(t).font(.subheadline.weight(.semibold)) }
}

// MARK: 徽章
//
// 一个徽章 = 一个短词 + 一个色。**不许塞句子进去。**

struct Chip: View {
    let text: String
    let tint: Color
    var filled: Bool = false

    init(_ text: String, _ tint: Color, filled: Bool = false) {
        self.text = text; self.tint = tint; self.filled = filled
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Space.xs).padding(.vertical, 3)
            .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
            .foregroundStyle(filled ? Color.white : tint)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// 可点的筛选标签 —— 选中态必须一眼可辨。
///
/// 显式写两个 init：加了显式 init 之后 memberwise init 会被抑制，
/// 而已经有人在用 `FilterChip(text:tint:selected:)` 那种写法，两个都得留。
struct FilterChip: View {
    let text: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    init(text: String, tint: Color, selected: Bool = false,
         action: @escaping () -> Void) {
        self.text = text; self.tint = tint; self.selected = selected; self.action = action
    }

    init(_ text: String, tint: Color, selected: Bool = false,
         action: @escaping () -> Void) {
        self.init(text: text, tint: tint, selected: selected, action: action)
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                .background(selected ? AnyShapeStyle(tint.opacity(0.9))
                                     : AnyShapeStyle(.quaternary))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: 类型徽章
//
// 文件类型靠**形状 + 颜色**辨识，**不写类型名字**。
// 卡片上写字会立刻把信息密度顶上去（这是实测过的）。

struct TypeBadge: View {
    let kind: InfoKind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: typeIcon(kind))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kindColor(kind).gradient)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(kindLabel(kind))
    }
}

// MARK: 来源标记
//
// 「来源」这两个字是这个产品的信誉所在。
// 界面上的每一个数字、每一条规则、每一份入口文档，都要能回答**"这是哪来的"**。
// 回答不了的东西，就不该出现在界面上。

struct SourceTag: View {
    let origin: String?
    var file: String? = nil

    private var text: String {
        switch origin {
        case "config": return "你配置的"
        case "auto":   return "自动发现"
        case .some(let o): return o
        case .none:    return "来源未知"
        }
    }

    private var tint: Color {
        switch origin {
        case "config": return .blue
        case "auto":   return .teal
        default:       return .gray
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: origin == "config"
                  ? "person.crop.circle" : "wand.and.stars")
                .font(.system(size: 9))
            Text(text).font(.caption2)
            if file != nil {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 8))
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .onTapGesture {
            if let file {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
            }
        }
        .help(file.map { "点开看原文：\($0)" } ?? text)
    }
}

// MARK: 会换行的标签组

struct FlexibleChips: View {
    let items: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Space.xxs) {
                    ForEach(row, id: \.self) { Chip($0, tint) }
                }
            }
        }
    }

    /// 按字数折行 —— 分组名长短差异大，固定宽度会截断
    private var rows: [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        var len = 0
        for it in items {
            if len + it.count > 26, !cur.isEmpty { out.append(cur); cur = []; len = 0 }
            cur.append(it); len += it.count + 1
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: 数值

/// 一行「标签 —— 值」。用于口径说明这类只读的键值展示。
struct CaliberRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// 右上角的紧凑数值（"117 个项目"这种）
struct StatPill: View {
    let value: String
    let unit: String
    var warn: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(warn ? Palette.warning : .primary)
            Text(unit).faintText()
        }
        .frame(minWidth: 62, alignment: .trailing)
    }
}

// MARK: 项目符号

struct Bullet: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Circle()
                .fill(.tertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 判断与条陈

/// 判断的四态配色。**这些词是给人的，不是给工具的。**
func verdictColor(_ v: String) -> Color {
    switch v {
    case Verdict.keep.rawValue:        return .green
    case Verdict.review.rawValue:      return .blue
    case Verdict.archive.rawValue:     return .orange
    case Verdict.discardable.rawValue: return .red
    default: return .gray
    }
}

/// 一条条陈 —— 权威级、签名、机器/人一眼可分。
struct ClaimRow: View {
    let claim: Claim

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xxs) {
                    Chip(claim.authority, claim.isMachine ? Palette.machine : Palette.human)
                    if let v = claim.verdict {
                        Chip(v, verdictColor(v))
                    }
                    Text(claim.signedBy)
                        .font(.caption2)
                        .foregroundStyle(claim.isMachine ? Palette.machine : Palette.human)
                    Spacer(minLength: 0)
                    Text(claim.tsText).faintText()
                }
                if !claim.note.isEmpty {
                    Text(.init(claim.note))
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(claim.target)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

// MARK: 工具函数

/// 体积文案。
/// `ByteCountFormatter` 对 0 会输出 "Zero KB" —— 那是英文碎片，不能给人看。
func sizeText(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 字节" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// 按扩展名给图标 —— 比 InfoKind 粗，用于还不该下判断的地方
func fileIcon(_ ext: String) -> String {
    switch ext.lowercased() {
    case ".md", ".markdown": return "doc.richtext"
    case ".json", ".yml", ".yaml", ".toml": return "curlybraces"
    case ".swift", ".js", ".ts", ".py", ".kt", ".java", ".go", ".rs":
        return "chevron.left.forwardslash.chevron.right"
    case ".html", ".css": return "globe"
    case ".txt", ".log": return "doc.plaintext"
    case ".pdf": return "doc.viewfinder"
    case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic": return "photo"
    case ".mp4", ".mov", ".avi", ".mkv": return "film"
    case ".mp3", ".wav", ".m4a", ".aac": return "waveform"
    case ".zip", ".tar", ".gz", ".7z", ".rar": return "archivebox"
    default: return "doc"
    }
}

/// 百分比
func percent(_ n: Int, _ total: Int) -> String {
    guard total > 0 else { return "—" }
    return String(format: "%.1f%%", Double(n) / Double(total) * 100)
}
