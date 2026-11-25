import Foundation
import Testing
@testable import PPTReader

/// 路线图：碰过的页、大纲请求的分段、大纲的解析和缓存。
@Suite("路线图")
struct RoadmapTests {
    // MARK: - 碰过的页

    @Test("每种操作都记下类型")
    func intents() {
        let region = PageRegion(page: 4, x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let cases: [(ChatIntent, String)] = [
            (.explainPage(auto: true), "explainPage"),
            (.quick(.explainPage), "explainPage"),
            (.selection(.translate, "x"), "selection.translate"),
            (.region(.explain, region, text: ""), "region.explain"),
            (.question("为什么？", selection: nil), "question"),
            (.quick(.summary), "quick.summary"),
            (.quick(.quiz), "quick.quiz"),
            (.continuation, "continuation"),
        ]
        for (intent, name) in cases {
            #expect(PromptBuilder.userMessage(for: intent, page: 3).intent == name)
        }
    }

    @Test("针对整份课件的操作和“继续”不算碰过，其余都算")
    func touchedPages() {
        let messages = [
            PromptBuilder.userMessage(for: .explainPage(auto: true), page: 2),
            ChatMessage(role: .assistant, content: "……"),
            PromptBuilder.userMessage(for: .selection(.explain, "x"), page: 5),
            PromptBuilder.userMessage(for: .question("这里？", selection: nil), page: 7),
            PromptBuilder.userMessage(for: .quick(.summary), page: 9),
            PromptBuilder.userMessage(for: .quick(.outline), page: 10),
            PromptBuilder.userMessage(for: .quick(.quiz), page: 11),
            PromptBuilder.userMessage(for: .continuation, page: 12),
        ]
        #expect(Roadmap.touchedPages(messages) == [2, 5, 7])
    }

    @Test("1.9 之前的记录没有类型：按固定指令的标题认出整份课件的操作，认不出的算碰过")
    func legacyMessages() {
        func legacy(_ content: String, prompt: String?, page: Int) -> ChatMessage {
            ChatMessage(role: .user, content: content, prompt: prompt, page: page)
        }
        let messages = [
            legacy("总结整份课件", prompt: "总结一下整份课件……", page: 3),
            legacy("Quiz me", prompt: "Write 3 practice questions…", page: 4),
            legacy("继续", prompt: "上一条回答达到长度上限……", page: 5),
            legacy("解释选中内容", prompt: "解释一下我选中的这段……", page: 6),
            // 自由提问没有固定指令，内容碰巧是“继续”也算
            legacy("继续", prompt: nil, page: 8),
        ]
        #expect(Roadmap.touchedPages(messages) == [6, 8])
    }

    @Test("讲解的目标页也算碰过")
    func explainsPage() {
        var message = PromptBuilder.userMessage(for: .explainPage(auto: false), page: 4)
        message.page = 3
        #expect(Roadmap.touchedPages([message]) == [3, 4])
    }

    // MARK: - 请求

    private func text(_ pages: [String]) -> DocumentText { DocumentText(pages: pages) }

    @Test("逐页标出页码，长页截断，没有文字的页说明一下")
    func pageBlocks() {
        let pages = RoadmapBuilder.pages(text(["标题页", String(repeating: "长", count: 5_000), "  "]))
        #expect(pages.map(\.number) == [1, 2, 3])
        #expect(pages[0].text.contains("1") && pages[0].text.contains("标题页"))
        #expect(pages[1].text.count < RoadmapBuilder.pageCharLimit + 20)
        #expect(!pages[2].text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("】"))
    }

    @Test("按预算分段，保持页码顺序；单页超过预算时自成一段")
    func chunks() {
        let pages = (1...10).map { RoadmapBuilder.Page(number: $0, text: "p\($0)", tokens: $0 == 6 ? 500 : 100) }
        let parts = RoadmapBuilder.chunks(pages, budget: 300)
        #expect(parts.map { $0.map(\.number) } == [[1, 2, 3], [4, 5], [6], [7, 8, 9], [10]])
        #expect(RoadmapBuilder.chunks(pages, budget: 10_000).count == 1)
    }

    @Test("分段请求说明是第几页到第几页，合并请求带上各段大纲")
    func requests() throws {
        let pages = RoadmapBuilder.pages(text(["a", "b", "c", "d"]))
        let part = RoadmapBuilder.outlineMessages(title: "Deck", pageCount: 4, pages: Array(pages[2...3]), isPart: true)
        let user = try #require(part.last?["content"] as? String)
        #expect(user.contains("3–4") && user.contains("<courseware>") && user.contains("Deck"))
        #expect(part.first?["role"] as? String == "system")

        let whole = RoadmapBuilder.outlineMessages(title: "Deck", pageCount: 4, pages: pages, isPart: false)
        #expect(!(try #require(whole.last?["content"] as? String)).contains("1–4"))

        let merge = RoadmapBuilder.mergeMessages(title: "Deck", pageCount: 4, parts: [
            [OutlineNode(title: "A", start: 1, end: 2)], [OutlineNode(title: "B", start: 3, end: 4)],
        ])
        let mergeText = try #require(merge.last?["content"] as? String)
        #expect(mergeText.contains("\"A\"") && mergeText.contains("\"B\"") && mergeText.contains("[3,4]"))
    }

    // MARK: - 解析

    @Test("读出三层大纲")
    func parse() throws {
        let output = #"{"outline":[{"title":"进程","pages":[2,9],"children":[{"title":"状态","pages":[5,7],"children":[{"title":"三态模型","pages":[5,5],"children":[]}]}]},{"title":"小结","pages":[10,10]}]}"#
        let outline = try #require(RoadmapBuilder.parse(output, pageCount: 10))
        #expect(outline.map(\.title) == ["进程", "小结"])
        #expect(outline[0].pages == 2...9)
        #expect(outline[0].children[0].children[0] == OutlineNode(title: "三态模型", start: 5, end: 5))
    }

    @Test("容忍代码块标记、前后的说明、顶层数组和各种页码写法")
    func parseLoose() throws {
        let fenced = "好的，大纲如下：\n```json\n[{\"title\":\"A\",\"pages\":[3]},{\"title\":\"B\",\"pages\":\"4-6\"},{\"title\":\"C\",\"pages\":7}]\n```\n希望有帮助。"
        let outline = try #require(RoadmapBuilder.parse(fenced, pageCount: 10))
        #expect(outline.map(\.pages) == [3...3, 4...6, 7...7])
    }

    @Test("页码限制在课件内；倒过来的范围摆正；父节点至少覆盖子节点；超出范围的节点去掉")
    func parseClamps() throws {
        let output = #"{"outline":[{"title":"A","pages":[8,3]},{"title":"B","pages":[9,40]},{"title":"C","pages":[50,60]},{"title":"D","pages":[4,4],"children":[{"title":"d","pages":[2,6]}]}]}"#
        let outline = try #require(RoadmapBuilder.parse(output, pageCount: 12))
        #expect(outline.map(\.title) == ["A", "B", "D"])
        #expect(outline[0].pages == 3...8)
        #expect(outline[1].pages == 9...12)
        #expect(outline[2].pages == 2...6)
    }

    @Test("没写页码的父节点用子节点的范围；超过三层的部分去掉；没有标题的节点去掉")
    func parseStructure() throws {
        let output = #"{"outline":[{"title":"A","children":[{"title":"a","pages":[2,3],"children":[{"title":"x","pages":[2,2],"children":[{"title":"太深","pages":[2,2]}]}]},{"title":"  ","pages":[4,4]}]}]}"#
        let outline = try #require(RoadmapBuilder.parse(output, pageCount: 10))
        #expect(outline[0].pages == 2...3)
        #expect(outline[0].children.count == 1)
        #expect(outline[0].children[0].children[0].children.isEmpty)
    }

    @Test("读不出大纲时返回空", arguments: ["", "抱歉，我无法完成。", #"{"outline":[]}"#, #"{"outline":[{"title":"A"}]}"#, "{not json}"])
    func parseFailure(_ output: String) {
        #expect(RoadmapBuilder.parse(output, pageCount: 10) == nil)
    }

    @Test("传给网页的格式")
    func json() throws {
        let node = OutlineNode(title: "A", start: 2, end: 4, children: [OutlineNode(title: "a", start: 2, end: 2)])
        let json = node.json
        #expect(json["title"] as? String == "A")
        #expect(json["pages"] as? [Int] == [2, 4])
        #expect((json["children"] as? [[String: Any]])?.first?["pages"] as? [Int] == [2, 2])
    }

    // MARK: - 缓存

    @Test("按课件文字或文件指纹都能读到缓存；删除后读不到")
    func cache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RoadmapCache(directory: directory)
        let file = directory.appendingPathComponent("deck.pdf")
        try Data("pdf".utf8).write(to: file)

        let keys = RoadmapCache.keys(text: text(["a", "b"]), file: file)
        let outline = [OutlineNode(title: "A", start: 1, end: 2)]
        #expect(cache.load(keys) == nil)
        cache.save(outline, keys)
        #expect(cache.load(keys) == outline)

        // 文字变了（扫描件识别完成），同一个文件仍然读得到；文件移走了，文字相同也读得到
        let ocr = RoadmapCache.keys(text: text(["a", "b 识别出的文字"]), file: file)
        #expect(ocr.text != keys.text && cache.load(ocr) == outline)
        let moved = RoadmapCache.Keys(text: keys.text, file: "file-elsewhere")
        #expect(cache.load(moved) == outline)

        cache.remove(keys)
        #expect(cache.load(keys) == nil)
    }

    @Test("生成路线图大纲是可以单独设置的任务，建议中等模型")
    func task() {
        #expect(ModelTask.roadmap.isConfigurable)
        #expect(ModelTask.roadmap.strength == .medium)
        #expect(ModelTask(rawValue: "roadmap") == .roadmap)
    }
}
