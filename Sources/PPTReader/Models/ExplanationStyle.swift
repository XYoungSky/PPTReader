import Foundation

/// 讲解风格：每次请求使用当前设置，已生成的回答保持不变。
///
/// 写给模型的是"这一项具体怎么写"，而不是一组偏好开关；
/// 同时明确告诉模型不要在回答里提起这些设置，避免出现"按你的设置，这里不举例"之类的话。
struct ExplanationStyle: Equatable {
    var detail: Detail = .normal
    var diagrams: Diagrams = .normal
    var examples: Examples = .necessary

    enum Detail: String, CaseIterable {
        case concise, normal, detailed

        var title: String {
            switch self {
            case .concise: tr("简洁清晰", "Concise")
            case .normal: tr("正常", "Normal")
            case .detailed: tr("详细", "Detailed")
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
            case .minimal: tr("尽量不用", "Minimal")
            case .normal: tr("正常", "Normal")
            case .frequent: tr("多用 SVG", "More SVG")
            }
        }

        var instruction: String {
            switch self {
            case .minimal:
                tr("图：尽量不画。用文字和公式讲清楚，只有文字实在说不清的结构或几何关系才画。课件里原有的图仍然要讲。",
                   "Diagrams: avoid them. Explain with words and formulas, and only draw when a structure or geometric relationship can't reasonably be put into words. Figures already in the deck still need explaining.")
            case .normal:
                tr("图：需要时画。结构、流程、几何或数量关系画出来明显更好懂时，画一张简洁的 SVG 或 Mermaid 图，并用一两句话说明该看哪里；文字说得清就不画。",
                   "Diagrams: when they help. If a structure, process, geometric or quantitative relationship is clearly easier to see in a picture, draw one clean SVG or Mermaid diagram and say in a sentence or two what to look at. If words do the job, don't draw.")
            case .frequent:
                tr("图：多画。凡是涉及结构、流程、层次、几何或数量关系的内容，都配一张 SVG 或 Mermaid 示意图，并用一两句话说明图里该看什么。图是为了帮助理解，不画装饰性的图。",
                   "Diagrams: use them generously. Whenever the content involves a structure, process, hierarchy, geometric or quantitative relationship, add an SVG or Mermaid diagram and say in a sentence or two what to look at. Diagrams are there to aid understanding, never as decoration.")
            }
        }
    }

    enum Examples: String, CaseIterable {
        case none, necessary, everyConcept

        var title: String {
            switch self {
            case .none: tr("不要例题", "None")
            case .necessary: tr("必要时", "When needed")
            case .everyConcept: tr("每个知识点", "Each concept")
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

    var prompt: String {
        var rules = [detail.instruction, diagrams.instruction, examples.instruction]
        // 只有组合本身有张力时才补充说明，平时不多写一句
        if detail == .concise, let kept = keptDespiteConcise {
            rules.append(tr("简短指的是文字精炼：上面要求的\(kept.zh)仍然要有，只是写得紧凑。",
                            "Short refers to the wording: still include the \(kept.en) asked for above, just keep them compact."))
        }
        return [
            tr("## 学生选的讲解方式", "## How this student wants things explained"),
            "",
            tr("学生在设置里选了下面这些讲解方式，照着写就行，但不要在回答里提到这些设置，比如不要说“按你的设置，这里不举例”。学生在消息里直接提的要求（“详细点”“举个例子”“画个图”“出几道题”等）优先于这些设置。",
               "The student picked the following in their settings. Follow them, but don't mention the settings in your answers (no \"per your settings, I'll skip the example\"). Anything the student asks for directly in a message, such as more detail, an example, a diagram or a quiz, takes precedence."),
            "",
            rules.map { "- " + $0 }.joined(separator: "\n"),
        ].joined(separator: "\n")
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
