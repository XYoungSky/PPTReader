import AVFoundation
import Foundation
import Observation

/// 把录音 buffer 分段写成 AAC 单声道 m4a。每个 buffer 只写进一个文件，所以分段之间不丢、不重叠；
/// 当前分段够长时，写完这个 buffer 就关掉文件，下一个 buffer 开新文件。
/// 只在一个线程上用（录音 tap 的回调线程），回调里把事件交给调用方。
final class SegmentWriter: @unchecked Sendable {
    struct Event: Sendable {
        enum Kind: Sendable { case opened, closed(duration: Double) }
        let index: Int
        let kind: Kind
        let at: Date
    }

    let bitRate: Int
    let segmentSeconds: Double
    private let url: @Sendable (Int) -> URL
    private let onEvent: @Sendable (Event) -> Void
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private(set) var index: Int
    private var framesInSegment: AVAudioFramePosition = 0

    /// - Parameters:
    ///   - firstIndex: 第一个分段的序号（暂停后继续、换输入设备时接着往下编）。
    ///   - url: 分段序号 → 文件位置。
    init(bitRate: Int, segmentSeconds: Double, firstIndex: Int,
         url: @escaping @Sendable (Int) -> URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.bitRate = bitRate
        self.segmentSeconds = segmentSeconds
        self.index = firstIndex - 1
        self.url = url
        self.onEvent = onEvent
    }

    /// 写入一个 buffer（任意声道数，转成单声道）。
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        let mono = try monoBuffer(buffer)
        if file == nil { try open(sampleRate: mono.format.sampleRate) }
        try file?.write(from: mono)
        framesInSegment += AVAudioFramePosition(mono.frameLength)
        if Double(framesInSegment) >= segmentSeconds * mono.format.sampleRate { close() }
    }

    /// 关掉正在写的分段（暂停、停止、换设备时）。
    func close() {
        guard let file else { return }
        let duration = Double(framesInSegment) / file.processingFormat.sampleRate
        Self.close(file)
        self.file = nil
        framesInSegment = 0
        onEvent(Event(index: index, kind: .closed(duration: duration), at: Date()))
    }

    private func open(sampleRate: Double) throws {
        index += 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        file = try AVAudioFile(forWriting: url(index), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        framesInSegment = 0
        onEvent(Event(index: index, kind: .opened, at: Date()))
    }

    private func monoBuffer(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let format = buffer.format
        if format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved { return buffer }
        if converter?.inputFormat != format {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: mono) else { throw RecorderError.unsupportedFormat }
            converter.downmix = true
            self.converter = converter
            monoFormat = mono
        }
        guard let converter, let monoFormat,
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { throw RecorderError.unsupportedFormat }
        try converter.convert(to: out, from: buffer)
        return out
    }

    /// 关闭文件后马上可读。macOS 15 以前没有 `close()`，释放对象时关闭。
    private static func close(_ file: AVAudioFile) {
        if #available(macOS 15, *) { file.close() }
    }
}

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInput
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            tr("没有麦克风权限。请在「系统设置 → 隐私与安全性 → 麦克风」中允许 PPTReader。",
               "PPTReader can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
        case .noInput:
            tr("未找到可用的音频输入设备。", "No audio input device was found.")
        case .unsupportedFormat:
            tr("该输入设备的音频格式不受支持。", "The input device's audio format is not supported.")
        }
    }
}

/// 录音时长上限：到点前 5 分钟提醒，到点自动停止。
struct RecordingLimit: Equatable, Sendable {
    var seconds: Double
    static let warningLead: Double = 5 * 60
    static let standard = RecordingLimit(seconds: 3 * 3600)

    enum Status: Equatable { case normal, warning(remaining: Double), reached }

    func status(at elapsed: Double) -> Status {
        if elapsed >= seconds { return .reached }
        if elapsed >= seconds - Self.warningLead { return .warning(remaining: seconds - elapsed) }
        return .normal
    }
}

/// 课堂录音：AVAudioEngine 从输入设备取 buffer，分段写入，同时更新清单。
/// 暂停时关掉当前分段，继续时开新的一段；换输入设备时也一样，所以这些时候退出都不会丢已经录下的部分。
@MainActor
@Observable
final class LectureRecorder {
    enum State: Equatable { case idle, recording, paused }

    static let segmentSeconds: Double = 5 * 60

    private(set) var state: State = .idle
    private(set) var recording: Recording?
    /// 录音时间（不含暂停），秒。
    private(set) var elapsed: Double = 0
    /// 输入电平，0…1。
    private(set) var level: Float = 0
    private(set) var limitStatus: RecordingLimit.Status = .normal
    /// 录音中出的错（换设备失败、写文件失败）。录音会先停下，已经录的部分保留。
    private(set) var lastError: String?

    /// 每个 buffer 也交给这里（实时转写用），在录音线程上调用。开始录音前设置。
    @ObservationIgnored nonisolated(unsafe) var onBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// 分段关闭后调用（补转写、更新列表用）。
    @ObservationIgnored var onSegmentClosed: ((Recording, Int) -> Void)?
    /// 录音结束后调用，包括到了时长上限、出错自动停下的情况。
    @ObservationIgnored var onStop: ((Recording?) -> Void)?

    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var writer: SegmentWriter?
    @ObservationIgnored private var counter: FrameCounter?
    @ObservationIgnored private var limit = RecordingLimit.standard
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    /// 之前几次开引擎（暂停前、换设备前）录下的时长。
    @ObservationIgnored private var baseElapsed: Double = 0

    init(store: RecordingStore = .shared) {
        self.store = store
    }

    // MARK: - 控制

    func start(title: String, coursePath: String?, deckPath: String?, locale: String = "en_US",
               bitRate: Int = 32_000, limit: RecordingLimit = .standard) async throws {
        guard state == .idle else { return }
        try await Self.requestMicrophone()
        recording = try store.create(title: title, coursePath: coursePath, deckPath: deckPath, locale: locale, bitRate: bitRate)
        self.limit = limit
        baseElapsed = 0
        elapsed = 0
        lastError = nil
        limitStatus = .normal
        do {
            try startEngine()
        } catch {
            finish()
            throw error
        }
        state = .recording
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Recording a lecture")
    }

    func pause() {
        guard state == .recording else { return }
        stopEngine()
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused else { return }
        do {
            try startEngine()
            state = .recording
        } catch {
            fail(error)
        }
    }

    func stop() {
        guard state != .idle else { return }
        stopEngine()
        finish()
    }

    // MARK: - 引擎

    private func startEngine() throws {
        guard let recording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        let store = self.store
        let writer = SegmentWriter(bitRate: recording.bitRate, segmentSeconds: Self.segmentSeconds,
                                   firstIndex: recording.nextSegmentIndex,
                                   url: { store.segmentURL(recording, $0) },
                                   onEvent: { [weak self] event in Self.onMain { self?.handle(event) } })
        let counter = FrameCounter(sampleRate: format.sampleRate)
        let meter = LevelMeter()
        let onBuffer = self.onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            do {
                try writer.write(buffer)
            } catch {
                Self.onMain { self?.fail(error) }
                return
            }
            let seconds = counter.add(buffer.frameLength)
            onBuffer?(buffer, time)
            if let level = meter.update(buffer) {
                Self.onMain { self?.tick(level: level, seconds: seconds) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.writer = writer
        self.counter = counter
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        writer?.close()
        writer = nil
        if let counter { baseElapsed += counter.seconds }
        counter = nil
        elapsed = baseElapsed
    }

    /// 拔插耳机、换了输入设备：关掉当前分段，用新设备的格式重新开始。
    private func inputChanged() {
        guard state == .recording else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            fail(error)
        }
    }

    // MARK: - 状态

    private func tick(level: Float, seconds: Double) {
        guard state == .recording else { return }
        self.level = level
        elapsed = baseElapsed + seconds
        let status = limit.status(at: elapsed)
        if status != limitStatus { limitStatus = status }
        if status == .reached { stop() }
    }

    /// 分段打开 / 关闭时更新清单。两个事件可能乱序到达（停止时“关闭”在主线程同步处理，
    /// 录音线程上刚发出的“打开”还在排队），所以两边都不假设对方已经处理过。
    private func handle(_ event: SegmentWriter.Event) {
        guard let id = recording?.id else { return }
        let updated = try? store.update(id) { recording in
            let existing = recording.segments.firstIndex { $0.index == event.index }
            switch event.kind {
            case .opened:
                guard existing == nil else { return }
                recording.segments.append(Recording.Segment(index: event.index, startedAt: event.at, duration: 0,
                                                            state: .recording, transcribed: false))
            case .closed(let duration):
                let state: Recording.Segment.State = duration > 0 ? .complete : .damaged
                if let existing {
                    recording.segments[existing].duration = duration
                    recording.segments[existing].state = state
                } else {
                    recording.segments.append(Recording.Segment(index: event.index, startedAt: event.at.addingTimeInterval(-duration),
                                                                duration: duration, state: state, transcribed: false))
                    recording.segments.sort { $0.index < $1.index }
                }
            }
        }
        guard let updated else { return }
        recording = updated
        if case .closed = event.kind { onSegmentClosed?(updated, event.index) }
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        stop()
    }

    private func finish() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        state = .idle
        level = 0
        onStop?(recording)
    }

    /// 在主线程上按顺序执行：已经在主线程就马上执行，否则排进主队列（先进先出）。
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    // MARK: - 权限

    static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecorderError.microphoneDenied
        default:
            throw RecorderError.microphoneDenied
        }
    }
}

/// 这次开引擎以来录了多少帧。录音线程写，主线程读。
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: Int64 = 0
    let sampleRate: Double

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func add(_ count: AVAudioFrameCount) -> Double {
        lock.lock()
        defer { lock.unlock() }
        frames += Int64(count)
        return Double(frames) / sampleRate
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(frames) / sampleRate
    }
}

/// 每 0.1 秒算一次输入电平（RMS，换成 0…1）。
private final class LevelMeter: @unchecked Sendable {
    private var frames: AVAudioFrameCount = 0
    private var sum: Float = 0
    private var count: Int = 0

    func update(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channel = data[0]
        for i in 0..<n { sum += channel[i] * channel[i] }
        count += n
        frames += buffer.frameLength
        guard Double(frames) >= buffer.format.sampleRate / 10 else { return nil }
        let rms = sqrt(sum / Float(max(count, 1)))
        frames = 0
        sum = 0
        count = 0
        // -60 dB … 0 dB → 0 … 1
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 60) / 60))
    }
}
