import AVFoundation
import Foundation
import Testing
@testable import PPTReader

/// 「课堂录音」窗口：传给网页的数据、导出的文本、回放时拼接的时长。
@Suite("课堂录音：窗口")
struct RecordingsWindowTests {
    private func recording() -> Recording {
        Recording(id: "2026-11-25_14-30-05", title: "第 4 章", startedAt: Date(timeIntervalSince1970: 1_764_000_000),
                  coursePath: "/Courses/操作系统", deckPath: "/Courses/操作系统/04.pdf", locale: "en_GB", bitRate: 32_000,
                  segments: [
                    .init(index: 1, startedAt: Date(), duration: 300, state: .complete, transcribed: true),
                    .init(index: 2, startedAt: Date(), duration: 0, state: .damaged, transcribed: false),
                    .init(index: 3, startedAt: Date(), duration: 120, state: .complete, transcribed: false),
                  ])
    }

    @Test("列表项：课程取文件夹名，时间用毫秒；录音中才带已录时长")
    func item() throws {
        let item = RecordingsPayload.item(recording(), status: .ready)
        #expect(item["course"] as? String == "操作系统")
        #expect(item["duration"] as? Double == 420)
        #expect(item["startedAt"] as? Double == 1_764_000_000_000)
        #expect(item["status"] as? String == "ready")
        #expect(item["elapsed"] == nil)
        #expect(RecordingsPayload.item(recording(), status: .recording, elapsed: 61)["elapsed"] as? Double == 61)
        #expect(JSONSerialization.isValidJSONObject(item))
    }

    @Test("详情：句子换算成录音时间（跳过损坏的分段），分段标出是否在排队")
    func detail() throws {
        let lines = [
            TranscriptLine(segment: 1, start: 2, end: 4, text: "a"),
            TranscriptLine(segment: 2, start: 1, end: 2, text: "lost"),
            TranscriptLine(segment: 3, start: 5, end: 7, text: "b"),
        ]
        let payload = RecordingsPayload.detail(recording(), lines: lines, status: .transcribing, queued: [3])
        let mapped = try #require(payload["lines"] as? [[String: Any]])
        #expect(mapped.map { $0["text"] as? String } == ["a", "b"])
        #expect(mapped.map { $0["t"] as? Double } == [2, 305])
        #expect(mapped.map { $0["end"] as? Double } == [4, 307])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        #expect(segments.map { $0["state"] as? String } == ["complete", "damaged", "complete"])
        #expect(segments.map { $0["queued"] as? Bool } == [false, false, true])
        #expect(payload["deck"] as? String == "04.pdf")
        #expect(payload["live"] == nil)
        #expect(JSONSerialization.isValidJSONObject(payload))

        let live = RecordingsPayload.detail(recording(), lines: [], status: .recording, queued: [], duration: 999, live: ("x", "y"))
        #expect(live["duration"] as? Double == 999)
        #expect((live["live"] as? [String: String]) == ["text": "x", "volatile": "y"])
    }

    @Test("导出的文本：标题，然后每句一行，前面是录音时间")
    func text() {
        let text = RecordingsPayload.text(recording(), lines: [
            TranscriptLine(segment: 1, start: 2, end: 4, text: "Okay."),
            TranscriptLine(segment: 3, start: 3725, end: 3730, text: "Long one."),
        ])
        #expect(text == "第 4 章\n\n[0:00:02] Okay.\n[1:07:05] Long one.\n")
    }

    @Test("导出纠正版：改过的句子换成纠正后的")
    func correctedText() {
        let lines = [TranscriptLine(segment: 1, start: 2, end: 4, text: "The colonel."),
                     TranscriptLine(segment: 3, start: 5, end: 6, text: "Next.")]
        let corrections = LectureOrganizer.Corrections(lines: [.init(segment: 1, start: 2, text: "The kernel.")], createdAt: Date())
        #expect(RecordingsPayload.text(recording(), lines: lines, corrections: corrections)
                == "第 4 章\n\n[0:00:02] The kernel.\n[0:05:05] Next.\n")
    }

    @Test("导出补充要点按课件和页分组（对不上页的放最后），课程安排按时间排")
    func markdown() {
        let items: [LectureOrganizer.Supplement] = [
            .init(kind: .supplement, deck: "/c/04.pdf", page: 9, point: "B", quote: "", time: 50),
            .init(kind: .supplement, deck: nil, page: nil, point: "C", quote: "q", time: 10),
            .init(kind: .supplement, deck: "/c/04.pdf", page: 3, point: "A", quote: "", time: 90),
            .init(kind: .arrangement, deck: nil, page: nil, point: "Exam on Friday", quote: "", time: 3700),
            .init(kind: .arrangement, deck: "/c/04.pdf", page: 12, point: "Page 12 is on the exam", quote: "", time: 30),
        ]
        let supplements = RecordingsPayload.markdown(recording(), items: items, kind: .supplement)
        let a = supplements.range(of: "**p.3**")!.lowerBound, b = supplements.range(of: "**p.9**")!.lowerBound
        let off = supplements.range(of: "[0:00:10] C")!.lowerBound
        #expect(supplements.hasPrefix("# 第 4 章 · ") && a < b && b < off)
        #expect(supplements.contains("## 04\n") && supplements.contains("  > “q”"))
        #expect(!supplements.contains("Exam"))

        let arrangements = RecordingsPayload.markdown(recording(), items: items, kind: .arrangement)
        let first = arrangements.range(of: "Page 12")!.lowerBound, second = arrangements.range(of: "Exam on Friday")!.lowerBound
        #expect(first < second && arrangements.contains("[1:01:40] Exam on Friday"))
        #expect(!arrangements.contains("**p."))
        #expect(RecordingsPayload.markdown(recording(), items: [], kind: .arrangement).contains("（没有）") ||
                RecordingsPayload.markdown(recording(), items: [], kind: .arrangement).contains("(none)"))
    }

    @Test("回放时按顺序拼接分段，总长等于各段之和")
    func compose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SegmentWriter(bitRate: 32_000, segmentSeconds: 1, firstIndex: 1,
                                   url: { directory.appendingPathComponent(Recording.Segment.fileName($0)) }, onEvent: { _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for _ in 0..<25 { try writer.write(buffer) }   // 2.5 秒 → 3 段
        writer.close()
        let urls = (1...3).map { directory.appendingPathComponent(Recording.Segment.fileName($0)) }
        let composition = try await RecordingPlayer.compose(urls)
        #expect(abs(composition.duration.seconds - 2.5) < 0.01)

        let exported = directory.appendingPathComponent("joined.m4a")
        try await RecordingPlayer.export(composition, to: exported)
        let file = try AVAudioFile(forReading: exported)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2.5) < 0.05)
    }

    @Test("整理的进度和结果：选课件时标出录音时打开的那份，补充要点带课件名")
    @MainActor
    func organizePayload() throws {
        let candidate = LectureOrganizer.Candidate(path: "/c/04.pdf", title: "04", folder: "L", head: "", readable: true)
        let choosing = RecordingsPayload.organize(.choosing([.init(candidate: candidate, suggested: true, reason: "r")]), recordedDeck: "/c/04.pdf")
        let deck = try #require((choosing["decks"] as? [[String: Any]])?.first)
        #expect(choosing["stage"] as? String == "choosing")
        #expect(deck["recorded"] as? Bool == true && deck["suggested"] as? Bool == true && deck["reason"] as? String == "r")
        let running = RecordingsPayload.organize(.running(step: 2, message: "m", done: 1, total: 4), recordedDeck: nil)
        #expect(running["step"] as? Int == 2 && running["total"] as? Int == 4)
        #expect(RecordingsPayload.organize(.failed("x"), recordedDeck: nil)["message"] as? String == "x")
        #expect(JSONSerialization.isValidJSONObject(choosing))

        let result = LectureOrganizer.Result(decks: ["/c/04.pdf"], supplements: [
            .init(deck: "/c/04.pdf", page: 3, point: "p", quote: "q", time: 12),
            .init(deck: nil, page: nil, point: "off", quote: "", time: 30),
        ], createdAt: Date())
        let items = RecordingsPayload.supplements(result)
        #expect(items[0]["deckTitle"] as? String == "04" && items[0]["page"] as? Int == 3 && items[0]["t"] as? Double == 12)
        #expect(items[0]["kind"] as? String == "supplement")
        #expect(items[1]["deck"] == nil && items[1]["page"] == nil)
        #expect(JSONSerialization.isValidJSONObject(items))
    }

    @Test("快捷键：开始 / 停止录音 ⌘⇧R，课堂录音窗口 ⌥⌘R，不和别的冲突")
    func shortcuts() {
        let combos = ShortcutAction.allCases.compactMap(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
        #expect(ShortcutAction.record.defaultCombo == KeyCombo("r", [.shift, .command]))
        #expect(ShortcutAction.recordings.group == .recording)
    }
}
