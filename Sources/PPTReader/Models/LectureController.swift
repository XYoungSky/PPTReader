import AVFoundation
import Foundation
import Observation

/// 课堂录音的总调度：开始 / 暂停 / 停止，录完的分段交给转写队列，同时跑实时字幕。
/// 录音功能只在 macOS 26+ 提供（系统的离线转写从 26 开始才有），低版本不显示入口。
@MainActor
@Observable
final class LectureController {
    nonisolated static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// 可选的转写语言（系统离线识别本机已有或可下载的）。英文授课按口音选。
    static var locales: [(id: String, title: String)] { [
        ("en_US", tr("美式英语", "US English")),
        ("en_GB", tr("英式英语", "UK English")),
        ("en_AU", tr("澳式英语", "Australian English")),
        ("en_CA", tr("加拿大英语", "Canadian English")),
        ("en_IN", tr("印度英语", "Indian English")),
        ("en_IE", tr("爱尔兰英语", "Irish English")),
        ("en_NZ", tr("新西兰英语", "New Zealand English")),
        ("en_SG", tr("新加坡英语", "Singapore English")),
        ("en_ZA", tr("南非英语", "South African English")),
        ("zh_CN", tr("普通话", "Mandarin Chinese")),
    ] }

    static func localeTitle(_ id: String) -> String {
        locales.first { $0.id == id }?.title ?? id
    }

    /// 开始录音时需要的课件信息。
    struct Context {
        var title: String
        var coursePath: String?
        var deckPath: String?
        /// 课件文字，用来挑词表。
        var pages: [String]
    }

    /// 停止后显示几秒的提示。
    struct Saved: Equatable {
        var id: String
        var duration: Double
    }

    let recorder: LectureRecorder
    let transcription: TranscriptionQueue
    private(set) var captionFinal = ""
    private(set) var captionVolatile = ""
    /// 录音条上方显示实时字幕。
    var showsCaptions: Bool { didSet { UserDefaults.standard.set(showsCaptions, forKey: Self.captionsKey) } }
    private(set) var saved: Saved?
    /// 开始录音失败、录音中出错停下、导入失败的原因。
    var problem: String?

    /// 正在整理的录音（「AI 整理」）。
    var organizing: [String: OrganizeState] = [:]
    /// 正在导入的录音和进度（0…1）。
    var importing: [String: Double] = [:]

    @ObservationIgnored var context: () -> Context? = { nil }
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let stats: StatsStore
    @ObservationIgnored let store: RecordingStore
    @ObservationIgnored var organizeTasks: [String: Task<Void, Never>] = [:]
    /// 整理完一次录音后调用（刷新课件上的批注）。
    @ObservationIgnored var onOrganized: (() -> Void)?
    /// 替换掉真正的模型调用（测试用）。
    @ObservationIgnored var completion: ((ModelTask, [[String: Any]]) async throws -> LLMTask.Output)?
    @ObservationIgnored private var captioner: AnyObject?
    @ObservationIgnored private var hideSaved: Task<Void, Never>?
    @ObservationIgnored private static let captionsKey = "recording.showsCaptions"

    var isRecording: Bool { recorder.state != .idle }

    init(settings: AppSettings, stats: StatsStore, store: RecordingStore = .shared) {
        self.settings = settings
        self.stats = stats
        self.store = store
        recorder = LectureRecorder(store: store)
        transcription = TranscriptionQueue(store: store)
        showsCaptions = UserDefaults.standard.object(forKey: Self.captionsKey) as? Bool ?? true

        recorder.onSegmentClosed = { [weak self] recording, index in
            self?.transcription.enqueue(recording.id, segment: index)
            RecordingsWindow.shared.recordingsDidChange()
        }
        recorder.onStop = { [weak self] recording in self?.recordingStopped(recording) }
        transcription.onJobFinished = { _ in RecordingsWindow.shared.recordingsDidChange() }

        if #available(macOS 26, *) {
            let captioner = LiveCaptioner()
            captioner.onChange = { [weak self, weak captioner] in
                guard let self, let captioner else { return }
                self.captionFinal = captioner.final
                self.captionVolatile = captioner.volatile
                RecordingsWindow.shared.captionsDidChange()
            }
            let sink = captioner.sink
            recorder.onBuffer = { buffer, _ in sink(buffer) }
            self.captioner = captioner
            // 上次中途退出的录音：修复清单，把没转写的分段补上
            transcription.engine = settings.transcriptionEngine
            transcription.repairAll()
        }
    }

    // MARK: - 控制

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard Self.isSupported, !isRecording else { return }
        let context = context() ?? Context(title: Self.defaultTitle(), coursePath: nil, deckPath: nil, pages: [])
        let locale = settings.recordingLocale
        let bitRate = settings.recordingBitRate
        let limit = RecordingLimit(seconds: Double(settings.recordingLimitHours) * 3600)
        transcription.engine = settings.transcriptionEngine
        problem = nil
        dismissSaved()
        Task {
            do {
                try await recorder.start(title: context.title, coursePath: context.coursePath, deckPath: context.deckPath,
                                         locale: locale, bitRate: bitRate, limit: limit)
            } catch {
                problem = tr("无法开始录音：", "Couldn't start recording: ") + error.localizedDescription
                return
            }
            if let id = recorder.recording?.id {
                transcription.terms[id] = TranscriptText.terms(in: context.pages)
                // 路径里认得出课程编号时先作为标签，整理时再由模型确认
                if let code = Recording.courseCode(in: [context.coursePath, context.deckPath]) {
                    _ = try? store.update(id) { $0.tags = [code] }
                }
            }
            RecordingsWindow.shared.recordingsDidChange()
            await startCaptions(locale: locale, reset: true)
        }
    }

    func pause() {
        recorder.pause()
        Task { await stopCaptions() }
        RecordingsWindow.shared.recordingsDidChange()
    }

    func resume() {
        recorder.resume()
        guard recorder.state == .recording else { return }
        Task { await startCaptions(locale: recorder.recording?.locale ?? settings.recordingLocale, reset: false) }
        RecordingsWindow.shared.recordingsDidChange()
    }

    func stop() {
        recorder.stop()
    }

    func dismissProblem() { problem = nil }

    func dismissSaved() {
        hideSaved?.cancel()
        saved = nil
    }

    // MARK: - 内部

    private func recordingStopped(_ recording: Recording?) {
        Task { await stopCaptions() }
        if let error = recorder.lastError { problem = tr("录音已停止：", "Recording stopped: ") + error }
        guard let recording = recording.flatMap({ store.load($0.id) }) else { return }
        // 一段都没录下来（比如刚开始就出错）：不留空的录音
        if recording.segments.allSatisfy({ $0.state != .complete }) {
            try? store.delete(recording.id)
        } else {
            saved = Saved(id: recording.id, duration: recording.duration)
            hideSaved?.cancel()
            hideSaved = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.saved = nil
            }
        }
        RecordingsWindow.shared.recordingsDidChange()
    }

    private func startCaptions(locale: String, reset: Bool) async {
        guard #available(macOS 26, *), let captioner = captioner as? LiveCaptioner else { return }
        if reset { captioner.reset() }
        // 字幕只是辅助：起不来（比如识别模型还在下载）也不影响录音
        try? await captioner.start(locale: Locale(identifier: locale))
    }

    private func stopCaptions() async {
        guard #available(macOS 26, *), let captioner = captioner as? LiveCaptioner else { return }
        await captioner.stop()
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return tr("课堂录音 ", "Lecture ") + formatter.string(from: Date())
    }
}
