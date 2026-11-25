import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 导入现成的音频（手机、录音笔或其他电脑录的课）：读出音轨，写成和录音一样的 5 分钟一段 AAC 单声道，
/// 之后和录音一样逐段转写、整理。原文件不动；视频文件只取其中的音轨。
enum AudioImporter {
    /// 选择文件时可选的类型。
    static let contentTypes: [UTType] = [.audio, .movie]

    enum Failure: LocalizedError, Equatable {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: tr("文件中没有音轨。", "The file has no audio track.")
            case .unreadable(let reason):
                tr("无法读取该文件", "Can't read the file") + (reason.isEmpty ? "。" : tr("：", ": ") + reason)
            }
        }
    }

    struct Info: Sendable {
        var duration: Double
        /// 录下的时间：文件里记录的创建时间；没有时按文件的修改时间往前推一个时长（文件多半是录完时写好的）。
        var recordedAt: Date
        /// 写分段用的采样率：原来的采样率，最高 48 kHz。
        var sampleRate: Double
    }

    static func info(of url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
            track = first
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let duration = seconds.isFinite ? max(0, seconds) : 0
        var sampleRate = 48_000.0
        if let description = try? await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, basic.mSampleRate > 0 {
            sampleRate = min(basic.mSampleRate, 48_000)
        }
        var recordedAt: Date?
        if let item = try? await asset.load(.creationDate) { recordedAt = try? await item.load(.dateValue) }
        if recordedAt == nil, let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            recordedAt = modified.addingTimeInterval(-duration)
        }
        return Info(duration: duration, recordedAt: recordedAt ?? Date(), sampleRate: sampleRate)
    }

    /// 读出音轨写成分段。在后台线程上调用；分段开、关的事件和进度（0…1）也在后台线程上回调。
    /// 中途出错或被取消时，已经写下的部分照常关好（和录音中途停下一样），再把错误抛出去。
    static func write(_ url: URL, info: Info, bitRate: Int, segmentSeconds: Double,
                      segmentURL: @escaping @Sendable (Int) -> URL,
                      onEvent: @escaping @Sendable (SegmentWriter.Event) -> Void,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: info.sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable("") }
        reader.add(output)
        guard reader.startReading(),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: info.sampleRate, channels: 1, interleaved: false)
        else { throw Failure.unreadable(reader.error?.localizedDescription ?? "") }

        let writer = SegmentWriter(bitRate: bitRate, segmentSeconds: segmentSeconds, firstIndex: 1, url: segmentURL, onEvent: onEvent)
        var frames = 0.0
        var reported = -1.0
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
                buffer.frameLength = AVAudioFrameCount(count)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                                         into: buffer.mutableAudioBufferList)
                guard status == noErr else { throw Failure.unreadable("") }
                try writer.write(buffer)
                frames += Double(count)
                if info.duration > 0 {
                    let fraction = min(1, frames / info.sampleRate / info.duration)
                    if fraction - reported >= 0.01 {
                        reported = fraction
                        progress(fraction)
                    }
                }
            }
            if reader.status == .failed { throw Failure.unreadable(reader.error?.localizedDescription ?? "") }
        } catch {
            if reader.status == .reading { reader.cancelReading() }
            writer.close()
            throw error
        }
        writer.close()
        progress(1)
    }

    /// 导入时把关好的分段记进清单：开始时间按前面各段的时长从录下的时间往后推。
    static func add(_ event: SegmentWriter.Event, to recording: inout Recording) {
        guard case .closed(let duration) = event.kind, !recording.segments.contains(where: { $0.index == event.index }) else { return }
        let offset = recording.segments.filter { $0.index < event.index }.reduce(0) { $0 + $1.duration }
        recording.segments.append(Recording.Segment(index: event.index, startedAt: recording.startedAt.addingTimeInterval(offset),
                                                    duration: duration, state: duration > 0 ? .complete : .damaged,
                                                    transcribed: false))
        recording.segments.sort { $0.index < $1.index }
    }
}
