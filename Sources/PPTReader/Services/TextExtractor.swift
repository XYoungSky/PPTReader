import AppKit
import PDFKit
import Vision

/// 逐页提取课件文字；几乎没有文字的页面（扫描件、整页图片）用系统 OCR 识别。
enum TextExtractor {
    /// 少于这个字符数的页面视为需要 OCR。
    private static let ocrThreshold = 20

    static func cached(for pdfURL: URL) -> DocumentText? {
        guard let data = try? Data(contentsOf: cacheURL(for: pdfURL)),
              let text = try? JSONDecoder().decode(DocumentText.self, from: data),
              text.version == DocumentText.currentVersion else { return nil }
        return text
    }

    private static func cacheURL(for pdfURL: URL) -> URL {
        AppPaths.extractedText.appendingPathComponent(AppPaths.fingerprint(of: pdfURL) + ".json")
    }

    private static func save(_ text: DocumentText, for pdfURL: URL) {
        guard let data = try? JSONEncoder().encode(text) else { return }
        try? data.write(to: cacheURL(for: pdfURL), options: .atomic)
    }

    /// - Parameters:
    ///   - priorityPage: 优先 OCR 的页（从 1 开始），由近及远处理。
    ///   - update: 每当有新结果时回调（文字、已 OCR 页数、需 OCR 总页数）。
    static func extract(
        pdfURL: URL,
        priorityPage: Int,
        update: @escaping @Sendable (DocumentText, Int, Int) async -> Void
    ) async {
        if let cached = cached(for: pdfURL) {
            await update(cached, 0, 0)
            return
        }
        // 单独打开一份文档，避免和界面上的 PDFView 争用同一个对象。
        guard let document = PDFDocument(url: pdfURL) else { return }
        var text = DocumentText(pages: (0..<document.pageCount).map { index in
            clean(document.page(at: index)?.string ?? "")
        })

        let needsOCR = text.pages.indices
            .filter { text.pages[$0].filter { !$0.isWhitespace }.count < ocrThreshold }
            .sorted { abs($0 - (priorityPage - 1)) < abs($1 - (priorityPage - 1)) }
        await update(text, 0, needsOCR.count)

        for (done, index) in needsOCR.enumerated() {
            if Task.isCancelled { return }
            guard let page = document.page(at: index) else { continue }
            let recognized = recognize(page)
            if recognized.filter({ !$0.isWhitespace }).count > text.pages[index].filter({ !$0.isWhitespace }).count {
                text.pages[index] = recognized
                text.ocrPages.insert(index)
            }
            if done % 3 == 2 || done == needsOCR.count - 1 {
                await update(text, done + 1, needsOCR.count)
            }
        }
        save(text, for: pdfURL)
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recognize(_ page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0 else { return "" }
        let scale = min(3, 2200 / longest)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
