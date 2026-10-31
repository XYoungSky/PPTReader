import Foundation
import Observation

/// 只读地扫描课程文件夹，列出其中可阅读的课件。
@MainActor
@Observable
final class CourseLibrary {
    private static let recentKey = "library.recentFolders"
    nonisolated private static let maxDepth = 8

    private(set) var rootURL: URL?
    private(set) var nodes: [FileNode] = []
    private(set) var isScanning = false
    private(set) var recentFolders: [URL] = []

    init() {
        recentFolders = (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var fileCount: Int { nodes.reduce(0) { $0 + ($1.isFolder ? $1.allFiles.count : 1) } }

    func open(_ url: URL) {
        rootURL = url
        recentFolders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentFolders.insert(url, at: 0)
        recentFolders = Array(recentFolders.prefix(8))
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: Self.recentKey)
        refresh()
    }

    func refresh() {
        guard let root = rootURL else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let nodes = Self.scan(root, depth: 0)
            await MainActor.run {
                guard self.rootURL == root else { return }
                self.nodes = nodes
                self.isScanning = false
            }
        }
    }

    func node(for url: URL) -> FileNode? {
        func find(_ nodes: [FileNode]) -> FileNode? {
            for node in nodes {
                if node.url == url { return node }
                if let children = node.children, let hit = find(children) { return hit }
            }
            return nil
        }
        return find(nodes)
    }

    nonisolated private static func scan(_ directory: URL, depth: Int) -> [FileNode] {
        guard depth < maxDepth else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var folders: [FileNode] = []
        var files: [FileNode] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values?.isHidden == true || name.hasPrefix("~$") || name.hasPrefix(".") { continue }
            if values?.isDirectory == true {
                guard values?.isPackage != true, values?.isSymbolicLink != true else { continue }
                let children = scan(url, depth: depth + 1)
                if !children.isEmpty { folders.append(FileNode(url: url, kind: .folder, children: children)) }
            } else if let kind = CourseFileKind(fileExtension: url.pathExtension) {
                files.append(FileNode(url: url, kind: kind))
            }
        }
        let byName: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }
}
