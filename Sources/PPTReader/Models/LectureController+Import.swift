import Foundation

/// 导入音频：一个文件一条录音，归到当前打开的课程文件夹。写好一段就排队转写，和录音一样。
extension LectureController {
    /// 导入一个或几个文件，按顺序一个一个来。
    func importAudio(_ urls: [URL]) {
        guard Self.isSupported, !urls.isEmpty else { return }
        Task {
            for url in urls { await importAudio(url) }
        }
    }

    private func importAudio(_ url: URL) async {
        let context = context()
        let bitRate = settings.recordingBitRate
        let locale = settings.recordingLocale
        let store = self.store
        transcription.engine = settings.transcriptionEngine
        let title = url.deletingPathExtension().lastPathComponent

        let info: AudioImporter.Info
        let recording: Recording
        do {
            info = try await AudioImporter.info(of: url)
            recording = try store.create(title: title, coursePath: context?.coursePath, deckPath: nil,
                                         locale: locale, bitRate: bitRate, now: info.recordedAt)
        } catch {
            report(tr("无法导入“\(title)”：", "Couldn't import “\(title)”: ") + error.localizedDescription)
            return
        }
        let id = recording.id
        if let code = Recording.courseCode(in: [context?.coursePath]) { _ = try? store.update(id) { $0.tags = [code] } }
        if let pages = context?.pages, !pages.isEmpty { transcription.terms[id] = TranscriptText.terms(in: pages) }
        importing[id] = 0
        RecordingsWindow.shared.show(select: id)

        // 后台读文件、写分段；事件按顺序回到主线程更新清单
        enum Update: Sendable { case segment(SegmentWriter.Event), progress(Double) }
        let (updates, continuation) = AsyncStream<Update>.makeStream()
        let work = Task.detached {
            defer { continuation.finish() }
            try await AudioImporter.write(url, info: info, bitRate: bitRate, segmentSeconds: LectureRecorder.segmentSeconds,
                                          segmentURL: { store.folder(id).appendingPathComponent(Recording.Segment.fileName($0)) },
                                          onEvent: { continuation.yield(.segment($0)) },
                                          progress: { continuation.yield(.progress($0)) })
        }
        var lastRefresh = Date.distantPast
        for await update in updates {
            switch update {
            case .segment(let event):
                guard case .closed = event.kind else { continue }
                let updated = try? store.update(id) { AudioImporter.add(event, to: &$0) }
                if updated?.segments.contains(where: { $0.index == event.index && $0.state == .complete }) == true {
                    transcription.enqueue(id, segment: event.index)
                }
                RecordingsWindow.shared.recordingsDidChange()
                lastRefresh = Date()
            case .progress(let value):
                importing[id] = value
                // 进度最多每秒刷新一次窗口
                if Date().timeIntervalSince(lastRefresh) >= 1 {
                    lastRefresh = Date()
                    RecordingsWindow.shared.recordingsDidChange()
                }
            }
        }
        let failure: Error?
        do { try await work.value; failure = nil } catch { failure = error }
        importing[id] = nil

        // 一段都没写下来：不留空的录音
        if store.load(id)?.segments.contains(where: { $0.state == .complete }) != true {
            try? store.delete(id)
            report(tr("无法导入“\(title)”：", "Couldn't import “\(title)”: ")
                   + (failure?.localizedDescription ?? AudioImporter.Failure.noAudio.localizedDescription))
        } else if let failure {
            report(tr("“\(title)”只导入了一部分：", "“\(title)” was only partly imported: ") + failure.localizedDescription)
        } else {
            report(tr("已导入“\(title)”，正在转写", "Imported “\(title)”; transcribing"), error: false)
        }
        RecordingsWindow.shared.recordingsDidChange()
    }

    /// 用当前的识别方式重新转写一条录音：去掉纠正版，所有录好的分段重新排队（每段转写完替换原来的句子）。
    func retranscribe(_ id: String) {
        guard Self.isSupported, let recording = store.load(id) else { return }
        transcription.engine = settings.transcriptionEngine
        store.removeCorrections(id)
        _ = try? store.update(id) { recording in
            for i in recording.segments.indices where recording.segments[i].state == .complete {
                recording.segments[i].transcribed = false
            }
        }
        for segment in recording.segments where segment.state == .complete { transcription.enqueue(id, segment: segment.index) }
        RecordingsWindow.shared.recordingsDidChange()
    }

    /// 提示放在「课堂录音」窗口里；窗口没开时，出错的提示显示在录音条的位置。
    private func report(_ message: String, error: Bool = true) {
        if RecordingsWindow.shared.isVisible {
            RecordingsWindow.shared.toast(message)
        } else if error {
            problem = message
        }
    }
}
