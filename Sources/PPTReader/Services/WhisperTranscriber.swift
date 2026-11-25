import Foundation
import Observation
import WhisperKit

/// 本机 Whisper：OpenAI 的开源语音识别模型，用 WhisperKit 在 Core ML（神经网络引擎）上运行。
/// 口音重、离得远、有杂音时比系统识别准得多，代价是要先下载约 650 MB 的模型、转写慢一些。录音不上传。
/// 模型放在 Application Support（不放在“文稿”，那里可能同步到 iCloud）。
@MainActor
@Observable
final class WhisperModel {
    static let shared = WhisperModel()

    /// large-v3 turbo（2024-09）的压缩版：准确率接近完整版，体积不到一半。
    nonisolated static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    nonisolated static let approximateBytes: Int64 = 646_000_000

    enum State: Equatable {
        case missing
        case downloading(Double)
        /// 下载完，第一次加载（取分词器、为这台 Mac 编译模型）。
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        state = Self.isDownloaded ? .ready : .missing
    }

    nonisolated static var base: URL { AppPaths.support.appendingPathComponent("Whisper", isDirectory: true) }

    /// 下载后的模型文件夹（Hugging Face 的目录结构）。
    nonisolated static var folder: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// 模型和分词器都在：可以离线转写。
    nonisolated static var isDownloaded: Bool {
        let files = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        return files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            && FileManager.default.fileExists(atPath: tokenizerMarker.path)
    }

    /// 第一次加载成功后写下的标记：分词器已经下载好。
    nonisolated static var tokenizerMarker: URL { base.appendingPathComponent(".tokenizer-ready") }

    var isReady: Bool { state == .ready }

    /// 占用的空间（字节）。
    nonisolated static func size() -> Int64 {
        guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
                _ = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.base) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(fraction) }
                    }
                }
                self?.state = .preparing
                try await WhisperEngine.shared.prepare()
                FileManager.default.createFile(atPath: Self.tokenizerMarker.path, contents: Data())
                self?.state = .ready
            } catch is CancellationError {
                self?.state = Self.isDownloaded ? .ready : .missing
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        task?.cancel()
        Task {
            await WhisperEngine.shared.unload()
            try? FileManager.default.removeItem(at: Self.base)
            state = .missing
        }
    }
}

/// 加载好的模型。转写时加载，空闲一分钟后释放（加载后约占 1 GB 内存）。
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var kit: WhisperKit?
    private var idle: Task<Void, Never>?

    /// 第一次加载：下载分词器、为这台 Mac 编译模型。实测约三分钟，之后几秒。
    func prepare() async throws {
        _ = try await loaded()
        scheduleUnload()
    }

    func unload() async {
        idle?.cancel()
        await kit?.unloadModels()
        kit = nil
    }

    /// 转写一个音频文件。`language` 为空时自动识别语言。
    /// 不把课件术语作为提示：实测在听不清的地方，模型会把提示词原样写进转写，还更容易复读。
    func transcribe(_ url: URL, language: String?) async throws -> [TranscriptText.Line] {
        idle?.cancel()
        defer { scheduleUnload() }
        let kit = try await loaded()
        let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 3,
                                      usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: false,
                                      chunkingStrategy: .vad)
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        try Task.checkCancellation()
        return Self.lines(results.flatMap(\.segments).map {
            Segment(start: Double($0.start), end: Double($0.end), text: $0.text, noSpeech: Double($0.noSpeechProb),
                    logProb: Double($0.avgLogprob), compression: Double($0.compressionRatio))
        })
    }

    private func loaded() async throws -> WhisperKit {
        if let kit { return kit }
        guard FileManager.default.fileExists(atPath: WhisperModel.folder.path) else { throw TranscriptionFailure.whisperMissing }
        let config = WhisperKitConfig(modelFolder: WhisperModel.folder.path, tokenizerFolder: WhisperModel.base,
                                      verbose: false, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        self.kit = kit
        return kit
    }

    private func scheduleUnload() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self.unload()
        }
    }

    // MARK: - 纯函数（方便测试）

    /// Whisper 的一个句段，带上判断是否“幻觉”用的两个值。
    struct Segment {
        var start: Double
        var end: Double
        var text: String
        /// 这段没有人说话的概率。
        var noSpeech: Double = 0
        /// 平均对数概率，越低越没把握。
        var logProb: Double = 0
        /// 文字的压缩比，越高越像在复读。
        var compression: Double = 1
    }

    /// Whisper 的句段 → 转写的句子。去掉：
    /// - 空的、只有标点的、只有标记的（[BLANK_AUDIO]、(music)）和特殊记号；
    /// - 多半没人说话、模型又没把握的（Whisper 的常用判据：无语音概率 > 0.6 且平均对数概率 < -1），安静处常冒出的 “Thank you.” 就是这种；
    /// - 压缩比超过 2.4 的（Whisper 的判据：多半在复读，例如一个短句连说八遍）；
    /// - 和前一句一样、隔得很近的重复（“Okay. Okay. Okay.”）。
    /// 一句里同一个短句连续出现三遍以上时只留一遍。
    static func lines(_ segments: [Segment]) -> [TranscriptText.Line] {
        var result: [TranscriptText.Line] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = collapseRepeats(segment.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.rangeOfCharacter(from: .alphanumerics) != nil,
                  text.range(of: #"^[\[\(][^\]\)]*[\]\)]$"#, options: .regularExpression) == nil,
                  !(segment.noSpeech > 0.6 && segment.logProb < -1), segment.compression <= 2.4 else { continue }
            if let last = result.last, last.text.caseInsensitiveCompare(text) == .orderedSame, segment.start - last.end < 5 {
                result[result.count - 1].end = max(last.end, segment.end)
                continue
            }
            result.append(TranscriptText.Line(start: segment.start, end: max(segment.start, segment.end), text: text))
        }
        return result
    }

    /// 同一个短句（以标点结尾）连续出现三遍以上：只留一遍。
    static func collapseRepeats(_ text: String) -> String {
        text.replacingOccurrences(of: #"([^.!?,]{2,60}?[.!?,])(\s*\1){2,}"#, with: "$1", options: .regularExpression)
    }

    /// 录音的语言（en_US、zh_CN）→ Whisper 的语言代码（en、zh）。
    static func language(for locale: String) -> String? {
        Locale(identifier: locale).language.languageCode?.identifier
    }
}
