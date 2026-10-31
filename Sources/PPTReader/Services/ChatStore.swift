import Foundation

/// 每个课件一份对话记录，保存在 ~/Library/Application Support/PPTReader/Chats。
final class ChatStore {
    private let queue = DispatchQueue(label: "PPTReader.ChatStore", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func fileURL(for sourcePath: String) -> URL {
        AppPaths.chats.appendingPathComponent(AppPaths.hash(sourcePath) + ".json")
    }

    func load(for source: URL) -> ChatThread {
        let path = source.standardizedFileURL.path
        guard let data = try? Data(contentsOf: fileURL(for: path)),
              let thread = try? decoder.decode(ChatThread.self, from: data) else {
            return ChatThread(sourcePath: path)
        }
        return thread
    }

    func save(_ thread: ChatThread) {
        let url = fileURL(for: thread.sourcePath)
        guard let data = try? encoder.encode(thread) else { return }
        queue.async {
            try? data.write(to: url, options: .atomic)
        }
    }
}
