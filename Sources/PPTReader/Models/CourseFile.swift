import Foundation

enum CourseFileKind: Sendable {
    case folder
    case pdf
    case slides
    case document

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "ppt", "pptx", "pps", "ppsx", "pptm": self = .slides
        case "doc", "docx", "rtf", "docm": self = .document
        default: return nil
        }
    }

    /// 需要先借助 Office 转换为 PDF 的类型。
    var needsConversion: Bool { self == .slides || self == .document }
}

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: CourseFileKind
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isFolder: Bool { kind == .folder }

    /// 展平后的所有文件（不含文件夹），用于搜索。
    var allFiles: [FileNode] {
        guard let children else { return [self] }
        return children.flatMap(\.allFiles)
    }
}
