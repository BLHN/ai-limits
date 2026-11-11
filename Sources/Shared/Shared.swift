import Foundation
import SwiftUI
import Darwin

let limitsWidgetKind = "AILimitsAllAccounts"

// The widget receives read permission for only this host-produced, sanitized file.
// getpwuid resolves the real home rather than the extension's sandbox container.
var publishedSnapshotURL: URL {
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AILimits/widget-snapshot.json")
}

struct PublishedAccount: Codable {
    let id: String
    let name: String
    /// "codex" or "claude". Optional so a file published by an older host still decodes.
    let type: String?
    let usage: Usage?
    // Optional so a file published by an older host still decodes.
    let models: [ModelQuota]?
    let billingAnchor: String?
}

/// The widget cannot read accounts.json (sandbox), so the snapshot carries everything it shows.
struct PublishedSnapshot: Codable {
    let accounts: [PublishedAccount]
    init(rows: [AccountRow]) {
        accounts = rows.map {
            PublishedAccount(id: $0.id, name: $0.name, type: $0.kind.rawValue, usage: $0.usage,
                             models: $0.models, billingAnchor: $0.billingAnchor)
        }
    }
    var displayRows: [AccountRow] {
        accounts.map {
            // Older files have no type: the usage provider or the legacy id still tells.
            let kind = $0.type.flatMap(AccountKind.init(rawValue:))
                ?? $0.usage.flatMap { AccountKind(rawValue: $0.provider) }
                ?? ($0.id == "codex" ? .codex : .claude)
            return AccountRow(id: $0.id, name: $0.name, kind: kind, usage: $0.usage,
                              models: $0.models ?? [], billingAnchor: $0.billingAnchor)
        }
    }
    /// A well-formed snapshot: at most `maxAccounts` entries with valid, unique ids.
    var isValid: Bool {
        accounts.count <= maxAccounts && Set(accounts.map(\.id)).count == accounts.count
            && accounts.allSatisfy { isValidAccountID($0.id) }
    }
    /// The last published rows, or nil when there is no usable file yet. The widget always
    /// reads the fixed path; the host passes its own data folder (AI_LIMITS_DATA_DIR).
    static func loadPublished(from url: URL = publishedSnapshotURL) -> [AccountRow]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.isValid
        else { return nil }
        return decoded.displayRows
    }
    static func load() -> [AccountRow] { loadPublished() ?? placeholderRows }
}

// MARK: - Accounts

/// Up to 8 accounts. The medium widget shows up to 4 columns (3 plus a "more" column beyond
/// that) and the large widget switches to a one-row-per-account list above 4.
let maxAccounts = 8

enum AccountKind: String, Codable, Sendable {
    case codex, claude
}

/// Lowercase [a-z0-9-], 1...32 characters. Ids are file keys (history, billing, usage cache),
/// so anything that could be an email or a path is rejected.
func isValidAccountID(_ id: String) -> Bool {
    (1...32).contains(id.count) && id.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
    }
}

/// What a row needs to know about an account before any data arrives.
struct AccountSlot: Equatable, Sendable {
    let id: String
    let kind: AccountKind
    let name: String
}

/// Generic list for the widget gallery and before the host has published anything.
let placeholderSlots = [AccountSlot(id: "codex", kind: .codex, name: "Codex"),
                        AccountSlot(id: "claude-1", kind: .claude, name: "Claude")]
var placeholderRows: [AccountRow] { rows(for: placeholderSlots, usages: nil) }

/// User-visible strings of the account setup.
enum SetupText {
    static var emptyTitle: String { L("No accounts yet", "Аккаунтов пока нет") }
    static var emptyBody: String {
        L("Install Claude Code or the Codex CLI and log in. The accounts appear here by themselves.",
          "Установите Claude Code или Codex CLI и войдите в аккаунт. Аккаунты появятся здесь сами.")
    }
    static var emptyHint: String {
        L("Several accounts: list them in ~/Library/Application Support/AILimits/accounts.json.",
          "Несколько аккаунтов: перечислите их в ~/Library/Application Support/AILimits/accounts.json.")
    }
    static var widgetEmpty: String { L("Open AI Limits to set up accounts", "Откройте AI Limits, чтобы настроить аккаунты") }
}

struct Quota: Codable {
    let usedPercent: Double
    let resetsAt: String?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
}

// A per-model weekly window, e.g. Claude's "Fable only" scoped limit.
struct ModelQuota: Codable {
    let id: String
    let title: String
    let quota: Quota
}

struct Usage: Codable {
    let provider: String
    let updatedAt: String?
    let primary: Quota?
    let secondary: Quota?
}

struct AccountRow: Identifiable {
    let id: String
    let name: String
    let kind: AccountKind
    let usage: Usage?
    var models: [ModelQuota] = []
    var billingAnchor: String? = nil
    /// Length of the weekly window when the service reports it. Host-only: never published.
    var weeklyWindow: TimeInterval? = nil
    /// Why the latest fetch failed, if it did. Host-only: never published.
    var failure: FetchFailure? = nil
    /// Login email and plan name reported by the CLI's own files or app-server. Host-only and
    /// in memory only: never published, logged or written to any file.
    var email: String? = nil
    var plan: String? = nil
    /// The account has its own folder (Claude config dir / Codex home) rather than the default
    /// login. Host-only: never published.
    var dedicated: Bool = false

    /// Short badge and accent, derived from the account type rather than a fixed id.
    var code: String { kind == .codex ? "CX" : "CL" }
    var tint: Color { kind == .codex ? Palette.cyan : Palette.orange }
}

// Per-account data that is not part of Usage: per-model windows, the billing anchor
// and the weekly window length (the latter is not published to the widget).
struct AccountExtras {
    var models: [ModelQuota] = []
    var billingAnchor: String? = nil
    var weeklyWindow: TimeInterval? = nil
    var failure: FetchFailure? = nil
    /// Host-only, in memory only (see AccountRow).
    var email: String? = nil
    var plan: String? = nil
    var dedicated: Bool = false
}

// MARK: - Fetch failures

/// Fixed category of a failed quota fetch. The UI shows only the app-authored hint for it,
/// never the CLI's own output.
enum FetchFailure: String, Sendable {
    /// Claude Code asked whether to trust the probe folder.
    case probeNotTrusted
    /// The CLI answered but reported no plan limits: not logged in, API-key login, no plan.
    case notLoggedIn
    /// The CLI binary was not found.
    case cliNotFound
    /// Timeout, early exit or anything else.
    case failed
}

/// The app's own Claude probe folder (default location), for the trust hint.
let claudeProbeFolderDisplay = "~/Library/Application Support/AILimits/ClaudeProbe"

/// One short line for the account block.
func fetchHint(_ failure: FetchFailure, kind: AccountKind) -> String {
    switch failure {
    case .probeNotTrusted:
        return L("Run claude once in the probe folder — see README", "Запустите claude в папке проверки — см. README")
    case .notLoggedIn:
        return L("Not logged in or no plan limits", "Нет входа или у тарифа нет лимитов")
    case .cliNotFound:
        let name = kind == .codex ? "codex" : "claude"
        return L("\(name) not found", "\(name) не найден")
    case .failed:
        return L("Check failed — run AILimits --check", "Проверка не удалась — запустите AILimits --check")
    }
}

/// Short reason shown next to a "Fix" link (the host app), where the fix itself is one click away.
func fixHint(_ failure: FetchFailure, kind: AccountKind) -> String {
    switch failure {
    case .probeNotTrusted: return L("Claude needs your OK once", "Claude ждёт вашего разрешения")
    case .notLoggedIn: return L("Not signed in or no plan limits", "Нет входа или у тарифа нет лимитов")
    case .cliNotFound:
        return kind == .codex ? L("Codex CLI is not installed", "Codex CLI не установлен")
                              : L("Claude Code is not installed", "Claude Code не установлен")
    case .failed: return L("Check failed", "Проверка не удалась")
    }
}

/// Longer tooltip text for the same failure.
func fetchHintDetail(_ failure: FetchFailure, kind: AccountKind) -> String {
    switch failure {
    case .probeNotTrusted:
        return L("Claude Code asks whether to trust \(claudeProbeFolderDisplay). Open it once in Terminal and confirm:\n"
                 + "cd \(claudeProbeFolderDisplay.replacingOccurrences(of: " ", with: "\\ ")) && claude\n"
                 + "For an extra login: CLAUDE_CONFIG_DIR=<configDir> claude",
                 "Claude Code спрашивает, доверять ли папке \(claudeProbeFolderDisplay). Откройте её один раз в терминале и подтвердите:\n"
                 + "cd \(claudeProbeFolderDisplay.replacingOccurrences(of: " ", with: "\\ ")) && claude\n"
                 + "Для дополнительного входа: CLAUDE_CONFIG_DIR=<configDir> claude")
    case .notLoggedIn:
        return kind == .codex
            ? L("Run codex and sign in with your ChatGPT account; an API-key login has no plan limits.",
                "Запустите codex и войдите через аккаунт ChatGPT; при входе по API-ключу лимитов тарифа нет.")
            : L("Run claude in the probe folder, log in, finish the setup and check that /usage shows the limits.",
                "Запустите claude в папке проверки, войдите, завершите настройку и проверьте, что /usage показывает лимиты.")
    case .cliNotFound:
        return L("Install the CLI or set its path under \"cli\" in accounts.json. AI Limits looks again every 5 minutes.",
                 "Установите CLI или укажите путь в блоке \"cli\" файла accounts.json. AI Limits ищет его заново раз в 5 минут.")
    case .failed:
        return L("Run AILimits --check in Terminal to see the error for this account.",
                 "Запустите AILimits --check в терминале, чтобы увидеть ошибку по этому аккаунту.")
    }
}

enum Palette {
    static let background = Color(red: 20/255, green: 20/255, blue: 21/255)
    static let text = Color(red: 237/255, green: 237/255, blue: 237/255)
    static let muted = Color(red: 161/255, green: 161/255, blue: 166/255)
    static let cyan = text
    static let orange = text
    static let red = Color(red: 240/255, green: 113/255, blue: 117/255)
    static let amber = Color(red: 224/255, green: 178/255, blue: 103/255)
}

func parsedDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    if let result = formatter.date(from: value) { return result }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: value)
}

func measurementAge(_ usage: Usage?, now: Date) -> TimeInterval? {
    guard let measured = parsedDate(usage?.updatedAt) else { return nil }
    let age = now.timeIntervalSince(measured)
    return age >= -10 ? max(0, age) : nil
}

func ageLabel(_ usage: Usage?, now: Date) -> String {
    guard let age = measurementAge(usage, now: now) else { return L("no data", "нет данных") }
    if age < 60 { return L("\(Int(age)) s ago", "\(Int(age)) с назад") }
    if age < 3600 { return L("\(Int(age / 60)) min ago", "\(Int(age / 60)) мин назад") }
    return L("\(Int(age / 3600)) h ago", "\(Int(age / 3600)) ч назад")
}

func resetLabel(_ quota: Quota?, now: Date) -> String {
    guard quota != nil else { return L("No limit reported", "Сервис не передал лимит") }
    guard let date = parsedDate(quota?.resetsAt) else { return L("Reset time unknown", "Сброс не указан") }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return L("Reset passed · awaiting data", "Сброс прошёл · ждём данные") }
    let minutes = Int(ceil(seconds / 60))
    if minutes < 60 { return L("Resets in \(minutes) min", "Сброс через \(minutes) мин") }
    if minutes < 1440 { return L("Resets in \(minutes / 60) h \(minutes % 60) min", "Через \(minutes / 60) ч \(minutes % 60) мин") }
    return L("Resets in \(minutes / 1440) d \((minutes % 1440) / 60) h", "Через \(minutes / 1440) д \((minutes % 1440) / 60) ч")
}

func resetDetail(_ quota: Quota?) -> String {
    guard let date = parsedDate(quota?.resetsAt) else {
        return L("The service did not report the reset time", "Время сброса не получено от сервиса")
    }
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = L("MMMM d, HH:mm", "d MMMM, HH:mm")
    return L("Resets ", "Сброс: ") + formatter.string(from: date)
}

/// One row per account, in the configured order. Usage is keyed by account id;
/// a missing entry stays unknown, never zero.
func rows(for slots: [AccountSlot], usages: [String: Usage]?, extras: [String: AccountExtras] = [:]) -> [AccountRow] {
    slots.map { slot in
        AccountRow(id: slot.id, name: slot.name, kind: slot.kind, usage: usages?[slot.id],
                   models: extras[slot.id]?.models ?? [], billingAnchor: extras[slot.id]?.billingAnchor,
                   weeklyWindow: extras[slot.id]?.weeklyWindow, failure: extras[slot.id]?.failure,
                   email: extras[slot.id]?.email, plan: extras[slot.id]?.plan,
                   dedicated: extras[slot.id]?.dedicated ?? false)
    }
}

// MARK: - Login emails (host UI only)

/// "a•••@example.com": the first character, three bullets and the domain. Text without "@"
/// keeps only its first character.
func maskedEmail(_ email: String) -> String {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "" }
    guard let at = trimmed.lastIndex(of: "@"), at > trimmed.startIndex else { return String(first) + "•••" }
    return String(first) + "•••" + trimmed[at...]
}

/// "Max · name@example.com" (masked when `hideEmails`), only the known half, or nil.
func identityLine(plan: String?, email: String?, hideEmails: Bool) -> String? {
    let shownEmail = email.map { hideEmails ? maskedEmail($0) : $0 }
    let parts = [plan, shownEmail].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Two accounts of the same type that report the same login email (case-insensitive).
/// `later` is the one asked to sign into another account; `earlier` keeps its login.
struct SameLoginPair: Equatable {
    let earlier: String
    let later: String
}

/// Every account whose email matches another account of the same type, paired with the account
/// that keeps the login. The account asked to sign in again is never the default login: of a
/// group sharing one email, the default-login account (no dedicated folder) keeps it, otherwise
/// the first in list order does, and every other member is asked to sign in again. Pairs come in
/// the list order of the account asked. Accounts without an email never match.
func sameLoginPairs(_ accounts: [(id: String, kind: AccountKind, email: String?, dedicated: Bool)]) -> [SameLoginPair] {
    var groups: [String: [(id: String, dedicated: Bool)]] = [:]
    var keys: [(key: String, id: String)] = []
    for account in accounts {
        guard let email = account.email?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty else { continue }
        let key = account.kind.rawValue + "|" + email
        groups[key, default: []].append((account.id, account.dedicated))
        keys.append((key, account.id))
    }
    var keeper: [String: String] = [:]
    for (key, members) in groups where members.count > 1 {
        keeper[key] = (members.first { !$0.dedicated } ?? members[0]).id
    }
    return keys.compactMap { entry in
        guard let kept = keeper[entry.key], kept != entry.id else { return nil }
        return SameLoginPair(earlier: kept, later: entry.id)
    }
}

/// The pairs the popover and panel warn about: a later account whose last check failed shows
/// its failure instead, as its setup card does, so Fix never lands on a card without the warning.
func sameLoginPairs(_ rows: [AccountRow]) -> [SameLoginPair] {
    let failing = Set(rows.filter { $0.failure != nil }.map(\.id))
    return sameLoginPairs(rows.map { (id: $0.id, kind: $0.kind, email: $0.email, dedicated: $0.dedicated) })
        .filter { !failing.contains($0.later) }
}

/// "Claude 1 and Claude 2 are the same login".
func sameLoginTitle(_ earlier: String, _ later: String) -> String {
    L("\(earlier) and \(later) are the same login", "\(earlier) и \(later) — один и тот же вход")
}

/// What to do about it, for the later account.
func sameLoginHint(_ later: String, kind: AccountKind) -> String {
    kind == .claude
        ? L("Sign \(later) into your other Claude account: open Terminal for its login folder and type /login.",
            "Войдите в \(later) под другим аккаунтом Claude: откройте Терминал для его папки входа и введите /login.")
        : L("Sign \(later) into your other ChatGPT account: open Terminal and run codex login for its folder.",
            "Войдите в \(later) под другим аккаунтом ChatGPT: откройте Терминал и выполните codex login для его папки.")
}

// MARK: - Widget layouts

/// Large widget: one block per account up to 4, a compact one-row list above that.
func largeWidgetUsesList(accountCount: Int) -> Bool { accountCount > 4 }

/// Medium widget: one column per account up to 4; with more, a two-column grid of compact
/// cells (name, week remaining, bar) so every account stays readable.
func mediumWidgetUsesGrid(accountCount: Int) -> Bool { accountCount > 4 }

// MARK: - Payment estimate

private var billingCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar
}

/// Anchor day as a calendar date: "yyyy-MM-dd" literally, or an ISO8601 instant
/// (any fractional precision) converted to the system time zone.
private func anchorComponents(_ anchor: String) -> DateComponents? {
    let value = anchor.trimmingCharacters(in: .whitespaces)
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    if value.count == 10, parts.count == 3,
       let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
       (1...12).contains(month), (1...31).contains(day) {
        return DateComponents(year: year, month: month, day: day)
    }
    var instant = parsedDate(value)
    if instant == nil, let range = value.range(of: #"\.[0-9]+"#, options: .regularExpression) {
        instant = parsedDate(value.replacingCharacters(in: range, with: ""))
    }
    guard let instant else { return nil }
    return billingCalendar.dateComponents([.year, .month, .day], from: instant)
}

/// Next monthly payment on the anchor's day-of-month (clamped to the month length).
/// A payment due today returns today. The estimate never precedes the anchor date itself.
func nextPayment(anchor: String?, now: Date) -> Date? {
    guard let anchor, let start = anchorComponents(anchor), let day = start.day else { return nil }
    let calendar = billingCalendar
    let today = calendar.startOfDay(for: now)
    if let first = calendar.date(from: start), first >= today { return first }
    func occurrence(monthOffset: Int) -> Date? {
        guard let month = calendar.date(byAdding: .month, value: monthOffset, to: today),
              let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let length = calendar.range(of: .day, in: .month, for: monthStart)?.count
        else { return nil }
        return calendar.date(byAdding: .day, value: min(day, length) - 1, to: monthStart)
    }
    guard let current = occurrence(monthOffset: 0) else { return nil }
    return current >= today ? current : occurrence(monthOffset: 1)
}

/// Whole days from today to the next payment (0 = today).
func paymentDaysAway(anchor: String?, now: Date) -> Int? {
    guard let date = nextPayment(anchor: anchor, now: now) else { return nil }
    let calendar = billingCalendar
    return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day
}

func paymentLabel(anchor: String?, now: Date, short: Bool = false) -> String? {
    guard let date = nextPayment(anchor: anchor, now: now) else { return nil }
    let parts = billingCalendar.dateComponents([.month, .day], from: date)
    guard let month = parts.month, let day = parts.day else { return nil }
    if short { return L("Due ", "Оплата ") + L(shortDayMonth(day: day, month: month), String(format: "%02d.%02d", day, month)) }
    return L("Payment ", "Оплата ") + shortDayMonth(day: day, month: month)
}


// MARK: - Pace

let weekWindow: TimeInterval = 7 * 86_400
let claudeSessionWindow: TimeInterval = 5 * 3_600

enum PaceStatus: Equatable {
    case onTrack
    case reserve(Int)    // used this many points less than the elapsed share
    case overspend(Int)  // used this many points more than the elapsed share
}

struct PaceReading: Equatable {
    let status: PaceStatus
    /// Linear projection of the moment the limit runs out, when that precedes the reset.
    let runsOut: Date?
}

/// Elapsed share of the window against the used share. nil when the reset is unknown or
/// past, the window has barely started (< 3 % elapsed) or the limit is already exhausted.
func paceReading(_ quota: Quota, window: TimeInterval, now: Date) -> PaceReading? {
    guard window > 0, let reset = parsedDate(quota.resetsAt), reset > now, quota.remaining > 0 else { return nil }
    let start = reset.addingTimeInterval(-window)
    let elapsedSeconds = now.timeIntervalSince(start)
    let elapsed = elapsedSeconds / window
    guard elapsed >= 0.03, elapsed <= 1 else { return nil }
    let used = max(0, min(100, quota.usedPercent)) / 100
    let diff = (used - elapsed) * 100
    let status: PaceStatus = abs(diff) < 5 ? .onTrack
        : diff < 0 ? .reserve(Int((-diff).rounded())) : .overspend(Int(diff.rounded()))
    var runsOut: Date?
    if used > 0 {
        let exhaust = start.addingTimeInterval(elapsedSeconds / used)
        if exhaust < reset { runsOut = exhaust }
    }
    return PaceReading(status: status, runsOut: runsOut)
}

/// "today, 14:30", "tomorrow, 09:00" or "Fri, 14:30" ("сегодня", "завтра", "пт") in the system time zone.
func paceMoment(_ date: Date, now: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
    let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    if calendar.isDate(date, inSameDayAs: now) { return L("today, ", "сегодня, ") + time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
        return L("tomorrow, ", "завтра, ") + time
    }
    return "\(shortWeekday(parts.weekday ?? 1)), \(time)"
}

func paceCaption(_ pace: PaceReading, now: Date) -> String {
    var text: String
    switch pace.status {
    case .onTrack: text = L("On pace", "В темпе")
    case .reserve(let points): text = L("\(points)% under pace", "Запас \(points)%")
    case .overspend(let points): text = L("\(points)% over pace", "Перерасход \(points)%")
    }
    if let runsOut = pace.runsOut { text += L(" · lasts until ", " · хватит до ") + paceMoment(runsOut, now: now) }
    return text
}
