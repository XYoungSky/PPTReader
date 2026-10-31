import Foundation

/// 课件逐页提取出的文字。
struct DocumentText: Codable, Sendable {
    static let currentVersion = 1

    var version = DocumentText.currentVersion
    var pages: [String]
    /// 通过 OCR 识别得到文字的页（从 0 开始）。
    var ocrPages: Set<Int> = []

    var totalCharacters: Int { pages.reduce(0) { $0 + $1.count } }

    func text(ofPage page: Int) -> String {
        pages.indices.contains(page - 1) ? pages[page - 1] : ""
    }
}
