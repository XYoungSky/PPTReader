import CryptoKit
import Foundation

/// App 自己的数据目录。课程文件夹本身只读，所有生成的数据都放在这里。
enum AppPaths {
    static let appName = "PPTReader"

    static var support: URL { directory(.applicationSupportDirectory) }
    static var caches: URL { directory(.cachesDirectory) }

    static var chats: URL { ensure(support.appendingPathComponent("Chats", isDirectory: true)) }
    static var convertedPDFs: URL { ensure(caches.appendingPathComponent("Converted", isDirectory: true)) }
    static var extractedText: URL { ensure(caches.appendingPathComponent("Text", isDirectory: true)) }

    private static func directory(_ kind: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 由路径、修改时间和大小生成的指纹：文件变化后缓存自动失效。
    static func fingerprint(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return hash("\(url.standardizedFileURL.path)|\(modified)|\(size)")
    }
}
