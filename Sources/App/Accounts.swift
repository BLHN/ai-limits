import Foundation
import Darwin

// Which accounts the app shows and where their CLIs live. The list comes from an optional
// user-edited accounts.json; without it the installed CLIs are detected. Nothing here reads
// credentials: only paths and the user's own labels (the --accounts report also shows the
// Claude login email from the profile state file, masked).

struct AccountConfig: Equatable, Sendable {
    let id: String
    let kind: AccountKind
    let name: String
    /// Claude: passed as CLAUDE_CONFIG_DIR; nil = the default login (the variable stays unset).
    /// Codex: passed as CODEX_HOME; nil = the inherited environment or ~/.codex.
    let directory: String?

    var slot: AccountSlot { AccountSlot(id: id, kind: kind, name: name) }

    /// Same id, type and folder: the same login, whatever its name. A fetch result is applied
    /// only while its account still matches this way.
    func sameFolder(as other: AccountConfig) -> Bool {
        other.id == id && other.kind == kind && other.directory == directory
    }

    /// Claude profile state file; only oauthAccount.subscriptionCreatedAt, emailAddress and
    /// planDisplayName are read from it (Fetchers.swift).
    var claudeStateFile: URL {
        directory.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? realHome.appendingPathComponent(".claude.json")
    }
}

struct AccountsConfiguration: Equatable, Sendable {
    var accounts: [AccountConfig] = []
    /// "claude" / "codex" -> absolute executable path from accounts.json.
    var cli: [String: String] = [:]
    /// Short human-readable problem with accounts.json; nil when there is none.
    var warning: String?
    /// false: the list was auto-detected (no file, or a file without usable entries).
    var fromFile = false

    var slots: [AccountSlot] { accounts.map(\.slot) }
    var ids: [String] { accounts.map(\.id) }
    var codexAccounts: [AccountConfig] { accounts.filter { $0.kind == .codex } }
    var claudeAccounts: [AccountConfig] { accounts.filter { $0.kind == .claude } }
}

var accountsURL: URL { appDataFolder.appendingPathComponent("accounts.json") }

func accountsModificationDate() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: accountsURL.path))?[.modificationDate] as? Date
}

/// "~" and "~/x" expand against `home`; the result must be absolute.
func expandedPath(_ text: String, home: URL) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    var path = trimmed
    if trimmed == "~" { path = home.path } else if trimmed.hasPrefix("~/") { path = home.path + trimmed.dropFirst(1) }
    guard path.hasPrefix("/") else { return nil }
    return (path as NSString).standardizingPath
}

// MARK: - accounts.json

struct ParsedAccountsFile {
    var accounts: [AccountConfig]
    var cli: [String: String]
    var problems: [String]
}

/// Pure parser. nil when the data is not a JSON object with an "accounts" list; otherwise bad
/// entries are dropped with a problem each, and default names are filled in.
func parseAccountsFile(_ data: Data, home: URL, isExecutable: (String) -> Bool) -> ParsedAccountsFile? {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let list = object["accounts"] as? [Any] else { return nil }
    var problems: [String] = []
    var entries: [(id: String, kind: AccountKind, name: String?, directory: String?)] = []
    for (offset, item) in list.enumerated() {
        let label = L("entry \(offset + 1)", "запись \(offset + 1)")
        guard let entry = item as? [String: Any] else {
            problems.append(L("\(label) is not an object", "\(label) не объект")); continue
        }
        guard let id = entry["id"] as? String, isValidAccountID(id) else {
            problems.append(L("\(label): id must be 1-32 characters a-z, 0-9 or -",
                              "\(label): id должен быть из 1-32 символов a-z, 0-9 или -")); continue
        }
        guard !entries.contains(where: { $0.id == id }) else {
            problems.append(L("\(label): duplicate id \"\(id)\"", "\(label): повторный id \"\(id)\"")); continue
        }
        guard let kind = (entry["type"] as? String).flatMap(AccountKind.init(rawValue:)) else {
            problems.append(L("\(label): type must be \"claude\" or \"codex\"", "\(label): type должен быть \"claude\" или \"codex\"")); continue
        }
        let key = kind == .claude ? "configDir" : "home"
        var directory: String?
        if let raw = entry[key] {
            guard let text = raw as? String, let path = expandedPath(text, home: home) else {
                problems.append(L("\(label): \(key) must be an absolute path", "\(label): \(key) должен быть абсолютным путём")); continue
            }
            directory = path
        }
        // Several Codex logins need separate homes; only one may use the default (~/.codex).
        if kind == .codex {
            let homeKey = codexHomeKey(directory, home: home)
            if entries.contains(where: { $0.kind == .codex && codexHomeKey($0.directory, home: home) == homeKey }) {
                problems.append(directory == nil || homeKey == codexHomeKey(nil, home: home)
                    ? L("\(label): only one codex account can use the default home; give it its own \"home\"",
                        "\(label): основной home может быть только у одного аккаунта codex; укажите отдельный \"home\"")
                    : L("\(label): another codex account already uses this home",
                        "\(label): этот home уже занят другим аккаунтом codex"))
                continue
            }
        }
        let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append((id, kind, name.flatMap { $0.isEmpty ? nil : String($0.prefix(32)) }, directory))
    }
    if entries.count > maxAccounts {
        problems.append(L("only the first \(maxAccounts) accounts are shown", "показаны только первые \(maxAccounts) \(ruPlural(maxAccounts, "аккаунт", "аккаунта", "аккаунтов"))"))
        entries = Array(entries.prefix(maxAccounts))
    }
    let claudeCount = entries.filter { $0.kind == .claude }.count
    let codexCount = entries.filter { $0.kind == .codex }.count
    var claudeIndex = 0
    var codexIndex = 0
    let accounts = entries.map { entry -> AccountConfig in
        let fallback: String
        if entry.kind == .claude {
            claudeIndex += 1
            fallback = claudeCount == 1 ? "Claude" : "Claude \(claudeIndex)"
        } else {
            codexIndex += 1
            fallback = codexCount == 1 ? "Codex" : "Codex \(codexIndex)"
        }
        return AccountConfig(id: entry.id, kind: entry.kind, name: entry.name ?? fallback, directory: entry.directory)
    }
    var cli: [String: String] = [:]
    if let overrides = object["cli"] as? [String: Any] {
        for name in ["claude", "codex"] {
            guard let raw = overrides[name] else { continue }
            if let text = raw as? String, let path = expandedPath(text, home: home), isExecutable(path) {
                cli[name] = path
            } else {
                problems.append(L("cli.\(name) is not an executable file", "cli.\(name) не исполняемый файл"))
            }
        }
    }
    return ParsedAccountsFile(accounts: accounts, cli: cli, problems: problems)
}

/// Comparable Codex home: the folder, with the default (no "home") meaning ~/.codex.
func codexHomeKey(_ directory: String?, home: URL) -> String {
    URL(fileURLWithPath: directory ?? home.appendingPathComponent(".codex").path).standardizedFileURL.path
}

private func warningText(_ problems: [String]) -> String? {
    guard !problems.isEmpty else { return nil }
    let shown = problems.prefix(2).joined(separator: "; ")
    let more = problems.count - 2
    return "accounts.json: " + shown + (more > 0 ? L("; and \(more) more", "; и ещё \(more)") : "")
}

/// The file when it parses into at least one account, else auto-detection: a Codex account
/// when the codex CLI is found and the default Claude login when the claude CLI is found.
/// `findCLI(name, override)` locates a CLI; it is only asked during auto-detection.
func resolveAccounts(fileData: Data?, home: URL, isExecutable: (String) -> Bool,
                     findCLI: (String, String?) -> String?) -> AccountsConfiguration {
    var problems: [String] = []
    var cli: [String: String] = [:]
    if let fileData {
        if let parsed = parseAccountsFile(fileData, home: home, isExecutable: isExecutable) {
            if !parsed.accounts.isEmpty {
                return AccountsConfiguration(accounts: parsed.accounts, cli: parsed.cli,
                                             warning: warningText(parsed.problems), fromFile: true)
            }
            problems = parsed.problems + [L("no usable accounts, detecting the installed CLIs",
                                            "нет подходящих аккаунтов, ищу установленные CLI")]
            cli = parsed.cli
        } else {
            problems = [L("not valid JSON with an \"accounts\" list, detecting the installed CLIs",
                          "не JSON со списком \"accounts\", ищу установленные CLI")]
        }
    }
    var accounts: [AccountConfig] = []
    if findCLI("codex", cli["codex"]) != nil {
        accounts.append(AccountConfig(id: "codex", kind: .codex, name: "Codex", directory: nil))
    }
    if findCLI("claude", cli["claude"]) != nil {
        accounts.append(AccountConfig(id: "claude-1", kind: .claude, name: "Claude", directory: nil))
    }
    return AccountsConfiguration(accounts: accounts, cli: cli, warning: warningText(problems), fromFile: false)
}

/// Reads accounts.json (if any) and applies its CLI overrides to the locator.
/// May ask the login shell for a CLI path, so it runs off the main thread.
func loadAccountsConfiguration() -> AccountsConfiguration {
    let data = try? Data(contentsOf: accountsURL)
    let configuration = resolveAccounts(fileData: data, home: realHome,
                                        isExecutable: FileManager.default.isExecutableFile(atPath:)) { name, override in
        CLILocator.shared.locate(name, override: override)
    }
    CLILocator.shared.setOverrides(configuration.cli)
    return configuration
}

// MARK: - Writing accounts.json (onboarding)

/// One account as the onboarding window edits it.
struct AccountDraft: Identifiable, Equatable, Sendable {
    var id: String
    var kind: AccountKind
    var name: String
    /// Claude: CLAUDE_CONFIG_DIR (nil = default login). Codex: CODEX_HOME (nil = default).
    var directory: String?

    init(id: String, kind: AccountKind, name: String, directory: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.directory = directory
    }

    init(_ config: AccountConfig) {
        self.init(id: config.id, kind: config.kind, name: config.name, directory: config.directory)
    }

    /// Same login as a resolved account: kind and folder match (the name may differ).
    func sameLogin(as config: AccountConfig) -> Bool {
        config.id == id && config.kind == kind && config.directory == directory
    }
}

/// "~/x" for paths inside `home`, the path itself otherwise.
func displayPath(_ path: String, home: URL) -> String {
    let base = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
    if path == base { return "~" }
    if path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
    return path
}

/// Lowercase ASCII slug for folder names: Latin transliteration, [a-z0-9] runs joined by "-",
/// at most 24 characters. Empty when nothing usable is left.
func accountSlug(_ name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false)?
        .applyingTransform(.stripDiacritics, reverse: false) ?? name
    var slug = ""
    var pendingDash = false
    for scalar in latin.lowercased().unicodeScalars {
        if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
            if pendingDash && !slug.isEmpty { slug += "-" }
            pendingDash = false
            slug.unicodeScalars.append(scalar)
        } else {
            pendingDash = true
        }
    }
    while slug.count > 24 { slug = String(slug.prefix(24)) }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug
}

/// Smallest free "claude-N", N >= 1.
func nextClaudeID(existing: [String]) -> String {
    var number = 1
    while existing.contains("claude-\(number)") { number += 1 }
    return "claude-\(number)"
}

/// "codex" for the first Codex account, then the smallest free "codex-N", N >= 2.
func nextCodexID(existing: [String]) -> String {
    if !existing.contains("codex") { return "codex" }
    var number = 2
    while existing.contains("codex-\(number)") { number += 1 }
    return "codex-\(number)"
}

func nextAccountID(kind: AccountKind, existing: [String]) -> String {
    kind == .claude ? nextClaudeID(existing: existing) : nextCodexID(existing: existing)
}

/// Hidden folder prefix of a login folder: ".claude" or ".codex".
func loginFolderPrefix(_ kind: AccountKind) -> String { kind == .claude ? ".claude" : ".codex" }

/// "~/.claude-<slug>" for a new Claude login; "-2", "-3"... when the folder is already in use
/// (by another account or on disk, as `exists` says).
func suggestedClaudeFolder(name: String, home: URL, taken: [String], exists: (String) -> Bool) -> String {
    suggestedLoginFolder(kind: .claude, name: name, home: home, taken: taken, exists: exists)
}

/// "~/.claude-<slug>" or "~/.codex-<slug>" for a new login, unique like suggestedClaudeFolder.
func suggestedLoginFolder(kind: AccountKind, name: String, home: URL, taken: [String], exists: (String) -> Bool) -> String {
    let slug = accountSlug(name)
    let base = loginFolderPrefix(kind) + "-" + (slug.isEmpty ? "account" : slug)
    var candidate = base
    var number = 2
    func path(_ folder: String) -> String { home.appendingPathComponent(folder).path }
    while taken.contains(path(candidate)) || exists(path(candidate)) {
        candidate = "\(base)-\(number)"
        number += 1
    }
    return "~/" + candidate
}

/// Label for a found login folder: ".claude-work" -> "Claude Work", ".claude2" -> "Claude 2".
func suggestedName(forClaudeFolder path: String) -> String { suggestedName(forFolder: path, kind: .claude) }

/// ".codex-work" -> "Codex Work"; the Claude rule for ".claude..." folders.
func suggestedName(forFolder path: String, kind: AccountKind) -> String {
    let folder = (path as NSString).lastPathComponent
    let prefix = loginFolderPrefix(kind)
    var rest = folder.hasPrefix(prefix) ? String(folder.dropFirst(prefix.count)) : folder
    rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
    let words = rest.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return String(([kind == .claude ? "Claude" : "Codex"] + words).joined(separator: " ").prefix(32))
}

/// Extra Claude logins in `home`: folders whose name starts with ".claude" (not ".claude"
/// itself) that contain a ".claude.json" file. Only directory names and the file's existence
/// are checked; nothing is read. Sorted by name, at most `limit`.
func discoverClaudeLogins(home: URL, limit: Int = 8, fileManager: FileManager = .default) -> [String] {
    discoverLogins(kind: .claude, home: home, limit: limit, fileManager: fileManager)
}

/// Extra Codex logins: folders named ".codex..." (not ".codex") that contain an "auth.json".
/// Only its existence is checked; the file is never opened.
func discoverCodexLogins(home: URL, limit: Int = 8, fileManager: FileManager = .default) -> [String] {
    discoverLogins(kind: .codex, home: home, limit: limit, fileManager: fileManager)
}

func discoverLogins(kind: AccountKind, home: URL, limit: Int = 8, fileManager: FileManager = .default) -> [String] {
    guard let names = try? fileManager.contentsOfDirectory(atPath: home.path) else { return [] }
    let prefix = loginFolderPrefix(kind)
    let marker = kind == .claude ? ".claude.json" : "auth.json"
    var found: [String] = []
    for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    where name.hasPrefix(prefix) && name != prefix {
        let path = home.appendingPathComponent(name).path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.fileExists(atPath: path + "/" + marker) else { continue }
        found.append(path)
        if found.count >= limit { break }
    }
    return found
}

/// New accounts.json content for `drafts`. A top-level "cli" block and any other top-level keys
/// of `existing` are kept, and so are unknown keys inside an existing entry with the same id.
/// Folders inside `home` are written as "~/...".
func accountsFileData(drafts: [AccountDraft], existing: Data?, home: URL) throws -> Data {
    var object = existing.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    var previous: [String: [String: Any]] = [:]
    for item in object["accounts"] as? [Any] ?? [] {
        if let entry = item as? [String: Any], let id = entry["id"] as? String, previous[id] == nil { previous[id] = entry }
    }
    object["accounts"] = drafts.map { draft -> [String: Any] in
        var entry = previous[draft.id] ?? [:]
        entry["id"] = draft.id
        entry["type"] = draft.kind.rawValue
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        entry["name"] = name.isEmpty ? nil : String(name.prefix(32))
        entry["configDir"] = nil
        entry["home"] = nil
        if let directory = draft.directory {
            entry[draft.kind == .claude ? "configDir" : "home"] = displayPath(directory, home: home)
        }
        return entry
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

/// Atomic write with mode 0600; the folder is created with 0700. A file that is not a JSON
/// object is kept next to it as accounts.json.bak before it is replaced.
func writeAccountsFile(drafts: [AccountDraft], to url: URL = accountsURL, home: URL = realHome) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    let existing = try? Data(contentsOf: url)
    if let existing, !existing.isEmpty, (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] == nil {
        let backup = url.appendingPathExtension("bak")
        try? existing.write(to: backup, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
    let data = try accountsFileData(drafts: drafts, existing: existing, home: home)
    try data.write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Terminal scripts (onboarding)

/// POSIX single-quoted word: 'it'\''s'.
func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// What a Terminal session started from the onboarding is for.
enum TerminalTask: Equatable, Sendable {
    /// Claude in the probe folder: confirm the trust prompt.
    case claudeTrust
    /// Claude in the probe folder: trust (if asked) and /login.
    case claudeLogin
    /// `codex login`.
    case codexLogin
}

/// The instruction lines a script prints before it starts the CLI.
func terminalInstructions(_ task: TerminalTask) -> [String] {
    switch task {
    case .claudeTrust:
        return [L("AI Limits: Claude Code will ask whether you trust this folder. Use the arrow keys to pick \"Yes, I trust this folder\", then press Enter.",
                  "AI Limits: Claude Code спросит, доверяете ли вы этой папке. Стрелками выберите «Yes, I trust this folder» и нажмите Enter."),
                L("Then type /exit and close this window. AI Limits never types here.",
                  "Потом введите /exit и закройте это окно. AI Limits сам здесь ничего не вводит.")]
    case .claudeLogin:
        return [L("AI Limits: if Claude Code asks whether you trust this folder, pick \"Yes, I trust this folder\" with the arrow keys and press Enter.",
                  "AI Limits: если Claude Code спросит, доверяете ли вы этой папке, стрелками выберите «Yes, I trust this folder» и нажмите Enter."),
                L("Then type /login, sign in with your Claude subscription, type /exit and close this window.",
                  "Потом введите /login, войдите в подписку Claude, введите /exit и закройте это окно.")]
    case .codexLogin:
        return [L("AI Limits: sign in with your ChatGPT account in the browser page that opens.",
                  "AI Limits: войдите в аккаунт ChatGPT на открывшейся странице браузера."),
                L("When it says you are signed in, close this window.",
                  "Когда вход завершится, закройте это окно.")]
    }
}

/// Fixed-content zsh script for a .command file. Every path is single-quoted; nothing is piped
/// into the CLI, which takes over the terminal through exec. For Claude the environment
/// matches the app's own check: CLAUDE*/ANTHROPIC* variables are removed and CLAUDE_CONFIG_DIR
/// is set only for an extra login. For Codex, CODEX_HOME is the account's folder, or for the
/// default login exactly what the app's own check inherits (unset in the usual case), so a
/// CODEX_HOME exported in the user's shell profile cannot redirect the login to another folder.
func terminalScript(task: TerminalTask, cli: String, directory: String?, probeFolder: String, home: URL,
                    defaultCodexHome: String? = inheritedCodexHome()) -> String {
    var lines = ["#!/bin/zsh", "# Written by AI Limits. It starts your own CLI; AI Limits never types into it."]
    let cliFolder = (cli as NSString).deletingLastPathComponent
    lines.append("export PATH=\(shellQuote(cliFolder)):\"$PATH\"")
    switch task {
    case .claudeTrust, .claudeLogin:
        lines.append("cd \(shellQuote(probeFolder)) || exit 1")
        lines.append("unset -m 'CLAUDE*' 'ANTHROPIC*'")
        if let directory { lines.append("export CLAUDE_CONFIG_DIR=\(shellQuote(directory))") }
    case .codexLogin:
        lines.append("cd \(shellQuote(home.path)) || exit 1")
        if let codexHome = directory ?? defaultCodexHome {
            lines.append("export CODEX_HOME=\(shellQuote(codexHome))")
        } else {
            lines.append("unset CODEX_HOME")
        }
    }
    lines.append("printf '%s\\n' " + terminalInstructions(task).map(shellQuote).joined(separator: " ") + " ''")
    lines.append("exec \(shellQuote(cli))" + (task == .codexLogin ? " login" : ""))
    return lines.joined(separator: "\n") + "\n"
}

/// A path as a shell word: ~/'rest' inside `home` (the tilde stays outside the quotes so the
/// shell expands it), the whole path single-quoted otherwise.
func shellPath(_ path: String, home: URL) -> String {
    let shown = displayPath(path, home: home)
    if shown == "~" { return "~" }
    if shown.hasPrefix("~/") { return "~/" + shellQuote(String(shown.dropFirst(2))) }
    return shellQuote(path)
}

/// The same session as one line for another terminal app; the CLI is called by name. The folder
/// variable is a prefix assignment (zsh expands "~" there, not in an argument to env), and the
/// default logins drop CLAUDE_CONFIG_DIR / CODEX_HOME inherited from the user's shell.
func terminalCommand(task: TerminalTask, directory: String?, probeFolder: String, home: URL,
                     defaultCodexHome: String? = inheritedCodexHome()) -> String {
    switch task {
    case .claudeTrust, .claudeLogin:
        // An exported API key would make claude sign in with it instead of the subscription.
        let clean = "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN"
        let command = directory.map { "CLAUDE_CONFIG_DIR=\(shellPath($0, home: home)) \(clean) claude" }
            ?? "\(clean) -u CLAUDE_CONFIG_DIR claude"
        return "cd \(shellPath(probeFolder, home: home)) && " + command
    case .codexLogin:
        if let codexHome = directory ?? defaultCodexHome { return "CODEX_HOME=\(shellPath(codexHome, home: home)) codex login" }
        return "env -u CODEX_HOME codex login"
    }
}

/// CODEX_HOME as the app's own check of the default Codex login sees it (normally unset).
func inheritedCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = realHome) -> String? {
    environment["CODEX_HOME"].flatMap { expandedPath($0, home: home) }
}

var onboardingScriptsFolder: URL { appDataFolder.appendingPathComponent("Onboarding") }

/// Writes `<name>.command` (mode 0700) into the Onboarding folder (0700) and returns its URL.
func writeTerminalScript(_ content: String, name: String, folder: URL = onboardingScriptsFolder) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let url = folder.appendingPathComponent(name + ".command")
    try Data(content.utf8).write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

// MARK: - CLI lookup

/// Usual install locations, in order. A GUI app gets a minimal PATH from launchd.
func cliSearchDirectories(home: URL) -> [String] {
    [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin",
     home.appendingPathComponent(".npm-global/bin").path, home.appendingPathComponent(".bun/bin").path,
     home.appendingPathComponent(".volta/bin").path, home.appendingPathComponent(".claude/local").path]
}

/// accounts.json override -> usual directories -> the user's login shell. A found path is
/// remembered for the session; "not found" only for `missTTL`, so a CLI installed later appears.
final class CLILocator: @unchecked Sendable {
    static let shared = CLILocator()
    private let lock = NSLock()
    /// Serializes login-shell lookups so one name never starts two shells.
    private let shellLock = NSLock()
    private var overrides: [String: String] = [:]
    private var shellAnswers: [String: String] = [:]
    private var shellMisses: [String: Date] = [:]
    /// How long a login-shell "not found" is trusted; matches the 5-minute re-detection.
    let missTTL: TimeInterval
    /// Login-shell lookup; replaceable for the self-test.
    private let shellLookup: (String) -> String?

    init(missTTL: TimeInterval = 300, shellLookup: @escaping (String) -> String? = { loginShellLookup($0) }) {
        self.missTTL = missTTL
        self.shellLookup = shellLookup
    }

    func setOverrides(_ value: [String: String]) { lock.lock(); overrides = value; lock.unlock() }

    /// Forgets login-shell "not found" answers, so a CLI the user just installed is looked up again.
    func forgetMisses() { lock.lock(); shellMisses = [:]; lock.unlock() }

    func locate(_ name: String) -> String? {
        lock.lock(); let override = overrides[name]; lock.unlock()
        return locate(name, override: override)
    }

    func locate(_ name: String, override: String?) -> String? {
        let manager = FileManager.default
        if let override, manager.isExecutableFile(atPath: override) { return override }
        if let found = cliSearchDirectories(home: realHome).map({ "\($0)/\(name)" })
            .first(where: { manager.isExecutableFile(atPath: $0) }) { return found }
        return shellLocate(name)
    }

    /// The login shell's answer, cached: hits for the session, misses for `missTTL`.
    func shellLocate(_ name: String, now: Date = Date()) -> String? {
        shellLock.lock()
        defer { shellLock.unlock() }
        lock.lock()
        let hit = shellAnswers[name]
        let missedAt = shellMisses[name]
        lock.unlock()
        if let hit { return hit }
        if let missedAt, now.timeIntervalSince(missedAt) < missTTL { return nil }
        let answer = shellLookup(name)
        lock.lock()
        if let answer { shellAnswers[name] = answer; shellMisses[name] = nil } else { shellMisses[name] = now }
        lock.unlock()
        return answer
    }
}

/// `$SHELL -lc 'command -v <name>'` with a short timeout. Only an absolute path to an existing
/// executable is accepted; whatever else a profile prints is ignored.
func loginShellLookup(_ name: String, timeout: TimeInterval = 4) -> String? {
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
    let manager = FileManager.default
    let environmentShell = ProcessInfo.processInfo.environment["SHELL"]
    let accountShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
    guard let shell = [environmentShell, accountShell, "/bin/zsh"].compactMap({ $0 })
        .first(where: { $0.hasPrefix("/") && manager.isExecutableFile(atPath: $0) }) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", "command -v \(name)"]
    process.currentDirectoryURL = realHome
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let pid = process.processIdentifier
    ChildProcesses.shared.add(pid, group: false)
    defer {
        if process.isRunning { process.terminate() }
        let grace = Date().addingTimeInterval(1)
        while process.isRunning && Date() < grace { usleep(20_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
        ChildProcesses.shared.remove(pid)
    }
    let deadline = Date().addingTimeInterval(timeout)
    let reader = output.fileHandleForReading.fileDescriptor
    var collected = Data()
    // A background job started by a profile may keep the pipe open: stop soon after the shell exits.
    while Date() < deadline {
        let slice = min(deadline, Date().addingTimeInterval(0.2))
        if let chunk = readChunk(reader, until: slice) {
            if chunk.isEmpty { break }
            collected.append(chunk)
        } else if !process.isRunning {
            break
        }
    }
    let lines = String(decoding: collected, as: UTF8.self).split(whereSeparator: \.isNewline)
    guard let last = lines.last.map({ $0.trimmingCharacters(in: .whitespaces) }), last.hasPrefix("/"),
          manager.isExecutableFile(atPath: last) else { return nil }
    return last
}

// MARK: - Log roots

extension UsageSources {
    /// Claude: <configDir or ~/.claude>/projects per Claude account, deduplicated.
    /// Codex: <home or $CODEX_HOME or ~/.codex>/sessions per Codex account, deduplicated.
    init(configuration: AccountsConfiguration, home: URL = realHome,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        var claude: [URL] = []
        for account in configuration.claudeAccounts {
            let root = URL(fileURLWithPath: account.directory ?? home.appendingPathComponent(".claude").path)
                .appendingPathComponent("projects").standardizedFileURL
            if !claude.contains(where: { $0.path == root.path }) { claude.append(root) }
        }
        var codex: [URL] = []
        for account in configuration.codexAccounts {
            let base = account.directory ?? environment["CODEX_HOME"].flatMap { expandedPath($0, home: home) }
                ?? home.appendingPathComponent(".codex").path
            let root = URL(fileURLWithPath: base).appendingPathComponent("sessions").standardizedFileURL
            if !codex.contains(where: { $0.path == root.path }) { codex.append(root) }
        }
        self.init(claudeRoots: claude, codexRoots: codex)
    }
}

// MARK: - CLI report

/// `AILimits --accounts`: the resolved list and any warning. Locates the CLIs, never runs them
/// (only the login shell may be asked for a path). A Claude login's email from its profile
/// state file is printed masked; Codex emails need a live check and are not shown here.
func runAccountsReport() {
    let configuration = loadAccountsConfiguration()
    let exists = FileManager.default.fileExists(atPath: accountsURL.path)
    let source = configuration.fromFile ? "accounts.json" : "auto-detected"
    print("AI Limits accounts (\(source)); file: \(accountsURL.path)\(exists ? "" : " (not present)")")
    if configuration.accounts.isEmpty {
        print("no accounts: install Claude Code or the Codex CLI and log in, or list accounts in accounts.json")
    }
    for account in configuration.accounts {
        let key = account.kind == .claude ? "configDir" : "home"
        var directory = account.directory ?? "default"
        if let path = account.directory, !FileManager.default.fileExists(atPath: path) { directory += " (missing)" }
        let cli = CLILocator.shared.locate(account.kind.rawValue) ?? "not found"
        var login = ""
        if account.kind == .claude {
            let profile = claudeProfile(account)
            login = " email=" + (profile?.email.map(maskedEmail) ?? "unknown")
            if let plan = profile?.plan { login += " plan=\"\(plan)\"" }
        }
        print("\(account.id): type=\(account.kind.rawValue) name=\"\(account.name)\" \(key)=\(directory) cli=\(cli)\(login)")
    }
    print("warning: \(configuration.warning ?? "none")")
}
