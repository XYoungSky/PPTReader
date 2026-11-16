import Foundation

/// 讲解风格：每次请求使用当前设置，已生成的回答保持不变。
///
/// 写给模型的是"这一项具体怎么写"，而不是一组偏好开关；
/// 同时明确告诉模型不要在回答里提起这些设置，避免出现"按你的设置，这里不举例"之类的话。
///
/// 1.6 起这段要求附在每次提问的末尾（见 `PromptBuilder`），而不是写进系统提示：
/// 对话越长，系统提示末尾的要求离当前问题越远，模型越容易忘记画图、举例；
/// 系统提示也因此对同一份课件保持不变，服务商的前缀缓存更容易命中。
struct ExplanationStyle: Equatable {
    var detail: Detail = .normal
    var diagrams: Diagrams = .normal
    var examples: Examples = .necessary
    /// 学生自己写的额外要求，附在几项选择之后。
    var custom = ""

    static let customLimit = 600

    enum Detail: String, CaseIterable {
        case concise, normal, detailed

        var title: String {
            switch self {
            case .concise: tr("简洁", "Concise")
            case .normal: tr("适中", "Balanced")
            case .detailed: tr("详细", "Detailed")
            }
        }

        /// 设置页中对当前选项的说明。
        var summary: String {
            switch self {
            case .concise: tr("只讲核心意思和用得上的公式，一般两三段", "Core idea and the formulas that matter, usually two or three paragraphs")
            case .normal: tr("核心概念讲透，难点多写，简单处从简", "Explain the core ideas properly; more words on the hard parts")
            case .detailed: tr("讲清为什么、每个符号和推导步骤，补上前提知识", "Why it works, every symbol and step, plus the prerequisites")
            }
        }

        var instruction: String {
            switch self {
            case .concise:
                tr("篇幅：简短。只讲最核心的意思和真正用得上的公式，一般两三段就够。省掉背景铺垫，同一个意思不要换个说法再说一遍。",
                   "Length: short. Cover the core idea and the formulas that actually matter, usually in two or three paragraphs. Skip the background, and don't say the same thing twice in different words.")
            case .normal:
                tr("篇幅：适中。把核心概念讲透，必要的推导和前提点到为止。简单的地方写短，难的地方多花些笔墨。",
                   "Length: moderate. Explain the core ideas properly and touch on the derivations and prerequisites that are needed. Keep the easy parts short and spend the words on the hard ones.")
            case .detailed:
                tr("篇幅：详细。多讲为什么：这个概念为什么要引入，每个符号代表什么，推导的每一步凭什么成立，再补上需要的前提知识和容易理解错的地方。详细是讲得更深，不是更啰嗦，每一段都应该带来新的东西。",
                   "Length: detailed. Spend more time on why: why the concept is introduced, what each symbol stands for, why each step of a derivation holds, plus the prerequisites and the places people commonly get wrong. Detailed means deeper, not wordier; every paragraph should add something new.")
            }
        }
    }

    enum Diagrams: String, CaseIterable {
        case minimal, normal, frequent

        var title: String {
            switch self {
            case .minimal: tr("少用", "Few")
            case .normal: tr("适中", "Balanced")
            case .frequent: tr("多用", "Many")
            }
        }

        var summary: String {
            switch self {
            case .minimal: tr("用文字和公式讲，文字说不清的结构才画", "Words and formulas; draw only when words can't do it")
            case .normal: tr("讲解页面或难点时，能画出来的关系就配一张图", "Add a diagram when a page or hard idea has something drawable")
            case .frequent: tr("每次讲解至少一张图，结构、流程、图像都画出来", "At least one diagram per explanation; draw structures, processes, graphs")
            }
        }

        var instruction: String {
            switch self {
            case .minimal:
                tr("图：尽量不画。用文字和公式讲清楚，只有文字实在说不清的结构或几何关系才画。课件里原有的图仍然要讲。",
                   "Diagrams: avoid them. Explain with words and formulas, and only draw when a structure or geometric relationship can't reasonably be put into words. Figures already in the deck still need explaining.")
            case .normal:
                tr("图：讲解一页、一个概念或一段推导时，只要里面有能画出来的东西（结构、流程、层次、函数图像、几何或数量关系），就画一张 SVG 或 Mermaid 图，并用一两句话说明该看哪里。随口问的小问题、纯粹的定义或翻译不用画。",
                   "Diagrams: when explaining a page, a concept or a derivation, draw one SVG or Mermaid diagram whenever there's something drawable in it (a structure, process, hierarchy, function graph, geometric or quantitative relationship), and say in a sentence or two what to look at. Quick questions, plain definitions and translations don't need one.")
            case .frequent:
                tr("图：多画。每次讲解至少配一张 SVG 或 Mermaid 图，只有标题页、目录这类没有实质内容的情况除外；内容里有几个不同的结构、流程、函数图像、几何或数量关系时，分别配图。每张图用一两句话说明该看哪里。图是为了帮助理解，不画装饰性的图。",
                   "Diagrams: draw generously. Every explanation gets at least one SVG or Mermaid diagram, except for title or contents pages with no real content; when the material has several distinct structures, processes, graphs, geometric or quantitative relationships, give each its own diagram. Say in a sentence or two what to look at in each. Diagrams are there to aid understanding, never as decoration.")
            }
        }
    }

    enum Examples: String, CaseIterable {
        case none, necessary, everyConcept

        var title: String {
            switch self {
            case .none: tr("不出", "None")
            case .necessary: tr("需要时", "When useful")
            case .everyConcept: tr("每个知识点", "Every concept")
            }
        }

        var summary: String {
            switch self {
            case .none: tr("直接讲知识本身，课件里原有的题照常讲", "Explain the ideas directly; problems in the deck are still covered")
            case .necessary: tr("具体算一遍明显更好懂时举一道", "One worked example when a calculation would make it click")
            case .everyConcept: tr("每个实质性的知识点后面跟一道例题", "A worked example after every substantive concept")
            }
        }

        var instruction: String {
            switch self {
            case .none:
                tr("例题：不主动出例题或练习题，直接讲知识本身；课件里原有的题目照常讲。讲解中顺手带一个具体的数或一句话的小例子没问题，只是不要展开成完整的例题。",
                   "Worked examples: don't add worked examples or practice problems; explain the ideas directly. Problems already in the deck still get explained. Dropping in a concrete number or a one-line example along the way is fine, as long as it doesn't grow into a full worked example.")
            case .necessary:
                tr("例题：需要时举。一个具体的计算或应用能明显帮助理解时，在相关内容讲完后举一道，写出关键步骤和结果；不必每次都举。",
                   "Worked examples: when they help. If a concrete calculation or application would clearly make an idea click, add one after explaining the idea, with the key steps and the result. Not every answer needs one.")
            case .everyConcept:
                tr("例题：每个实质性的知识点都配一道例题，紧跟在这个知识点讲完之后，写清题目、关键步骤和答案。例题要贴合课件的内容和符号；标题页、目录这类没有知识点的内容不用配。",
                   "Worked examples: give a worked example for every substantive concept, right after explaining it, with the problem, the key steps and the answer. Keep examples true to the deck's content and notation; title or contents pages need none.")
            }
        }
    }

    /// 设置页「自定义要求」下方的快捷短语，点按后追加到文本末尾。
    static var customSuggestions: [(title: String, text: String)] {
        [
            (tr("术语附英文", "Bilingual terms"), tr("专业术语第一次出现时附上英文原词。", "Give the Chinese term alongside each technical term the first time it appears.")),
            (tr("多用类比", "Analogies"), tr("抽象的概念先用一个贴切的生活类比引入，再讲严格的定义。", "Introduce abstract ideas with a fitting everyday analogy before the formal definition.")),
            (tr("推导写完整", "Full derivations"), tr("公式推导不要跳步，每一步写出依据。", "Don't skip steps in derivations; justify each one.")),
            (tr("联系考试", "Exam focus"), tr("讲完后指出这部分常见的考法和容易丢分的地方。", "After explaining, point out how this is usually examined and where marks are commonly lost.")),
            (tr("先给结论", "Conclusion first"), tr("先用一两句话给出结论，再展开解释。", "State the conclusion in a sentence or two first, then explain.")),
        ]
    }

    var trimmedCustom: String {
        String(custom.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.customLimit))
    }

    /// 附在每次提问末尾的讲解方式。系统提示里说明了这段内容的用法和优先级。
    var block: String {
        var rules = [detail.instruction, diagrams.instruction, examples.instruction]
        // 只有组合本身有张力时才补充说明，平时不多写一句
        if detail == .concise, let kept = keptDespiteConcise {
            rules.append(tr("简短指的是文字精炼：上面要求的\(kept.zh)仍然要有，只是写得紧凑。",
                            "Short refers to the wording: still include the \(kept.en) asked for above, just keep them compact."))
        }
        var lines = [tr("【讲解方式】", "[Explanation style]")] + rules.map { "- " + $0 }
        let custom = trimmedCustom
        if !custom.isEmpty {
            lines.append(tr("- 学生自己写的要求：", "- The student's own requests: ") + custom.replacingOccurrences(of: "\n", with: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// 简洁模式下仍要保留的内容：只列出实际选了"多用"的那几项。
    private var keptDespiteConcise: (zh: String, en: String)? {
        switch (diagrams == .frequent, examples == .everyConcept) {
        case (true, true): ("图和例题", "diagrams and worked examples")
        case (true, false): ("图", "diagrams")
        case (false, true): ("例题", "worked examples")
        case (false, false): nil
        }
    }
}
