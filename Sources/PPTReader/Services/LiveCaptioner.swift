import AVFoundation
import Foundation
import Speech

/// 实时字幕：把录音的 buffer 同时送进一个 SpeechAnalyzer，只用来显示，不保存
/// （存下来的转写是每段录完后从文件转写的，见 `TranscriptionQueue`）。
@available(macOS 26, *)
@MainActor
final class LiveCaptioner {
    /// 最近几句定稿的文字 + 正在识别、还会变的文字。
    private(set) var final = ""
    private(set) var volatile = ""
    var onChange: (() -> Void)?

    private let feeder = CaptionFeeder()
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var finals: [String] = []
    /// 保留最近这么多字，字幕卡片最多显示三行。
    private static let keep = 320

    /// 在录音线程上调用。
    nonisolated var sink: @Sendable (AVAudioPCMBuffer) -> Void {
        let feeder = self.feeder
        return { feeder.feed($0) }
    }

    func start(locale: Locale) async throws {
        await stop()
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        try await SpeechFileTranscriber.prepare(locale: locale, engine: .speech)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        feeder.begin(format: format, continuation: continuation)
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.receive(text, isFinal: result.isFinal)
                }
            } catch {}
        }
    }

    func stop() async {
        feeder.end()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        analyzer = nil
        results?.cancel()
        results = nil
        volatile = ""
        onChange?()
    }

    /// 新的一次录音开始时清空。
    func reset() {
        finals = []
        final = ""
        volatile = ""
        onChange?()
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            if !text.isEmpty { finals.append(text) }
            var joined = finals.joined(separator: " ")
            while joined.count > Self.keep, finals.count > 1 {
                finals.removeFirst()
                joined = finals.joined(separator: " ")
            }
            final = joined
            volatile = ""
        } else {
            volatile = text
        }
        onChange?()
    }
}

/// 在录音线程上把 buffer 转成识别器要的格式（通常是 16 kHz 单声道 Int16），交给 AsyncStream。
@available(macOS 26, *)
private final class CaptionFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func begin(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        self.format = format
        self.converter = nil
        self.continuation = continuation
        lock.unlock()
    }

    func end() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let format, let continuation, buffer.frameLength > 0 else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }
}
