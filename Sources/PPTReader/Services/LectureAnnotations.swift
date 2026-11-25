import AppKit
import PDFKit

/// 把课堂录音整理出的要点（对应到页的补充要点和课程安排）叠加到课件上，显示成页边的批注。
/// 只加到内存里的 `PDFDocument`，不写回原文件；可以另外导出一份带批注的副本。点批注跳到录音里的那个时间。
enum LectureAnnotations {
    static let author = "PPTReader"
    static let recordingKey = PDFAnnotationKey(rawValue: "/PPTReaderRecording")
    static let timeKey = PDFAnnotationKey(rawValue: "/PPTReaderTime")

    struct Item: Equatable, Sendable {
        var recording: Recording
        var supplement: LectureOrganizer.Supplement
    }

    /// 所有整理结果里对应到这份课件某一页的要点，按页和时间排好。
    static func items(for deck: URL, store: RecordingStore) -> [Item] {
        let path = deck.standardizedFileURL.path
        var result: [Item] = []
        for recording in store.all() {
            guard let organized = store.organized(recording.id) else { continue }
            for item in organized.supplements where item.page != nil {
                guard let itemDeck = item.deck, URL(fileURLWithPath: itemDeck).standardizedFileURL.path == path else { continue }
                result.append(Item(recording: recording, supplement: item))
            }
        }
        return result.sorted { ($0.supplement.page ?? 0, $0.recording.startedAt, $0.supplement.time) < ($1.supplement.page ?? 0, $1.recording.startedAt, $1.supplement.time) }
    }

    /// 先去掉之前加的批注，再按页叠加。返回加了几条。
    @discardableResult
    static func apply(_ items: [Item], to document: PDFDocument) -> Int {
        remove(from: document)
        var perPage: [Int: Int] = [:]
        var added = 0
        for item in items {
            guard let number = item.supplement.page, let page = document.page(at: number - 1) else { continue }
            let index = perPage[number, default: 0]
            perPage[number] = index + 1
            page.addAnnotation(annotation(for: item, on: page, index: index))
            added += 1
        }
        return added
    }

    /// 去掉 PPTReader 加的批注，课件里原有的批注不动。
    static func remove(from document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == author && target(of: annotation) != nil {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// 批注对应的录音和时间；不是 PPTReader 加的批注时为 nil。
    static func target(of annotation: PDFAnnotation) -> (recording: String, time: Double)? {
        guard let id = annotation.value(forAnnotationKey: recordingKey) as? String else { return nil }
        let time = (annotation.value(forAnnotationKey: timeKey) as? NSNumber)?.doubleValue
            ?? (annotation.value(forAnnotationKey: timeKey) as? String).flatMap(Double.init) ?? 0
        return (id, time)
    }

    /// 批注的文字：类型 · 录音标题 · 时间，然后是要点和原话。
    static func contents(for item: Item) -> String {
        let kind = item.supplement.kind == .arrangement ? tr("课程安排", "Course arrangement") : tr("补充要点", "Supplement")
        var text = "\(kind) · \(item.recording.title) · \(LectureOrganizer.clock(item.supplement.time))\n\(item.supplement.point)"
        if !item.supplement.quote.isEmpty { text += "\n“\(item.supplement.quote)”" }
        return text
    }

    /// 导出一份带批注的副本：重新打开原来的 PDF，加上批注后另存，不影响正在显示的文档。
    static func exportCopy(of pdfURL: URL, items: [Item], to destination: URL) throws {
        guard let document = PDFDocument(url: pdfURL) else { throw CocoaError(.fileReadCorruptFile) }
        apply(items, to: document)
        guard document.write(to: destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 页面右上角往下排；一列放不下时往左再排一列。
    private static func annotation(for item: Item, on page: PDFPage, index: Int) -> PDFAnnotation {
        let bounds = page.bounds(for: .cropBox)
        let size: CGFloat = 18, gap: CGFloat = 6, margin: CGFloat = 8
        let perColumn = max(1, Int((bounds.height - margin * 2) / (size + gap)))
        let column = CGFloat(index / perColumn), row = CGFloat(index % perColumn)
        let rect = CGRect(x: bounds.maxX - margin - size - column * (size + gap),
                          y: bounds.maxY - margin - size - row * (size + gap), width: size, height: size)
        let note = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
        note.contents = contents(for: item)
        note.userName = author
        note.iconType = item.supplement.kind == .arrangement ? .key : .comment
        note.color = item.supplement.kind == .arrangement
            ? NSColor(srgbRed: 0.36, green: 0.45, blue: 0.85, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        note.setValue(item.recording.id, forAnnotationKey: recordingKey)
        note.setValue(NSNumber(value: item.supplement.time), forAnnotationKey: timeKey)
        return note
    }
}
