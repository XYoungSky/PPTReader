import AppKit
import Observation
import PDFKit

struct ReaderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum ReaderPhase {
    case empty
    case loading(name: String)
    case converting(name: String, app: String)
    case ready(ReaderModel)
    case failed(name: String, message: String)
}

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let library = CourseLibrary()
    let chat: ChatController
    private(set) var phase: ReaderPhase = .empty

    var selectedFile: URL? {
        didSet { if selectedFile != oldValue { openSelectedFile() } }
    }

    @ObservationIgnored private let store = ChatStore()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private static let lastFileKey = "library.lastFile"

    init() {
        chat = ChatController(settings: settings, store: store)
        if let folder = library.recentFolders.first {
            library.open(folder)
            if let last = UserDefaults.standard.string(forKey: Self.lastFileKey),
               last.hasPrefix(folder.path), FileManager.default.fileExists(atPath: last) {
                selectedFile = URL(fileURLWithPath: last)
                openSelectedFile()
            }
        }
    }

    var reader: ReaderModel? {
        if case .ready(let reader) = phase { return reader }
        return nil
    }

    // MARK: - 课程文件夹

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = tr("选择课程文件夹", "Choose a course folder")
        panel.message = tr("只读取，不会修改任何文件", "Read-only — nothing in the folder is changed")
        panel.prompt = tr("打开", "Open")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    func openFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            library.open(url)
        } else if CourseFileKind(fileExtension: url.pathExtension) != nil {
            // 拖入单个文件：打开它所在的文件夹并选中它
            library.open(url.deletingLastPathComponent())
            selectedFile = url
        }
    }

    // MARK: - 打开课件

    func reloadCurrent() {
        openSelectedFile()
    }

    private func openSelectedFile() {
        guard let url = selectedFile else { return }
        guard let kind = CourseFileKind(fileExtension: url.pathExtension), kind != .folder else { return }
        UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
        loadTask?.cancel()
        reader?.close()

        let name = url.lastPathComponent
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var pdfURL = url
                if kind.needsConversion {
                    if let cached = DocumentConverter.cachedPDF(for: url) {
                        pdfURL = cached
                    } else {
                        self.phase = .converting(name: name, app: DocumentConverter.officeAppName(for: kind))
                        pdfURL = try await DocumentConverter.shared.pdf(for: url, kind: kind)
                    }
                } else {
                    self.phase = .loading(name: name)
                }
                guard !Task.isCancelled else { return }

                guard let document = PDFDocument(url: pdfURL) else {
                    throw ReaderError(tr("无法读取这个 PDF，文件可能已损坏。", "Can't read this PDF; it may be damaged."))
                }
                if document.isLocked && !document.unlock(withPassword: "") {
                    throw ReaderError(tr("暂不支持有密码的 PDF。", "Password-protected PDFs aren't supported."))
                }
                let thread = self.store.load(for: url)
                let reader = ReaderModel(sourceURL: url, pdfURL: pdfURL, kind: kind,
                                         document: document, initialPage: thread.lastPage ?? 1)
                reader.onPageChange = { [weak self] page in self?.chat.pageDidChange(page) }
                self.phase = .ready(reader)
                self.chat.attach(reader: reader, thread: thread)
                reader.startTextExtraction()
            } catch {
                guard !Task.isCancelled else { return }
                self.chat.detach()
                self.phase = .failed(name: name, message: error.localizedDescription)
            }
        }
    }

    func openInDefaultApp() {
        guard let url = selectedFile else { return }
        NSWorkspace.shared.open(url)
    }
}
