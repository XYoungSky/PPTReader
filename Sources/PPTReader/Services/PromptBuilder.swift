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
        var explanationStyle = ExplanationStyle()
    }

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
        case .question(let text, let selection):
            return ChatMessage(role: .user, content: text, page: page, selection: selection)
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
        // 历史轮次只带界面上显示的简短文字（如“讲解第 5 页”）：完整指令只对当轮有用，
        // 在历史里反复出现会让模型把回答写得越来越像同一个模板，也白占 token。
        parts.append(isCurrent ? message.instruction : message.content)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 系统提示

    static func systemPrompt(_ context: Context) -> String {
        Localizer.shared.isEnglish ? englishSystemPrompt(context) : chineseSystemPrompt(context)
    }

    // 写法说明：
    // - 提示本身用连贯的段落来写，不写成一条条规则。模型会模仿提示的文风，规则清单写多了，回答也会变成清单。
    // - 不给模型套"你是一位××老师"之类的角色，只交代任务、读者和写法。
    // - 讲解方式放在课件文字之后：切换风格时课件这段长前缀不变，服务商的前缀缓存仍能命中；
    //   放在末尾也离学生的问题更近，模型更容易照做。

    private static func chineseSystemPrompt(_ context: Context) -> String {
        """
        学生正在学习课件《\(context.title)》（共 \(context.pageCount) 页），你负责讲解这份课件、回答学生的问题。整份课件逐页提取的文字在后面的 <courseware> 里。

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

        Markdown、LaTeX 公式（行内 $...$，独立公式 $$...$$）、注明语言的代码块、表格，以及 ```svg 和 ```mermaid 代码块，后两种会直接画成图。SVG 要写完整的 <svg> 标签，并带上 viewBox。

        <courseware>
        \(coursewareText(context))
        </courseware>

        \(context.explanationStyle.prompt)
        """
    }

    private static func englishSystemPrompt(_ context: Context) -> String {
        """
        A student is studying the deck "\(context.title)" (\(context.pageCount) pages). Your job is to explain the deck and answer their questions. The text of every page is in <courseware> below.

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

        Markdown, LaTeX (inline $...$, display $$...$$), fenced code blocks with a language, tables, and ```svg and ```mermaid blocks, which are drawn as diagrams. An SVG must be a complete <svg> element with a viewBox.

        <courseware>
        \(coursewareText(context))
        </courseware>

        \(context.explanationStyle.prompt)
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
