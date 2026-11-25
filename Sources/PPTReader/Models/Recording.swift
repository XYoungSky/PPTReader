import Foundation

/// 一次课堂录音。音频按分段存（每段约 5 分钟一个 m4a），强制退出时最多丢正在写的那一段。
/// 存在录音文件夹的 `recording.json` 里，每切一段更新一次。
struct Recording: Codable, Identifiable, Equatable, Sendable {
    /// 也是文件夹名，例如 `2026-11-25_14-30-05`。
    var id: String
    var title: String
    var startedAt: Date
    /// 录音时打开的课件所在的课程文件夹，用来分组和找相关课件。
    var coursePath: String?
    /// 录音时打开的课件。
    var deckPath: String?
    /// 转写语言，例如 `en_US`。
    var locale: String
    var bitRate: Int
    var segments: [Segment]
    /// 整理第 1 步确认过的相关课件。
    var relatedDecks: [String]

    struct Segment: Codable, Equatable, Sendable {
        /// 从 1 开始。
        var index: Int
        var startedAt: Date
        /// 秒。正在录的分段是 0，录完（或启动时修复）后填上。
        var duration: Double
        var state: State
        /// 这一段的转写已经完整写进 `transcript.jsonl`。
        var transcribed: Bool

        enum State: String, Codable, Sendable {
            /// 正在写。启动时还是这个状态，说明上次录音中途退出了。
            case recording
            case complete
            /// 文件打不开（多半是写到一半退出了），回放和补转写时跳过。
            case damaged
        }

        var file: String { Self.fileName(index) }

        static func fileName(_ index: Int) -> String { String(format: "segment-%03d.m4a", index) }
    }

    init(id: String, title: String, startedAt: Date, coursePath: String?, deckPath: String?,
         locale: String, bitRate: Int, segments: [Segment] = [], relatedDecks: [String] = []) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.coursePath = coursePath
        self.deckPath = deckPath
        self.locale = locale
        self.bitRate = bitRate
        self.segments = segments
        self.relatedDecks = relatedDecks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, coursePath, deckPath, locale, bitRate, segments, relatedDecks
    }

    /// 以后加的字段都要有默认值，旧清单照样读得出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        coursePath = try c.decodeIfPresent(String.self, forKey: .coursePath)
        deckPath = try c.decodeIfPresent(String.self, forKey: .deckPath)
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en_US"
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate) ?? 32_000
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        relatedDecks = try c.decodeIfPresent([String].self, forKey: .relatedDecks) ?? []
    }

    // MARK: - 时间

    /// 能回放的分段，按顺序。回放时把它们拼成一段，进度条上的时间就是“录音时间”。
    var playable: [Segment] { segments.filter { $0.state == .complete } }

    /// 能回放的总时长（不含暂停和损坏的分段）。
    var duration: Double { playable.reduce(0) { $0 + $1.duration } }

    /// 某个分段在录音时间里从哪开始。损坏或还没录完的分段没法回放，返回 nil。
    func offset(ofSegment index: Int) -> Double? {
        var offset = 0.0
        for segment in segments where segment.state == .complete {
            if segment.index == index { return offset }
            offset += segment.duration
        }
        return nil
    }

    /// 分段里的位置 → 录音时间。
    func time(segment index: Int, at seconds: Double) -> Double? {
        offset(ofSegment: index).map { $0 + seconds }
    }

    /// 录音时间 → 哪个分段的哪个位置（回放时用来高亮当前句）。超出范围时取最近的一端。
    func locate(_ time: Double) -> (segment: Int, seconds: Double)? {
        let segments = playable
        guard let last = segments.last else { return nil }
        var offset = 0.0
        for segment in segments {
            if time < offset + segment.duration { return (segment.index, max(0, time - offset)) }
            offset += segment.duration
        }
        return (last.index, last.duration)
    }

    /// 下一个分段的序号。
    var nextSegmentIndex: Int { (segments.map(\.index).max() ?? 0) + 1 }
}

/// 转写里的一句。时间是在所属分段里的秒数；换算成录音时间用 `Recording.time(segment:at:)`。
struct TranscriptLine: Codable, Equatable, Sendable {
    var segment: Int
    var start: Double
    var end: Double
    var text: String
}
