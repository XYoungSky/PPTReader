import AppKit
import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import PPTReader

/// 课堂录音的批注：只把对应到页的要点叠加到课件上，不写回原文件；导出带批注的副本。
@Suite("课堂录音：课件上的批注")
struct LectureAnnotationsTests {
    private func makePDF(_ url: URL, pages: Int) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func withFixture(_ body: (URL, RecordingStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = root.appendingPathComponent("04.pdf")
        makePDF(deck, pages: 3)
        let store = RecordingStore(root: root.appendingPathComponent("Recordings"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let r = try store.create(title: "Week 4", coursePath: nil, deckPath: deck.path, locale: "en_US", bitRate: 32_000)
        try store.saveOrganized(.init(decks: [deck.path], supplements: [
            .init(kind: .supplement, deck: deck.path, page: 2, point: "PCB 存寄存器", quote: "The PCB", time: 65),
            .init(kind: .arrangement, deck: deck.path, page: 2, point: "这一页会考", quote: "", time: 300),
            .init(kind: .supplement, deck: nil, page: nil, point: "对不上页", quote: "", time: 10),
            .init(kind: .supplement, deck: "/other.pdf", page: 1, point: "别的课件", quote: "", time: 20),
            .init(kind: .arrangement, deck: deck.path, page: 3, point: "周五交作业", quote: "", time: 900),
        ], createdAt: Date()), for: r.id)
        try body(deck, store, root)
    }

    @Test("只取这份课件、有页码的要点，按页排")
    func items() throws {
        try withFixture { deck, store, _ in
            let items = LectureAnnotations.items(for: deck, store: store)
            #expect(items.map(\.supplement.point) == ["PCB 存寄存器", "这一页会考", "周五交作业"])
            #expect(items.allSatisfy { $0.recording.title == "Week 4" })
        }
    }

    @Test("叠加到文档上：同一页往下排；再加一次会先去掉旧的；课件原有的批注不动；点批注能找到录音和时间")
    func apply() throws {
        try withFixture { deck, store, _ in
            let document = try #require(PDFDocument(url: deck))
            let own = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .freeText, withProperties: nil)
            own.contents = "我自己的"
            document.page(at: 1)!.addAnnotation(own)

            let items = LectureAnnotations.items(for: deck, store: store)
            #expect(LectureAnnotations.apply(items, to: document) == 3)
            #expect(LectureAnnotations.apply(items, to: document) == 3)
            let page2 = document.page(at: 1)!.annotations.filter { LectureAnnotations.target(of: $0) != nil }
            #expect(page2.count == 2)
            #expect(page2[0].bounds.minY > page2[1].bounds.minY)
            #expect(page2[0].contents?.contains("PCB 存寄存器") == true && page2[0].contents?.contains("01:05") == true)
            let target = try #require(LectureAnnotations.target(of: page2[1]))
            #expect(target.time == 300 && target.recording == items[1].recording.id)

            LectureAnnotations.remove(from: document)
            #expect(document.page(at: 1)!.annotations.map(\.contents) == ["我自己的"])
            #expect(document.page(at: 2)!.annotations.isEmpty)
        }
    }

    @Test("导出带批注的副本：批注和对应的录音时间都在，原文件不变")
    func export() throws {
        try withFixture { deck, store, root in
            let before = try hash(deck)
            let copy = root.appendingPathComponent("copy.pdf")
            try LectureAnnotations.exportCopy(of: deck, items: LectureAnnotations.items(for: deck, store: store), to: copy)
            #expect(try hash(deck) == before)
            let reopened = try #require(PDFDocument(url: copy))
            let notes = (0..<reopened.pageCount).flatMap { reopened.page(at: $0)!.annotations }.compactMap(LectureAnnotations.target(of:))
            #expect(notes.map(\.time).sorted() == [65, 300, 900])
        }
    }
}
