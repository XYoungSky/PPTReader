import Foundation
import Observation

/// Token 用量合计。
struct TokenTally: Codable, Equatable {
    var requests = 0
    var prompt = 0
    var completion = 0
    var cacheHit = 0

    var total: Int { prompt + completion }

    static func += (lhs: inout TokenTally, rhs: TokenTally) {
        lhs.requests += rhs.requests
        lhs.prompt += rhs.prompt
        lhs.completion += rhs.completion
        lhs.cacheHit += rhs.cacheHit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        prompt = try c.decodeIfPresent(Int.self, forKey: .prompt) ?? 0
        completion = try c.decodeIfPresent(Int.self, forKey: .completion) ?? 0
        cacheHit = try c.decodeIfPresent(Int.self, forKey: .cacheHit) ?? 0
    }
}

/// 某一天在某份课件上的学习记录。
struct DeckDay: Codable, Equatable {
    /// 有操作的阅读时长（秒）。
    var seconds: Double = 0
    /// 看过的页码（从 1 开始，升序不重复）。
    var pages: [Int] = []
    /// 讲解本页（含自动讲解）的次数。
    var explains = 0
    /// 其余提问（自由提问、选中内容、总结等）的次数。
    var questions = 0
    var tokens = TokenTally()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        pages = try c.decodeIfPresent([Int].self, forKey: .pages) ?? []
        explains = try c.decodeIfPresent(Int.self, forKey: .explains) ?? 0
        questions = try c.decodeIfPresent(Int.self, forKey: .questions) ?? 0
        tokens = try c.decodeIfPresent(TokenTally.self, forKey: .tokens) ?? TokenTally()
    }

    mutating func insertPage(_ page: Int) {
        guard page > 0 else { return }
        let index = pages.firstIndex { $0 >= page } ?? pages.endIndex
        if index == pages.endIndex || pages[index] != page { pages.insert(page, at: index) }
    }

    mutating func merge(_ other: DeckDay) {
        seconds += other.seconds
        for page in other.pages { insertPage(page) }
        explains += other.explains
        questions += other.questions
        tokens += other.tokens
    }
}

struct StatsDay: Codable, Equatable {
    /// 课件路径 → 当天记录。
    var decks: [String: DeckDay] = [:]
    /// 模型名 → 当天用量；空字符串表示没有记录模型的旧对话。
    var models: [String: TokenTally] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decks = try c.decodeIfPresent([String: DeckDay].self, forKey: .decks) ?? [:]
        models = try c.decodeIfPresent([String: TokenTally].self, forKey: .models) ?? [:]
    }
}

/// 全部统计：按本地日期（yyyy-MM-dd）汇总。
struct StatsLog: Codable, Equatable {
    var version = 1
    var days: [String: StatsDay] = [:]

    var isEmpty: Bool { days.isEmpty }

    mutating func merge(_ other: StatsLog) {
        for (key, day) in other.days {
            var target = days[key] ?? StatsDay()
            for (deck, value) in day.decks { target.decks[deck, default: DeckDay()].merge(value) }
            for (model, value) in day.models { target.models[model, default: TokenTally()] += value }
            days[key] = target
        }
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum ReplyKind {
    case explain, question
}

/// 学习统计：阅读时长、看过的页、提问次数与 Token 用量，保存在
/// ~/Library/Application Support/PPTReader/Stats.json。清空对话不会影响统计。
@MainActor
@Observable
final class StatsStore {
    private(set) var log = StatsLog()

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "PPTReader.StatsStore", qos: .utility)
    @ObservationIgnored private static let backfillKey = "stats.backfilled"

    init(fileURL: URL = AppPaths.support.appendingPathComponent("Stats.json")) {
        self.fileURL = fileURL
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(StatsLog.self, from: data) {
                log = decoded
            } else {
                // 无法读取时保留原文件，避免被新数据覆盖
                let backup = fileURL.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: backup)
            }
        }
        if exists {
            UserDefaults.standard.set(true, forKey: Self.backfillKey)
        } else if !UserDefaults.standard.bool(forKey: Self.backfillKey) {
            backfillFromChats(before: Date())
        }
    }

    // MARK: - 记录

    func addStudyTime(_ seconds: Double, deck: String, at date: Date = Date()) {
        guard seconds > 0 else { return }
        update(deck: deck, at: date) { $0.seconds += seconds }
    }

    func notePage(_ page: Int, deck: String, at date: Date = Date()) {
        let key = StatsLog.key(for: date)
        if log.days[key]?.decks[deck]?.pages.contains(page) == true { return }
        update(deck: deck, at: date) { $0.insertPage(page) }
    }

    func recordReply(deck: String, page: Int?, model: String?, kind: ReplyKind, usage: TokenUsage?, at date: Date) {
        let tally = Self.tally(usage)
        let key = StatsLog.key(for: date)
        var day = log.days[key] ?? StatsDay()
        var entry = day.decks[deck] ?? DeckDay()
        switch kind {
        case .explain: entry.explains += 1
        case .question: entry.questions += 1
        }
        if let page { entry.insertPage(page) }
        entry.tokens += tally
        day.decks[deck] = entry
        day.models[model ?? "", default: TokenTally()] += tally
        log.days[key] = day
        scheduleSave()
    }

    func clear() {
        log = StatsLog()
        UserDefaults.standard.set(true, forKey: Self.backfillKey)
        scheduleSave(delay: 0)
    }

    private func update(deck: String, at date: Date, _ change: (inout DeckDay) -> Void) {
        let key = StatsLog.key(for: date)
        var day = log.days[key] ?? StatsDay()
        var entry = day.decks[deck] ?? DeckDay()
        change(&entry)
        day.decks[deck] = entry
        log.days[key] = day
        scheduleSave()
    }

    nonisolated private static func tally(_ usage: TokenUsage?) -> TokenTally {
        var tally = TokenTally()
        tally.requests = 1
        if let usage {
            tally.prompt = usage.prompt
            tally.completion = usage.completion
            tally.cacheHit = usage.cacheHit ?? 0
        }
        return tally
    }

    // MARK: - 保存

    private func scheduleSave(delay: Double = 3) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// 立即写入（退出时调用）。
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(log) else { return }
        let url = fileURL
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - 从已有对话补录

    /// 第一次启用统计时，从已保存的对话中补录提问次数和 Token 用量（没有阅读时长）。
    private func backfillFromChats(before cutoff: Date) {
        Task.detached(priority: .utility) {
            let imported = Self.importChats(from: AppPaths.chats, before: cutoff)
            await MainActor.run {
                self.log.merge(imported)
                UserDefaults.standard.set(true, forKey: Self.backfillKey)
                self.scheduleSave(delay: 0)
            }
        }
    }

    /// - Parameter cutoff: 只补录这个时间之前的回答，之后的由 ChatController 实时记录。
    nonisolated static func importChats(from directory: URL, before cutoff: Date) -> StatsLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var log = StatsLog()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let thread = try? decoder.decode(ChatThread.self, from: data) else { continue }
            let messages = thread.messages
            for (index, reply) in messages.enumerated() where reply.role == .assistant {
                guard reply.error == nil, !reply.content.isEmpty, reply.createdAt < cutoff,
                      index > 0, messages[index - 1].role == .user else { continue }
                let question = messages[index - 1]
                let key = StatsLog.key(for: reply.createdAt)
                var day = log.days[key] ?? StatsDay()
                var entry = day.decks[thread.sourcePath] ?? DeckDay()
                if question.explainsPage != nil { entry.explains += 1 } else { entry.questions += 1 }
                if let page = question.page { entry.insertPage(page) }
                let tally = tally(reply.usage)
                entry.tokens += tally
                day.decks[thread.sourcePath] = entry
                day.models[reply.model ?? "", default: TokenTally()] += tally
                log.days[key] = day
            }
        }
        return log
    }
}
