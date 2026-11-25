import Foundation

/// 「AI 整理」的流程：先判断相关课件让用户确认，再参照课件纠正转写，最后对照课件找补充要点和课程安排。
/// 每一步用对应任务的模型，用量计入统计。
extension LectureController {
    /// 某次录音正在整理到哪一步（录音窗口据此显示）。
    enum OrganizeState: Equatable {
        /// 第 1 步：正在判断相关课件。
        case finding
        /// 等用户确认相关课件。
        case choosing([DeckOption])
        /// 第 2、3 步进行中。
        case running(step: Int, message: String, done: Int, total: Int)
        case failed(String)
    }

    struct DeckOption: Equatable {
        var candidate: LectureOrganizer.Candidate
        var suggested: Bool
        var reason: String
    }

    enum OrganizeFailure: LocalizedError {
        case noTranscript
        case notConfigured
        case unreadable(truncated: Bool)

        var errorDescription: String? {
            switch self {
            case .noTranscript:
                tr("该录音尚无转写内容，无法整理。", "This recording has no transcript to organize.")
            case .notConfigured:
                tr("尚未设置 API Key，请在「设置 → 模型」中填写。", "No API key. Add one in Settings → Model.")
            case .unreadable(let truncated):
                truncated
                    ? tr("模型输出过长被截断，无法解析结果。请换用输出上限更大的模型。", "The model's output was truncated and could not be parsed. Use a model with a larger output limit.")
                    : tr("无法解析模型返回的结果，请重试或更换模型。", "Could not parse the model's response. Try again or use another model.")
            }
        }
    }

    // MARK: - 第 1 步

    func organize(_ id: String) {
        guard organizeTasks[id] == nil, let recording = store.load(id) else { return }
        organizing[id] = .finding
        RecordingsWindow.shared.recordingsDidChange()
        organizeTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.organizeTasks[id] = nil }
            do {
                let (options, course) = try await self.findDecks(recording)
                guard !Task.isCancelled else { return }
                if let course {
                    _ = try? self.store.update(id) { $0.tags = [course] + $0.tags.filter { $0.caseInsensitiveCompare(course) != .orderedSame } }
                }
                self.organizing[id] = .choosing(options)
            } catch {
                self.organizeFailed(id, error)
            }
            RecordingsWindow.shared.recordingsDidChange()
        }
    }

    /// 第 1 步：相关课件（让用户确认）和课程编号。
    private func findDecks(_ recording: Recording) async throws -> ([DeckOption], String?) {
        let lines = LectureOrganizer.timed(store.transcript(recording.id), in: recording)
        guard !lines.isEmpty else { throw OrganizeFailure.noTranscript }
        let folder = (recording.coursePath ?? recording.deckPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
            .map { URL(fileURLWithPath: $0) }
        let recorded = recording.deckPath
        let candidates = await Task.detached(priority: .userInitiated) {
            folder.map { LectureOrganizer.candidates(course: $0, recordedDeck: recorded) } ?? []
        }.value
        var options = candidates.map { DeckOption(candidate: $0, suggested: false, reason: "") }
        let readable = candidates.filter(\.readable)
        let guessed = Recording.courseCode(in: [recording.coursePath, recording.deckPath])
        // 只有一份能读的课件、路径里也认得出课程编号时，不用问模型
        guard readable.count > 1 || guessed == nil else {
            if let only = readable.first, let i = options.firstIndex(where: { $0.candidate.path == only.path }) {
                options[i].suggested = true
            }
            return (options, guessed)
        }
        guard completion != nil || settings.canRequest(.lectureDecks) else { throw OrganizeFailure.notConfigured }
        let messages = LectureOrganizer.deckMessages(recording: recording, excerpt: LectureOrganizer.excerpt(lines),
                                                     candidates: candidates, english: Localizer.shared.isEnglish)
        let output = try await complete(.lectureDecks, messages, limit: 2_048, cacheKey: nil, deck: statsDeck(recording, decks: []))
        guard let choices = LectureOrganizer.parseDecks(output.text, candidates: candidates) else {
            throw OrganizeFailure.unreadable(truncated: output.truncated)
        }
        let course = LectureOrganizer.parseCourse(output.text) ?? guessed
        for choice in choices {
            if let i = options.firstIndex(where: { $0.candidate.path == choice.path }) {
                options[i].suggested = true
                options[i].reason = choice.reason
            }
        }
        // 模型建议的排在前面
        return (options.filter(\.suggested) + options.filter { !$0.suggested }, course)
    }

    // MARK: - 第 2、3 步

    func confirmOrganize(_ id: String, decks paths: [String]) {
        guard organizeTasks[id] == nil, let recording = store.load(id) else { return }
        organizing[id] = .running(step: 2, message: tr("正在读取课件…", "Reading the decks…"), done: 0, total: 0)
        RecordingsWindow.shared.recordingsDidChange()
        organizeTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.organizeTasks[id] = nil }
            do {
                try await self.runOrganize(recording, paths: paths)
                self.organizing[id] = nil
                self.onOrganized?()
            } catch is CancellationError {
                self.organizing[id] = nil
            } catch {
                self.organizeFailed(id, error)
            }
            RecordingsWindow.shared.recordingsDidChange()
        }
    }

    func cancelOrganize(_ id: String) {
        organizeTasks[id]?.cancel()
        organizeTasks[id] = nil
        organizing[id] = nil
        RecordingsWindow.shared.recordingsDidChange()
    }

    private func runOrganize(_ recording: Recording, paths: [String]) async throws {
        let id = recording.id
        let lines = LectureOrganizer.timed(store.transcript(id), in: recording)
        guard !lines.isEmpty else { throw OrganizeFailure.noTranscript }
        guard completion != nil || (settings.canRequest(.lectureTranscript) && settings.canRequest(.lectureSupplements)) else {
            throw OrganizeFailure.notConfigured
        }
        let english = Localizer.shared.isEnglish

        var decks: [LectureOrganizer.Deck] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let pages = await Self.fullText(url) {
                decks.append(.init(path: path, title: url.deletingPathExtension().lastPathComponent, pages: pages))
            }
            try Task.checkCancellation()
        }
        let statsDeck = statsDeck(recording, decks: paths)

        // 课件太长时缩短每页的字数，给转写留出地方（两步用同样的前缀，同一个模型时可以共用缓存）
        let config = settings.connection(for: .lectureSupplements)
        let maxOutput = settings.outputCap(config.providerID, config.model, limit: 8_192)
        let deckBudget = budget(config, maxOutput: maxOutput) - 4_000
        var pageLimit = 1_200
        while TokenEstimate.of(LectureOrganizer.coursewarePrefix(decks, pageLimit: pageLimit, english: english)) > deckBudget, pageLimit > 150 {
            pageLimit = pageLimit * 7 / 10
        }
        let parts = LectureOrganizer.chunks(lines)

        // 第 2 步：纠正转写。只是锦上添花：某一段读不出结果时跳过这一段
        var corrected = lines
        var fixed: [LectureOrganizer.Corrections.Line] = []
        let correction = LectureOrganizer.correctionSystem(decks: decks, pageLimit: pageLimit, english: english)
        var offset = 0
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            organizing[id] = .running(step: 2, message: parts.count > 1
                                      ? tr("纠正转写（第 \(index + 1)/\(parts.count) 段）", "Correcting the transcript (part \(index + 1) of \(parts.count))")
                                      : tr("纠正转写…", "Correcting the transcript…"),
                                      done: index, total: parts.count)
            RecordingsWindow.shared.recordingsDidChange()
            let numbered = part.enumerated().map { (id: offset + $0.offset + 1, line: $0.element) }
            offset += part.count
            let messages = LectureOrganizer.correctionMessages(system: correction, part: numbered, index: index + 1,
                                                               total: parts.count, english: english)
            let output = try await complete(.lectureTranscript, messages, limit: 8_192, cacheKey: "lecture-\(id)", deck: statsDeck)
            for (lineID, text) in LectureOrganizer.parseCorrections(output.text, part: numbered) ?? [:] {
                let line = corrected[lineID - 1]
                corrected[lineID - 1].text = text
                fixed.append(.init(segment: line.segment, start: line.start, text: text))
            }
        }
        fixed.sort { ($0.segment, $0.start) < ($1.segment, $1.start) }
        try store.saveCorrections(.init(lines: fixed, createdAt: Date()), for: id)
        RecordingsWindow.shared.recordingsDidChange()

        // 第 3 步：对照课件找补充要点和课程安排（没有课件时只找课程安排），用纠正过的转写
        let system = LectureOrganizer.supplementSystem(decks: decks, pageLimit: pageLimit, english: english)
        let correctedParts = LectureOrganizer.chunks(corrected)
        var items: [LectureOrganizer.Supplement] = []
        for (index, part) in correctedParts.enumerated() {
            try Task.checkCancellation()
            let what = decks.isEmpty ? tr("整理课程安排", "Extracting course arrangements") : tr("对照课件整理要点", "Comparing with the slides")
            organizing[id] = .running(step: 3, message: correctedParts.count > 1
                                      ? tr("\(what)（第 \(index + 1)/\(correctedParts.count) 段）", "\(what) (part \(index + 1) of \(correctedParts.count))")
                                      : what + "…",
                                      done: index, total: correctedParts.count)
            RecordingsWindow.shared.recordingsDidChange()
            let messages = LectureOrganizer.supplementMessages(system: system, part: part, index: index + 1, total: correctedParts.count,
                                                               english: english)
            let output = try await complete(.lectureSupplements, messages, limit: 8_192, cacheKey: "lecture-\(id)", deck: statsDeck)
            guard let found = LectureOrganizer.parseSupplements(output.text, decks: decks, part: part) else {
                throw OrganizeFailure.unreadable(truncated: output.truncated)
            }
            items += found
        }
        items.sort { $0.time < $1.time }
        try Task.checkCancellation()
        try store.saveOrganized(.init(decks: decks.map(\.path), supplements: items, createdAt: Date()), for: id)
    }

    // MARK: - 工具

    /// 用这个任务的模型调用一次（测试时用 `completion` 代替）。
    private func complete(_ task: ModelTask, _ messages: [[String: Any]], limit: Int, cacheKey: String?,
                          deck: String) async throws -> LLMTask.Output {
        if let completion { return try await completion(task, messages) }
        let config = settings.connection(for: task)
        let quirks = settings.quirks(config.providerID, config.model)
        let llm = try LLMTask(config: config, messages: messages, quirks: quirks,
                              maxOutput: settings.outputCap(config.providerID, config.model, limit: limit), cacheKey: cacheKey)
        return try await llm.run(stats: stats, deck: deck, task: task)
    }

    private func organizeFailed(_ id: String, _ error: Error) {
        if error is CancellationError {
            organizing[id] = nil
        } else {
            organizing[id] = .failed(error.localizedDescription)
        }
    }

    /// 这个模型一次请求能放多少 token 的输入（和路线图同样的算法）。
    private func budget(_ config: ConnectionConfig, maxOutput: Int) -> Int {
        let quirks = settings.quirks(config.providerID, config.model)
        let window = Double(settings.contextWindow(config.providerID, config.model)) / (quirks.tokenScale ?? 1)
        return max(8_000, Int(window * settings.contextBudgetPercent) - min(maxOutput, Int(window) / 4) - 1_500)
    }

    /// 统计里归到哪份课件。
    private func statsDeck(_ recording: Recording, decks: [String]) -> String {
        recording.deckPath ?? decks.first ?? recording.coursePath ?? store.folder(recording.id).path
    }

    /// 课件全文：有提取缓存就用缓存；大部分页有文字层时直接读；扫描件才做 OCR（比较慢，结果会缓存）。
    private static func fullText(_ deck: URL) async -> [String]? {
        guard let pdf = LectureOrganizer.pdfURL(for: deck) else { return nil }
        if let cached = TextExtractor.cached(for: pdf) { return cached.pages }
        if let quick = LectureOrganizer.quickText(deck), !quick.isEmpty,
           quick.filter({ $0.filter { !$0.isWhitespace }.count >= 20 }).count * 2 >= quick.count {
            return quick
        }
        let box = TextBox()
        await TextExtractor.extract(pdfURL: pdf, priorityPage: 1) { text, _, _ in await box.set(text) }
        return await box.text?.pages
    }
}

private actor TextBox {
    var text: DocumentText?
    func set(_ text: DocumentText) { self.text = text }
}
