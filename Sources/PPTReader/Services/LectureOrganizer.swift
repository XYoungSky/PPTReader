import Foundation
import PDFKit

/// 整理课堂录音（「AI 整理」）：
/// 1. 判断这节课讲了课程文件夹里的哪几份课件（轻量模型，看转写摘录和各课件开头），列出来让用户确认；
/// 2. 对每份确认的课件，按约 10 分钟一段，找出老师讲了、课件上没有的补充要点，对应到页（强模型；课件放在请求前部，各段共用缓存）；
/// 3. 写整节课的笔记（强模型），课件以外的要点放进笔记。
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

    /// 一条补充要点。
    struct Supplement: Codable, Equatable, Sendable {
        /// 课件路径；课件以外的要点为 nil。
        var deck: String?
        /// 对应的页（从 1 开始）；对不上任何一页时为 nil。
        var page: Int?
        var point: String
        /// 转写里的原话。
        var quote: String
        /// 录音时间（秒）。
        var time: Double
    }

    /// 存在录音文件夹的 `supplements.json`。笔记另存 `notes.md`。
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

    /// 按 token 预算把句子分成几部分（笔记太长时分部分写，再合并）。
    static func parts(_ lines: [TimedLine], budget: Int) -> [[TimedLine]] {
        var result: [[TimedLine]] = []
        var current: [TimedLine] = []
        var used = 0
        for line in lines {
            let tokens = TokenEstimate.of(line.text) + 4
            if !current.isEmpty, used + tokens > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += tokens
        }
        if !current.isEmpty { result.append(current) }
        return result
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
              You help a student organize a recorded lecture. From the transcript excerpts, decide which of the listed decks the lecture covered: one, several, or none. The transcript comes from speech recognition and may contain misheard words.
              Output only JSON: {"decks":[{"id":2,"reason":"one short sentence"}]}, where id is the number in the list. Output {"decks":[]} if none match.
              """
            : """
              你在帮学生整理课堂录音。根据老师讲课转写的摘录，判断这节课讲的是下面列出的哪几份课件：可能是一份、几份，也可能都不是。转写是语音识别的结果，可能有听错的词。
              只输出 JSON：{"decks":[{"id":2,"reason":"一句话理由"}]}，id 是列表里的编号。都不相关时输出 {"decks":[]}。
              """
        let user = english
            ? "Recording: \(recording.title), \(clock(recording.duration)) long.\n<transcript_excerpt>\n\(excerpt)\n</transcript_excerpt>\n\nDecks:\n\(list)"
            : "录音：\(recording.title)，时长 \(clock(recording.duration))。\n<transcript_excerpt>\n\(excerpt)\n</transcript_excerpt>\n\n课件列表：\n\(list)"
        return [["role": "system", "content": system], ["role": "user", "content": user]]
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

    /// 前缀：说明 + 带页码的课件全文。各段请求共用，可以命中缓存。
    static func supplementSystem(decks: [Deck], pageLimit: Int, english: Bool) -> String {
        let courseware = courseware(decks, pageLimit: pageLimit, english: english)
        let several = decks.count > 1
        if english {
            return """
            You help a student organize a recorded lecture taught in English. Below is the full text of the \(several ? "decks" : "deck") used in this lecture, with page numbers. I will then send the lecture transcript in parts, with timestamps.
            Find what the lecturer said that is NOT on the slides: extra explanations, examples, analogies, wording that differs from the slides, exam hints, assignments or schedule changes, and common mistakes the lecturer warned about. Leave out anything the slides already say and anything merely read from the slides.
            For each point:
            - deck: the id of the deck it relates to.
            - page: the page of that deck it relates to most (an integer), or null if it matches no page.
            - point: the point itself in English, one or two sentences.
            - quote: a short excerpt from the transcript that supports it.
            - start: when that excerpt starts, written as in the transcript, e.g. "12:05".
            Output only JSON: {"supplements":[{"deck":1,"page":12,"point":"…","quote":"…","start":"12:05"}]}. If this part adds nothing beyond the slides, output {"supplements":[]}.
            The transcript comes from speech recognition and may contain misheard words; use the deck's terminology to make sense of it.
            <courseware>
            \(courseware)
            </courseware>
            """
        }
        return """
        你在帮学生整理一节英文授课的课堂录音。下面是这节课用到的\(several ? "几份" : "")课件全文，按页标出页码。之后我会分段发给你老师讲课的转写，每句前面是时间。
        你的任务：找出老师讲了、但课件上没有的内容，包括补充的解释、例子、类比、和课件不同的说法、考试提示、作业或安排的变化、老师提醒的易错点。课件上已经写了的内容不要列出，照着课件念的也不要列出。
        每条要点：
        - deck：和哪份课件有关（课件的 id）。
        - page：和这份课件第几页最相关（整数）；和任何一页都对不上时写 null。
        - point：用中文写的要点，一两句话，专业术语保留英文原文。
        - quote：转写里能支持这条要点的原话（英文，简短摘录）。
        - start：这段原话开始的时间，照转写里的写法，例如 "12:05"。
        只输出 JSON：{"supplements":[{"deck":1,"page":12,"point":"…","quote":"…","start":"12:05"}]}。这一段没有课件以外的内容时输出 {"supplements":[]}。
        转写是语音识别的结果，可能有听错的词，请参照课件里的术语理解。
        <courseware>
        \(courseware)
        </courseware>
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

    /// 解析一段的补充要点：课件 id 缺省时是第一份；页码限制在那份课件内（越界的当作课件以外）；
    /// 时间限制在这一段附近，读不出时用这一段的开头。
    static func parseSupplements(_ output: String, decks: [Deck], part: [TimedLine]) -> [Supplement]? {
        guard let json = jsonValue(output) else { return nil }
        let list = ((json as? [String: Any])?["supplements"] as? [Any]) ?? (json as? [Any])
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
            return Supplement(deck: page == nil ? nil : deck?.path, page: page, point: point, quote: quote, time: time)
        }
    }

    // MARK: - 第 3 步：笔记

    static func notesMessages(recording: Recording, decks: [String], lines: [TimedLine], supplements: [Supplement],
                              english: Bool, part: (Int, Int)? = nil) -> [[String: Any]] {
        let deckList = decks.isEmpty ? (english ? "(none)" : "（无）") : decks.joined(separator: english ? ", " : "、")
        let extra = supplements.map { item -> String in
            let page = item.page.map { english ? "page \($0)" : "第 \($0) 页" } ?? (english ? "not on the slides" : "课件以外")
            return "- [\(clock(item.time))] (\(page)) \(item.point)"
        }.joined(separator: "\n")
        let system: String
        if english {
            system = """
            You turn a recorded lecture taught in English into study notes for a student. Write Markdown:
            1. Start with a short paragraph summarizing what the lecture covered.
            2. Then follow the order of the lecture: one level-2 heading per part, with its start time in parentheses, e.g. "## Process scheduling (12:05)". Under each, write the key points as bullets. Mention briefly what is already on the slides (say which page, e.g. "see slide 12") and write out in more detail what the lecturer added.
            3. A section "Beyond the slides" with what doesn't match any slide.
            4. If the lecturer mentioned exams, assignments or deadlines, a section "Reminders".
            Don't invent anything that isn't in the transcript. The transcript comes from speech recognition and may contain misheard words.
            """
        } else {
            system = """
            你在帮学生把一节英文授课的课堂录音整理成笔记。用 Markdown 写：
            1. 开头一段话概括这节课讲了什么。
            2. 然后按讲课的顺序分成几个部分，每部分一个二级标题，标题后面括号里写开始时间，例如“## 进程调度（12:05）”。下面用条目写要点：课件上已有的内容简要带过并注明页码（例如“见课件第 12 页”），老师补充的内容写详细。
            3. 一节“课件以外”，写和课件对不上的内容。
            4. 老师提到考试、作业、截止日期时，单独一节“提醒”。
            用中文写，专业术语保留英文原文。不要编造转写里没有的内容。转写是语音识别的结果，可能有听错的词。
            """
        }
        var user = english
            ? "Lecture: \(recording.title). Decks: \(deckList)."
            : "课程录音：\(recording.title)。相关课件：\(deckList)。"
        if let part {
            user += english
                ? " This is part \(part.0) of \(part.1) of the transcript; write notes for this part only."
                : "这是转写的第 \(part.0)/\(part.1) 部分，只整理这一部分。"
        }
        if !extra.isEmpty {
            user += english ? "\n\nPoints beyond the slides found earlier:\n\(extra)" : "\n\n之前找出的课件以外的要点：\n\(extra)"
        }
        user += "\n\n<transcript>\n\(block(lines))\n</transcript>"
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    /// 笔记分部分写了之后，合并成一份。
    static func mergeNotesMessages(recording: Recording, parts: [String], english: Bool) -> [[String: Any]] {
        let joined = parts.enumerated().map { "<part index=\"\($0.offset + 1)\">\n\($0.element)\n</part>" }.joined(separator: "\n\n")
        let system = english
            ? "Merge these partial notes of one lecture into a single set of notes in the same Markdown format: one summary paragraph at the top, parts in lecture order with their start times, then \"Beyond the slides\" and \"Reminders\" sections. Keep every concrete point; remove repetition. Don't add anything new."
            : "把同一节课分部分写的笔记合并成一份，格式不变：开头一段概括，然后按讲课顺序的各部分（保留开始时间），最后是“课件以外”和“提醒”。保留所有具体的要点，去掉重复，不要添加新内容。"
        let user = (english ? "Lecture: \(recording.title)\n\n" : "课程录音：\(recording.title)\n\n") + joined
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    /// 去掉模型有时包在外面的代码块标记。
    static func cleanNotes(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = String(text.drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text
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
    static let notesName = "notes.md"
    static let supplementsName = "supplements.json"

    func notes(_ id: String) -> String? {
        try? String(contentsOf: folder(id).appendingPathComponent(Self.notesName), encoding: .utf8)
    }

    func organized(_ id: String) -> LectureOrganizer.Result? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(Self.supplementsName)) else { return nil }
        return try? decoder.decode(LectureOrganizer.Result.self, from: data)
    }

    /// 保存整理结果，并在清单里记下相关课件。
    func saveOrganized(_ result: LectureOrganizer.Result, notes: String, for id: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: folder(id).appendingPathComponent(Self.supplementsName), options: .atomic)
        try notes.write(to: folder(id).appendingPathComponent(Self.notesName), atomically: true, encoding: .utf8)
        try update(id) { $0.relatedDecks = result.decks }
    }
}
