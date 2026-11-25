import AVFoundation
import Foundation
import Observation
import Speech

/// 用哪种系统识别器。两种都是本机离线识别（macOS 26+）：
/// - speech（SpeechTranscriber）：自动分句，速度快，但不用词表；
/// - dictation（DictationTranscriber，远场）：会参考课件里的术语，句子要自己按词的时间戳切。
/// 哪种更准要拿真实的课堂录音比较，先默认 speech。
enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case speech, dictation
}

/// 转写结果的整理：切句、从课件里挑术语。都是纯函数，方便测试。
enum TranscriptText {
    /// 一个带时间的词（或标点）。
    struct Token: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Line: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    /// 一句话最多这么多个词；老师一直不停顿时也要切开，方便点句子跳转。
    static let maxWords = 40

    /// 按句末标点切句；太长的句子在词数到上限时切开。
    static func sentences(_ tokens: [Token]) -> [Line] {
        var lines: [Line] = []
        var current: [Token] = []
        var words = 0
        func flush() {
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let first = current.first, let last = current.last {
                lines.append(Line(start: first.start, end: last.end, text: text))
            }
            current = []
            words = 0
        }
        for token in tokens {
            current.append(token)
            if token.text.contains(where: \.isLetter) { words += 1 }
            let trimmed = token.text.trimmingCharacters(in: .whitespaces)
            if trimmed.last.map({ ".?!。？！".contains($0) }) == true || words >= maxWords { flush() }
        }
        flush()
        return lines
    }

    /// 词表最多这么多条。
    static let termLimit = 100

    /// 从课件文字里挑出识别器可能认错的词：缩写（PCB、FCFS）、专有名词（课件里只以大写出现的词，如 Dijkstra），
    /// 以及反复出现的长词（semaphore）。按出现次数排序。
    static func terms(in pages: [String], limit: Int = termLimit) -> [String] {
        var capitalized: [String: Int] = [:]
        var lowercase: [String: Int] = [:]
        var acronyms: [String: Int] = [:]
        for page in pages {
            for word in page.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") }) {
                let word = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
                guard word.count >= 2, word.unicodeScalars.allSatisfy({ $0.isASCII }) else { continue }
                // 缩写：2–6 个大写字母或数字，至少两个大写字母，可以带复数 s（PCBs）
                let core = word.count > 2 && word.hasSuffix("s") ? word.dropLast() : Substring(word)
                if (2...6).contains(core.count), core.allSatisfy({ $0.isUppercase || $0.isNumber }),
                   core.filter(\.isUppercase).count >= 2 {
                    acronyms[String(core), default: 0] += 1
                } else if word.first!.isUppercase {
                    capitalized[word, default: 0] += 1
                } else {
                    lowercase[word, default: 0] += 1
                }
            }
        }
        var scored: [(String, Int)] = acronyms.map { ($0.key, $0.value + 1) }
        for (word, count) in capitalized where word.count >= 4 && lowercase[word.lowercased()] == nil
            && !stopwords.contains(word.lowercased()) && word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "-" }) {
            scored.append((word, count))
        }
        for (word, count) in lowercase where word.count >= 7 && count >= 3 {
            scored.append((word, count))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    /// 句首常见的大写词，不算专有名词。
    private static let stopwords: Set<String> = [
        "this", "that", "these", "those", "there", "then", "than", "when", "where", "what", "which", "while", "with",
        "from", "into", "each", "every", "some", "many", "most", "more", "much", "also", "only", "both", "either",
        "other", "such", "they", "their", "them", "your", "here", "have", "will", "would", "should", "could", "must",
        "does", "done", "make", "note", "example", "examples", "summary", "introduction", "overview", "definition",
        "chapter", "lecture", "section", "part", "figure", "table", "question", "questions", "answer", "solution",
        "step", "case", "first", "second", "third", "next", "last", "today", "however", "therefore", "thus", "because",
    ]
}

/// 从录好的分段文件转写。
enum TranscriptionFailure: LocalizedError {
    case unavailable
    case unsupportedLocale(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: tr("本机语音转写需要 macOS 26 或更新版本。", "On-device transcription requires macOS 26 or later.")
        case .unsupportedLocale(let id): tr("本机语音转写不支持 \(id)。", "On-device transcription doesn't support \(id).")
        }
    }
}

@available(macOS 26, *)
enum SpeechFileTranscriber {
    typealias Failure = TranscriptionFailure

    /// 需要时先下载识别模型（系统管理，不占应用体积）。
    static func prepare(locale: Locale, engine: TranscriptionEngine) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw Failure.unsupportedLocale(locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale: locale, engine: engine)]) {
            try await request.downloadAndInstall()
        }
    }

    static func transcribe(_ url: URL, locale: Locale, engine: TranscriptionEngine, terms: [String]) async throws -> [TranscriptText.Line] {
        try await prepare(locale: locale, engine: engine)
        let file = try AVAudioFile(forReading: url)
        switch engine {
        case .speech:
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collect = Task {
                var lines: [TranscriptText.Line] = []
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        lines.append(TranscriptText.Line(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
                    }
                }
                return lines
            }
            try await run(analyzer, file: file, collect: collect)
            return try await collect.value
        case .dictation:
            let transcriber = DictationTranscriber(locale: locale, contentHints: [.farField], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.frequentFinalization], attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !terms.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = terms
                try await analyzer.setContext(context)
            }
            let collect = Task {
                var tokens: [TranscriptText.Token] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        tokens.append(TranscriptText.Token(text: String(result.text[run.range].characters),
                                                           start: range.start.seconds, end: range.end.seconds))
                    }
                }
                return TranscriptText.sentences(tokens)
            }
            try await run(analyzer, file: file, collect: collect)
            return try await collect.value
        }
    }

    private static func module(locale: Locale, engine: TranscriptionEngine) -> any SpeechModule {
        switch engine {
        case .speech: SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictation: DictationTranscriber(locale: locale, preset: .longDictation)
        }
    }

    private static func run<T>(_ analyzer: SpeechAnalyzer, file: AVAudioFile, collect: Task<T, Error>) async throws {
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

/// 转写队列：分段录完就排队，一段一段地从文件转写，写进 `transcript.jsonl` 并在清单里标记。
/// 启动时把以前没转写完的分段也补上。
@MainActor
@Observable
final class TranscriptionQueue {
    struct Job: Hashable, Sendable {
        var recording: String
        var segment: Int
    }

    private(set) var pending: [Job] = []
    private(set) var current: Job?
    /// 最近一次失败的原因（显示在录音窗口里）。失败的分段留着“没转写”，下次启动再试。
    private(set) var lastError: String?

    var engine: TranscriptionEngine = .speech
    /// 录音 id → 词表（课件里的术语）。
    @ObservationIgnored var terms: [String: [String]] = [:]

    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// 换成别的转写方式（测试用）。
    @ObservationIgnored private let transcribe: @MainActor (URL, Locale, TranscriptionEngine, [String]) async throws -> [TranscriptText.Line]

    init(store: RecordingStore = .shared,
         transcribe: (@MainActor (URL, Locale, TranscriptionEngine, [String]) async throws -> [TranscriptText.Line])? = nil) {
        self.store = store
        self.transcribe = transcribe ?? { url, locale, engine, terms in
            guard #available(macOS 26, *) else { throw TranscriptionFailure.unavailable }
            return try await SpeechFileTranscriber.transcribe(url, locale: locale, engine: engine, terms: terms)
        }
    }

    var isIdle: Bool { current == nil && pending.isEmpty }

    func enqueue(_ recording: String, segment: Int) {
        let job = Job(recording: recording, segment: segment)
        guard job != current, !pending.contains(job) else { return }
        pending.append(job)
        startIfNeeded()
    }

    /// 修复所有录音（中途退出留下的分段），再把没转写完的分段排进队列。
    /// - Parameter probe: 读音频文件的时长，打不开返回 nil。
    func repairAll(probe: (URL) -> Double? = TranscriptionQueue.duration) {
        for recording in store.all() {
            var current = recording
            if let fixed = RecordingStore.repaired(recording, probe: probe, folder: store.folder(recording.id)) {
                try? store.save(fixed)
                current = fixed
            }
            for segment in RecordingStore.needsTranscription(current) { enqueue(current.id, segment: segment.index) }
        }
    }

    /// 等队列空了再返回（测试用）。
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    nonisolated static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let job = self.next() {
                await self.run(job)
            }
            self?.current = nil
            self?.worker = nil
        }
    }

    private func next() -> Job? {
        guard !pending.isEmpty else { return nil }
        current = pending.removeFirst()
        return current
    }

    private func run(_ job: Job) async {
        guard let recording = store.load(job.recording),
              let segment = recording.segments.first(where: { $0.index == job.segment }), segment.state == .complete else { return }
        do {
            let lines = try await transcribe(store.segmentURL(recording, job.segment), Locale(identifier: recording.locale),
                                             engine, terms[job.recording] ?? [])
            try store.removeTranscript(segment: job.segment, from: job.recording)
            try store.appendTranscript(lines.map { TranscriptLine(segment: job.segment, start: $0.start, end: $0.end, text: $0.text) },
                                       to: job.recording)
            try store.update(job.recording) { recording in
                if let i = recording.segments.firstIndex(where: { $0.index == job.segment }) { recording.segments[i].transcribed = true }
            }
            lastError = nil
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }
}
