import Foundation

/// 把逐日统计汇总成统计窗口需要的数字、柱状图分桶和排行。
struct StatsSummary {
    enum Period: String, CaseIterable, Identifiable {
        case week, month, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: tr("7 天", "7 days")
            case .month: tr("30 天", "30 days")
            case .all: tr("全部", "All time")
            }
        }
    }

    enum Unit {
        case day, week, month

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    struct Bucket: Identifiable, Equatable {
        let start: Date
        var seconds: Double = 0
        var interactions = 0
        var tokens = 0

        var id: Date { start }
    }

    struct DeckRow: Identifiable {
        let path: String
        var seconds: Double = 0
        var pages = Set<Int>()
        var explains = 0
        var questions = 0
        var tokens = 0
        var lastDay = Date.distantPast

        var id: String { path }
        var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        var interactions: Int { explains + questions }
    }

    struct ModelRow: Identifiable {
        let name: String
        var tally = TokenTally()

        var id: String { name }
    }

    let period: Period
    let unit: Unit
    private(set) var buckets: [Bucket] = []
    private(set) var seconds: Double = 0
    private(set) var pagesViewed = 0
    private(set) var explains = 0
    private(set) var questions = 0
    private(set) var tokens = TokenTally()
    private(set) var activeDays = 0
    private(set) var streak = 0
    private(set) var decks: [DeckRow] = []
    private(set) var models: [ModelRow] = []

    var interactions: Int { explains + questions }
    var hasActivity: Bool { seconds > 0 || interactions > 0 || pagesViewed > 0 }

    /// 一天里读满一分钟或问过问题，就算学习过。
    static func isActive(_ day: StatsDay) -> Bool {
        day.decks.values.contains { $0.seconds >= 60 || $0.explains + $0.questions > 0 }
    }

    init(log: StatsLog, period: Period, now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        let today = calendar.startOfDay(for: now)
        let parsed = log.days.compactMap { key, day in StatsLog.date(forKey: key, calendar: calendar).map { ($0, day) } }

        let start: Date
        switch period {
        case .week: start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all: start = min(parsed.map(\.0).min() ?? today, today)
        }
        let span = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        unit = period != .all || span <= 31 ? .day : (span <= 26 * 7 ? .week : .month)

        // 分桶
        var bucketIndex: [Date: Int] = [:]
        var cursor = bucketStart(start, unit: unit, calendar: calendar)
        let last = bucketStart(today, unit: unit, calendar: calendar)
        while cursor <= last {
            bucketIndex[cursor] = buckets.count
            buckets.append(Bucket(start: cursor))
            guard let next = calendar.date(byAdding: unit.component, value: 1, to: cursor) else { break }
            cursor = next
        }

        var deckRows: [String: DeckRow] = [:]
        var modelRows: [String: TokenTally] = [:]
        var pageSet = Set<String>()
        for (date, day) in parsed where date >= start && date <= today {
            if Self.isActive(day) { activeDays += 1 }
            let index = bucketIndex[bucketStart(date, unit: unit, calendar: calendar)]
            for (path, entry) in day.decks {
                seconds += entry.seconds
                explains += entry.explains
                questions += entry.questions
                tokens += entry.tokens
                for page in entry.pages { pageSet.insert("\(page)|\(path)") }
                if let index {
                    buckets[index].seconds += entry.seconds
                    buckets[index].interactions += entry.explains + entry.questions
                    buckets[index].tokens += entry.tokens.total
                }
                var row = deckRows[path] ?? DeckRow(path: path)
                row.seconds += entry.seconds
                row.pages.formUnion(entry.pages)
                row.explains += entry.explains
                row.questions += entry.questions
                row.tokens += entry.tokens.total
                row.lastDay = max(row.lastDay, date)
                deckRows[path] = row
            }
            for (name, tally) in day.models { modelRows[name, default: TokenTally()] += tally }
        }
        pagesViewed = pageSet.count
        decks = deckRows.values
            .filter { $0.seconds >= 1 || $0.interactions > 0 || !$0.pages.isEmpty }
            .sorted { ($0.seconds, $0.interactions, $0.tokens, $0.lastDay) > ($1.seconds, $1.interactions, $1.tokens, $1.lastDay) }
        models = modelRows.filter { $0.value.requests > 0 }
            .map { ModelRow(name: $0.key, tally: $0.value) }
            .sorted { ($0.tally.total, $0.tally.requests) > ($1.tally.total, $1.tally.requests) }

        // 连续学习天数：今天还没学也不中断，从昨天往前数
        let activeKeys = Set(log.days.filter { Self.isActive($0.value) }.map(\.key))
        var day = activeKeys.contains(StatsLog.key(for: today, calendar: calendar))
            ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while activeKeys.contains(StatsLog.key(for: day, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
    }
}

// MARK: - 热力图

/// 最近一年的逐日记录，像 GitHub 贡献图那样每列一周，最右一列是本周。
struct StudyCalendar {
    struct Day: Identifiable {
        let date: Date
        /// 第几周（从左往右）。
        let column: Int
        /// 一周中的第几天，从 calendar.firstWeekday 起算。
        let row: Int
        var seconds: Double = 0
        var interactions = 0
        var tokens = 0

        var id: Date { date }
    }

    /// 今天之后的日子不包含在内。
    private(set) var days: [Day] = []
    let columns: Int
    private(set) var activeDays = 0

    init(log: StatsLog, weeks: Int = 53, now: Date = Date(), calendar: Calendar = .current) {
        columns = weeks
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        var cursor = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        var index = 0
        while cursor <= today {
            var day = Day(date: cursor, column: index / 7, row: index % 7)
            if let record = log.days[StatsLog.key(for: cursor, calendar: calendar)] {
                for entry in record.decks.values {
                    day.seconds += entry.seconds
                    day.interactions += entry.explains + entry.questions
                    day.tokens += entry.tokens.total
                }
                if StatsSummary.isActive(record) { activeDays += 1 }
            }
            days.append(day)
            index += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
    }
}

private func bucketStart(_ date: Date, unit: StatsSummary.Unit, calendar: Calendar) -> Date {
    switch unit {
    case .day: calendar.startOfDay(for: date)
    case .week: calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    case .month: calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

// MARK: - 格式化

enum StatsFormat {
    /// 例如「2 小时 15 分钟」「45 分钟」。
    static func duration(_ seconds: Double) -> String {
        if seconds > 0 && seconds < 60 { return tr("不到 1 分钟", "< 1 min") }
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return tr("\(minutes) 分钟", "\(minutes) min") }
        if rest == 0 { return tr("\(hours) 小时", "\(hours) h") }
        return tr("\(hours) 小时 \(rest) 分", "\(hours) h \(rest) min")
    }

    /// 1,284 · 12.9K · 4.2M
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case ..<10_000: return value.formatted(.number.grouping(.automatic))
        case ..<1_000_000: return trim(v / 1000) + "K"
        case ..<1_000_000_000: return trim(v / 1_000_000) + "M"
        default: return trim(v / 1_000_000_000) + "B"
        }
    }

    private static func trim(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// 日期格式跟随界面语言，而不是系统语言。
    static var dateStyle: Date.FormatStyle {
        Date.FormatStyle(locale: Locale(identifier: Localizer.shared.isEnglish ? "en_US" : "zh_CN"))
    }
}
