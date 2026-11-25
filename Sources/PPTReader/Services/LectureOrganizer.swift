import Foundation
import PDFKit

/// 整理课堂录音（「AI 整理」）。不写整节课的笔记，只找两类东西：课件上没有的内容，和课程安排。
/// 1. 判断这节课讲了课程文件夹里的哪几份课件（轻量模型，看转写摘录和各课件开头），列出来让用户确认；
/// 2. 按约 10 分钟一段对照确认的课件，找出老师讲了、课件上没有的补充要点（对应到页），以及考试、作业、进度这些课程安排
///    （强模型；所有课件放在请求前部，各段共用缓存）。没有勾选课件时只找课程安排。
/// 这里只有组装请求、解析输出这些纯函数；调用模型的流程在 `LectureController`。
enum LectureOrganizer {
    // MARK: - 数据

    /// 课程文件夹里的一份课件。
    struct Candidate: Equatable, Sendable {
        var path: String
        var title: String
        /// 相对课程文件夹的子文件夹，例如 "Tutorial/Tutorial09"。
        var folder: String
        /// 开头几页的文字；读不到（没转换过的 PPT）时为空。
        var head: String
        var readable: Bool
    }

    /// 第 1 步的结果：模型认为相关的课件和理由。
    struct Choice: Equatable, Sendable {
        var path: String
        var reason: String
    }

    /// 一条整理出来的要点。
    struct Supplement: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// 老师讲了、课件上没有的内容。
            case supplement
            /// 课程安排：考试、作业和截止日期、进度变化、分数构成、要读的材料、答疑时间等。
            case arrangement
        }

        var kind: Kind
        /// 课件路径；对不上任何一页时为 nil。
        var deck: String?
        /// 对应的页（从 1 开始）；对不上任何一页时为 nil。
        var page: Int?
        var point: String
        /// 转写里的原话。
        var quote: String
        /// 录音时间（秒）。
        var time: Double

        init(kind: Kind = .supplement, deck: String?, page: Int?, point: String, quote: String, time: Double) {
            self.kind = kind
            self.deck = deck
            self.page = page
            self.point = point
            self.quote = quote
            self.time = time
        }

        private enum CodingKeys: String, CodingKey { case kind, deck, page, point, quote, time }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .supplement
            deck = try c.decodeIfPresent(String.self, forKey: .deck)
            page = try c.decodeIfPresent(Int.self, forKey: .page)
            point = try c.decode(String.self, forKey: .point)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        }
    }

    /// 存在录音文件夹的 `supplements.json`。
    struct Result: Codable, Equatable, Sendable {
        var version = 1
        var decks: [String]
        var supplements: [Supplement]
        var createdAt: Date
    }

    /// 转写里的一句，时间已经换算成录音时间。
    struct TimedLine: Equatable, Sendable {
        var time: Double
        var text: String
    }

    // MARK: - 转写

    static func timed(_ lines: [TranscriptLine], in recording: Recording) -> [TimedLine] {
        lines.compactMap { line in
            recording.time(segment: line.segment, at: line.start).map { TimedLine(time: $0, text: line.text) }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 读回模型写的时间：`12:05`、`1:02:03`，或者秒数。
    static func seconds(from value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = (value as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: " []()")) else { return nil }
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// 每句一行，前面是录音时间。
    static func block(_ lines: [TimedLine]) -> String {
        lines.map { "[\(clock($0.time))] \($0.text)" }.joined(separator: "\n")
    }

    /// 按录音时间切成大约 `seconds` 秒一段。
    static func chunks(_ lines: [TimedLine], seconds: Double = 600) -> [[TimedLine]] {
        guard let first = lines.first else { return [] }
        var result: [[TimedLine]] = []
        var current: [TimedLine] = []
        var start = first.time
        for line in lines {
            if !current.isEmpty, line.time - start >= seconds {
                result.append(current)
                current = []
                start = line.time
            }
            current.append(line)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 第 1 步用的摘录：每 10 分钟取开头的一些句子，总长不超过 `limit` 个字符。只用来判断讲了什么。
    static func excerpt(_ lines: [TimedLine], limit: Int = 12_000) -> String {
        let parts = chunks(lines)
        guard !parts.isEmpty else { return "" }
        let share = max(400, limit / parts.count)
        return parts.map { part -> String in
            var text = ""
            for line in part {
                let next = "[\(clock(line.time))] \(line.text)\n"
                if text.count + next.count > share { break }
                text += next
            }
            return text
        }.joined(separator: "…\n")
    }

    // MARK: - 课件

    /// 课程文件夹里的课件（最多 `limit` 份；多的时候优先和录音时打开的课件在同一个文件夹的）。
    static func candidates(course: URL, recordedDeck: String?, limit: Int = 40) -> [Candidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: course, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 5 { enumerator.skipDescendants() }
            let name = url.lastPathComponent
            guard !name.hasPrefix("~$"), CourseFileKind(fileExtension: url.pathExtension) != nil else { continue }
            files.append(url)
        }
        let recordedFolder = recordedDeck.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path }
        files.sort { a, b in
            let sameA = a.deletingLastPathComponent().standardizedFileURL.path == recordedFolder
            let sameB = b.deletingLastPathComponent().standardizedFileURL.path == recordedFolder
            if sameA != sameB { return sameA }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        let root = course.standardizedFileURL.path
        return files.prefix(limit).map { url in
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            let relative = folder.hasPrefix(root) ? String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
            let text = quickText(url, pages: 3)
            let head = (text ?? []).map { String($0.prefix(500)) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Candidate(path: url.path, title: url.deletingPathExtension().lastPathComponent, folder: relative,
                             head: head, readable: text != nil)
        }
    }

    /// 课件能读到文字的 PDF：PDF 本身，或者 PPT / Word 转换过的缓存。没转换过的返回 nil（不在后台驱动 Office）。
    static func pdfURL(for deck: URL) -> URL? {
        guard let kind = CourseFileKind(fileExtension: deck.pathExtension) else { return nil }
        return kind.needsConversion ? DocumentConverter.cachedPDF(for: deck) : deck
    }

    /// 快速取前几页的文字（不做 OCR）；有提取缓存时用缓存。
    static func quickText(_ deck: URL, pages: Int? = nil) -> [String]? {
        guard let pdf = pdfURL(for: deck) else { return nil }
        if let cached = TextExtractor.cached(for: pdf) { return Array(cached.pages.prefix(pages ?? cached.pages.count)) }
        guard let document = PDFDocument(url: pdf) else { return nil }
        let count = min(document.pageCount, pages ?? document.pageCount)
        return (0..<count).map { document.page(at: $0)?.string ?? "" }
    }

    // MARK: - 第 1 步：相关课件

    static func deckMessages(recording: Recording, excerpt: String, candidates: [Candidate], english: Bool) -> [[String: Any]] {
        let list = candidates.enumerated().map { index, deck -> String in
            var entry = "[\(index + 1)] \(deck.title)"
            if !deck.folder.isEmpty { entry += english ? " (folder: \(deck.folder))" : "（文件夹：\(deck.folder)）" }
            if deck.path == recording.deckPath { entry += english ? " — open while recording" : " —— 录音时打开的课件" }
            entry += "\n" + (deck.head.isEmpty ? (english ? "(text not available)" : "（读不到文字）") : deck.head)
            return entry
        }.joined(separator: "\n\n")
        let system = english
            ? """
              You help a student organize a recorded lecture. From the transcript excerpts, decide which of the listed decks the lecture covered: one, several, or none. Also give the course code (such as ADS205 or COMP3021), from the course folder, the deck names or what the lecturer says; use null if you can't tell. The transcript comes from speech recognition and may contain misheard words.
              Output only JSON: {"course":"ADS205","decks":[{"id":2,"reason":"one short sentence"}]}, where id is the number in the list. Use "decks":[] if none match.
              """
            : """
              你在帮学生整理课堂录音。根据老师讲课转写的摘录，判断这节课讲的是下面列出的哪几份课件：可能是一份、几份，也可能都不是。另外给出这门课的课程编号（例如 ADS205、COMP3021），可以从课程文件夹、课件名或老师讲的话里看出来；看不出来时写 null。转写是语音识别的结果，可能有听错的词。
              只输出 JSON：{"course":"ADS205","decks":[{"id":2,"reason":"一句话理由"}]}，id 是列表里的编号。都不相关时 "decks" 写 []。
              """
        let folder = (recording.coursePath ?? recording.deckPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            .map { URL(fileURLWithPath: $0).pathComponents.filter { $0 != "/" }.suffix(3).joined(separator: "/") } ?? ""
        let deckList = list.isEmpty ? (english ? "(none found)" : "（没有找到课件）") : list
        let user = english
            ? "Recording: \(recording.title), \(clock(recording.duration)) long. Course folder: \(folder)\n<transcript_excerpt>\n\(excerpt)\n</transcript_excerpt>\n\nDecks:\n\(deckList)"
            : "录音：\(recording.title)，时长 \(clock(recording.duration))。课程文件夹：\(folder)\n<transcript_excerpt>\n\(excerpt)\n</transcript_excerpt>\n\n课件列表：\n\(deckList)"
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    /// 读出课程编号：去掉空白，转成大写；太长或没有数字的不算（多半不是编号）。
    static func parseCourse(_ output: String) -> String? {
        guard let object = jsonValue(output) as? [String: Any], let raw = object["course"] as? String else { return nil }
        let code = raw.replacingOccurrences(of: " ", with: "").uppercased()
        guard (3...16).contains(code.count), code.contains(where: \.isNumber), code.contains(where: \.isLetter) else { return nil }
        return code
    }

    static func parseDecks(_ output: String, candidates: [Candidate]) -> [Choice]? {
        guard let json = jsonValue(output) else { return nil }
        let list = ((json as? [String: Any])?["decks"] as? [Any]) ?? (json as? [Any])
        guard let list else { return nil }
        var seen = Set<String>()
        return list.compactMap { item -> Choice? in
            let dict = item as? [String: Any]
            let raw = dict?["id"] ?? item
            let id = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let id, candidates.indices.contains(id - 1) else { return nil }
            let path = candidates[id - 1].path
            guard seen.insert(path).inserted else { return nil }
            return Choice(path: path, reason: (dict?["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    // MARK: - 第 2 步：补充要点

    /// 一份确认过的课件和它的文字。
    struct Deck: Equatable, Sendable {
        var path: String
        var title: String
        var pages: [String]
    }

    /// 课件文字按页标出页码。每页最多 `pageLimit` 个字符，几份课件合起来太长时由调用方调小。
    static func courseware(_ decks: [Deck], pageLimit: Int, english: Bool) -> String {
        decks.enumerated().map { index, deck in
            let pages = deck.pages.enumerated().map { number, raw -> String in
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = text.isEmpty ? (english ? "(no text on this page)" : "（这一页没有文字）") : String(text.prefix(pageLimit))
                return (english ? "[Page \(number + 1)]" : "【第 \(number + 1) 页】") + "\n" + body
            }.joined(separator: "\n\n")
            return "<deck id=\"\(index + 1)\" title=\"\(deck.title)\">\n\(pages)\n</deck>"
        }.joined(separator: "\n\n")
    }

    /// 前缀：说明 + 带页码的课件全文。各段请求共用，可以命中缓存。没有课件时只找课程安排。
    static func supplementSystem(decks: [Deck], pageLimit: Int, english: Bool) -> String {
        if decks.isEmpty { return arrangementSystem(english: english) }
        let courseware = courseware(decks, pageLimit: pageLimit, english: english)
        let several = decks.count > 1
        if english {
            return """
            You help a student go through a recorded lecture taught in English. Below is the full text of the \(several ? "decks" : "deck") used in this lecture, with page numbers. I will then send the lecture transcript in parts, with timestamps.
            List only two kinds of things; the student doesn't need a summary of the lecture:
            - "supplement": what the lecturer said that is NOT on the slides: extra explanations, examples, analogies, wording that differs from the slides, and common mistakes the lecturer warned about. Leave out anything the slides already say and anything merely read from the slides.
            - "arrangement": anything about how the course runs: exams (dates, scope, format, what to focus on), assignments and deadlines, changes to the schedule or the room, grading, readings or preparation, office hours.
            For each item:
            - kind: "supplement" or "arrangement".
            - deck: the id of the deck it relates to.
            - page: the page of that deck it relates to most (an integer), or null if it matches no page.
            - point: the item in English, one or two sentences; keep dates, times and numbers exactly as said.
            - quote: a short excerpt from the transcript that supports it.
            - start: when that excerpt starts, written as in the transcript, e.g. "12:05".
            Output only JSON: {"items":[{"kind":"supplement","deck":1,"page":12,"point":"…","quote":"…","start":"12:05"}]}. If this part has neither, output {"items":[]}.
            The transcript comes from speech recognition and may contain misheard words; use the deck's terminology to make sense of it.
            <courseware>
            \(courseware)
            </courseware>
            """
        }
        return """
        你在帮学生整理一节英文授课的课堂录音。下面是这节课用到的\(several ? "几份" : "")课件全文，按页标出页码。之后我会分段发给你老师讲课的转写，每句前面是时间。
        只列出两类内容，不需要概括这节课讲了什么：
        - "supplement"（补充）：老师讲了、但课件上没有的内容，包括补充的解释、例子、类比、和课件不同的说法、老师提醒的易错点。课件上已经写了的内容不要列出，照着课件念的也不要列出。
        - "arrangement"（课程安排）：和课程安排有关的内容，包括考试（时间、范围、题型、重点）、作业和截止日期、上课时间或地点的变动、分数构成、需要阅读或预习的材料、答疑时间。
        每一条：
        - kind："supplement" 或 "arrangement"。
        - deck：和哪份课件有关（课件的 id）。
        - page：和这份课件第几页最相关（整数）；和任何一页都对不上时写 null。
        - point：用中文写，一两句话，专业术语保留英文原文；日期、时间、数字照原话写。
        - quote：转写里能支持这一条的原话（英文，简短摘录）。
        - start：这段原话开始的时间，照转写里的写法，例如 "12:05"。
        只输出 JSON：{"items":[{"kind":"supplement","deck":1,"page":12,"point":"…","quote":"…","start":"12:05"}]}。这一段两类内容都没有时输出 {"items":[]}。
        转写是语音识别的结果，可能有听错的词，请参照课件里的术语理解。
        <courseware>
        \(courseware)
        </courseware>
        """
    }

    /// 没有课件可以对照：只找课程安排。
    static func arrangementSystem(english: Bool) -> String {
        if english {
            return """
            You help a student go through a recorded lecture taught in English. I will send the lecture transcript in parts, with timestamps.
            List only what is about how the course runs: exams (dates, scope, format, what to focus on), assignments and deadlines, changes to the schedule or the room, grading, readings or preparation, office hours. Don't summarize the lecture content.
            For each item: kind "arrangement"; page null; point: the item in English, one or two sentences, keeping dates, times and numbers exactly as said; quote: a short supporting excerpt from the transcript; start: when it starts, e.g. "12:05".
            Output only JSON: {"items":[{"kind":"arrangement","page":null,"point":"…","quote":"…","start":"12:05"}]}. If this part has none, output {"items":[]}.
            The transcript comes from speech recognition and may contain misheard words.
            """
        }
        return """
        你在帮学生整理一节英文授课的课堂录音。我会分段发给你老师讲课的转写，每句前面是时间。
        只列出和课程安排有关的内容：考试（时间、范围、题型、重点）、作业和截止日期、上课时间或地点的变动、分数构成、需要阅读或预习的材料、答疑时间。不要概括讲课内容。
        每一条：kind 写 "arrangement"；page 写 null；point 用中文写，一两句话，日期、时间、数字照原话写；quote 是转写里的原话（英文，简短摘录）；start 是原话开始的时间，例如 "12:05"。
        只输出 JSON：{"items":[{"kind":"arrangement","page":null,"point":"…","quote":"…","start":"12:05"}]}。这一段没有时输出 {"items":[]}。
        转写是语音识别的结果，可能有听错的词。
        """
    }

    static func supplementMessages(system: String, part: [TimedLine], index: Int, total: Int, english: Bool) -> [[String: Any]] {
        let range = "\(clock(part.first?.time ?? 0))–\(clock(part.last?.time ?? 0))"
        let intro = english ? "Transcript part \(index)/\(total) (\(range)):" : "转写第 \(index)/\(total) 段（\(range)）："
        return [
            ["role": "system", "content": system],
            ["role": "user", "content": "\(intro)\n<transcript>\n\(block(part))\n</transcript>"],
        ]
    }

    /// 解析一段的结果：类型认不出时当作补充；课件 id 缺省时是第一份；页码限制在那份课件内（越界的当作对不上任何一页）；
    /// 时间限制在这一段附近，读不出时用这一段的开头。没有课件时都当作课程安排。
    static func parseSupplements(_ output: String, decks: [Deck], part: [TimedLine]) -> [Supplement]? {
        guard let json = jsonValue(output) else { return nil }
        let object = json as? [String: Any]
        let list = (object?["items"] as? [Any]) ?? (object?["supplements"] as? [Any]) ?? (json as? [Any])
        guard let list else { return nil }
        let start = part.first?.time ?? 0
        let end = part.last?.time ?? start
        func integer(_ value: Any?) -> Int? {
            (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0.filter(\.isNumber)) }
        }
        return list.compactMap { item -> Supplement? in
            guard let dict = item as? [String: Any],
                  let point = (dict["point"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !point.isEmpty else { return nil }
            let deckIndex = (integer(dict["deck"]) ?? 1) - 1
            let deck = decks.indices.contains(deckIndex) ? decks[deckIndex] : decks.first
            var page = integer(dict["page"])
            if let p = page, !(1...max(1, deck?.pages.count ?? 0)).contains(p) { page = nil }
            var time = seconds(from: dict["start"] ?? dict["time"]) ?? start
            if time < start - 30 || time > end + 30 { time = start }
            let quote = (dict["quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let raw = (dict["kind"] as? String)?.lowercased() ?? ""
            let kind: Supplement.Kind = decks.isEmpty || raw.hasPrefix("arrange") || raw.contains("安排") ? .arrangement : .supplement
            if decks.isEmpty { page = nil }
            return Supplement(kind: kind, deck: page == nil ? nil : deck?.path, page: page, point: point, quote: quote, time: time)
        }
    }

    // MARK: - 工具

    /// 从输出里取出 JSON（容忍前后的说明和代码块标记）。
    static func jsonValue(_ output: String) -> Any? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = output.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))
    }
}

extension RecordingStore {
    static let organizedName = "supplements.json"

    func organized(_ id: String) -> LectureOrganizer.Result? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(Self.organizedName)) else { return nil }
        return try? decoder.decode(LectureOrganizer.Result.self, from: data)
    }

    /// 保存整理结果，并在清单里记下相关课件。
    func saveOrganized(_ result: LectureOrganizer.Result, for id: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: folder(id).appendingPathComponent(Self.organizedName), options: .atomic)
        try update(id) { $0.relatedDecks = result.decks }
    }
}
