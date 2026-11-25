import Foundation
import Testing
@testable import PPTReader

/// 课堂录音：清单、录音时间的换算、启动时的修复、转写的读写。
@Suite("课堂录音：数据和存储")
struct RecordingTests {
    private func segment(_ index: Int, _ duration: Double, _ state: Recording.Segment.State = .complete,
                         transcribed: Bool = true) -> Recording.Segment {
        Recording.Segment(index: index, startedAt: Date(timeIntervalSince1970: Double(index) * 1000),
                          duration: duration, state: state, transcribed: transcribed)
    }

    private func recording(_ segments: [Recording.Segment]) -> Recording {
        Recording(id: "r", title: "r", startedAt: Date(timeIntervalSince1970: 0), coursePath: nil, deckPath: nil,
                  locale: "en_US", bitRate: 32_000, segments: segments)
    }

    /// 每个测试用自己的临时目录。
    private func withStore(_ body: (RecordingStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(RecordingStore(root: root))
    }

    // MARK: - 时间

    @Test("录音时间跳过损坏和还在录的分段")
    func timeline() throws {
        let r = recording([segment(1, 300), segment(2, 300), segment(3, 0, .damaged), segment(4, 120), segment(5, 0, .recording)])
        #expect(r.duration == 720)
        #expect(r.offset(ofSegment: 1) == 0)
        #expect(r.offset(ofSegment: 4) == 600)
        #expect(r.offset(ofSegment: 3) == nil)
        #expect(r.offset(ofSegment: 5) == nil)
        #expect(r.time(segment: 2, at: 12.5) == 312.5)
        #expect(r.time(segment: 3, at: 1) == nil)
    }

    @Test("从录音时间找回分段和段内位置；超出范围取最近的一端")
    func locate() throws {
        let r = recording([segment(1, 300), segment(2, 0, .damaged), segment(3, 100)])
        func at(_ time: Double) -> [Double]? { r.locate(time).map { [Double($0.segment), $0.seconds] } }
        #expect(at(0) == [1, 0])
        #expect(at(299.5) == [1, 299.5])
        #expect(at(300) == [3, 0])
        #expect(at(350) == [3, 50])
        #expect(at(1_000) == [3, 100])
        #expect(at(-5) == [1, 0])
        #expect(recording([]).locate(10) == nil)
    }

    @Test("分段文件名和下一个序号")
    func naming() {
        #expect(Recording.Segment.fileName(7) == "segment-007.m4a")
        #expect(Recording.Segment.fileName(123) == "segment-123.m4a")
        #expect(recording([]).nextSegmentIndex == 1)
        #expect(recording([segment(1, 1), segment(3, 1)]).nextSegmentIndex == 4)
    }

    // MARK: - 清单

    @Test("清单存进去再读出来不变；新的在前")
    func manifest() throws {
        try withStore { store in
            let early = Date(timeIntervalSince1970: 1_764_000_000)
            var a = try store.create(title: "第一节", coursePath: "/c/os", deckPath: "/c/os/4.pdf", locale: "en_GB",
                                     bitRate: 64_000, now: early)
            a.segments = [segment(1, 300), segment(2, 0, .recording, transcribed: false)]
            a.relatedDecks = ["/c/os/4.pdf", "/c/os/5.pdf"]
            try store.save(a)
            let b = try store.create(title: "第二节", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000,
                                     now: early.addingTimeInterval(3600))
            #expect(store.load(a.id) == a)
            #expect(store.all().map(\.id) == [b.id, a.id])
            #expect(a.id == RecordingStore.id(for: early))
        }
    }

    @Test("同一秒开始的两次录音不会撞名")
    func uniqueIDs() throws {
        try withStore { store in
            let now = Date(timeIntervalSince1970: 1_764_000_000)
            let a = try store.create(title: "a", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000, now: now)
            let b = try store.create(title: "b", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000, now: now)
            #expect(a.id != b.id && b.id.hasPrefix(a.id))
        }
    }

    @Test("只有必需字段的清单也读得出来；读不出清单的文件夹跳过")
    func tolerantManifest() throws {
        try withStore { store in
            let folder = store.folder("old")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"id":"old","startedAt":"2026-11-25T06:30:05Z","future":1}"#.utf8)
                .write(to: folder.appendingPathComponent(RecordingStore.manifestName))
            let broken = store.folder("broken")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: broken.appendingPathComponent(RecordingStore.manifestName))

            let old = try #require(store.load("old"))
            #expect(old.title == "old" && old.locale == "en_US" && old.bitRate == 32_000)
            #expect(old.segments.isEmpty && old.relatedDecks.isEmpty)
            #expect(store.all().map(\.id) == ["old"])
        }
    }

    @Test("删除录音；统计占用空间")
    func deleteAndSize() throws {
        try withStore { store in
            let r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            try Data(count: 10_000).write(to: store.segmentURL(r, 1))
            #expect(store.size(r.id) >= 10_000)
            #expect(store.size() == store.size(r.id))
            try store.delete(r.id)
            #expect(store.load(r.id) == nil && store.all().isEmpty)
        }
    }

    // MARK: - 修复

    @Test("中途退出：打得开的分段补上时长，打不开的标成损坏；正常结束的不用修")
    func repair() throws {
        let folder = URL(fileURLWithPath: "/tmp/r")
        let r = recording([segment(1, 300), segment(2, 0, .recording, transcribed: false), segment(3, 0, .recording, transcribed: false)])
        let fixed = try #require(RecordingStore.repaired(r, probe: { $0.lastPathComponent == "segment-002.m4a" ? 287.5 : nil }, folder: folder))
        #expect(fixed.segments.map(\.state) == [.complete, .complete, .damaged])
        #expect(fixed.segments[1].duration == 287.5)
        #expect(RecordingStore.needsTranscription(fixed).map(\.index) == [2])
        #expect(RecordingStore.repaired(fixed, probe: { _ in 1 }, folder: folder) == nil)
    }

    @Test("长度为 0 的文件也算损坏")
    func repairEmpty() throws {
        let r = recording([segment(1, 0, .recording)])
        let fixed = try #require(RecordingStore.repaired(r, probe: { _ in 0 }, folder: URL(fileURLWithPath: "/tmp")))
        #expect(fixed.segments[0].state == .damaged)
    }

    // MARK: - 转写

    @Test("转写追加写入，读出时按分段和时间排好；坏掉的行跳过")
    func transcript() throws {
        try withStore { store in
            let r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            #expect(store.transcript(r.id).isEmpty)
            try store.appendTranscript([TranscriptLine(segment: 2, start: 1, end: 2, text: "b")], to: r.id)
            try store.appendTranscript([TranscriptLine(segment: 1, start: 5, end: 6, text: "a2"),
                                        TranscriptLine(segment: 1, start: 0, end: 4, text: "a1 \"quoted\" / slash")], to: r.id)
            // 写到一半退出留下的半行
            let url = store.folder(r.id).appendingPathComponent(RecordingStore.transcriptName)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"segment":3,"start":0,"te"#.utf8))
            try handle.close()

            #expect(store.transcript(r.id).map(\.text) == ["a1 \"quoted\" / slash", "a2", "b"])
        }
    }

    @Test("重新转写前去掉这一段原来的句子，其他段不动")
    func removeSegmentTranscript() throws {
        try withStore { store in
            let r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            try store.appendTranscript([TranscriptLine(segment: 1, start: 0, end: 1, text: "keep"),
                                        TranscriptLine(segment: 2, start: 0, end: 1, text: "partial")], to: r.id)
            try store.removeTranscript(segment: 2, from: r.id)
            try store.appendTranscript([TranscriptLine(segment: 2, start: 0, end: 3, text: "full")], to: r.id)
            #expect(store.transcript(r.id).map(\.text) == ["keep", "full"])
        }
    }
}
