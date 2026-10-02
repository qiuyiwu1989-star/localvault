import SwiftUI
import Charts

// MARK: - 图表
//
// 这一版把上一版**手搓的**图表全部换成了 Swift Charts。
//
// 为什么：手搓的环形图、条形图在 macOS 上永远差一口气 ——
// 动画曲线、抗锯齿、深浅色适配、坐标轴排布、辅助功能，
// 苹果已经在这套框架里做了十几年。自己画等于把这些全部重做一遍，而且做不对。
// 系统自带、零依赖，没有理由不用。
//
// 图表的克制原则（来自 Apple Charts 的做法）：
// **仪表盘里的图不画坐标轴和网格线。** 数字本身就在旁边，
// 图只负责"一眼看出比例"，不负责精确读数。

// MARK: 环形图

struct DonutSlice: Identifiable {
    let label: String
    let value: Int
    let tint: Color
    var id: String { label }
}

struct TriageDonut: View {
    let slices: [DonutSlice]
    let center: String
    let caption: String
    var size: CGFloat = 132

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var total: Int { max(1, slices.reduce(0) { $0 + $1.value }) }

    var body: some View {
        Chart(slices) { s in
            // 数值抄 Apple SectorMark 官方示例，不自创
            SectorMark(
                angle: .value("数量", s.value),
                innerRadius: .ratio(0.618),
                angularInset: 1
            )
            .cornerRadius(4)
            .foregroundStyle(s.tint.gradient)
        }
        .chartLegend(.hidden)
        .frame(width: size, height: size)
        .overlay {
            VStack(spacing: 0) {
                Text(center)
                    .font(.system(size: size * 0.19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(total)))
                Text(caption)
                    .font(.system(size: size * 0.075))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("共 \(total) 个文件已判断")
    }
}

// MARK: 横向条形图

struct BarDatum: Identifiable {
    let name: String
    let count: Int
    let bytes: Int64
    let tint: Color
    var id: String { name }
}

/// 按体量排的横向条形图。
/// 横向是因为**分类名是文字** —— 竖着放就得斜排标签，那是 Excel 的做法。
struct KindBars: View {
    let items: [BarDatum]
    var rowHeight: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Bars {
        /// 类别名画在条形左边的槽里。2–3 个汉字在 `.caption` 下最宽约 33pt。
        static let labelGutter = Space.xxl + Space.xxs   // 52
        static let headroom: Double = 1.30               // 给右侧数值标注留的地方
    }

    /// **开方，不开线性。**
    /// 本机实测：视频 14.14 GB，而图片/文档/代码各 185/185/154 MB。
    /// 线性刻度下小类只占全宽 0.98%（约 10px），就是一个点 ——
    /// 面板副标题自己写着"否则小类在里面看不见"，线性刻度做不到这件事。
    /// 开方比取对数好读：0 字节仍然是 0，不用造一个假的底。
    private func scaled(_ bytes: Int64) -> Double { sqrt(Double(max(0, bytes))) }
    private var peak: Double { max(1, items.map { scaled($0.bytes) }.max() ?? 1) }

    var body: some View {
        Chart(items) { it in
            BarMark(
                x: .value("体量", scaled(it.bytes)),
                y: .value("类型", it.name)
            )
            .foregroundStyle(it.tint.gradient)
            .cornerRadius(3)
            // 类别名**不用 y 轴**：分类轴的标签被放在 band 顶部，
            // 而条形居中，两者差半行（实测 12.5pt），
            // 整排读起来是"名称一行、条+数值一行"。
            // 前导标注是跟着条形居中的，所以改用标注。
            .annotation(position: .leading, alignment: .trailing, spacing: Space.xs) {
                Text(it.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            // 标注显示的是**真实字节**，不是开方后的值
            .annotation(position: .trailing, alignment: .leading, spacing: Space.xxs,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(ByteCountFormatter.string(fromByteCount: it.bytes, countStyle: .file))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: 0...(peak * Bars.headroom))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)                        // 标签改由前导标注画
        .chartPlotStyle { $0.padding(.leading, Bars.labelGutter) }
        .frame(height: CGFloat(items.count) * rowHeight + Space.xs)
        .animation(reduceMotion ? nil : Motion.base, value: items.map(\.name))
    }
}

// MARK: 趋势图

/// 月度改动量。
/// x 轴必须是**连续的时间轴** —— 用分类轴的话，缺的月份会被挤掉，时间就是假的。
struct ActivityTrend: View {
    let months: [(key: String, count: Int)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = .blue
    var showAxis: Bool = true

    private struct Point: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    private var points: [Point] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return months.compactMap { m in
            guard let d = f.date(from: m.key) else { return nil }
            return Point(date: d, count: m.count)
        }
    }

    var body: some View {
        Chart(points) { p in
            AreaMark(
                x: .value("月份", p.date),
                y: .value("改动", p.count)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(
                .linearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            LineMark(
                x: .value("月份", p.date),
                y: .value("改动", p.count)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .foregroundStyle(tint)
        }
        .chartXAxis {
            if showAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            Text(d, format: .dateTime.year(.twoDigits).month(.twoDigits))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    AxisTick().foregroundStyle(.quaternary)
                }
            } else {
                AxisMarks { _ in }
            }
        }
        .chartYAxis(.hidden)
        .animation(reduceMotion ? nil : Motion.base, value: points.map(\.count))
    }
}

// MARK: 指标卡
//
// 一个数字 + 一句说明。数字用 rounded + 等宽，
// 这样数值变化时宽度不变、不会左右跳。

struct MetricTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var tint: Color = .accentColor
    /// 传了就画一根占比尺
    var fraction: Double? = nil
    /// 传了就变成可点的筛选项
    var selected: Bool = false
    var onTap: (() -> Void)? = nil

    private var inner: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .metricValue(30)
                .foregroundStyle(tint)

            if let fraction {
                BarMeter(fraction: fraction, tint: tint)
                    .padding(.top, 2)
            }

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.sm)
        .cardSurface(selected: selected)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let onTap {
            Button(action: onTap) { inner }.buttonStyle(.plain)
        } else {
            inner
        }
    }
}

// MARK: 视图模式

enum ViewMode: String, CaseIterable, Identifiable {
    case waterfall = "瀑布流"
    case list = "列表"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .waterfall: return "square.grid.2x2"
        case .list:      return "list.bullet"
        }
    }
}

struct ViewModePicker: View {
    @Binding var mode: ViewMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(ViewMode.allCases) { m in
                Image(systemName: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 78)
        .help("切换瀑布流 / 列表")
    }
}
