import Foundation

/// 生成路线图的大纲：把课件逐页的文字交给“生成路线图大纲”任务的模型，让它输出三层大纲的 JSON。
/// 课件放不下时按页分段生成，再让模型合并一次。
enum RoadmapBuilder {
    /// 每页最多放这么多字。整理结构用不到全文，截断长页能省下不少 token。
    static let pageCharLimit = 1_200
    /// 大纲的 max_tokens 上限：几百页的课件也够用，思考型模型的思考也算在里面。
    static let maxOutput = 16_384
    /// 系统提示和格式说明大约占的 token。
    private static let promptOverhead = 1_500

    enum Failure: LocalizedError, Equatable {
        /// 课件没有提取到文字（扫描件还没识别完，或者全是图片）。
        case noText
        /// 模型的输出读不出大纲。
        case unreadable(truncated: Bool)

        var errorDescription: String? {
            switch self {
            case .noText:
                tr("这份课件没有提取到文字，没法整理大纲。扫描版课件可以等文字识别完成后再试。",
                   "No text was extracted from this deck, so there's nothing to outline. For scanned decks, try again once text recognition finishes.")
            case .unreadable(let truncated):
                truncated
                    ? tr("大纲太长，在输出上限处被截断了。可以在「设置 → 模型 → 按任务选择模型」里给“生成路线图大纲”换一个输出上限更大的模型。",
                         "The outline was cut off at the output limit. In Settings → Model → Models by task, pick a model with a larger output limit for Roadmap outline.")
                    : tr("模型返回的内容不是能读懂的大纲，可以再试一次或换一个模型。",
                         "The model didn't return a readable outline. Try again, or use another model.")
            }
        }
    }

    /// 生成进度：分段时第几段，以及最后的合并。
    enum Stage: Equatable {
        case part(Int, of: Int)
        case merging

        var message: String {
            switch self {
            case .part(_, let total) where total == 1: tr("正在读课件、整理大纲…", "Reading the deck and outlining it…")
            case .part(let index, let total): tr("正在整理第 \(index)/\(total) 段…", "Outlining part \(index) of \(total)…")
            case .merging: tr("正在合并各段大纲…", "Merging the parts…")
            }
        }
    }

    struct Page: Equatable {
        var number: Int
        var text: String
        var tokens: Int
    }

    // MARK: - 请求

    /// 逐页的文字（长页截断），用来组装请求和分段。
    static func pages(_ text: DocumentText) -> [Page] {
        text.pages.enumerated().map { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmed.isEmpty ? tr("（这一页没有提取到文字）", "(no text extracted from this page)") : String(trimmed.prefix(pageCharLimit))
            let block = pageHeader(index + 1) + "\n" + body
            return Page(number: index + 1, text: block, tokens: TokenEstimate.of(block) + 2)
        }
    }

    private static func pageHeader(_ page: Int) -> String {
        tr("【第 \(page) 页】", "[Page \(page)]")
    }

    /// 按顺序把页分成几段，每段的 token 不超过预算（单页超过预算时自成一段）。
    static func chunks(_ pages: [Page], budget: Int) -> [[Page]] {
        var result: [[Page]] = []
        var current: [Page] = []
        var used = 0
        for page in pages {
            if !current.isEmpty, used + page.tokens > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(page)
            used += page.tokens
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 整理一段（或整份）课件的请求。
    static func outlineMessages(title: String, pageCount: Int, pages: [Page], isPart: Bool) -> [[String: Any]] {
        var intro = tr("课件《\(title)》，共 \(pageCount) 页。", "Deck: \"\(title)\", \(pageCount) pages.")
        if isPart, let first = pages.first?.number, let last = pages.last?.number {
            intro += tr("这里只有第 \(first)–\(last) 页，只整理这些页，页码照原样写。",
                        " This is only pages \(first)–\(last); outline just these pages and keep their page numbers.")
        }
        let body = pages.map(\.text).joined(separator: "\n\n")
        return [
            ["role": "system", "content": instructions],
            ["role": "user", "content": intro + "\n\n<courseware>\n" + body + "\n</courseware>"],
        ]
    }

    /// 把分段整理出的几段大纲合并成一份的请求。
    static func mergeMessages(title: String, pageCount: Int, parts: [[OutlineNode]]) -> [[String: Any]] {
        let json = parts.map { part in ["outline": part.map(\.json)] }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "[]"
        let request = tr("""
            课件《\(title)》，共 \(pageCount) 页。课件太长，是按页分成 \(parts.count) 段分别整理的，下面是各段的大纲，按页码顺序排列。请把它们合并成一份完整的大纲：前后两段里属于同一个主题的合成一个，一级主题仍然控制在 3 到 8 个，其余要求不变。

            \(text)
            """, """
            Deck: "\(title)", \(pageCount) pages. The deck was too long, so it was outlined in \(parts.count) parts by page; their outlines are below, in page order. Merge them into one complete outline: combine parts of the same topic that run across two parts, keep 3 to 8 top-level topics, and follow the same rules otherwise.

            \(text)
            """)
        return [["role": "system", "content": instructions], ["role": "user", "content": request]]
    }

    private static var instructions: String {
        tr("""
            你在帮学生整理一份课件的学习路线图。根据逐页提取的课件文字，把课件的结构整理成最多三层的大纲：主题、小节、知识点，每个节点标出对应的页码范围。

            要求：
            - 按页码顺序排列，覆盖所有讲了实际内容的页。封面、目录、致谢这类页不用放进大纲。
            - 一级主题一般 3 到 8 个。往下分到什么程度看内容，一个知识点通常对应 1 到 3 页；简单的部分只分两层也可以。
            - 标题简短具体，一般不超过 12 个字，用课件里的叫法，不写成句子，不加编号。标题用中文；课件是外文时，专业术语可以保留原文。
            - pages 写成 [起始页, 结束页]，页码从 1 开始，只有一页时两个数相同。子节点的范围落在父节点之内，同级节点之间不重叠。
            - 文字是程序从 PDF 里提取的，可能缺了图和公式，按看得出的结构整理就好。
            - 只输出一个 JSON 对象，不要解释，也不要加代码块标记。格式：
            {"outline":[{"title":"主题","pages":[2,9],"children":[{"title":"小节","pages":[2,4],"children":[{"title":"知识点","pages":[2,2],"children":[]}]}]}]}
            """, """
            You're helping a student build a study roadmap for a slide deck. From the text extracted from each page, outline the deck's structure in up to three levels: topics, sections and key points, each with the range of pages it covers.

            Rules:
            - Follow page order and cover every page with real content. Leave out pages like the cover, contents and acknowledgements.
            - Usually 3 to 8 top-level topics. How far to break things down depends on the content; a key point usually spans 1 to 3 pages, and simple parts can stop at two levels.
            - Keep titles short and specific (usually under 6 words), use the deck's own terms, no full sentences and no numbering. Write titles in English, keeping technical terms from other languages where useful.
            - Write pages as [first, last], starting from 1, with both numbers the same for a single page. A child's range falls inside its parent's, and siblings don't overlap.
            - The text was extracted from a PDF by a program and may be missing figures and formulas; outline the structure you can see.
            - Output a single JSON object with no explanation and no code fences, in this format:
            {"outline":[{"title":"Topic","pages":[2,9],"children":[{"title":"Section","pages":[2,4],"children":[{"title":"Key point","pages":[2,2],"children":[]}]}]}]}
            """)
    }

    // MARK: - 解析

    /// 读出模型输出里的大纲。容忍代码块标记、前后的说明文字、顶层直接是数组、页码写成一个数或字符串；
    /// 页码限制在课件范围内，父节点的范围至少覆盖子节点，最多三层。读不出任何节点时返回 nil。
    static func parse(_ output: String, pageCount: Int) -> [OutlineNode]? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = output.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) else { return nil }
        let list = ((json as? [String: Any])?["outline"] as? [Any]) ?? (json as? [Any])
        guard let list else { return nil }
        let result = nodes(list, depth: 1, pageCount: pageCount)
        return result.isEmpty ? nil : result
    }

    private static func nodes(_ list: [Any], depth: Int, pageCount: Int) -> [OutlineNode] {
        list.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let title = ((dict["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let children = depth < OutlineNode.maxDepth
                ? nodes(dict["children"] as? [Any] ?? [], depth: depth + 1, pageCount: pageCount) : []
            var range = pageRange(dict["pages"])
            if let low = children.map(\.start).min(), let high = children.map(\.end).max() {
                range = range.map { (min($0.0, low), max($0.1, high)) } ?? (low, high)
            }
            guard let range else { return nil }
            let first = min(range.0, range.1), last = max(range.0, range.1)
            guard last >= 1, first <= pageCount else { return nil }
            return OutlineNode(title: String(title.prefix(80)), start: max(1, first), end: min(pageCount, last), children: children)
        }
    }

    private static func pageRange(_ value: Any?) -> (Int, Int)? {
        func number(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        if let list = value as? [Any] {
            let numbers = list.compactMap(number)
            guard let first = numbers.first else { return nil }
            return (first, numbers.count > 1 ? numbers[1] : first)
        }
        if let text = value as? String {
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let first = numbers.first else { return nil }
            return (first, numbers.count > 1 ? numbers[1] : first)
        }
        return number(value).map { ($0, $0) }
    }

    // MARK: - 生成

    /// 生成整份课件的大纲。用“生成路线图大纲”任务的模型；用量计入统计。
    @MainActor
    static func generate(text: DocumentText, title: String, pageCount: Int, settings: AppSettings, stats: StatsStore,
                         deck: String, progress: (Stage) -> Void) async throws -> [OutlineNode] {
        let pages = pages(text)
        guard text.pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Failure.noText }
        let config = settings.connection(for: .roadmap)
        let quirks = settings.quirks(config.providerID, config.model)
        let maxOutput = settings.outputCap(config.providerID, config.model, limit: Self.maxOutput)
        // 估算偏低的模型按校准系数缩小预算；输出也占上下文窗口
        let window = Double(settings.contextWindow(config.providerID, config.model)) / (quirks.tokenScale ?? 1)
        let budget = max(4_000, Int(window * settings.contextBudgetPercent) - min(maxOutput, Int(window) / 4) - promptOverhead)
        let parts = chunks(pages, budget: budget)

        func run(_ messages: [[String: Any]]) async throws -> [OutlineNode] {
            let task = try LLMTask(config: config, messages: messages, quirks: quirks, maxOutput: maxOutput, cacheKey: nil)
            let output = try await task.run(stats: stats, deck: deck, task: .roadmap)
            guard let outline = parse(output.text, pageCount: pageCount) else { throw Failure.unreadable(truncated: output.truncated) }
            return outline
        }

        var outlines: [[OutlineNode]] = []
        for (index, part) in parts.enumerated() {
            progress(.part(index + 1, of: parts.count))
            outlines.append(try await run(outlineMessages(title: title, pageCount: pageCount, pages: part, isPart: parts.count > 1)))
        }
        guard outlines.count > 1 else { return outlines[0] }
        progress(.merging)
        do {
            return try await run(mergeMessages(title: title, pageCount: pageCount, parts: outlines))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 合并失败时直接拼起来：主题可能在分段处断开，但页码和结构都还在
            return outlines.flatMap { $0 }
        }
    }
}

/// 大纲缓存：按课件文字的哈希保存，课件不变就不再调用模型；另外按文件指纹存一份，
/// 扫描件的文字识别完成后文字变了，也还能找到之前生成的大纲（需要时可以重新生成）。
struct RoadmapCache {
    let directory: URL

    static var shared: RoadmapCache { RoadmapCache(directory: AppPaths.ensure(AppPaths.support.appendingPathComponent("Roadmaps", isDirectory: true))) }

    struct Keys: Equatable {
        var text: String
        var file: String
    }

    private struct Entry: Codable {
        var version = 1
        var outline: [OutlineNode]
        var createdAt = Date()
    }

    static func keys(text: DocumentText, file: URL) -> Keys {
        Keys(text: "text-" + AppPaths.hash(text.pages.joined(separator: "\u{1}")), file: "file-" + AppPaths.fingerprint(of: file))
    }

    func load(_ keys: Keys) -> [OutlineNode]? {
        for key in [keys.text, keys.file] {
            if let data = try? Data(contentsOf: url(key)), let entry = try? JSONDecoder().decode(Entry.self, from: data),
               !entry.outline.isEmpty {
                return entry.outline
            }
        }
        return nil
    }

    func save(_ outline: [OutlineNode], _ keys: Keys) {
        guard let data = try? JSONEncoder().encode(Entry(outline: outline)) else { return }
        for key in [keys.text, keys.file] { try? data.write(to: url(key), options: .atomic) }
    }

    func remove(_ keys: Keys) {
        for key in [keys.text, keys.file] { try? FileManager.default.removeItem(at: url(key)) }
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }
}
