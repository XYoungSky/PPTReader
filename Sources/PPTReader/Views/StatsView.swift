import AppKit
import SwiftUI

/// 学习统计窗口，外观与设置窗口一致。
@MainActor
enum StatsWindow {
    private static var window: NSWindow?

    static func show() {
        guard let model = SettingsWindow.model else { return }
        if window == nil {
            let hosting = NSHostingController(rootView: StatsView(stats: model.stats, library: model.library) { [weak model] url in
                if url.hasDirectoryPath { model?.openFolder(url) } else { model?.openDeck(url) }
                // 回到主窗口
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "PPTReader" }?
                    .makeKeyAndOrderFront(nil)
            })
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.panelNSColor
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 480)
            window.setContentSize(NSSize(width: 760, height: 640))
            window.center()
            window.setFrameAutosaveName("StatsWindow")
            self.window = window
        }
        window?.title = tr("学习统计", "Statistics")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

enum StatsMetric: String, CaseIterable, Identifiable {
    case time, interactions, tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .time: tr("阅读时长", "Reading time")
        case .interactions: tr("讲解与提问", "Questions")
        case .tokens: tr("Token", "Tokens")
        }
    }

    /// 柱高和热力图深浅所用的数值；时长以分钟计。
    func value(seconds: Double, interactions: Int, tokens: Int) -> Double {
        switch self {
        case .time: seconds / 60
        case .interactions: Double(interactions)
        case .tokens: Double(tokens)
        }
    }

    func label(_ value: Double) -> String {
        switch self {
        case .time: StatsFormat.duration(value * 60)
        case .interactions: tr("\(Int(value)) 次", Int(value) == 1 ? "1 question" : "\(Int(value)) questions")
        case .tokens: StatsFormat.compact(Int(value)) + tr(" Token", " tokens")
        }
    }
}

struct StatsView: View {
    let stats: StatsStore
    /// 用来判断课件属于哪个课程文件夹。
    let library: CourseLibrary
    /// 点按课件或课程时在主窗口中打开（课程以文件夹 URL 传入）。
    let openDeck: (URL) -> Void
    @AppStorage("stats.period") private var period: StatsSummary.Period = .week
    @AppStorage("stats.metric") private var metric: StatsMetric = .time

    var body: some View {
        let log = stats.log
        let summary = StatsSummary(log: log, period: period)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(summary)
                if log.isEmpty {
                    EmptyStats()
                } else {
                    tiles(summary)
                    chartCard(summary)
                    HeatmapCard(year: StudyCalendar(log: log), metric: metric)
                    if !summary.decks.isEmpty {
                        DeckList(rows: summary.decks, roots: courseRoots, openDeck: openDeck)
                    }
                    if summary.models.contains(where: { !$0.name.isEmpty }) { ModelList(rows: summary.models) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.content, value: period)
        }
        .scrollIndicators(.never)
        .background(Theme.panel)
        .ignoresSafeArea()
    }

    /// 打开过的课程文件夹（当前的排在最前）。
    private var courseRoots: [URL] {
        ([library.rootURL].compactMap { $0 } + library.recentFolders)
    }

    private func header(_ summary: StatsSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(tr("学习统计", "Statistics"))
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.text)
            if summary.streak > 0 {
                Label(tr("连续 \(summary.streak) 天", summary.streak == 1 ? "1-day streak" : "\(summary.streak)-day streak"), systemImage: "flame")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.hover))
                    .help(tr("今天或昨天起连续学习的天数", "Consecutive days of study up to today"))
            }
            Spacer(minLength: 12)
            SegmentedPicker(selection: $period, options: StatsSummary.Period.allCases.map { ($0, $0.title) })
        }
    }

    // MARK: 数字

    private func tiles(_ summary: StatsSummary) -> some View {
        let tokens = summary.tokens
        let tokenCaption: String = if tokens.prompt > 0 && tokens.cacheHit > 0 {
            tr("缓存命中 ", "Cache hit ") + StatsFormat.percent(Double(tokens.cacheHit) / Double(tokens.prompt))
        } else if tokens.requests > 0 {
            tr("\(tokens.requests) 次请求", tokens.requests == 1 ? "1 request" : "\(tokens.requests) requests")
        } else {
            " "
        }
        let deckCount = summary.decks.filter { !$0.pages.isEmpty }.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            StatTile(label: tr("阅读时长", "Reading time"), value: StatsFormat.duration(summary.seconds),
                     caption: tr("学习 \(summary.activeDays) 天", summary.activeDays == 1 ? "1 day" : "\(summary.activeDays) days"))
            StatTile(label: tr("阅读页数", "Pages read"), value: StatsFormat.compact(summary.pagesViewed),
                     caption: tr("\(deckCount) 份课件", deckCount == 1 ? "1 deck" : "\(deckCount) decks"))
            StatTile(label: tr("讲解与提问", "Questions"), value: StatsFormat.compact(summary.interactions),
                     caption: tr("讲解 \(summary.explains) · 提问 \(summary.questions)", "\(summary.explains) explain · \(summary.questions) ask"))
            StatTile(label: tr("Token 用量", "Tokens"), value: StatsFormat.compact(tokens.total), caption: tokenCaption)
                .help(tr("输入 ", "Input ") + StatsFormat.compact(tokens.prompt) + " · " + tr("输出 ", "Output ") + StatsFormat.compact(tokens.completion))
        }
    }

    // MARK: 图表

    private func chartCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(metric.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(unitCaption(summary.unit))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                Spacer()
                SegmentedPicker(selection: $metric, options: StatsMetric.allCases.map { ($0, $0.title) })
            }
            ColumnChart(buckets: summary.buckets, unit: summary.unit, metric: metric)
                .frame(height: 200)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private func unitCaption(_ unit: StatsSummary.Unit) -> String {
        switch unit {
        case .day: tr("每天", "per day")
        case .week: tr("每周", "per week")
        case .month: tr("每月", "per month")
        }
    }
}

// MARK: - 数字卡片

private struct StatTile: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyStats: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accent.opacity(0.1)))
            Text(tr("还没有学习记录", "No study history yet"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - 柱状图

/// 单系列柱状图：柱宽不超过 24pt，顶端 4pt 圆角、底端贴齐基线；悬停显示数值并淡化其他柱。
private struct ColumnChart: View {
    let buckets: [StatsSummary.Bucket]
    let unit: StatsSummary.Unit
    let metric: StatsMetric
    @ViewState private var hovered: Date?

    private static let axisWidth: CGFloat = 44
    private static let labelHeight: CGFloat = 20

    var body: some View {
        let values = buckets.map(value(of:))
        let scale = AxisScale(maxValue: values.max() ?? 0, metric: metric)
        GeometryReader { geometry in
            let plotWidth = max(geometry.size.width - Self.axisWidth, 1)
            let plotHeight = max(geometry.size.height - Self.labelHeight, 1)
            let slot = plotWidth / CGFloat(max(buckets.count, 1))
            let barWidth = min(24, max(2, slot * 0.62))
            let stride = max(1, Int((40 / slot).rounded(.up)))

            ZStack(alignment: .topLeading) {
                // 网格线与刻度
                ForEach(scale.ticks, id: \.self) { tick in
                    let y = plotHeight * (1 - CGFloat(tick / scale.top))
                    Rectangle()
                        .fill(Theme.border.opacity(tick == 0 ? 1 : 0.7))
                        .frame(width: plotWidth, height: 1)
                        .offset(x: Self.axisWidth, y: y)
                    Text(scale.label(tick))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                        .frame(width: Self.axisWidth - 8, alignment: .trailing)
                        .offset(y: y - 7)
                }

                // 柱
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    let value = values[index]
                    let height = scale.top > 0 ? plotHeight * CGFloat(value / scale.top) : 0
                    let x = Self.axisWidth + slot * CGFloat(index)
                    let dimmed = hovered != nil && hovered != bucket.start
                    ZStack(alignment: .bottom) {
                        Color.clear
                        if value > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: min(4, barWidth / 2), topTrailingRadius: min(4, barWidth / 2), style: .continuous)
                                .fill(Theme.accent)
                                .frame(width: barWidth, height: max(height, 2))
                                .opacity(dimmed ? 0.35 : 1)
                        }
                    }
                    .frame(width: slot, height: plotHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = bucket.start } else if hovered == bucket.start { hovered = nil }
                    }
                    .offset(x: x)
                    .accessibilityElement()
                    .accessibilityLabel(dateLabel(bucket.start, long: true))
                    .accessibilityValue(valueLabel(value))

                    if (buckets.count - 1 - index) % stride == 0 {
                        Text(dateLabel(bucket.start, long: false))
                            .font(.system(size: 10.5))
                            .foregroundStyle(hovered == bucket.start ? Theme.text : Theme.text3)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: slot * CGFloat(stride) + 20)
                            .offset(x: x + slot / 2 - (slot * CGFloat(stride) + 20) / 2, y: plotHeight + 5)
                    }
                }
            }
            // 悬停提示放在覆盖层里，不影响图表本身的排版
            .overlay(alignment: .topLeading) {
                if let hovered, let index = buckets.firstIndex(where: { $0.start == hovered }) {
                    let value = values[index]
                    let barTop = plotHeight - (scale.top > 0 ? plotHeight * CGFloat(value / scale.top) : 0)
                    // 提示的底边中点对准柱顶上方 6pt；放在固定大小的框里，位置不依赖提示自身的尺寸
                    let box = CGSize(width: 240, height: 80)
                    let centerX = min(max(Self.axisWidth + slot * (CGFloat(index) + 0.5), Self.axisWidth + 80), geometry.size.width - 80)
                    let bottom = max(barTop - 6, 50)
                    Tooltip(title: dateLabel(hovered, long: true), value: valueLabel(value))
                        .fixedSize()
                        .frame(width: box.width, height: box.height, alignment: .bottom)
                        .offset(x: centerX - box.width / 2, y: bottom - box.height)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.hover, value: hovered)
        .animation(Motion.content, value: buckets)
        .animation(Motion.content, value: metric)
    }

    private func value(of bucket: StatsSummary.Bucket) -> Double {
        metric.value(seconds: bucket.seconds, interactions: bucket.interactions, tokens: bucket.tokens)
    }

    private func valueLabel(_ value: Double) -> String {
        metric.label(value)
    }

    private func dateLabel(_ date: Date, long: Bool) -> String {
        let style = StatsFormat.dateStyle
        switch unit {
        case .day:
            if long { return date.formatted(style.month(.abbreviated).day().weekday(.abbreviated)) }
            return buckets.count <= 7 ? date.formatted(style.weekday(.abbreviated)) : date.formatted(style.month(.defaultDigits).day())
        case .week:
            let label = date.formatted(style.month(.defaultDigits).day())
            return long ? tr("\(label) 起一周", "Week of \(label)") : label
        case .month:
            return date.formatted(long ? style.year().month(.abbreviated) : style.month(.abbreviated))
        }
    }
}

/// 纵轴：取整的刻度，时长超过两小时改用小时。
private struct AxisScale {
    let top: Double
    let ticks: [Double]
    let metric: StatsMetric
    let hours: Bool

    init(maxValue: Double, metric: StatsMetric) {
        self.metric = metric
        hours = metric == .time && maxValue >= 120
        let unit = hours ? 60.0 : 1.0
        let peak = maxValue / unit
        guard peak > 0 else {
            top = (metric == .time ? 30 : 4) * unit
            ticks = [0, top / 2, top]
            return
        }
        let raw = peak / 3
        let magnitude = pow(10, floor(log10(raw)))
        let residual = raw / magnitude
        var step = (residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 2.5 ? 2.5 : residual <= 5 ? 5 : 10) * magnitude
        if metric != .time || !hours { step = max(step, 1) }
        let count = max(1, Int((peak / step).rounded(.up)))
        top = Double(count) * step * unit
        ticks = (0...count).map { Double($0) * step * unit }
    }

    func label(_ value: Double) -> String {
        switch metric {
        case .time:
            if hours {
                let h = value / 60
                let text = h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
                return tr("\(text) 时", "\(text)h")
            }
            return tr("\(Int(value)) 分", "\(Int(value))m")
        case .interactions: return String(Int(value))
        case .tokens: return StatsFormat.compact(Int(value))
        }
    }
}

private struct Tooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - 热力图

/// 最近一年的逐日热力图，颜色深浅跟随柱状图选中的指标。
private struct HeatmapCard: View {
    let year: StudyCalendar
    let metric: StatsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(tr("过去一年", "Past year"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(tr("学习 \(year.activeDays) 天", year.activeDays == 1 ? "1 day" : "\(year.activeDays) days"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .contentTransition(.numericText())
                Spacer(minLength: 12)
                HeatmapLegend()
            }
            HeatmapGrid(year: year, metric: metric)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// 空白格加四级由浅到深的陶土橙；叠在卡片底色上，浅色、深色模式各自成立。
private enum HeatLevel {
    static let empty = Color(light: 0x1F1E1D, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    private static let opacities: [Double] = [0.3, 0.5, 0.72, 1]

    static func color(_ level: Int) -> Color {
        level <= 0 ? empty : Theme.accent.opacity(opacities[min(level, opacities.count) - 1])
    }

    /// 以非零值的第 90 百分位为最深一级，免得个别特别长的一天把其余格子都压成最浅色。
    static func reference(_ values: [Double]) -> Double {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return 0 }
        return positive[Int((Double(positive.count - 1) * 0.9).rounded())]
    }

    static func level(_ value: Double, reference: Double) -> Int {
        guard value > 0, reference > 0 else { return 0 }
        return min(4, max(1, Int((value / reference * 4).rounded(.up))))
    }
}

private struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text(tr("少", "Less"))
                .padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(HeatLevel.color(level))
                    .frame(width: 10, height: 10)
            }
            Text(tr("多", "More"))
                .padding(.leading, 3)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text3)
        .accessibilityHidden(true)
    }
}

/// 每列一周、每行一个星期几；格子随卡片宽度缩放，让一整年正好铺满。悬停显示当天数值。
private struct HeatmapGrid: View {
    let year: StudyCalendar
    let metric: StatsMetric
    @ViewState private var hovered: Int?

    private static let labelWidth: CGFloat = 28
    private static let monthHeight: CGFloat = 18

    private struct AxisLabel: Identifiable {
        let id: Int
        let text: String
    }

    var body: some View {
        let values = year.days.map { metric.value(seconds: $0.seconds, interactions: $0.interactions, tokens: $0.tokens) }
        let reference = HeatLevel.reference(values)
        let columns = year.columns
        WidthDrivenLayout(height: { width in
            let (pitch, gap) = Self.pitch(width: width, columns: columns)
            return Self.monthHeight + 7 * pitch - gap
        }) {
            GeometryReader { geometry in
                let (pitch, gap) = Self.pitch(width: geometry.size.width, columns: columns)
                let cell = pitch - gap
                let radius = max(1.5, cell * 0.2)
                let left = Self.labelWidth
                let top = Self.monthHeight

                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(monthLabels) { label in
                        Text(label.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                            .fixedSize()
                            .offset(x: left + CGFloat(label.id) * pitch)
                    }
                    ForEach(weekdayLabels) { label in
                        Text(label.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text3)
                            .fixedSize()
                            .frame(height: cell)
                            .offset(y: top + CGFloat(label.id) * pitch)
                    }
                    ForEach(Array(year.days.enumerated()), id: \.element.id) { index, day in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(HeatLevel.color(HeatLevel.level(values[index], reference: reference)))
                            .frame(width: cell, height: cell)
                            .offset(x: left + CGFloat(day.column) * pitch, y: top + CGFloat(day.row) * pitch)
                    }
                    if let hovered, hovered < year.days.count {
                        let day = year.days[hovered]
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Theme.text.opacity(0.55), lineWidth: 1)
                            .frame(width: cell, height: cell)
                            .offset(x: left + CGFloat(day.column) * pitch, y: top + CGFloat(day.row) * pitch)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var index: Int?
                    if case .active(let point) = phase {
                        let column = Int(((point.x - left) / pitch).rounded(.down))
                        let row = Int(((point.y - top) / pitch).rounded(.down))
                        if (0..<columns).contains(column), (0..<7).contains(row), column * 7 + row < year.days.count {
                            index = column * 7 + row
                        }
                    }
                    if index != hovered { hovered = index }
                }
                // 悬停提示：底边中点对准格子上方 6pt
                .overlay(alignment: .topLeading) {
                    if let hovered, hovered < year.days.count {
                        let day = year.days[hovered]
                        let box = CGSize(width: 260, height: 80)
                        let centerX = min(max(left + CGFloat(day.column) * pitch + cell / 2, 80), geometry.size.width - 80)
                        let bottom = top + CGFloat(day.row) * pitch - 6
                        Tooltip(title: day.date.formatted(StatsFormat.dateStyle.year().month(.abbreviated).day().weekday(.abbreviated)),
                                value: metric.label(values[hovered]))
                            .fixedSize()
                            .frame(width: box.width, height: box.height, alignment: .bottom)
                            .offset(x: centerX - box.width / 2, y: bottom - box.height)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(Motion.hover, value: hovered)
        .animation(Motion.content, value: metric)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("过去一年", "Past year"))
        .accessibilityValue(tr("学习 \(year.activeDays) 天", year.activeDays == 1 ? "1 day" : "\(year.activeDays) days"))
    }

    /// 格距（格子边长加间隙）随宽度变化，最小 6pt、最大 18pt。
    private static func pitch(width: CGFloat, columns: Int) -> (pitch: CGFloat, gap: CGFloat) {
        let count = CGFloat(max(columns, 1))
        let gap: CGFloat = (width - labelWidth) / count >= 12 ? 3 : 2
        return (min(18, max(6, (width - labelWidth + gap) / count)), gap)
    }

    /// 每个月第一次出现在首行的那一列标上月份；最左一列只剩上个月的尾巴时不标，免得和下个月挤在一起。
    private var monthLabels: [AxisLabel] {
        let calendar = Calendar.current
        var labels: [AxisLabel] = []
        var previous: Int?
        for day in year.days where day.row == 0 {
            let month = calendar.component(.month, from: day.date)
            guard month != previous else { continue }
            previous = month
            labels.append(AxisLabel(id: day.column, text: day.date.formatted(StatsFormat.dateStyle.month(.abbreviated))))
        }
        if labels.count > 1, labels[1].id - labels[0].id < 3 { labels.removeFirst() }
        return labels
    }

    /// 与 GitHub 一样只标周一、周三、周五。
    private var weekdayLabels: [AxisLabel] {
        let calendar = Calendar.current
        return year.days.prefix(7).compactMap { day in
            [2, 4, 6].contains(calendar.component(.weekday, from: day.date))
                ? AxisLabel(id: day.row, text: day.date.formatted(StatsFormat.dateStyle.weekday(.abbreviated)))
                : nil
        }
    }
}

/// 按提议的宽度决定高度的容器：热力图的高度取决于格子大小，而格子大小取决于宽度。
private struct WidthDrivenLayout: Layout {
    let height: (CGFloat) -> CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? 640
        let width = proposed.isFinite ? proposed : 640
        return CGSize(width: width, height: height(width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

// MARK: - 排行

/// 课件所在的位置：属于哪个打开过的课程文件夹，以及其中的子文件夹。
struct DeckLocation {
    /// 课程文件夹；课件不在任何打开过的课程文件夹里时，是它所在的文件夹。
    let course: URL
    /// 课程文件夹内的子文件夹，如 ["第 3 章"]。
    let subfolders: [String]
    let isKnownCourse: Bool

    init(path: String, roots: [URL]) {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        let root = roots.map(\.standardizedFileURL)
            .filter { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        course = root ?? folder
        isKnownCourse = root != nil
        subfolders = root.map { folder.path.dropFirst($0.path.count).split(separator: "/").map(String.init) } ?? []
    }

    var courseName: String { course.lastPathComponent }

    /// 例如「高等数学 › 第 3 章」。
    var breadcrumb: String { ([courseName] + subfolders).joined(separator: " › ") }

    /// 课程文件夹的路径，主目录缩写为 ~。
    var coursePath: String { (course.path as NSString).abbreviatingWithTildeInPath }
}

private enum DeckGrouping: String, CaseIterable {
    case deck, course

    var title: String {
        switch self {
        case .deck: tr("课件", "Decks")
        case .course: tr("课程", "Courses")
        }
    }
}

private struct DeckList: View {
    let rows: [StatsSummary.DeckRow]
    let roots: [URL]
    let openDeck: (URL) -> Void
    @AppStorage("stats.deckGrouping") private var grouping: DeckGrouping = .deck
    @ViewState private var showsAll = false

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let detail: String
        let value: Double
        let help: String
        let target: URL?
    }

    var body: some View {
        let items = grouping == .deck ? deckItems : courseItems
        let peak = items.map(\.value).max() ?? 0
        let visible = showsAll ? items : Array(items.prefix(6))
        RankCard(title: tr("课件与课程", "Decks & courses"), trailing: AnyView(
            SegmentedPicker(selection: $grouping, options: DeckGrouping.allCases.map { ($0, $0.title) })
        )) {
            ForEach(visible) { item in
                RankRow(
                    icon: item.icon,
                    title: item.title,
                    subtitle: item.subtitle,
                    detail: item.detail,
                    fraction: peak > 0 ? item.value / peak : 0,
                    help: item.help,
                    action: item.target.map { url in { openDeck(url) } }
                )
            }
            if items.count > 6 {
                Button(showsAll ? tr("收起", "Show less")
                       : (grouping == .deck ? tr("显示全部 \(items.count) 份", "Show all \(items.count)")
                                            : tr("显示全部 \(items.count) 门", "Show all \(items.count)"))) {
                    withAnimation(Motion.snappy) { showsAll.toggle() }
                }
                .buttonStyle(TextButtonStyle(font: .system(size: 12)))
                .padding(.leading, 6)
                .padding(.top, 2)
            }
        }
        .animation(Motion.content, value: grouping)
    }

    /// 有阅读时长时按时长排，否则按问答次数。
    private var byTime: Bool { rows.contains { $0.seconds >= 60 } }

    private var deckItems: [Item] {
        rows.map { row in
            let location = DeckLocation(path: row.path, roots: roots)
            let exists = FileManager.default.fileExists(atPath: row.path)
            return Item(
                id: row.path,
                icon: "doc.text",
                title: row.name,
                subtitle: location.breadcrumb + (exists ? "" : tr("（文件已移动或删除）", " (moved or deleted)")),
                detail: detail(seconds: row.seconds, pages: row.pages.count, interactions: row.interactions),
                value: byTime ? row.seconds : Double(row.interactions),
                help: (row.path as NSString).abbreviatingWithTildeInPath,
                target: exists ? URL(fileURLWithPath: row.path) : nil
            )
        }
    }

    private var courseItems: [Item] {
        var groups: [URL: (location: DeckLocation, rows: [StatsSummary.DeckRow])] = [:]
        for row in rows {
            let location = DeckLocation(path: row.path, roots: roots)
            groups[location.course, default: (location, [])].rows.append(row)
        }
        return groups.values.map { group in
            let seconds = group.rows.reduce(0) { $0 + $1.seconds }
            let pages = group.rows.reduce(0) { $0 + $1.pages.count }
            let interactions = group.rows.reduce(0) { $0 + $1.interactions }
            let count = group.rows.count
            let exists = FileManager.default.fileExists(atPath: group.location.course.path)
            return Item(
                id: group.location.course.path,
                icon: group.location.isKnownCourse ? "books.vertical" : "folder",
                title: group.location.courseName,
                subtitle: tr("\(count) 份课件 · ", count == 1 ? "1 deck · " : "\(count) decks · ") + group.location.coursePath,
                detail: detail(seconds: seconds, pages: pages, interactions: interactions),
                value: byTime ? seconds : Double(interactions),
                help: group.location.coursePath,
                target: exists ? URL(fileURLWithPath: group.location.course.path, isDirectory: true) : nil
            )
        }
        .sorted { ($0.value, $0.title) > ($1.value, $1.title) }
    }

    private func detail(seconds: Double, pages: Int, interactions: Int) -> String {
        var parts: [String] = []
        if seconds >= 60 { parts.append(StatsFormat.duration(seconds)) }
        if pages > 0 { parts.append(tr("\(pages) 页", pages == 1 ? "1 page" : "\(pages) pages")) }
        if interactions > 0 { parts.append(tr("\(interactions) 次问答", interactions == 1 ? "1 Q&A" : "\(interactions) Q&As")) }
        return parts.joined(separator: " · ")
    }
}

private struct ModelList: View {
    let rows: [StatsSummary.ModelRow]

    var body: some View {
        let peak = Double(rows.map(\.tally.total).max() ?? 0)
        RankCard(title: tr("模型", "Models")) {
            ForEach(rows) { row in
                RankRow(
                    icon: "cpu",
                    title: row.name.isEmpty ? tr("未记录模型", "Unrecorded model") : row.name,
                    detail: StatsFormat.compact(row.tally.total) + tr(" Token · ", " tokens · ")
                        + tr("\(row.tally.requests) 次", row.tally.requests == 1 ? "1 request" : "\(row.tally.requests) requests"),
                    fraction: peak > 0 ? Double(row.tally.total) / peak : 0,
                    help: tr("输入 ", "Input ") + StatsFormat.compact(row.tally.prompt) + " · "
                        + tr("输出 ", "Output ") + StatsFormat.compact(row.tally.completion),
                    monospaced: !row.name.isEmpty,
                    action: nil
                )
            }
        }
    }
}

private struct RankCard<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .padding(.leading, 4)
                Spacer()
                trailing
            }
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        }
    }
}

/// 排行中的一行：名称、数值和按比例的细条。
private struct RankRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    let detail: String
    let fraction: Double
    let help: String
    var monospaced = false
    let action: (() -> Void)?
    @ViewState private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
            } else {
                content
            }
        }
        .animation(Motion.hover, value: hovering)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                Text(detail)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .opacity(hovering ? 1 : 0)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hover)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(fraction > 0 ? 6 : 0, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
            .frame(height: 6)
            .padding(.leading, 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && action != nil ? Theme.hover : .clear)
        )
        .contentShape(Rectangle())
    }
}
