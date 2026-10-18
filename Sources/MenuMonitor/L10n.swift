import Foundation

/// In-app language setting (independent of the app bundle's localizations).
enum LanguageSetting: String, CaseIterable, Identifiable {
    case system, en, zh
    var id: String { rawValue }

    static var current: LanguageSetting {
        LanguageSetting(rawValue: UserDefaults.standard.string(forKey: SettingsKey.language) ?? "") ?? .system
    }

    /// Concrete UI language after resolving 跟随系统 / Follow System.
    var resolved: AppLanguage {
        switch self {
        case .en: return .en
        case .zh: return .zh
        case .system: return AppLanguage.systemPreferred
        }
    }

    var title: String {
        switch self {
        case .system: return L("Follow System", "跟随系统")
        case .en: return "English"
        case .zh: return "中文"
        }
    }
}

enum AppLanguage: String {
    case en, zh

    static var current: AppLanguage { LanguageSetting.current.resolved }

    /// Chinese if the first preferred system language is zh-*, else English.
    static var systemPreferred: AppLanguage {
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("zh") ? .zh : .en
    }

    func tr(_ en: String, _ zh: String) -> String {
        self == .zh ? zh : en
    }
}

/// Localize with the current in-app language: `L("Quick Clean", "快速清理")`.
func L(_ en: String, _ zh: String) -> String {
    AppLanguage.current.tr(en, zh)
}
