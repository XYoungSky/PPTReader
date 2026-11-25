import AppKit
import UniformTypeIdentifiers
import WebKit

/// 传给 recordings.html 的数据。纯函数，方便测试。
enum RecordingsPayload {
    enum Status: String { case recording, transcribing, ready }

    static func item(_ recording: Recording, status: Status, elapsed: Double? = nil, organized: Bool = false) -> [String: Any] {
        var item: [String: Any] = [
            "id": recording.id,
            "title": recording.title,
            "startedAt": recording.startedAt.timeIntervalSince1970 * 1000,
            "duration": recording.duration,
            "status": status.rawValue,
            "organized": organized,
            "tags": recording.displayTags,
        ]
        if let course = recording.coursePath { item["course"] = URL(fileURLWithPath: course).lastPathComponent }
        if let elapsed { item["elapsed"] = elapsed }
        return item
    }

    /// - Parameters:
    ///   - queued: 正在排队或正在转写的分段。
    ///   - live: 正在录音时的实时字幕（定稿的文字、还会变的文字）。
    static func detail(_ recording: Recording, lines: [TranscriptLine], status: Status, queued: Set<Int>,
                       duration: Double? = nil, live: (String, String)? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "id": recording.id,
            "title": recording.title,
            "startedAt": recording.startedAt.timeIntervalSince1970 * 1000,
            "duration": duration ?? recording.duration,
            "locale": recording.locale,
            "status": status.rawValue,
            "tags": recording.displayTags,
            "segments": recording.segments.map { segment -> [String: Any] in
                [
                    "index": segment.index,
                    "duration": segment.duration,
                    "state": segment.state.rawValue,
                    "transcribed": segment.transcribed,
                    "queued": queued.contains(segment.index) || status == .recording,
                ]
            },
            // 换算成录音时间；损坏分段里的句子（不应该有）没法回放，去掉
            "lines": lines.compactMap { line -> [String: Any]? in
                guard let start = recording.time(segment: line.segment, at: line.start) else { return nil }
                let end = recording.time(segment: line.segment, at: line.end) ?? start
                return ["segment": line.segment, "t": start, "end": max(start, end), "text": line.text]
            },
        ]
        if let deck = recording.deckPath { payload["deck"] = URL(fileURLWithPath: deck).lastPathComponent }
        if let live { payload["live"] = ["text": live.0, "volatile": live.1] }
        return payload
    }

    /// 整理结果（补充要点和课程安排）：带上课件名，时间是录音时间。
    static func supplements(_ result: LectureOrganizer.Result) -> [[String: Any]] {
        result.supplements.map { item in
            var entry: [String: Any] = ["kind": item.kind.rawValue, "point": item.point, "quote": item.quote, "t": item.time]
            if let deck = item.deck {
                entry["deck"] = deck
                entry["deckTitle"] = URL(fileURLWithPath: deck).deletingPathExtension().lastPathComponent
            }
            if let page = item.page { entry["page"] = page }
            return entry
        }
    }

    /// 「AI 整理」进行到哪一步。
    static func organize(_ state: LectureController.OrganizeState, recordedDeck: String?) -> [String: Any] {
        switch state {
        case .finding:
            return ["stage": "finding"]
        case .choosing(let options):
            return ["stage": "choosing", "decks": options.map { option -> [String: Any] in
                [
                    "path": option.candidate.path,
                    "title": option.candidate.title,
                    "folder": option.candidate.folder,
                    "readable": option.candidate.readable,
                    "suggested": option.suggested,
                    "reason": option.reason,
                    "recorded": option.candidate.path == recordedDeck,
                ]
            }]
        case .running(let step, let message, let done, let total):
            return ["stage": "running", "step": step, "message": message, "done": done, "total": total]
        case .failed(let message):
            return ["stage": "failed", "message": message]
        }
    }

    /// 导出的纯文本转写：每段一行，前面是录音时间。
    static func text(_ recording: Recording, lines: [TranscriptLine]) -> String {
        var output = "\(recording.title)\n"
        for line in lines {
            guard let time = recording.time(segment: line.segment, at: line.start) else { continue }
            output += "\n[\(clock(time))] \(line.text)"
        }
        return output + "\n"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
}

/// 「课堂录音」窗口：录音列表、回放、转写。和路线图一样是单独的浮动面板。
@MainActor
final class RecordingsWindow: NSObject {
    static let shared = RecordingsWindow()

    private var panel: FigurePanel?
    private var webView: FigureWebView?
    private var isReady = false
    private var selected: String?
    private let player = RecordingPlayer()
    private var ticker: Timer?
    private let store = RecordingStore.shared

    private var lectures: LectureController? { SettingsWindow.model?.lectures }

    var isVisible: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        player.onChange = { [weak self] state in
            self?.send("Recordings.setPlayback", ["time": state.time, "playing": state.playing, "rate": state.rate])
        }
    }

    func show(select id: String? = nil) {
        let panel = self.panel ?? makePanel()
        if let id { selected = id }
        if !panel.isVisible { place(panel) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        reload()
        startTicker()
    }

    /// 录音开始 / 停止、分段录完、转写完一段之后。
    func recordingsDidChange() {
        guard isVisible else { return }
        reload()
    }

    func captionsDidChange() {
        guard isVisible, let lectures, lectures.isRecording, selected == lectures.recorder.recording?.id else { return }
        send("Recordings.setLive", ["text": lectures.captionFinal, "volatile": lectures.captionVolatile])
    }

    // MARK: - 内容

    private func status(of recording: Recording) -> RecordingsPayload.Status {
        if let lectures, lectures.isRecording, lectures.recorder.recording?.id == recording.id { return .recording }
        if lectures?.transcription.isBusy(with: recording.id) == true { return .transcribing }
        return .ready
    }

    private func reload() {
        let recordings = sendList()
        guard let recording = recordings.first(where: { $0.id == selected }) else {
            player.stop()
            return
        }
        sendDetail(recording)
    }

    @discardableResult
    private func sendList() -> [Recording] {
        let recordings = store.all()
        if selected == nil || !recordings.contains(where: { $0.id == selected }) { selected = recordings.first?.id }
        let elapsed = lectures?.recorder.elapsed
        send("Recordings.setList", [
            "lang": Localizer.shared.code,
            "selected": selected.map { $0 as Any } ?? NSNull(),
            "items": recordings.map { recording in
                let status = status(of: recording)
                return RecordingsPayload.item(recording, status: status, elapsed: status == .recording ? elapsed : nil,
                                              organized: store.organized(recording.id) != nil)
            },
        ])
        return recordings
    }

    private func sendDetail(_ recording: Recording) {
        let status = status(of: recording)
        let queued = Set(recording.segments.map(\.index).filter { index in
            lectures?.transcription.pending.contains { $0.recording == recording.id && $0.segment == index } == true
                || lectures?.transcription.current == TranscriptionQueue.Job(recording: recording.id, segment: index)
        })
        var live: (String, String)?
        var duration: Double?
        if status == .recording, let lectures {
            live = (lectures.captionFinal, lectures.captionVolatile)
            duration = lectures.recorder.elapsed
        }
        var payload = RecordingsPayload.detail(recording, lines: store.transcript(recording.id), status: status,
                                               queued: queued, duration: duration, live: live)
        if let result = store.organized(recording.id) { payload["supplements"] = RecordingsPayload.supplements(result) }
        if let state = lectures?.organizing[recording.id] {
            payload["organize"] = RecordingsPayload.organize(state, recordedDeck: recording.deckPath)
        }
        send("Recordings.showDetail", payload)
        player.load(status == .recording ? nil : recording, store: store)
    }

    /// 录音时每秒更新一次列表里的时长。
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if self.lectures?.isRecording == true { self.sendList() }
            }
        }
    }

    // MARK: - 操作

    private func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        let id = dict["id"] as? String ?? selected
        switch type {
        case "ready":
            isReady = true
            reload()
        case "select":
            selected = id
            reload()
        case "play": player.play()
        case "pause": player.pause()
        case "seek":
            if let time = (dict["time"] as? NSNumber)?.doubleValue {
                player.seek(to: time, thenPlay: (dict["play"] as? Bool) == true)
            }
        case "rate":
            if let rate = (dict["rate"] as? NSNumber)?.floatValue { player.setRate(rate) }
        case "organize":
            if let id { lectures?.organize(id) }
        case "organizeConfirm":
            if let id, let paths = dict["decks"] as? [String] { lectures?.confirmOrganize(id, decks: paths) }
        case "organizeCancel":
            if let id { lectures?.cancelOrganize(id) }
        case "openPage":
            if let deck = dict["deck"] as? String, let page = (dict["page"] as? NSNumber)?.intValue {
                SettingsWindow.model?.open(deck: URL(fileURLWithPath: deck), page: page)
                NSApp.mainWindow?.makeKeyAndOrderFront(nil)
            }
        case "rename": if let id { rename(id) }
        case "editTags": if let id { editTags(id) }
        case "reveal": if let id { NSWorkspace.shared.activateFileViewerSelecting([store.folder(id)]) }
        case "exportAudio": if let id { exportAudio(id) }
        case "exportText": if let id { exportText(id) }
        case "delete": if let id { delete(id) }
        default: break
        }
    }

    private func rename(_ id: String) {
        guard let recording = store.load(id), let panel else { return }
        let alert = NSAlert()
        alert.messageText = tr("重命名录音", "Rename Recording")
        alert.addButton(withTitle: tr("好", "OK"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        let field = NSTextField(string: recording.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard response == .alertFirstButtonReturn, !title.isEmpty, let self else { return }
                try? self.store.update(id) { $0.title = title }
                self.reload()
            }
        }
    }

    private func editTags(_ id: String) {
        guard let recording = store.load(id), let panel else { return }
        let alert = NSAlert()
        alert.messageText = tr("编辑标签", "Edit Tags")
        alert.informativeText = tr("用逗号分开，第一个标签用来分组，通常是课程编号。", "Separate tags with commas. The first one groups the list; usually it's the course code.")
        alert.addButton(withTitle: tr("好", "OK"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        let field = NSTextField(string: recording.displayTags.joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                let tags = Recording.parseTags(field.stringValue)
                _ = try? self.store.update(id) { $0.tags = tags }
                self.reload()
            }
        }
    }

    private func exportText(_ id: String) {
        guard let recording = store.load(id), let panel else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = recording.title + ".txt"
        save.allowedContentTypes = [.plainText]
        save.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = save.url, let self else { return }
                let text = RecordingsPayload.text(recording, lines: self.store.transcript(id))
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self.send("Recordings.toast", error.localizedDescription)
                }
            }
        }
    }

    private func exportAudio(_ id: String) {
        guard let recording = store.load(id), let panel, status(of: recording) != .recording else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = recording.title + ".m4a"
        save.allowedContentTypes = [.mpeg4Audio]
        save.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = save.url, let self else { return }
                let urls = recording.playable.map { self.store.segmentURL(recording, $0.index) }
                self.send("Recordings.toast", tr("正在导出…", "Exporting…"))
                Task {
                    do {
                        let composition = try await RecordingPlayer.compose(urls)
                        try await RecordingPlayer.export(composition, to: url)
                        self.send("Recordings.toast", tr("已导出", "Exported"))
                    } catch {
                        self.send("Recordings.toast", tr("导出失败：", "Export failed: ") + error.localizedDescription)
                    }
                }
            }
        }
    }

    private func delete(_ id: String) {
        guard let recording = store.load(id), let panel else { return }
        if status(of: recording) == .recording {
            send("Recordings.toast", tr("正在录音，停止后才能删除", "Stop recording before deleting it"))
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("删除“\(recording.title)”？", "Delete “\(recording.title)”?")
        alert.informativeText = tr("录音、转写和整理结果都会删除，无法恢复。", "The audio, transcript and organized results will be deleted. This can't be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("删除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                if self.player.recordingID == id { self.player.stop() }
                if self.lectures?.organizing[id] != nil { self.lectures?.cancelOrganize(id) }
                try? self.store.delete(id)
                if self.selected == id { self.selected = nil }
                self.reload()
            }
        }
    }

    // MARK: - 窗口

    private func makePanel() -> FigurePanel {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ScriptMessageProxy { [weak self] body in self?.receive(body) }, name: "recordings")
        let webView = FigureWebView(frame: NSRect(x: 0, y: 0, width: 940, height: 660), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        let panel = FigurePanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.title = tr("课堂录音", "Lectures")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.panelNSColor
        panel.minSize = NSSize(width: 640, height: 440)
        panel.contentView = webView
        panel.onClose = { [weak self] in
            self?.player.pause()
            self?.ticker?.invalidate()
            self?.ticker = nil
        }

        self.panel = panel
        self.webView = webView
        if let directory = WebAssets.directory {
            webView.loadFileURL(directory.appendingPathComponent("recordings.html"), allowingReadAccessTo: directory)
        }
        return panel
    }

    /// 第一次打开放在主窗口中间偏右；之后记住用户放的位置。
    private func place(_ panel: NSPanel) {
        if panel.setFrameUsingName("RecordingsWindow") { return }
        let parent = NSApp.mainWindow ?? NSApp.windows.first { $0.title == "PPTReader" }
        let screen = parent?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let area = parent?.frame ?? visible
        let width = min(940, visible.width - 40), height = min(max(area.height * 0.78, 520), visible.height - 40)
        var origin = NSPoint(x: area.maxX - width - 24, y: area.midY - height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.setFrameAutosaveName("RecordingsWindow")
    }

    private func send(_ function: String, _ payload: Any) {
        // 不合法的对象（比如 nil、NaN）会让 JSONSerialization 抛出 ObjC 异常直接崩溃，先检查
        guard isReady, let webView, payload is String || JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(function)(\(json))") { _, error in
            if let error { NSLog("PPTReader recordings JS error: \(error)") }
        }
    }
}
