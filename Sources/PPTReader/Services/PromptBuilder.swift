import Foundation

/// 用户可以触发的讲解动作。
enum ChatIntent {
    case explainPage(auto: Bool)
    case selection(SelectionAction, String)
    case question(String, selection: String?)
    case quick(QuickAction)
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
        var text: DocumentText?
        var charLimit: Int
        var historyLimit: Int
        var pageImageJPEG: Data?
    }

    // MARK: - 指令

    static func userMessage(for intent: ChatIntent, page: Int) -> ChatMessage {
        switch intent {
        case .explainPage(let auto):
            var message = ChatMessage(role: .user, content: tr("讲解第 \(page) 页", "Explain page \(page)"), prompt: auto ? autoExplainPrompt(page) : explainPrompt(page), page: page)
            message.isAuto = auto
            message.explainsPage = page
            return message
        case .selection(let action, let text):
            let (title, prompt): (String, String) = switch action {
            case .explain: (
                tr("解释选中内容", "Explain selection"),
                tr("请解释我选中的这段内容：结合它所在的页面和整份课件的上下文，说明它的含义、在知识体系中的作用，必要时给出推导或例子。",
                   "Explain the selected passage: using its page and the whole deck as context, say what it means and how it fits in, with a derivation or example if helpful."))
            case .translate: (
                tr("翻译选中内容", "Translate selection"),
                tr("请翻译我选中的内容（外文译成中文，中文译成英文）。保留公式与专业术语原文，并对难懂的术语结合课件上下文做简短注释。",
                   "Translate the selected passage (into English, or into Chinese if it is already English). Keep formulas and technical terms intact and briefly gloss difficult terms using the deck's context."))
            case .example: (
                tr("举例说明选中内容", "Give examples"),
                tr("请针对我选中的内容举 1–2 个具体例子（数值例子、生活类比或代码均可），并说明例子与课件知识点的对应关系。",
                   "Give 1–2 concrete examples (numbers, an analogy or code) for the selected passage and show how they map to the ideas in the deck."))
            case .ask: (
                tr("就选中内容提问", "About the selection"),
                tr("请解释我选中的这段内容。", "Explain the selected passage."))
            }
            return ChatMessage(role: .user, content: title, prompt: prompt, page: page, selection: text)
        case .question(let text, let selection):
            return ChatMessage(role: .user, content: text, page: page, selection: selection)
        case .quick(let action):
            switch action {
            case .explainPage:
                return userMessage(for: .explainPage(auto: false), page: page)
            case .summary:
                return ChatMessage(role: .user, content: tr("总结整份课件", "Summarize the deck"), prompt: tr(
                    "请总结整份课件：用分层列表梳理主要内容，标出核心概念、重要结论与公式，说明各部分之间的联系，并注明对应的页码。",
                    "Summarize the whole deck as a nested list: main topics, key concepts, results and formulas, how the parts connect, with page numbers."), page: page)
            case .outline:
                return ChatMessage(role: .user, content: tr("梳理知识框架", "Concept map"), prompt: tr(
                    "请为整份课件梳理知识框架：先用一个 mermaid 图（flowchart 或 mindmap）画出知识结构，再简要说明建议的学习顺序、重点和难点，并注明对应页码。",
                    "Map out the deck's concepts: first draw the structure as a mermaid diagram (flowchart or mindmap), then briefly suggest a study order and the key and hard parts, with page numbers."), page: page)
            case .quiz:
                return ChatMessage(role: .user, content: tr("出几道练习题", "Quiz me"), prompt: tr(
                    "请围绕整份课件（侧重第 \(page) 页附近的内容）出 3 道练习题，由浅入深，题型包含选择题与计算/简答题。每道题的答案与解析放在该题下方，用 <details><summary>查看答案</summary> … </details> 折叠起来。",
                    "Write 3 practice questions on the deck (focusing around page \(page)), from easy to hard, mixing multiple choice and calculation/short answer. Put each answer and explanation right under its question inside <details><summary>Answer</summary> … </details>."), page: page)
            }
        }
    }

    private static func explainPrompt(_ page: Int) -> String {
        tr("""
        请讲解第 \(page) 页。
        1. 先用一两句话说明这一页在整份课件中的位置与作用（承接了什么、为后面什么做铺垫）；
        2. 逐条讲清这一页的核心概念、公式或图示：公式要解释每个符号的含义，必要时给出推导；
        3. 给出一个帮助理解的例子或类比；
        4. 如果这一页主要是图片或图表，结合截图与上下文说明它想表达的内容。
        """, """
        Explain page \(page).
        1. In a sentence or two, place this page within the deck (what it builds on, what it sets up).
        2. Go through its key concepts, formulas or figures: define every symbol and derive where useful.
        3. Give one example or analogy that makes it click.
        4. If the page is mostly images or charts, use the screenshot and context to explain what it shows.
        """)
    }

    private static func autoExplainPrompt(_ page: Int) -> String {
        tr("请简明讲解第 \(page) 页：说明它与前后内容的联系，突出核心知识点和关键公式，控制在 400 字左右。如果这一页只是标题页、目录或过渡页，用一两句话带过即可。",
           "Briefly explain page \(page): how it connects to what comes before and after, its key ideas and formulas, in about 200 words. If it is just a title, contents or transition page, one or two sentences are enough.")
    }

    // MARK: - 请求消息

    static func requestMessages(history: [ChatMessage], context: Context) -> [[String: Any]] {
        var result: [[String: Any]] = [["role": "system", "content": systemPrompt(context)]]
        guard let current = history.last, current.role == .user else { return result }

        // 历史中跳过出错的轮次，只保留最近若干条
        var turns: [ChatMessage] = []
        var index = 0
        let past = Array(history.dropLast())
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
        turns = Array(turns.suffix(max(0, context.historyLimit) / 2 * 2))

        for message in turns {
            switch message.role {
            case .user:
                result.append(["role": "user", "content": userText(message, context: context, isCurrent: false)])
            case .assistant:
                result.append(["role": "assistant", "content": message.content])
            }
        }

        let text = userText(current, context: context, isCurrent: true)
        if let image = context.pageImageJPEG {
            result.append(["role": "user", "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]],
            ]])
        } else {
            result.append(["role": "user", "content": text])
        }
        return result
    }

    private static func userText(_ message: ChatMessage, context: Context, isCurrent: Bool) -> String {
        var parts: [String] = []
        if let page = message.page {
            parts.append(isCurrent
                ? tr("【我正在看第 \(page) / \(context.pageCount) 页】", "[I'm on page \(page) of \(context.pageCount)]")
                : tr("【当时在看第 \(page) 页】", "[I was on page \(page)]"))
        }
        if let selection = message.selection, !selection.isEmpty {
            let page = message.page ?? context.currentPage
            parts.append(tr("【我在第 \(page) 页选中的内容】", "[Selected on page \(page)]") + "\n\(selection)")
        }
        if isCurrent, context.pageImageJPEG != nil {
            parts.append(tr("（附上了当前页的截图）", "(A screenshot of the current page is attached.)"))
        }
        parts.append(message.instruction)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 系统提示

    static func systemPrompt(_ context: Context) -> String {
        Localizer.shared.isEnglish ? englishSystemPrompt(context) : chineseSystemPrompt(context)
    }

    private static func chineseSystemPrompt(_ context: Context) -> String {
        """
        你是一位耐心、严谨的大学课程助教，正在陪学生学习课件《\(context.title)》（共 \(context.pageCount) 页）。

        ## 你掌握的材料
        <courseware> 中是整份课件逐页提取出的文字；学生提问时可能还会附上当前页的截图。注意：
        - 文字由程序从 PDF 中提取，可能丢失版式、图片和部分公式符号；标注「OCR」的页面来自图像识别，可能有错字；
        - 遇到明显的提取错误，请结合截图和上下文理解，不要照抄错误；课件中没有的内容可以用你的知识补充，但要和课件的符号、术语保持一致。

        ## 讲解原则
        - 始终以整份课件为背景：讲解某一页或某段选中内容时，要联系它在整份课件中的位置、前置知识与后续内容，而不是孤立地解释片段；
        - 学生的每条消息开头都会注明他正在看的页码，以及（如果有）他选中的文字；
        - 先讲直觉，再讲严谨定义与推导；重要概念配合具体例子；
        - 提到课件页码时写成「第 N 页」，学生可以点击跳转；
        - 使用简体中文回答，专业术语可以附上英文原词。

        ## 输出格式（界面支持完整渲染）
        - 使用 Markdown：标题、列表、表格、引用、代码块（注明语言）；
        - 数学公式使用 LaTeX：行内用 $...$，独立公式用 $$...$$；
        - 需要示意图时，可以输出 ```svg 代码块（会直接渲染成图形，请写完整的 <svg> 并带 viewBox），或 ```mermaid 流程图/思维导图；
        - 可以用 HTML 行内样式强调重点，例如 <span style="color:#d9480f">重点</span>、<mark>高亮</mark>；
        - 回答结构清晰、详略得当，不要寒暄。

        <courseware>
        \(coursewareText(context))
        </courseware>
        """
    }

    private static func englishSystemPrompt(_ context: Context) -> String {
        """
        You are a patient, rigorous university teaching assistant helping a student study the deck "\(context.title)" (\(context.pageCount) pages).

        ## Your material
        <courseware> holds the text extracted from every page of the deck; the student's message may also include a screenshot of the current page. Note:
        - The text was extracted from a PDF and may have lost layout, images and some math symbols; pages marked "OCR" come from image recognition and may contain typos;
        - Read through obvious extraction errors using the screenshot and context instead of repeating them; you may add knowledge beyond the deck, but keep its notation and terminology.

        ## How to teach
        - Always use the whole deck as context: when explaining a page or a selected passage, connect it to where it sits in the deck, what it builds on and what follows — never explain a fragment in isolation;
        - Each student message starts with the page they are viewing and, if any, the text they selected;
        - Start with intuition, then give precise definitions and derivations; pair important ideas with concrete examples;
        - Refer to pages as "page N" so the student can click to jump there;
        - Answer in English.

        ## Output format (fully rendered)
        - Markdown: headings, lists, tables, quotes, fenced code blocks with a language;
        - Math in LaTeX: inline $...$, display $$...$$;
        - For diagrams, output a ```svg block (rendered as an image; write a complete <svg> with a viewBox) or a ```mermaid flowchart/mindmap;
        - Inline HTML styling is allowed for emphasis, e.g. <span style="color:#d9480f">key point</span>, <mark>highlight</mark>;
        - Be well structured and to the point; no small talk.

        <courseware>
        \(coursewareText(context))
        </courseware>
        """
    }

    private static func coursewareText(_ context: Context) -> String {
        guard let text = context.text, !text.pages.isEmpty else {
            return tr("（课件文字仍在提取中，暂时无法提供。）", "(The deck's text is still being extracted.)")
        }
        let pages = text.pages
        var included = Set<Int>()
        if text.totalCharacters <= context.charLimit {
            included = Set(pages.indices)
        } else {
            // 课件过长：从当前页向两侧扩展，直到用完字符预算
            var budget = context.charLimit
            let center = min(max(context.currentPage - 1, 0), pages.count - 1)
            var offset = 0
            while budget > 0, offset < pages.count {
                for index in Set([center - offset, center + offset]) where pages.indices.contains(index) {
                    guard budget > 0 else { break }
                    included.insert(index)
                    budget -= pages[index].count + 20
                }
                offset += 1
            }
        }

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
}
