import Foundation

/// 路线图大纲里的一个节点：主题、小节或知识点，带页码范围（从 1 开始，含首尾）。
struct OutlineNode: Codable, Equatable, Sendable {
    var title: String
    var start: Int
    var end: Int
    var children: [OutlineNode] = []

    /// 最多三层：主题、小节、知识点。
    static let maxDepth = 3

    var pages: ClosedRange<Int> { start...end }

    /// 传给网页的格式：`{title, pages: [start, end], children}`。
    var json: [String: Any] {
        ["title": title, "pages": [start, end], "children": children.map(\.json)]
    }
}

/// 路线图用到的进度：哪些页“碰过”。
enum Roadmap {
    /// 1.9 之前的记录没有 `intent`。针对整份课件的快捷操作和“继续生成”都带固定的指令，按显示的标题认出来。
    private static let legacyWholeDeckTitles: Set<String> = [
        "总结整份课件", "Summarize the deck", "梳理知识框架", "Concept map", "出几道练习题", "Quiz me", "继续", "Continue",
    ]

    /// 这条消息算不算在它的页上做过 AI 操作。针对整份课件的操作（总结、知识框架、练习题）和“继续生成”不算；
    /// 认不出来的旧记录按算处理。
    static func countsAsTouch(_ message: ChatMessage) -> Bool {
        guard message.role == .user else { return false }
        if let intent = message.intent {
            return !intent.hasPrefix("quick.") && intent != "continuation"
        }
        // 自由提问没有固定指令（prompt 为空），一定算
        guard message.prompt != nil else { return true }
        return !legacyWholeDeckTitles.contains(message.content)
    }

    /// 碰过的页：发送时正在看的页，加上讲解的目标页。学习记录整理不会删掉消息，整理过的旧对话也算在内。
    static func touchedPages(_ messages: [ChatMessage]) -> Set<Int> {
        var pages = Set<Int>()
        for message in messages where countsAsTouch(message) {
            if let page = message.page { pages.insert(page) }
            if let page = message.explainsPage { pages.insert(page) }
        }
        return pages
    }
}
