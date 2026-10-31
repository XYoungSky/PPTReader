import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }
}

/// 界面语言。文案成对写在代码里：`tr("中文", "English")`，切换后界面立即刷新。
@Observable
final class Localizer: @unchecked Sendable {
    static let shared = Localizer()
    private static let key = "ui.language"

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
    }

    var isEnglish: Bool {
        switch language {
        case .zh: false
        case .en: true
        case .system: !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }

    /// 传给讲解网页的语言代码。
    var code: String { isEnglish ? "en" : "zh" }
}

func tr(_ zh: String, _ en: String) -> String {
    Localizer.shared.isEnglish ? en : zh
}
