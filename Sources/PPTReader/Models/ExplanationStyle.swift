import Foundation

/// 每次请求使用当前偏好，已生成的回答保持不变。
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
                tr("回答简洁清晰，直达重点，保留必要的概念与公式，避免重复和冗长铺垫。",
                   "Be concise and clear: get to the point, keep essential concepts and formulas, and avoid repetition or lengthy introductions.")
            case .normal:
                tr("回答详略适中，讲清核心概念与必要步骤，按理解需要展开。",
                   "Use a balanced level of detail, explaining core concepts and necessary steps as needed for understanding.")
            case .detailed:
                tr("回答详细，逐步解释概念、公式含义和推导过程，补充相关前提与易错点，避免无关扩展。",
                   "Explain in detail: work through concepts, notation and derivations step by step, including relevant prerequisites and common pitfalls without unrelated digressions.")
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
                tr("尽量不用图表，以文字和公式说明；只有文字难以表达时才使用图表。仍需解释课件原有图表。",
                   "Prefer text and formulas over diagrams or tables; use visuals only when text is insufficient. Still explain figures already in the deck.")
            case .normal:
                tr("按内容需要使用图表，仅在有助于理解时添加。",
                   "Use diagrams or tables when they help explain the content.")
            case .frequent:
                tr("多用 SVG 图表说明概念关系、流程与结构；适合可视化的知识点优先配图，并用文字解释图意，避免纯装饰图。",
                   "Use SVG diagrams frequently to explain relationships, processes and structures. Prefer a diagram for ideas suited to visualization, explain it in text, and avoid decorative graphics.")
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
                tr("不要主动添加例题、练习题或示例题解，直接讲解知识本身；课件原有题目仍可解释。",
                   "Do not add worked examples, practice questions or sample solutions unless requested; explain the concepts directly. You may still explain questions already in the deck.")
            case .necessary:
                tr("只在理解知识点确有必要时添加例题，并给出简明解答，不必每次都举例。",
                   "Add worked examples with brief solutions only when needed to understand an idea; examples are not required in every answer.")
            case .everyConcept:
                tr("本次讲解涉及的每个实质知识点都配一道相关例题，包含题目、解题步骤和答案；标题或目录等非知识内容无需凑题。",
                   "Give a relevant worked example for every substantive concept covered, including the question, solution steps and answer. Do not invent exercises for titles or contents pages.")
            }
        }
    }

    var prompt: String {
        """
        \(tr("## 讲解风格偏好", "## Explanation style preferences"))
        - \(detail.instruction)
        - \(diagrams.instruction)
        - \(examples.instruction)
        \(tr("以上偏好适用于自动讲解、手动讲解和后续问答，优先于通用讲解模板中的默认篇幅、配图和例题要求。若学生本次明确要求不同的风格或主动要求举例、出题、画图，以本次明确要求为准。简洁模式下仍需满足所选例题与图表偏好，用精炼文字表达。",
             "Apply these preferences to automatic explanations, manual explanations and follow-up answers, overriding default length, diagram and example requirements in generic teaching templates. If the student explicitly requests a different style, examples, a quiz or a diagram for this turn, follow that request. In concise mode, still honor the selected example and diagram preferences using brief wording."))
        """
    }
}
