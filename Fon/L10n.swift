import Foundation

/// Язык интерфейса: «Авто» (по языку телефона: русский — русский, иначе английский), русский или английский.
/// Выбор меняется в ⚙ → «Язык» и действует после перезапуска приложения (подписи создаются при запуске).
enum AppLanguage: Int, CaseIterable {
    case auto, ru, en

    var title: String {
        switch self {
        case .auto: return "Auto / Авто"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// Язык, на котором приложение работает сейчас (выбирается один раз при запуске).
    static let current: AppLanguage = {
        switch AppLanguage(rawValue: UserDefaults.standard.integer(forKey: "language")) ?? .auto {
        case .ru: return .ru
        case .en: return .en
        case .auto:
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("ru") ? .ru : .en
        }
    }()
}

extension Settings {
    static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.integer(forKey: "language")) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
}

/// Перевод строки интерфейса: ключ — русский текст (он же показывается на русском), английский — в `L10nTable`.
/// Нет перевода — остаётся русский текст.
func tr(_ ru: String) -> String {
    guard AppLanguage.current == .en else { return ru }
    return L10nTable.en[ru] ?? ru
}
