import AVFoundation
import Foundation
import Testing
@testable import PPTReader

/// 导入音频：读出音轨，写成和录音一样的分段（AAC 单声道），清单里的分段时间按顺序往后推。
@Suite("课堂录音：导入音频")
struct AudioImportTests {
    private func withFolder(_ body: (URL) async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// 合成一段立体声 WAV：左右声道不同频率的正弦波。
    private func makeWAV(_ url: URL, seconds: Double, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * 440 * t))
            buffer.floatChannelData![1][i] = Float(0.3 * sin(2 * .pi * 660 * t))
        }
        try file.write(from: buffer)
    }

    @Test("立体声 WAV 按 1 秒切成三段单声道 AAC，时长对得上；清单里每段的开始时间按前面的时长往后推")
    func importsInSegments() async throws {
        try await withFolder { root in
            let source = root.appendingPathComponent("lecture.wav")
            try makeWAV(source, seconds: 2.5)
            let info = try await AudioImporter.info(of: source)
            #expect(abs(info.duration - 2.5) < 0.05)
            #expect(info.sampleRate == 44_100)

            let events = Events()
            let progress = Events()
            try await AudioImporter.write(source, info: info, bitRate: 32_000, segmentSeconds: 1,
                                          segmentURL: { root.appendingPathComponent(Recording.Segment.fileName($0)) },
                                          onEvent: { events.append($0) },
                                          progress: { progress.append($0) })
            let segmentEvents = events.all.compactMap { $0 as? SegmentWriter.Event }
            let closed = segmentEvents.compactMap { event -> (Int, Double)? in
                if case .closed(let duration) = event.kind { return (event.index, duration) }
                return nil
            }
            #expect(closed.map(\.0) == [1, 2, 3])
            #expect(abs(closed.map(\.1).reduce(0, +) - 2.5) < 0.05)
            #expect(closed[0].1 >= 1 && closed[2].1 < 1)
            #expect((progress.all.last as? Double) == 1)

            for index in 1...3 {
                let file = try AVAudioFile(forReading: root.appendingPathComponent(Recording.Segment.fileName(index)))
                #expect(file.fileFormat.channelCount == 1)
                #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
            }

            // 记进清单
            let start = Date(timeIntervalSince1970: 1_000_000)
            var recording = Recording(id: "x", title: "lecture", startedAt: start, coursePath: nil, deckPath: nil,
                                      locale: "en_US", bitRate: 32_000)
            for event in segmentEvents { AudioImporter.add(event, to: &recording) }
            #expect(recording.segments.map(\.index) == [1, 2, 3])
            #expect(recording.segments.allSatisfy { $0.state == .complete && !$0.transcribed })
            #expect(abs(recording.segments[2].startedAt.timeIntervalSince(start) - (closed[0].1 + closed[1].1)) < 0.001)
            #expect(abs(recording.duration - 2.5) < 0.05)
        }
    }

    @Test("不是音频的文件：读不出音轨，报错")
    func rejectsNonAudio() async throws {
        try await withFolder { root in
            let fake = root.appendingPathComponent("notes.m4a")
            try Data("not audio".utf8).write(to: fake)
            await #expect(throws: AudioImporter.Failure.self) { _ = try await AudioImporter.info(of: fake) }
        }
    }

    /// 后台线程回调里收集事件。
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Any] = []
        func append(_ item: Any) { lock.withLock { items.append(item) } }
        var all: [Any] { lock.withLock { items } }
    }
}
