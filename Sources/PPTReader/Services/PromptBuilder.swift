import Foundation

/// 用户可以触发的讲解动作。
enum ChatIntent {
    case explainPage(auto: Bool)
    case selection(SelectionAction, String)
    /// 框选区域：截图和框内文字一起提问。
    case region(SelectionAction, PageRegion, text: String)
    case question(String, selection: String?, region: PageRegion? = nil)
    case quick(QuickAction)
    /// 上一条回答达到长度上限被截断，接着写。
    case continuation
}

enum SelectionAction: String, CaseIterable {
    case explain, translate, example, ask
}

enum QuickAction: String, CaseIterable {
    case explainPage, summary, outline, quiz

    var title: String {
        switch self {
        case .explainPage: tr("讲解本页", "Explain page")
        case .summary: tr("总结课件", "Summarize")
        case .outline: tr("知识框架", "Concept map")
        case .quiz: tr("练习题", "Quiz me")
        }
    }

    var symbol: String {
        switch self {
        case .explainPage: "sparkles"
        case .summary: "list.bullet.rectangle"
        case .outline: "point.3.connected.trianglepath.dotted"
        case .quiz: "checklist"
        }
    }
}

/// 构造发给模型的消息：系统提示中放入整份课件，用户消息中注明当前页与选中内容。
enum PromptBuilder {
    struct Context {
        var title: String
        var pageCount: Int
        var currentPage: Int
        /// 放进系统提示的课件文字。OCR 进行中只在几个节点更新（见 `ReaderModel.promptText`），系统提示因此保持稳定。
        var text: DocumentText?
        /// 最新提取到的文字；当前页不在系统提示里（或当时还没 OCR 完）时，从这里补进当轮提问。
        var latestText: DocumentText?
        var charLimit: Int
        var historyLimit: Int
        /// 整个请求最多使用的 token 数（模型上下文窗口 × 设置的比例）；为空时不限制。
        var tokenBudget: Int?
        var pageImageJPEG: Data?
        var explanationStyle = ExplanationStyle()
        /// 学习者档案（所有课件通用）。
        var profile = ""
        /// 这门课的课程说明。
        var courseNotes = ""
        /// 较早对话整理成的学习记录。
        var record: String?
        /// 给学习记录预留的 token 数（开启整理时为固定值），让历史预算在生成记录前后保持不变。
        var recordAllowance = 0

        /// 课件固定占预算的四分之三（扣掉写作说明和学习档案），剩下的给历史和当前提问。
        /// 这份预算只取决于设置和档案，不随对话长短变化，系统提示因此保持稳定。
        var coursewareTokenBudget: Int? {
            tokenBudget.map { max(2_000, $0 * 3 / 4 - 3_000 - TokenEstimate.of(profile) - TokenEstimate.of(courseNotes)) }
        }

        /// 历史切块的大小依据：只取决于设置，不随当轮提问的长短、有没有截图变化，切块边界因此不会每轮移动。
        var historyChunkBudget: Int? {
            tokenBudget.map { max(1_000, $0 - (coursewareTokenBudget ?? 0)) }
        }
    }

    /// 组装好的请求消息，以及不含截图的 token 估算（用来计算 max_tokens 和校准估算）。
    struct Request {
        var messages: [[String: Any]]
        var estimatedTokens: Int
        var breakdown = Breakdown()
    }

    /// 一次请求的 token 组成（估算），用于面板上的上下文用量显示（参考 Claude Code 的 /context）。
    struct Breakdown: Equatable {
        var instructions = 0
        var memory = 0
        var courseware = 0
        var record = 0
        var history = 0
        var question = 0
        var image = 0

        var total: Int { instructions + memory + courseware + record + history + question + image }
    }

    /// 学习记录最长保留的字数，超出时截断（提示里要求不超过 600 字，这里留足余量）。
    static let recordCharLimit = 3_000
    /// 开启整理时给学习记录预留的 token 数。
    static let recordAllowance = 2_500

    // MARK: - 指令

    static func userMessage(for intent: ChatIntent, page: Int) -> ChatMessage {
        switch intent {
        case .explainPage(let auto):
            var message = ChatMessage(role: .user, content: tr("讲解第 \(page) 页", "Explain page \(page)"), prompt: explainPrompt(page), page: page)
            message.isAuto = auto
            message.explainsPage = page
            return message
        case .selection(let action, let text):
            let (title, prompt): (String, String) = switch action {
            case .explain: (
                tr("解释选中内容", "Explain selection"),
                tr("解释一下我选中的这段：它是什么意思，为什么这么说，放在这一页和整份课件里起什么作用。",
                   "Explain the passage I selected: what it means, why it's true, and what it's doing on this page and in the deck as a whole."))
            case .translate: (
                tr("翻译选中内容", "Translate selection"),
                tr("把我选中的内容翻译一下（外文译成中文，中文译成英文），直接给译文。公式和专业术语保留原文；有难懂的术语，在译文后面结合课件简单注一下。",
                   "Translate the passage I selected (into English, or into Chinese if it's already English). Give the translation straight away, keeping formulas and technical terms as they are; if any terms are hard to follow, add a short note after the translation using the deck's context."))
            case .example: (
                tr("举例说明选中内容", "Give examples"),
                tr("针对我选中的内容举 1–2 个具体的例子，数值例子、生活里的类比或代码都行，并说明例子和课件里的知识点是怎么对应的。",
                   "Give 1–2 concrete examples of the passage I selected (numbers, an everyday analogy or code all work), and show how each one maps onto the ideas in the deck."))
            case .ask: (
                tr("就选中内容提问", "About the selection"),
                tr("解释一下我选中的这段内容。", "Explain the passage I selected."))
            }
            return ChatMessage(role: .user, content: title, prompt: prompt, page: page, selection: text)
        case .region(let action, let region, let text):
            let (title, prompt): (String, String) = switch action {
            case .explain: (
                tr("解释框选内容", "Explain selected area"),
                tr("解释一下我在课件上框出来的这块内容（图、公式或文字）：它是什么意思，为什么这样，放在这一页和整份课件里起什么作用。",
                   "Explain the area I boxed on the slide (a figure, formula or text): what it means, why it's so, and what it's doing on this page and in the deck as a whole."))
            case .translate: (
                tr("翻译框选内容", "Translate selected area"),
                tr("把我框出来的这块内容翻译一下（外文译成中文，中文译成英文），直接给译文。公式和专业术语保留原文；有难懂的术语，在译文后面结合课件简单注一下。图里的文字也一并翻译。",
                   "Translate the area I boxed (into English, or into Chinese if it's already English). Give the translation straight away, keeping formulas and technical terms as they are; if any terms are hard to follow, add a short note after it using the deck's context. Translate any text inside figures too."))
            case .example: (
                tr("举例说明框选内容", "Examples for selected area"),
                tr("针对我框出来的这块内容举 1–2 个具体的例子，数值例子、生活里的类比或代码都行，并说明例子和课件里的知识点是怎么对应的。",
                   "Give 1–2 concrete examples of the area I boxed (numbers, an everyday analogy or code all work), and show how each one maps onto the ideas in the deck."))
            case .ask: (
                tr("就框选内容提问", "About the selected area"),
                tr("解释一下我框出来的这块内容。", "Explain the area I boxed."))
            }
            return ChatMessage(role: .user, content: title, prompt: prompt, page: region.page,
                               selection: text.isEmpty ? nil : text, region: region)
        case .question(let text, let selection, let region):
            return ChatMessage(role: .user, content: text, page: region?.page ?? page, selection: selection, region: region)
        case .continuation:
            return ChatMessage(role: .user, content: tr("继续", "Continue"), prompt: tr(
                "上一条回答达到长度上限，在中途断开了。从断开的地方直接接着写，不要重复已经写过的内容，也不要加开场白。如果正好断在公式、表格、代码块或图（SVG / Mermaid）的中间，就把这一个公式、表格、代码块或图从头完整地重写一遍。",
                "Your last answer hit the length limit and was cut off. Carry on from exactly where it stopped, without repeating anything or adding an introduction. If it stopped in the middle of a formula, table, code block or diagram (SVG / Mermaid), rewrite that one item in full from the start."), page: page)
        case .quick(let action):
            switch action {
            case .explainPage:
                return userMessage(for: .explainPage(auto: false), page: page)
            case .summary:
                return ChatMessage(role: .user, content: tr("总结整份课件", "Summarize the deck"), prompt: tr(
                    "总结一下整份课件：用分层列表理出主要内容，标出核心概念、重要结论和公式，说明各部分之间怎么联系，并注明页码。",
                    "Summarize the whole deck as a nested list: the main topics, key concepts, results and formulas, and how the parts connect, with page numbers."), page: page)
            case .outline:
                return ChatMessage(role: .user, content: tr("梳理知识框架", "Concept map"), prompt: tr(
                    "帮我理一下整份课件的知识框架。先把各部分的层次和联系展示出来（Mermaid 思维导图、SVG 或分层列表，哪种最清楚用哪种），再说说建议的学习顺序、重点和难点，注明页码。",
                    "Map out how the deck's ideas fit together. First show the parts and how they connect (a Mermaid mind map, an SVG or a nested list, whichever is clearest), then suggest a study order and point out the key and hard parts, with page numbers."), page: page)
            case .quiz:
                return ChatMessage(role: .user, content: tr("出几道练习题", "Quiz me"), prompt: tr(
                    "围绕整份课件出 3 道练习题，侧重第 \(page) 页附近的内容，由浅入深，选择题和计算/简答题都要有。每道题的答案和解析放在题目下面，用 <details><summary>查看答案</summary> … </details> 折叠起来。",
                    "Write 3 practice questions on the deck, focusing on the material around page \(page), from easy to hard, with both multiple choice and calculation/short answer. Put each answer and its explanation right under the question inside <details><summary>Answer</summary> … </details>."), page: page)
            }
        }
    }

    /// 手动和自动讲解共用：不规定固定的段落顺序，详略、图示和例题交给系统提示里的讲解方式。
    private static func explainPrompt(_ page: Int) -> String {
        tr("讲一下第 \(page) 页：这一页在说什么，为什么是这样，关键的公式或图是什么意思。这一页主要是图的话，结合截图来讲；如果只是标题页、目录或过渡页，一两句话带过就行。",
           "Walk me through page \(page): what it's saying, why it's true, and what its key formulas or figures mean. If the page is mostly figures, work from the screenshot; if it's just a title, contents or transition page, a sentence or two is enough.")
    }

    // MARK: - 请求消息
    //
    // 服务商的前缀缓存要求前缀逐字相同（DeepSeek 只有完整匹配此前某次请求留下的前缀单元才算命中），
    // 所以请求按"只追加、不改写"来组织：
    // - 系统提示对同一份课件保持不变；随设置变化的讲解方式放在当轮提问里。
    // - 每条提问发出时的完整文字保存在 `sentText`，之后原样放进历史，不再改写页码标签或换成简短标题。
    //   截图只随当轮发送，它排在文字后面，去掉后前面的文字仍能命中。
    // - 历史超过上限时整块丢掉较早的一段，而不是每轮滑动一条，让前缀能连续几轮保持不变。

    /// 计算历史预算时给当轮提问（文字 + 截图）预留的 token 数。
    static let questionAllowance = 4_000

    static func requestMessages(history: [ChatMessage], context: Context) -> Request {
        let system = systemPrompt(context)
        var result: [[String: Any]] = [["role": "system", "content": system]]
        var estimate = TokenEstimate.of(system) + 4
        guard let current = history.last, current.role == .user else { return Request(messages: result, estimatedTokens: estimate) }

        let text = current.sentText ?? composeText(current, context: context)
        let currentCost = TokenEstimate.of(text) + (context.pageImageJPEG == nil ? 0 : TokenEstimate.image)
        let window = historyWindow(Array(history.dropLast()), limit: context.historyLimit,
                                   tokenBudget: historyBudget(context, system: system, currentCost: currentCost),
                                   chunkBudget: context.historyChunkBudget)
        var breakdown = systemBreakdown(context, system: system)
        for message in window {
            let content = message.role == .user ? (message.sentText ?? legacyText(message)) : message.content
            result.append(["role": message.role.rawValue, "content": content])
            breakdown.history += TokenEstimate.of(content) + 4
        }
        breakdown.question = TokenEstimate.of(text) + 4
        breakdown.image = context.pageImageJPEG == nil ? 0 : TokenEstimate.image
        estimate += breakdown.history + breakdown.question

        if let image = context.pageImageJPEG {
            result.append(["role": "user", "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]],
            ]])
        } else {
            result.append(["role": "user", "content": text])
        }
        return Request(messages: result, estimatedTokens: estimate, breakdown: breakdown)
    }

    /// 历史能用的预算：扣掉系统提示和当轮提问。当轮提问按固定的额度预留（只有特别长时才按实际），
    /// 学习记录也按固定额度预留，这样历史预算不随提问长短、有没有截图、记录长短来回变化，
    /// 保留的起点只会往前推、不会退回去，生成记录前算出的丢弃位置和生成后一致。
    private static func historyBudget(_ context: Context, system: String, currentCost: Int) -> Int? {
        context.tokenBudget.map { budget in
            let record = TokenEstimate.of(recordSection(context))
            let fixed = TokenEstimate.of(system) - record + max(record, context.recordAllowance)
            return max(0, budget - fixed - max(currentCost, Self.questionAllowance))
        }
    }

    private static func systemBreakdown(_ context: Context, system: String) -> Breakdown {
        var breakdown = Breakdown()
        breakdown.memory = TokenEstimate.of(memorySections(context))
        breakdown.courseware = TokenEstimate.of(coursewareText(context))
        breakdown.record = TokenEstimate.of(recordSection(context))
        breakdown.instructions = max(0, TokenEstimate.of(system) + 4 - breakdown.memory - breakdown.courseware - breakdown.record)
        return breakdown
    }

    // MARK: - 学习记录（压缩较早的对话）
    //
    // 参考 Codex 与 Claude Code 的上下文压缩：对话快超出预算时，不直接丢掉最早的一段，
    // 而是先让模型把它整理成一份学习记录，放在系统提示末尾，之后的请求带着记录继续。
    // 整理请求 = 系统提示 + 这些历史 + 一句整理指令，前缀和上一次请求相同，能命中缓存。

    /// 按下一次请求的预算，已有历史中将被丢掉的部分里最后一条有效消息；没有要丢的返回 nil。
    static func lastDroppedMessage(past: [ChatMessage], context: Context) -> ChatMessage? {
        let system = systemPrompt(context)
        let turns = validTurns(past)
        let kept = historyWindow(past, limit: context.historyLimit,
                                 tokenBudget: historyBudget(context, system: system, currentCost: 0),
                                 chunkBudget: context.historyChunkBudget)
        let dropped = turns.count - kept.count
        return dropped > 0 ? turns[dropped - 1] : nil
    }

    /// 整理学习记录的请求：和平常一样的系统提示（含旧记录）与历史，末尾追加整理指令。
    static func recordRequest(past: [ChatMessage], context: Context) -> Request {
        let system = systemPrompt(context)
        var result: [[String: Any]] = [["role": "system", "content": system]]
        var estimate = TokenEstimate.of(system) + 4
        for message in validTurns(past) {
            let content = message.role == .user ? (message.sentText ?? legacyText(message)) : message.content
            result.append(["role": message.role.rawValue, "content": content])
            estimate += TokenEstimate.of(content) + 4
        }
        let instruction = recordInstruction(hasRecord: context.record != nil)
        result.append(["role": "user", "content": instruction])
        estimate += TokenEstimate.of(instruction) + 4
        return Request(messages: result, estimatedTokens: estimate)
    }

    /// 整理指令（参考 Codex 的交接摘要：进展、关键约定、偏好、待办），按辅导场景改写。
    private static func recordInstruction(hasRecord: Bool) -> String {
        let merge = hasRecord
            ? tr("系统提示末尾已有一份较早的学习记录，把它和之后的对话合并成一份新的，其中仍然有用的内容不要丢。\n",
                 "There is an earlier study record at the end of the system prompt. Merge it with the conversation since into one new record, keeping whatever in it is still useful.\n")
            : ""
        return tr("""
            【整理学习记录】这一条不是学生的提问。请把到目前为止的辅导过程整理成一份学习记录。它会替代上面较早的对话，交给之后接着辅导这位学生的人使用，所以只写之后讲解真正用得上的内容：
            - 已经讲过哪些页和概念，各讲到什么程度（注明页码）；
            - 讲解中用过的例子、类比和约定的记号，之后要保持一致；
            - 学生问过什么，在哪里卡住或理解错了，练习题答得怎样；
            - 学生明确提出的要求和偏好；
            - 还没讲完、或答应之后再讲的内容。
            \(merge)用简洁的分条列表，总共不超过 600 字。直接输出记录本身，不要开场白和结尾，也不用遵循上面的讲解方式。
            """, """
            [Study record] This is not a question from the student. Write up the tutoring so far as a study record. It will replace the earlier conversation above and be handed to whoever continues tutoring this student, so include only what later explanations will actually need:
            - which pages and ideas have been covered, and how far (with page numbers);
            - examples, analogies and notation used, which should stay consistent;
            - what the student asked, where they got stuck or confused, and how they did on practice questions;
            - requests and preferences the student stated;
            - anything left unfinished or promised for later.
            \(merge)Use a concise bulleted list of at most 400 words. Output only the record, with no introduction or closing, and ignore the explanation style above.
            """)
    }

    /// 系统提示末尾的学习记录。
    private static func recordSection(_ context: Context) -> String {
        guard let record = context.record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty else { return "" }
        let intro = tr("前面较早的对话已整理成下面这份学习记录，之后的对话接着它继续。讲解时和记录里的进度、例子、记号保持一致，不用向学生提起这份记录。",
                       "The earlier part of the conversation has been condensed into the study record below, and the conversation continues from it. Stay consistent with its progress, examples and notation, and don't mention the record to the student.")
        return "\n\n<study_record>\n\(intro)\n\n\(String(record.prefix(recordCharLimit)))\n</study_record>"
    }

    /// 学习者档案和课程说明，放在写作说明之后、课件之前：从通用到具体（参考 CLAUDE.md / AGENTS.md 的分层），
    /// 同一门课的不同课件共用这一段前缀。
    private static func memorySections(_ context: Context) -> String {
        var parts: [String] = []
        let profile = context.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isEmpty {
            parts.append(tr("## 关于学生\n\n学生自己写的背景和目标，据此把握讲解的深浅和侧重：\n\n",
                            "## About the student\n\nThe student's own background and goals; use them to pitch the depth and focus of explanations:\n\n") + profile)
        }
        let notes = context.courseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append(tr("## 课程说明\n\n学生为这门课记下的说明（例如老师强调的重点、记号约定、考试范围），讲这门课的所有课件时都适用：\n\n",
                            "## Course notes\n\nNotes the student keeps for this course (such as what the lecturer stresses, notation, exam scope). They apply to every deck in the course:\n\n") + notes)
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n\n"
    }

    /// 一条提问实际发给模型的文字：页码、选中内容、指令和讲解方式。发出时保存，之后原样用作历史。
    static func composeText(_ message: ChatMessage, context: Context) -> String {
        var parts: [String] = []
        if let page = message.page {
            parts.append(tr("【我正在看第 \(page) / \(context.pageCount) 页】", "[I'm on page \(page) of \(context.pageCount)]"))
        }
        if let page = message.page, let supplement = pageSupplement(page, context: context) {
            parts.append(supplement)
        }
        if let region = message.region {
            parts.append(regionText(region, selection: message.selection, hasImage: context.pageImageJPEG != nil))
        } else if let selection = message.selection, !selection.isEmpty {
            let page = message.page ?? context.currentPage
            parts.append(tr("【我在第 \(page) 页选中的内容】", "[Selected on page \(page)]") + "\n\(selection)")
        }
        parts.append(message.instruction)
        parts.append(context.explanationStyle.block)
        return parts.joined(separator: "\n\n")
    }

    /// 框选区域：说明位置，有截图时提示截图附在后面，再附上框内文字。
    /// 没有截图（模型不支持识图或关闭了截图）时只靠框内文字。
    static func regionText(_ region: PageRegion, selection: String?, hasImage: Bool) -> String {
        let percent = { (value: Double) in Int((value * 100).rounded()) }
        let position = tr("（位置：从左 \(percent(region.x))%、从上 \(percent(region.y))%，宽 \(percent(region.width))%、高 \(percent(region.height))%）",
                          " (position: \(percent(region.x))% from left, \(percent(region.y))% from top, \(percent(region.width))% wide, \(percent(region.height))% tall)")
        var lines = [tr("【我在第 \(region.page) 页框选的区域】", "[Area I boxed on page \(region.page)]") + position]
        if hasImage { lines.append(tr("框内的截图附在这条消息后面。", "A screenshot of the area is attached after this message.")) }
        let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            lines.append(tr("框内的文字：", "Text inside the box:") + "\n" + text)
        } else if !hasImage {
            lines.append(tr("（框内没有可提取的文字，可能是图片。）", "(No text could be extracted from the box; it may be an image.)"))
        }
        return lines.joined(separator: "\n")
    }

    /// 当前页的文字不在系统提示里时（课件太长被省略，或 OCR 在系统提示定下来之后才完成），补进这条提问。
    /// 提问发出后原样保存为历史，所以补进来的文字之后也能命中缓存。
    private static func pageSupplement(_ page: Int, context: Context) -> String? {
        let index = page - 1
        let latest = (context.latestText ?? context.text)?.text(ofPage: page) ?? ""
        guard !latest.isEmpty else { return nil }
        if let text = context.text, !text.text(ofPage: page).isEmpty, includedPages(context).contains(index) { return nil }
        return tr("【第 \(page) 页的文字】", "[Text of page \(page)]") + "\n" + String(latest.prefix(6_000))
    }

    /// 1.6 之前保存的提问没有原文：按固定格式重建，保证每次请求得到相同的文字。
    private static func legacyText(_ message: ChatMessage) -> String {
        var parts: [String] = []
        if let page = message.page {
            parts.append(tr("【当时在看第 \(page) 页】", "[I was on page \(page)]"))
        }
        if let selection = message.selection, !selection.isEmpty, let page = message.page {
            parts.append(tr("【我在第 \(page) 页选中的内容】", "[Selected on page \(page)]") + "\n\(selection)")
        }
        parts.append(message.content)
        return parts.joined(separator: "\n\n")
    }

    /// 携带的历史：跳过出错的轮次；超过条数上限或 token 预算时，按"半个上限"为一块整块丢弃最早的轮次，
    /// 起点只在丢弃时才移动，前缀能连续几轮保持不变。
    /// - Parameter chunkBudget: 决定切块大小的稳定预算（为空时用 tokenBudget）。
    static func historyWindow(_ past: [ChatMessage], limit: Int, tokenBudget: Int? = nil, chunkBudget: Int? = nil) -> [ChatMessage] {
        let turns = validTurns(past)
        let limit = max(0, limit) / 2 * 2
        guard limit > 0, !turns.isEmpty else { return [] }
        let step = max(2, limit / 4 * 2)
        var drop = turns.count > limit ? (turns.count - limit + step - 1) / step * step : 0
        if let tokenBudget {
            drop = max(drop, tokenDrop(turns, budget: tokenBudget, chunkBudget: chunkBudget ?? tokenBudget))
        }
        return Array(turns.dropFirst(drop))
    }

    /// 能作为历史发送的轮次：一问一答成对，跳过出错或没有内容的回答。
    static func validTurns(_ past: [ChatMessage]) -> [ChatMessage] {
        var turns: [ChatMessage] = []
        var index = 0
        while index < past.count {
            let message = past[index]
            if message.role == .user, index + 1 < past.count, past[index + 1].role == .assistant {
                let reply = past[index + 1]
                if reply.error == nil && !reply.content.isEmpty {
                    turns.append(message)
                    turns.append(reply)
                }
                index += 2
            } else {
                index += 1
            }
        }
        return turns
    }

    /// 超出 token 预算时从哪里开始保留。按累计 token 把历史切成大约半个（稳定）预算一块，
    /// 块的边界只由更早的消息和设置决定，追加新消息、当轮提问长短变化时都不会移动；取能放进本轮预算的最早一个边界。
    /// 这样一次丢掉约半个预算的旧对话，之后能连续几轮保持同样的前缀。
    private static func tokenDrop(_ turns: [ChatMessage], budget: Int, chunkBudget: Int) -> Int {
        let costs = turns.map { message in
            TokenEstimate.of(message.role == .user ? (message.sentText ?? legacyText(message)) : message.content) + 4
        }
        var suffix = Array(repeating: 0, count: costs.count + 1)
        for index in costs.indices.reversed() { suffix[index] = suffix[index + 1] + costs[index] }
        guard suffix[0] > budget else { return 0 }

        let chunk = max(1, chunkBudget / 2)
        var boundaries = [0]
        var cumulative = 0
        var mark = chunk
        for index in stride(from: 0, to: costs.count, by: 2) {
            if cumulative >= mark {
                boundaries.append(index)
                while mark <= cumulative { mark += chunk }
            }
            cumulative += costs[index] + (index + 1 < costs.count ? costs[index + 1] : 0)
        }
        return boundaries.first { suffix[$0] <= budget } ?? costs.count
    }

    // MARK: - 系统提示

    static func systemPrompt(_ context: Context) -> String {
        Localizer.shared.isEnglish ? englishSystemPrompt(context) : chineseSystemPrompt(context)
    }

    // 写法说明：
    // - 提示本身用连贯的段落来写，不写成一条条规则。模型会模仿提示的文风，规则清单写多了，回答也会变成清单。
    // - 不给模型套"你是一位××老师"之类的角色，只交代任务、读者和写法。
    // - 系统提示里不放任何随设置或翻页变化的内容（讲解方式附在每条提问末尾），整段对同一份课件逐字不变。
    // - 课件标题、页数和课件文字都放在最后，前面的写作说明对所有课件逐字相同，换一份课件时这一段也能命中缓存。

    private static func chineseSystemPrompt(_ context: Context) -> String {
        """
        学生正在学习一份课件，你负责讲解这份课件、回答学生的问题。课件的标题和逐页提取的文字在最后的 <courseware> 里。

        ## 怎么写

        读的人是正在学这门课的学生，理解力没问题，只是对这些内容还不熟。所以要用完整的句子，句与句之间有逻辑上的衔接，让人能顺着思路一步步读下去。用词平实具体，能用一个具体的数、一个具体的情形说明的，就别停在抽象的概括上。专业术语照常用，第一次出现时让人明白它指什么。语气就是平常说话的语气，不用“非常重要”“极其关键”这类词来强调；一件事重不重要，讲清楚了自然看得出来。

        一开头就说正事。第一句就把最重要的意思说出来，再展开为什么、怎么来的。不复述问题，不用“好的”“这是个好问题”“我们来看一下”开场，也不要先来一句“这一页主要讲了……”。讲完就停，不加“总结一下”“一句话总结”“希望对你有帮助”“有问题随时问”之类的结尾，也不要把刚说过的内容再概括一遍。篇幅跟着问题走：随口问的小问题，几句话答清楚就够了；讲一整页或一个难点，才需要展开。

        排版是为了好读。默认写段落。内容本身就是并列的几项时（几个步骤、几个条件、几种情况的对比）才用列表，一段连贯的推理不要拆成一条条要点。短回答不用标题；长讲解确实分成几个部分时，可以用 ### 小标题。加粗只留给个别需要一眼看到的词。不用 emoji，不用彩色文字。

        有些写法用多了，文字就像是模板生成的，尽量避开：硬凑的“首先……其次……最后……”；“值得注意的是”“需要指出的是”“本质上”“核心在于”这类空转的过渡语；为了显得深刻反复使用“不是……而是……”；大量破折号；生硬、不贴切的比喻；“小贴士”“记忆口诀”这类附加栏目。偶尔自然地用到没关系，只是别拿它们凑字数、撑结构。

        准确比漂亮重要。公式出现时，说清楚每个符号代表什么、整个式子在说什么。推导的关键步骤要说明为什么成立，不要用“显然”“易得”带过。不确定就直说。可以补充课件以外的知识，但符号和术语要和课件一致，也不要把课件没写的内容说成课件里写的。

        ## 上下文

        <courseware> 里的文字是程序从 PDF 中提取的，可能丢了版式、图片和部分公式符号；标着 OCR 的页面来自图像识别，可能有错字。碰到明显的提取错误，结合截图和上下文理解就好，不用照抄，也不用特意指出来。

        学生的每条消息前面会标出当时在看第几页，有时还附带选中的文字或这一页的截图。这些是背景：问题和这一页有关，就结合这一页讲；无关就直接回答，不用硬扯回这一页。讲某一页时，如果它用到了前面的结论，或者在为后面的内容做准备，在确实有帮助的地方提一句即可，不写泛泛的“承上启下”。

        提到页码时写“第 N 页”，界面会把它变成可以点击跳转的链接。用简体中文回答，专业术语第一次出现时可以附上英文原词。

        ## 界面能显示什么

        Markdown、LaTeX 公式（行内 $...$，独立公式 $$...$$）、注明语言的代码块、表格，以及 ```svg 和 ```mermaid 代码块，后两种会直接画成图。比较几种情况、列出几组对应关系时，表格往往比段落清楚。

        ## 怎么画图

        图是讲解的一部分：画在它要说明的那段文字旁边，再用一两句话说明图里该看什么。流程、层次和概念之间的关系适合用 Mermaid；函数图像、几何关系、向量、电路、数据结构这类示意图用 SVG。

        SVG 写成完整的 <svg> 放进 ```svg 代码块，带上 viewBox，宽度在 480 到 720 之间，四周留出 16 左右的边距。图总是显示在白色背景上，文字和线条用深色（#1f1e1d、#5e5c56）；需要区分的部分从橙 #d97757、蓝 #4a7bb7、绿 #5b9a68、黄 #c99a2e 里选，填充用对应的浅色 #fbeae3、#e6eef8、#e7f2e9、#f8f0dc。文字用 font-family="-apple-system, PingFang SC, sans-serif"，字号 13 到 16，不要压在线条或别的文字上；坐标轴、箭头和关键的点都标上名字，箭头用 <marker> 定义。SVG 里的文字不会渲染 LaTeX，简单的式子写成 x²、θ、Σ 这样的 Unicode，复杂的公式写在图外面。不要用 <foreignObject>、脚本、外部图片或字体。

        Mermaid 的节点文字尽量短；文字里有括号、引号、冒号等符号时，用双引号把整段文字包起来，例如 A["f(x) 的导数"]。

        ## 讲解方式

        学生每条消息的末尾附有【讲解方式】：学生在设置里选的篇幅、图和例题，有时还有学生自己写的要求，以最新一条消息里的为准。照着写就行，但不要在回答里提到这些设置，比如不要说“按你的设置，这里不举例”。学生自己写的要求和前面几项冲突时，以学生自己写的为准；学生在消息正文里直接提的要求（“详细点”“举个例子”“画个图”“出几道题”等）优先于整个【讲解方式】。

        \(memorySections(context))## 课件

        《\(context.title)》，共 \(context.pageCount) 页。

        <courseware>
        \(coursewareText(context))
        </courseware>\(recordSection(context))
        """
    }

    private static func englishSystemPrompt(_ context: Context) -> String {
        """
        A student is studying a slide deck. Your job is to explain the deck and answer their questions. The deck's title and the text of every page are in <courseware> at the end.

        ## How to write

        The reader is a student taking this course: quick to understand, just new to this material. So write in full, connected sentences that let them follow the reasoning one step at a time. Use plain, concrete words, and when a specific number or case can show the idea, use it rather than staying abstract. Use technical terms as needed, but make each one clear the first time it appears. Keep an ordinary speaking tone. Don't lean on words like "crucial" or "extremely important"; if something matters, a clear explanation will show it.

        Start with substance. Put the most important point in the first sentence, then explain why and where it comes from. Don't restate the question, don't open with "Great question" or "Let's take a look", and don't begin with "This page is about…". Stop when you're done: no "In summary", "Key takeaway", "Hope this helps" or "Feel free to ask", and no recap of what you just said. Let the length follow the question. A quick question gets a few sentences; a whole page or a hard idea gets more room.

        Formatting is there to make things easier to read. Default to paragraphs. Use a list only when the content really is a set of parallel items (steps, conditions, cases being compared), and don't chop a line of reasoning into bullets. Short answers need no headings; a long explanation with distinct parts can use ### headings. Save bold for the occasional term that needs to stand out. No emoji, no colored text.

        Some habits make writing read as machine-generated, so steer clear of them: forced "First… Second… Finally…" scaffolding; filler transitions like "It's worth noting that" or "At its core"; reaching for "It's not X, it's Y" to sound insightful; lots of em dashes; analogies that don't quite fit; add-on sections like "Pro tip" or "Mnemonic". One of these now and then, where it's natural, is fine. Just don't use them as padding or scaffolding.

        Accuracy matters more than polish. When a formula appears, say what each symbol stands for and what the formula as a whole is saying. In a derivation, explain why the key steps hold instead of writing "clearly" or "it easily follows". If you're unsure, say so. You can bring in knowledge beyond the deck, but keep its notation and terminology, and never present something as being in the deck when it isn't.

        ## Context

        The text in <courseware> was extracted from a PDF by a program, so layout, images and some math symbols may be missing; pages marked OCR came from image recognition and may contain typos. Read through obvious extraction errors using the screenshot and surrounding text. There's no need to copy them or point them out.

        Each student message starts with the page they were on, and sometimes includes text they selected or a screenshot of the page. That's background. If the question is about that page, use it; if not, just answer the question without dragging the page in. When a page relies on an earlier result or sets up something later, mention it where it actually helps, and skip generic "this builds on… and leads into…" lines.

        Write page references as "page N"; the interface turns them into links that jump to the page. Answer in English.

        ## What the interface can display

        Markdown, LaTeX (inline $...$, display $$...$$), fenced code blocks with a language, tables, and ```svg and ```mermaid blocks, which are drawn as diagrams. When comparing cases or listing correspondences, a table is often clearer than a paragraph.

        ## Drawing diagrams

        A diagram is part of the explanation: put it next to the text it illustrates and say in a sentence or two what to look at. Processes, hierarchies and relationships between ideas suit Mermaid; function graphs, geometry, vectors, circuits, data structures and other schematics suit SVG.

        Write an SVG as a complete <svg> inside a ```svg block, with a viewBox, a width between 480 and 720 and about 16 of margin on every side. Diagrams are always shown on a white background, so use dark text and lines (#1f1e1d, #5e5c56). To tell parts apart, pick from orange #d97757, blue #4a7bb7, green #5b9a68 and yellow #c99a2e, with the matching light fills #fbeae3, #e6eef8, #e7f2e9 and #f8f0dc. Use font-family="-apple-system, Helvetica, sans-serif" at 13 to 16, and keep text off lines and other labels. Label axes, arrows and key points, and define arrowheads with <marker>. Text inside an SVG can't render LaTeX: write simple expressions in Unicode (x², θ, Σ) and put complex formulas outside the diagram. Don't use <foreignObject>, scripts, external images or fonts.

        Keep Mermaid node text short, and wrap it in double quotes whenever it contains brackets, quotes or colons, e.g. A["derivative of f(x)"].

        ## Explanation style

        Each student message ends with an [Explanation style] block: the length, diagram and example settings the student chose, sometimes followed by their own requests. The block in the latest message is the one that counts. Follow it, but don't mention it in your answers (no "per your settings, I'll skip the example"). Where the student's own requests conflict with the other items, their own requests win; anything the student asks for in the body of a message, such as more detail, an example, a diagram or a quiz, takes precedence over the whole block.

        \(memorySections(context))## The deck

        "\(context.title)", \(context.pageCount) pages.

        <courseware>
        \(coursewareText(context))
        </courseware>\(recordSection(context))
        """
    }

    /// 系统提示里放入了哪些页（从 0 开始）。课件放得下就全放；放不下时从中心页向两侧扩展，直到用完预算。
    /// 中心按步长取整，在附近翻页时摘取的范围（也就是系统提示）保持不变，前缀缓存不会因翻页失效。
    /// 步长不超过窗口能容纳页数的一半，当前页几乎总在窗口里；万一不在，由 `pageSupplement` 补进提问，
    /// 而不是改成以当前页为中心（那样每翻一页系统提示都会变）。
    static func includedPages(_ context: Context) -> Set<Int> {
        guard let pages = context.text?.pages, !pages.isEmpty else { return [] }
        // 每页的开销：字数受「课件文字上限」约束，token 数受上下文上限约束
        let costs = pages.map { PageCost(chars: $0.count + 20, tokens: TokenEstimate.of($0) + 8) }
        let budget = PageCost(chars: context.charLimit, tokens: context.coursewareTokenBudget ?? .max)
        let total = costs.reduce(PageCost(chars: 0, tokens: 0)) { PageCost(chars: $0.chars + $1.chars, tokens: $0.tokens + $1.tokens) }
        if total.chars <= budget.chars && total.tokens <= budget.tokens { return Set(pages.indices) }

        let fraction = min(Double(budget.chars) / Double(max(total.chars, 1)), Double(budget.tokens) / Double(max(total.tokens, 1)))
        let capacity = max(1, Int(Double(pages.count) * fraction))
        let step = max(1, min(max(5, pages.count / 10), capacity / 2))
        let current = min(max(context.currentPage - 1, 0), pages.count - 1)
        let snapped = min((current + step / 2) / step * step, pages.count - 1)
        return window(around: snapped, costs: costs, budget: budget)
    }

    private static func coursewareText(_ context: Context) -> String {
        guard let text = context.text else {
            return tr("（课件文字仍在提取中，暂时无法提供。）", "(The deck's text is still being extracted.)")
        }
        guard !text.pages.isEmpty else {
            return tr("（没有提取到课件文字。）", "(No text could be extracted from the deck.)")
        }
        let pages = text.pages
        let included = includedPages(context)

        var lines: [String] = []
        var omittedStart: Int?
        func closeOmitted(before index: Int) {
            guard let start = omittedStart else { return }
            let range = start == index - 1 ? "\(start + 1)" : "\(start + 1)–\(index)"
            lines.append(tr("=== 第 \(range) 页（篇幅所限，内容省略）===", "=== Page \(range) (omitted for length) ==="))
            omittedStart = nil
        }
        for (index, page) in pages.enumerated() {
            guard included.contains(index) else {
                if omittedStart == nil { omittedStart = index }
                continue
            }
            closeOmitted(before: index)
            let tag = text.ocrPages.contains(index) ? " (OCR)" : ""
            lines.append(tr("=== 第 \(index + 1) 页\(tag) ===", "=== Page \(index + 1)\(tag) ==="))
            lines.append(page.isEmpty ? tr("（此页没有可提取的文字，可能是图片或图表）", "(No extractable text; probably images or charts.)") : page)
        }
        closeOmitted(before: pages.count)
        return lines.joined(separator: "\n")
    }

    private struct PageCost {
        var chars: Int
        var tokens: Int
    }

    /// 以 center 为中心向前后两侧依次加页，某一侧放不下下一页就停下；中心页总会放入。
    private static func window(around center: Int, costs: [PageCost], budget: PageCost) -> Set<Int> {
        var included: Set<Int> = [center]
        var remaining = PageCost(chars: budget.chars - costs[center].chars, tokens: budget.tokens - costs[center].tokens)
        func take(_ index: Int) -> Bool {
            guard costs.indices.contains(index),
                  costs[index].chars <= remaining.chars, costs[index].tokens <= remaining.tokens else { return false }
            included.insert(index)
            remaining.chars -= costs[index].chars
            remaining.tokens -= costs[index].tokens
            return true
        }
        var low = center - 1, high = center + 1
        var lowOpen = true, highOpen = true
        while lowOpen || highOpen {
            if lowOpen { if take(low) { low -= 1 } else { lowOpen = false } }
            if highOpen { if take(high) { high += 1 } else { highOpen = false } }
        }
        return included
    }
}

/// 粗略估算 token 数（没有各家的分词器）：中日韩文字约 0.6 个 token，其余字符约 0.3 个；
/// 一张页面截图按 2000 个计。只用于控制上下文不超出模型窗口，上限比例本身也留了余量。
enum TokenEstimate {
    static let image = 2_000

    static func of(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: wide += 1
            default: narrow += 1
            }
        }
        return (wide * 6 + narrow * 3 + 9) / 10
    }

    /// 例如 860、128K、1M。
    static func label(_ tokens: Int) -> String {
        if tokens < 1_000 { return "\(max(tokens, 0))" }
        if tokens >= 1_000_000 {
            let value = Double(tokens) / 1_000_000
            return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + "M"
        }
        let k = tokens % 1024 == 0 ? tokens / 1024 : Int((Double(tokens) / 1000).rounded())
        return "\(k)K"
    }
}
