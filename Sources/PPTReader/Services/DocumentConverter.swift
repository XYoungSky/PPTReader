import AppKit
import Foundation

enum ConversionError: LocalizedError {
    case appMissing(String)
    case notAuthorized(String)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .appMissing(let app):
            tr("需要安装 \(app)", "\(app) is required to open this file")
        case .notAuthorized(let app):
            tr("请在「系统设置 › 隐私与安全性 › 自动化」中允许 PPTReader 控制 \(app)",
               "Allow PPTReader to control \(app) in System Settings › Privacy & Security › Automation")
        case .failed(let message):
            tr("转换失败：", "Conversion failed: ") + message
        case .timedOut:
            tr("转换超时，请检查 Office 是否弹出了对话框", "Conversion timed out — check whether Office is showing a dialog")
        }
    }
}

/// 借助本机已安装的 PowerPoint / Word 把课件转成 PDF。
/// 先把原文件复制到 Office 自己的沙盒目录再打开，课程文件夹不会出现任何改动（包括锁文件）。
actor DocumentConverter {
    static let shared = DocumentConverter()

    private struct OfficeApp {
        let name: String
        let bundleID: String
        let script: String
    }

    private static let powerPoint = OfficeApp(
        name: "Microsoft PowerPoint",
        bundleID: "com.microsoft.Powerpoint",
        script: """
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            tell application id "com.microsoft.Powerpoint"
                open POSIX file inPath
                set pres to active presentation
                save pres in POSIX file outPath as save as PDF
                close pres saving no
            end tell
        end run
        """
    )

    private static let word = OfficeApp(
        name: "Microsoft Word",
        bundleID: "com.microsoft.Word",
        script: """
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            tell application id "com.microsoft.Word"
                open POSIX file inPath
                repeat 60 times
                    if (count of documents) > 0 then exit repeat
                    delay 0.5
                end repeat
                save as active document file name outPath file format format PDF
                close active document saving no
            end tell
        end run
        """
    )

    /// 同一时间只驱动一次 Office，避免“当前演示文稿”混淆。
    private var queue: Task<Void, Never>?

    static func cachedPDF(for source: URL) -> URL? {
        let url = cacheURL(for: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func cacheURL(for source: URL) -> URL {
        AppPaths.convertedPDFs.appendingPathComponent(AppPaths.fingerprint(of: source) + ".pdf")
    }

    static func officeAppName(for kind: CourseFileKind) -> String {
        kind == .slides ? powerPoint.name : word.name
    }

    func pdf(for source: URL, kind: CourseFileKind) async throws -> URL {
        if let cached = Self.cachedPDF(for: source) { return cached }
        let previous = queue
        let job = Task { () throws -> URL in
            _ = await previous?.value
            if let cached = Self.cachedPDF(for: source) { return cached }
            return try await self.convert(source, app: kind == .slides ? Self.powerPoint : Self.word)
        }
        queue = Task { _ = await job.result }
        return try await job.value
    }

    private func convert(_ source: URL, app: OfficeApp) async throws -> URL {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil else {
            throw ConversionError.appMissing(app.name)
        }

        // Office 是沙盒应用，它自己的容器目录总是可读写的。
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(app.bundleID)/Data/tmp/PPTReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let copy = container.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        let output = container.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        defer {
            if !wasRunning {
                Task.detached { _ = try? await Self.runAppleScript("tell application id \"\(app.bundleID)\" to quit", arguments: [], timeout: 20) }
            }
        }

        do {
            _ = try await Self.runAppleScript(app.script, arguments: [copy.path, output.path], timeout: 240)
        } catch ConversionError.failed(let message) where message.contains("-1743") || message.contains("Not authorized") {
            throw ConversionError.notAuthorized(app.name)
        }

        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.failed(tr("\(app.name) 没有生成 PDF", "\(app.name) produced no PDF"))
        }
        let destination = Self.cacheURL(for: source)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: output, to: destination)
        return destination
    }

    private static func runAppleScript(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.components(separatedBy: "\n").flatMap { ["-e", $0] } + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        if proc.terminationStatus == 0 {
                            continuation.resume(returning: out)
                        } else {
                            continuation.resume(throwing: ConversionError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: ConversionError.failed(error.localizedDescription))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ConversionError.timedOut
            }
            defer {
                if process.isRunning { process.terminate() }
                group.cancelAll()
            }
            return try await group.next()!
        }
    }
}
