import AVFoundation
import Foundation

/// 回放一次录音：把能回放的分段按顺序拼成一个 composition，交给 AVPlayer。
/// 进度条上的时间就是“录音时间”（不含暂停、跳过损坏的分段），和转写里的时间一致。
@MainActor
final class RecordingPlayer {
    struct State: Equatable {
        var time: Double = 0
        var playing = false
        var rate: Float = 1
    }

    private(set) var state = State()
    private(set) var recordingID: String?
    private(set) var composition: AVMutableComposition?
    var onChange: ((State) -> Void)?

    private let player = AVPlayer()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var loading: Task<Void, Never>?
    private var loadedSegments: [Int] = []

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    /// 换一条录音（或者同一条有了新的分段）。录音中的那条不加载。
    func load(_ recording: Recording?, store: RecordingStore) {
        let segments = recording?.playable.map(\.index) ?? []
        // 同一条录音、分段没变（比如只是又转写完一段）：不打断正在播放的
        if recording?.id == recordingID, segments == loadedSegments, recording != nil { return }
        loadedSegments = segments
        loading?.cancel()
        let changed = recording?.id != recordingID
        if changed {
            player.pause()
            player.replaceCurrentItem(with: nil)
            composition = nil
            state = State(rate: state.rate)
            onChange?(state)
        }
        recordingID = recording?.id
        guard let recording else { return }
        let urls = recording.playable.map { store.segmentURL(recording, $0.index) }
        let resume = changed ? 0 : state.time
        loading = Task { [weak self] in
            guard let built = try? await Self.compose(urls), !Task.isCancelled, let self else { return }
            self.composition = built
            if let endObserver = self.endObserver { NotificationCenter.default.removeObserver(endObserver) }
            let item = AVPlayerItem(asset: built)
            self.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                      object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            }
            self.player.replaceCurrentItem(with: item)
            if resume > 0 { await self.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration {
            player.seek(to: .zero)
        }
        player.defaultRate = state.rate
        player.play()
        state.playing = true
        onChange?(state)
    }

    func pause() {
        player.pause()
        state.playing = false
        onChange?(state)
    }

    func seek(to seconds: Double, thenPlay: Bool) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        state.time = max(0, seconds)
        if thenPlay { play() } else { onChange?(state) }
    }

    func setRate(_ rate: Float) {
        state.rate = rate
        player.defaultRate = rate
        if state.playing { player.rate = rate }
        onChange?(state)
    }

    func stop() {
        loading?.cancel()
        loadedSegments = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        composition = nil
        recordingID = nil
        state = State(rate: state.rate)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        state.time = seconds
        state.playing = player.rate != 0
        onChange?(state)
    }

    private func ended() {
        state.playing = false
        onChange?(state)
    }

    /// 按顺序拼接各分段。
    nonisolated static func compose(_ urls: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return composition
        }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        return composition
    }

    /// 导出成一个 m4a。
    nonisolated static func export(_ composition: AVComposition, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if #available(macOS 15, *) {
            try await session.export(to: url, as: .m4a)
        } else {
            session.outputURL = url
            session.outputFileType = .m4a
            await session.export()
            if let error = session.error { throw error }
        }
    }
}
