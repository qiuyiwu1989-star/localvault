import SwiftUI
import AppKit

// MARK: - 设计变量（Theme）
//
// 这个文件是**全应用唯一的视觉变量来源**。
// 任何视图里出现写死的颜色、间距、圆角、字号，都是 bug ——
// 那意味着这个应用会慢慢长成五种风格。
//
// 参考：Apple Human Interface Guidelines（macOS）。
// 系统：macOS 26。最低支持 macOS 14（为了 Swift Charts 的 SectorMark）。

// MARK: 间距 —— 4pt 栅格

enum Space {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xxl: CGFloat = 48

    /// 内容区外边距。macOS 窗口里的标准内边距
    static let content: CGFloat = 20
}

// MARK: 圆角

enum Radius {
    static let xs: CGFloat = 4    // 小标记
    static let sm: CGFloat = 6    // 徽章、小按钮
    static let md: CGFloat = 10   // 卡片
    static let lg: CGFloat = 14   // 面板
    static let xl: CGFloat = 20   // 大容器
}

// MARK: 动效
//
// 统一用一条曲线：macOS 上界面元素的位移和淡入都用 easeOut，
// 只有"数值变化"用 spring。混着用会显得飘。

enum Motion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let base  = Animation.easeOut(duration: 0.24)
    static let count = Animation.spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: 调色板
//
// 纪律：**全应用只有一个强调色**（用户系统的 accentColor），
// 加上四个语义色。分类数据**不给每个分类一个色相** ——
// 9 个全饱和色并排就是彩虹，那是仪表盘模板的做法，不是苹果的做法。

enum Palette {
    /// 强调色 —— 跟着用户在"系统设置 → 外观"里选的走
    static let accent = Color.accentColor

    static let success = Color.green
    static let warning = Color.orange
    static let neutral = Color.gray

    /// 条陈的两类作者。**机器和人在界面上必须一眼可分** ——
    /// 这是 SPEC 不变量 I 的可视化落点：跨越信任边界的只有人，
    /// 机器写的条目必须自带不可消除的标记。
    static let machine = Color.purple
    static let human   = Color.green

    /// 图表用的低饱和填充（同色相降饱和，不换色相）
    static func fill(_ c: Color) -> Color { c.opacity(0.85) }
    static func soft(_ c: Color) -> Color { c.opacity(0.14) }
}

// MARK: 判断三态的颜色
//
// 「没用」原来是橙色。那是错的：橙色是**警告**色，
// 而 6,758 个"没用"文件不是警告，是背景噪声 ——
// 全屏橙色会让这个应用看起来像出了事。
// 真正需要你动手的是「待定」，橙色给它。

/// 六级梯子的颜色。
///
/// **不用六种色相。** 契约规定"一次配色只表示一件事"，而六级是**顺序**关系，
/// 不是六个并列的类别 —— 顺序该用同一族色 + 深浅，不该用彩虹。
/// 于是只用三族：绿=要读的、灰=不占注意力的、橙=等你动手的。
/// 「务必读」和「值得读」同色，靠**标签文字**和卡片位置区分（它本来就排在最前）。
func triageColor(_ t: Triage) -> Color {
    switch t {
    case .mustRead:   return Palette.success
    case .readable:   return Palette.success
    case .skimmable:  return Palette.neutral
    case .unreadable: return Palette.warning   // 真正需要你动手的是「待定」，橙色给它
    case .searchOnly: return Palette.neutral
    case .excluded:   return Palette.neutral
    }
}

/// 判断的短解释 —— 界面上不该只出现一个颜色
func triageHint(_ t: Triage) -> String {
    switch t {
    case .mustRead:   return "项目入口文档。别人或未来的你该先读的就是它"
    case .readable:   return "文档笔记，正文有实质内容"
    case .skimmable:  return "可读，但没什么判断内容"
    case .unreadable: return "机器读不懂，等你或转录"
    case .searchOnly: return "源码与数据：agent 搜得到，不占你注意力"
    case .excluded:   return "安装包、依赖、构建产物、重复件"
    }
}

// MARK: 文件类型
//
// 13 种类型**不给 13 个颜色**。
// **图标形状**负责辨识是哪种（doc.text / tablecells / chevron.left.forwardslash…），
// **颜色**只负责回答"它属于哪一族"。
// 这样既看得出差别，又不会变成调色盘。

enum KindFamily {
    case content   // 文档、表格、通讯
    case code      // 代码、配置
    case media     // 图片、音视频、设计资产
    case machine   // 安装包、模型、二进制、第三方、垃圾
    case unknown

    var tint: Color {
        switch self {
        case .content: return .blue
        case .code:    return .purple
        case .media:   return .pink
        case .machine: return Palette.neutral
        case .unknown: return .secondary
        }
    }
}

func kindFamily(_ k: InfoKind) -> KindFamily {
    switch k {
    case .prose, .structured, .comms:                 return .content
    case .code, .config:                              return .code
    case .media, .asset:                              return .media
    case .installer, .model, .binary, .vendor, .junk: return .machine
    case .unknown:                                    return .unknown
    }
}

func kindColor(_ k: InfoKind) -> Color { kindFamily(k).tint }

/// 类型图标 —— 形状是辨识的依据，所以它是这个应用里少数必须写死的地方
func typeIcon(_ k: InfoKind) -> String {
    switch k {
    case .prose:      return "doc.text"
    case .structured: return "tablecells"
    case .code:       return "chevron.left.forwardslash.chevron.right"
    case .comms:      return "bubble.left.and.bubble.right"
    case .media:      return "photo.on.rectangle"
    case .asset:      return "paintpalette"
    case .installer:  return "shippingbox"
    case .model:      return "brain.head.profile"
    case .binary:     return "gearshape.2"
    case .config:     return "slider.horizontal.3"
    case .vendor:     return "building.2"
    case .junk:       return "trash"
    case .unknown:    return "questionmark.square.dashed"
    }
}

/// 索引层的粗粒度类型（SQL 里的 `kind`）→ 颜色。
/// 用在"文件类型分布"图上 —— 那里的分类来自索引，不是 `InfoKind`。
/// **必须和 `KindFamily` 共用同一套色**：之前这里是 8 个色相
/// （blue/purple/pink/orange/indigo/teal/brown/cyan），
/// 一张图里出现 8 种饱和色就是典型的"彩虹感"——
/// 颜色一旦什么都能表示，就什么都不表示了。
func indexKindTint(_ kind: String) -> Color {
    switch kind {
    case "doc":                        return KindFamily.content.tint
    case "code", "web", "config":      return KindFamily.code.tint
    case "image", "video", "audio":    return KindFamily.media.tint
    case "data", "archive", "model",
         "binary", "installer":        return KindFamily.machine.tint
    default:                           return KindFamily.unknown.tint
    }
}

/// 索引层的粗粒度类型 → 中文名。界面上不许出现 `video`/`archive` 这种裸英文 key。
func indexKindLabel(_ kind: String) -> String {
    switch kind {
    case "doc":       return "文档"
    case "code":      return "代码"
    case "config":    return "配置"
    case "image":     return "图片"
    case "video":     return "视频"
    case "audio":     return "音频"
    case "data":      return "数据"
    case "archive":   return "压缩包"
    case "web":       return "网页"
    case "model":     return "模型"
    case "binary":    return "二进制"
    case "installer": return "安装包"
    case "other":     return "其他"
    // 下面 4 个是本机索引里真实存在、但第一版漏掉的 kind
    case "sheet":     return "表格"
    case "slide":     return "幻灯片"
    case "symlink":   return "符号链接"
    case "bundle":    return "应用包"
    default:          return kind
    }
}

/// 类型的中文名 —— **卡片上不显示**，只在下钻的详情条里出现
func kindLabel(_ k: InfoKind) -> String { k.rawValue }

// MARK: 表面（材质与层次）
//
// 三种层次，从低到高：
//   ① 窗口底色（系统的，不碰）
//   ② `cardSurface`  —— 卡片。比底色亮一档 + 极细描边
//   ③ `panelSurface` —— 分组面板。用材质，带一点透明
//
// 为什么不用纯色块：macOS 的层次感来自**材质叠加**，
// 一个平灰色的圆角矩形在任何系统上都显得像网页。

struct CardSurface: ViewModifier {
    var radius: CGFloat = Radius.md
    var selected: Bool = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.background.secondary)
                    // 层次优先顺序：**底色差 > 描边 > 阴影**。
                    // 所以阴影只在浅色下给一层极轻的，深色下完全不要 ——
                    // 深色里阴影看不见，靠描边和底色差就够了。
                    // 堆三层阴影是最典型的"业余感"来源。
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06),
                            radius: 6, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        selected ? AnyShapeStyle(Palette.accent)
                                 : AnyShapeStyle(.separator),
                        lineWidth: selected ? 2 : (scheme == .dark ? 1 : 0.5)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct PanelSurface: ViewModifier {
    var radius: CGFloat = Radius.lg

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func cardSurface(radius: CGFloat = Radius.md, selected: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, selected: selected))
    }
    func panelSurface(radius: CGFloat = Radius.lg) -> some View {
        modifier(PanelSurface(radius: radius))
    }

    /// 面板的内边距。全应用统一，避免每个视图自己猜
    func panelPadding() -> some View { padding(Space.md) }
}

// MARK: 文字层次
//
// 苹果的克制原则：**不用字号制造层次，用颜色和字重**。
// 所以这里只有两个自定义字号（大数字、区块标题），其余全用系统的语义字号。

extension View {
    /// 统计数字 —— 等宽数字 + rounded，数字变化时不会左右跳。
    /// HIG：SF Pro Rounded 用于"和柔和/圆润的界面元素配合的文字"，
    /// 所以它只给统计数字和空状态用，正文一律默认字体。
    func metricValue(_ size: CGFloat = 34) -> some View {
        self.font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }

    /// 区块标题
    func sectionTitle() -> some View {
        self.font(.headline)
    }

    /// 说明文字 —— 全应用统一用 secondary + caption
    func captionText() -> some View {
        self.font(.caption).foregroundStyle(.secondary)
    }

    /// 更淡的一层
    func faintText() -> some View {
        self.font(.caption2).foregroundStyle(.tertiary)
    }

    /// 等宽路径
    func pathText() -> some View {
        self.font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

// MARK: 数字条
//
// 一根极细的占比尺。原来的版本 4pt 太粗、颜色太满。

struct BarMeter: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
    }
}

// MARK: 空状态
//
// 苹果的空状态有固定结构：**图标（淡）→ 标题 → 一句说明 → 动作**。
// 不许只放一句"暂无数据"。

struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Space.sm) {
            // HIG：SF Symbol 32pt + .tertiary，标题 .title3
            Image(systemName: icon)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Space.xxs)
            Text(title).font(.title3)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            action.padding(.top, Space.xxs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.lg)
    }
}

extension EmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
