import AVFoundation
import Foundation
import Speech
import Testing
@testable import PPTReader

/// 课堂录音：转写结果的整理、转写队列，以及一次真实的系统转写（macOS 26+）。
@Suite("课堂录音：转写")
struct TranscriptionTests {
    private func token(_ text: String, _ start: Double) -> TranscriptText.Token {
        TranscriptText.Token(text: text, start: start, end: start + 0.4)
    }

    @Test("按句末标点切句，去掉首尾空白；没有标点时按词数切开")
    func sentences() {
        let tokens = [token("OK", 0), token(", ", 0.4), token("let's ", 0.5), token("start", 0.9), token(". ", 1.3),
                      token("Is ", 2), token("it ", 2.4), token("clear", 2.8), token("? ", 3.2), token("Next ", 4)]
        let lines = TranscriptText.sentences(tokens)
        #expect(lines.map(\.text) == ["OK, let's start.", "Is it clear?", "Next"])
        #expect(lines[1].start == 2 && lines[1].end == 3.6)

        let long = (0..<100).map { token("word ", Double($0)) }
        let split = TranscriptText.sentences(long)
        #expect(split.count == 3)
        #expect(split[0].text.split(separator: " ").count == TranscriptText.maxWords)
        #expect(split[1].start == Double(TranscriptText.maxWords))
        #expect(TranscriptText.sentences([]).isEmpty)
    }

    @Test("从课件里挑术语：缩写、专有名词、反复出现的长词；句首的普通词不算")
    func terms() {
        let pages = [
            "Process Scheduling\nEvery process has a PCB. The scheduler picks the next process.",
            "Round robin vs FCFS. Dijkstra introduced semaphores. This is important.",
            "Semaphores: wait and signal. PCBs live in kernel memory. Dijkstra again. semaphores semaphores scheduler scheduler",
        ]
        let terms = TranscriptText.terms(in: pages)
        #expect(terms.contains("PCB") && terms.contains("FCFS") && terms.contains("Dijkstra"))
        #expect(terms.contains("semaphores") && terms.contains("scheduler"))
        #expect(!terms.contains("This") && !terms.contains("Every") && !terms.contains("Process"))
        #expect(!terms.contains("PCBs"))
        #expect(terms.first == "PCB")   // 出现最多（PCB、PCBs）
        #expect(TranscriptText.terms(in: pages, limit: 2).count == 2)
    }

    // MARK: - 队列

    @MainActor
    private final class Fake {
        var calls: [String] = []
        var failOn: String?
        func transcribe(_ url: URL, _ locale: Locale, _ engine: TranscriptionEngine, _ terms: [String]) async throws -> [TranscriptText.Line] {
            calls.append(url.lastPathComponent)
            if url.lastPathComponent == failOn { throw TranscriptionFailure.unavailable }
            return [TranscriptText.Line(start: 1, end: 2, text: "\(url.lastPathComponent) \(locale.identifier) \(terms.joined(separator: ","))")]
        }
    }

    private func withStore(_ body: (RecordingStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(RecordingStore(root: root))
    }

    private func segment(_ index: Int, _ state: Recording.Segment.State, transcribed: Bool) -> Recording.Segment {
        Recording.Segment(index: index, startedAt: Date(), duration: state == .complete ? 300 : 0, state: state, transcribed: transcribed)
    }

    @Test("启动时修复并补转写：只转写完成了还没转写的分段；写进转写并标记；失败的留着下次再试")
    @MainActor
    func queue() async throws {
        try await withStore { store in
            var r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_GB", bitRate: 32_000)
            r.segments = [segment(1, .complete, transcribed: true), segment(2, .complete, transcribed: false),
                          segment(3, .damaged, transcribed: false), segment(4, .recording, transcribed: false),
                          segment(5, .recording, transcribed: false)]
            try store.save(r)
            try store.appendTranscript([TranscriptLine(segment: 2, start: 0, end: 1, text: "live partial")], to: r.id)

            let fake = Fake()
            fake.failOn = "segment-005.m4a"
            let queue = TranscriptionQueue(store: store, transcribe: fake.transcribe)
            queue.terms[r.id] = ["PCB", "Dijkstra"]
            // 中途退出留下两个“录音中”的分段：第 4 段打不开（标成损坏），第 5 段打得开（补上时长）但转写失败
            queue.repairAll(probe: { $0.lastPathComponent == "segment-005.m4a" ? 120 : nil })
            queue.enqueue(r.id, segment: 2)   // 重复排队不会转两次
            await queue.waitUntilIdle()

            #expect(fake.calls == ["segment-002.m4a", "segment-005.m4a"])
            let saved = try #require(store.load(r.id))
            #expect(saved.segments.map(\.state) == [.complete, .complete, .damaged, .damaged, .complete])
            #expect(saved.segments.map(\.transcribed) == [true, true, false, false, false])
            #expect(store.transcript(r.id).map(\.text) == ["segment-002.m4a en_GB PCB,Dijkstra"])
            #expect(queue.lastError != nil && queue.isIdle)
        }
    }

    // MARK: - 真实转写

    @Test("用系统识别器转写一段合成的英文讲课（录音格式：分段写入的 AAC）",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func realTranscription() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let speech = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "Every process has a process control block. The kernel performs a context switch. Round robin scheduling uses a time quantum."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        // 和录音时一样经过 SegmentWriter，写成 32 kbps 单声道 AAC
        let input = try AVAudioFile(forReading: speech)
        let writer = SegmentWriter(bitRate: 32_000, segmentSeconds: 600, firstIndex: 1,
                                   url: { directory.appendingPathComponent(Recording.Segment.fileName($0)) }, onEvent: { _ in })
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: 4096)
            try writer.write(buffer)
        }
        writer.close()

        for engine in TranscriptionEngine.allCases {
            let lines = try await SpeechFileTranscriber.transcribe(directory.appendingPathComponent("segment-001.m4a"),
                                                                    locale: Locale(identifier: "en_US"), engine: engine,
                                                                    terms: ["kernel", "quantum"])
            let text = lines.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("process") && text.contains("context switch") && text.contains("quantum"), "\(engine): \(text)")
            #expect(lines.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
            #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start })
        }
    }
}
