import Foundation

/// 课堂录音的存储：`Application Support/PPTReader/Recordings/<录音 id>/` 下放
/// `recording.json`（清单）、`segment-001.m4a`…（音频分段）、`transcript.jsonl`（转写，每行一句）。
/// 课程文件夹本身不动。分组（按课程、日期）看清单里的字段，文件夹不分层，课程文件夹改名也不影响。
struct RecordingStore: Sendable {
    let root: URL

    static var shared: RecordingStore {
        RecordingStore(root: AppPaths.ensure(AppPaths.support.appendingPathComponent("Recordings", isDirectory: true)))
    }

    static let manifestName = "recording.json"
    static let transcriptName = "transcript.jsonl"

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func segmentURL(_ recording: Recording, _ index: Int) -> URL {
        folder(recording.id).appendingPathComponent(Recording.Segment.fileName(index))
    }

    // MARK: - 清单

    /// 新建一次录音（还没有分段）。id 用开始时间，同一秒里重复时加序号。
    func create(title: String, coursePath: String?, deckPath: String?, locale: String, bitRate: Int,
                now: Date = Date()) throws -> Recording {
        let base = Self.id(for: now)
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        let recording = Recording(id: id, title: title, startedAt: now, coursePath: coursePath, deckPath: deckPath,
                                  locale: locale, bitRate: bitRate)
        try save(recording)
        return recording
    }

    func save(_ recording: Recording) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recording)
        try data.write(to: folder(recording.id).appendingPathComponent(Self.manifestName), options: .atomic)
    }

    func load(_ id: String) -> Recording? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(Self.manifestName)),
              let recording = try? decoder.decode(Recording.self, from: data), recording.id == id else { return nil }
        return recording
    }

    /// 所有录音，新的在前。读不出清单的文件夹跳过。
    func all() -> [Recording] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load).sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: folder(id))
    }

    /// 占用的空间（字节）。
    func size(_ id: String? = nil) -> Int64 {
        let base = id.map(folder) ?? root
        guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 修复

    /// 启动时检查上次没正常结束的录音：还在“正在写”的分段，打得开就补上时长、标成完成，打不开就标成损坏。
    /// - Parameter probe: 读出音频文件的时长，打不开时返回 nil（测试时替换掉）。
    /// - Returns: 修复后的清单；没有要修的返回 nil。
    static func repaired(_ recording: Recording, probe: (URL) -> Double?, folder: URL) -> Recording? {
        var recording = recording
        var changed = false
        for i in recording.segments.indices where recording.segments[i].state == .recording {
            let url = folder.appendingPathComponent(recording.segments[i].file)
            if let duration = probe(url), duration > 0 {
                recording.segments[i].duration = duration
                recording.segments[i].state = .complete
            } else {
                recording.segments[i].state = .damaged
            }
            changed = true
        }
        return changed ? recording : nil
    }

    /// 已经完整、但转写还没写完的分段：要从文件补转写。
    static func needsTranscription(_ recording: Recording) -> [Recording.Segment] {
        recording.segments.filter { $0.state == .complete && !$0.transcribed }
    }

    // MARK: - 转写

    /// 追加几句转写。每句一行 JSON，写到一半退出时最多坏最后一行。
    func appendTranscript(_ lines: [TranscriptLine], to id: String) throws {
        guard !lines.isEmpty else { return }
        let data = try Self.encode(lines)
        let url = folder(id).appendingPathComponent(Self.transcriptName)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    /// 读出转写，按分段和时间排好。坏掉的行跳过。
    func transcript(_ id: String) -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(Self.transcriptName)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A)
            .compactMap { try? decoder.decode(TranscriptLine.self, from: Data($0)) }
            .sorted { ($0.segment, $0.start) < ($1.segment, $1.start) }
    }

    /// 重新转写某个分段之前，去掉它原来的句子（实时转写写了一半的也一起去掉）。
    func removeTranscript(segment: Int, from id: String) throws {
        let kept = transcript(id).filter { $0.segment != segment }
        try Self.encode(kept).write(to: folder(id).appendingPathComponent(Self.transcriptName), options: .atomic)
    }

    private static func encode(_ lines: [TranscriptLine]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        return data
    }

    /// 用本地时间，例如 `2026-11-25_14-30-05`。
    static func id(for date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
