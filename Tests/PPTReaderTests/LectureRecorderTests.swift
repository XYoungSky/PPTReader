import AVFoundation
import Foundation
import Testing
@testable import PPTReader

/// 课堂录音：分段写入（用合成的 buffer 代替麦克风）和时长上限。
@Suite("课堂录音：分段写入")
struct LectureRecorderTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SegmentWriter.Event] = []
        func add(_ event: SegmentWriter.Event) { lock.lock(); items.append(event); lock.unlock() }
        var all: [SegmentWriter.Event] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// 0.1 秒的正弦波 buffer。
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { data[i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(format.sampleRate)) }
        }
        return buffer
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("按时长切段，序号接着往下编；每段读回的帧数和写入的一致；立体声转成单声道")
    func segments() throws {
        try withDirectory { directory in
            let events = Events()
            let writer = SegmentWriter(bitRate: 32_000, segmentSeconds: 1, firstIndex: 3,
                                       url: { directory.appendingPathComponent(Recording.Segment.fileName($0)) },
                                       onEvent: { events.add($0) })
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            for _ in 0..<35 { try writer.write(buffer(stereo)) }   // 3.5 秒
            writer.close()
            writer.close()   // 重复关闭不出事

            let closed = events.all.compactMap { event -> (Int, Double)? in
                if case .closed(let duration) = event.kind { return (event.index, duration) }
                return nil
            }
            #expect(closed.map(\.0) == [3, 4, 5, 6])
            #expect(closed.map(\.1) == [1, 1, 1, 0.5])
            #expect(events.all.count == 8)

            for (index, duration) in closed {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(Recording.Segment.fileName(index)))
                #expect(file.fileFormat.channelCount == 1)
                #expect(file.length == AVAudioFramePosition(duration * 48_000))
            }
        }
    }

    @Test("单声道输入不用转换；空 buffer 不开文件")
    func mono() throws {
        try withDirectory { directory in
            let events = Events()
            let writer = SegmentWriter(bitRate: 32_000, segmentSeconds: 60, firstIndex: 1,
                                       url: { directory.appendingPathComponent(Recording.Segment.fileName($0)) },
                                       onEvent: { events.add($0) })
            let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            try writer.write(buffer(mono, frames: 0))
            #expect(events.all.isEmpty)
            for _ in 0..<5 { try writer.write(buffer(mono, frames: 4410)) }
            writer.close()
            let file = try AVAudioFile(forReading: directory.appendingPathComponent("segment-001.m4a"))
            #expect(file.length == 22_050)
        }
    }

    @Test("时长上限：最后 5 分钟提醒，到点停止")
    func limit() {
        let limit = RecordingLimit(seconds: 3600)
        #expect(limit.status(at: 0) == .normal)
        #expect(limit.status(at: 3299) == .normal)
        #expect(limit.status(at: 3300) == .warning(remaining: 300))
        #expect(limit.status(at: 3540) == .warning(remaining: 60))
        #expect(limit.status(at: 3600) == .reached)
        #expect(RecordingLimit.standard.seconds == 3 * 3600)
    }
}
