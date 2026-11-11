import Foundation

// UI language: English by default, Russian when the system prefers it. Strings live inline as
// L("English", "Русский") pairs next to the code that shows them, so a change touches one line.
// CLI reports pin English; only the app and the widget follow the user's language.

enum Language: String, Sendable {
    case en, ru
}

enum L10n {
    /// Resolved once per process. The self-test, the preview tool and CLI reports pin it.
    nonisolated(unsafe) static var language: Language = resolveLanguage()

    /// Locale for system-formatted text (relative dates) so it matches the chosen language.
    static var locale: Locale { Locale(identifier: language == .ru ? "ru_RU" : "en_US") }
}

/// Override from AI_LIMITS_LANG ("en"/"ru"), then the "language" user default, then the first
/// preferred system language: Russian when it starts with "ru", English for everything else.
func resolveLanguage(environment: [String: String] = ProcessInfo.processInfo.environment,
                     defaults: String? = UserDefaults.standard.string(forKey: "language"),
                     preferred: [String] = Locale.preferredLanguages) -> Language {
    for value in [environment["AI_LIMITS_LANG"], defaults] {
        if let value, let language = Language(rawValue: value.lowercased()) { return language }
    }
    return preferred.first?.lowercased().hasPrefix("ru") == true ? .ru : .en
}

/// The string for the current language.
func L(_ english: String, _ russian: String) -> String {
    L10n.language == .ru ? russian : english
}

/// Runs `body` with the language pinned, then restores it (tests and previews).
func withLanguage<T>(_ language: Language, _ body: () throws -> T) rethrows -> T {
    let saved = L10n.language
    L10n.language = language
    defer { L10n.language = saved }
    return try body()
}

/// Russian noun form for a count: 1 процент, 2 процента, 5 процентов, 21 процент, 11 процентов.
func ruPlural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n = abs(count) % 100
    if (11...14).contains(n) { return many }
    switch n % 10 {
    case 1: return one
    case 2...4: return few
    default: return many
    }
}

/// "47 percent" / "47 процентов", for accessibility labels.
func percentWords(_ value: Int) -> String {
    L("\(value) percent", "\(value) \(ruPlural(value, "процент", "процента", "процентов"))")
}

/// Noun after a token count. Russian takes the genitive plural after "тыс"/"млн" and so on,
/// so only a bare number below a thousand needs the plural rule.
func tokensWord(_ value: Int64) -> String {
    if L10n.language == .en { return value == 1 ? "token" : "tokens" }
    return abs(value) < 1000 ? ruPlural(Int(value), "токен", "токена", "токенов") : "токенов"
}

private let monthsEN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
private let monthsRU = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
private let weekdaysEN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let weekdaysRU = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]

/// "Nov 16" / "16 ноя". `month` is 1...12.
func shortDayMonth(day: Int, month: Int) -> String {
    let index = (max(1, month) - 1) % 12
    return L("\(monthsEN[index]) \(day)", "\(day) \(monthsRU[index])")
}

/// "Fri" / "пт". `weekday` is Calendar's 1 (Sunday) ... 7.
func shortWeekday(_ weekday: Int) -> String {
    let index = (max(1, weekday) - 1) % 7
    return L(weekdaysEN[index], weekdaysRU[index])
}
