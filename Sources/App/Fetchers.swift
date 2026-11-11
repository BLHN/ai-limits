import Foundation
import Darwin

// Host-only quota fetchers. They launch the user's installed `codex` and `claude` CLIs
// and read what those tools print. This file never reads tokens, credentials or the
// keychain and makes no network or model requests of its own. Nothing here logs,
// prints or stores emails, account ids or tokens.

/// `description` is for the terminal (`--check`); the UI shows only the hint for `reason`.
struct FetchError: Error, CustomStringConvertible {
    let description: String
    let reason: FetchFailure
    init(_ description: String, reason: FetchFailure = .failed) {
        self.description = description
        self.reason = reason
    }
}

/// The failure category of any error a fetcher throws.
func fetchFailure(of error: Error) -> FetchFailure {
    (error as? FetchError)?.reason ?? .failed
}

var realHome: URL {
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home)
}

func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number.doubleValue
}

private func clampPercent(_ value: Double) -> Double { max(0, min(100, value)) }

private func readJSONObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Child process helpers

/// CLI path: accounts.json override, the usual install folders, then the login shell (Accounts.swift).
func resolveCLI(_ name: String) -> String? { CLILocator.shared.locate(name) }

/// The CLI's own folder goes first on PATH: node-based CLIs expect their node next to them.
func childEnvironment(removingClaudeVariables: Bool, executable: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if removingClaudeVariables {
        environment = environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    }
    var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    let folder = (executable as NSString).deletingLastPathComponent
    path.removeAll { $0 == folder }
    path.insert(folder, at: 0)
    let required = [realHome.appendingPathComponent(".local/bin").path,
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    for directory in required where !path.contains(directory) { path.append(directory) }
    environment["PATH"] = path.joined(separator: ":")
    return environment
}

/// Children started by the fetchers, so quitting the app does not leave them behind.
final class ChildProcesses: @unchecked Sendable {
    static let shared = ChildProcesses()
    private let lock = NSLock()
    private var groups: [pid_t: Bool] = [:]  // pid -> signal its whole process group

    func add(_ pid: pid_t, group: Bool) { lock.lock(); groups[pid] = group; lock.unlock() }
    func remove(_ pid: pid_t) { lock.lock(); groups[pid] = nil; lock.unlock() }
    func terminateAll() {
        lock.lock(); let current = groups; lock.unlock()
        for (pid, group) in current { kill(group ? -pid : pid, SIGTERM) }
    }
}

private let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN); return () }()

/// Waits on `fd` until `deadline`. Returns nil on timeout, empty Data on EOF.
func readChunk(_ fd: Int32, until deadline: Date) -> Data? {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { return nil }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining, 0.25) * 1000) + 1)
        if ready < 0 { if errno == EINTR { continue }; return Data() }
        if ready == 0 { continue }
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { return Data(buffer[0..<count]) }
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        return Data()
    }
}

// MARK: - Codex

/// Turns an `account/rateLimits/read` response line into Usage. Windows up to one day
/// are the session limit (primary); longer windows are the weekly limit (secondary).
func codexUsage(fromResponse data: Data, now: Date) throws -> Usage {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw FetchError("Codex: unreadable app-server response")
    }
    if object["error"] != nil { throw FetchError("Codex: app-server returned an error", reason: .notLoggedIn) }
    guard let result = object["result"] as? [String: Any],
          let limits = result["rateLimits"] as? [String: Any] else {
        throw FetchError("Codex: response has no rateLimits", reason: .notLoggedIn)
    }
    var session: Quota?
    var weekly: Quota?
    for slot in ["primary", "secondary"] {
        guard let window = limits[slot] as? [String: Any], let used = finiteNumber(window["usedPercent"]) else { continue }
        var reset: String?
        if var seconds = finiteNumber(window["resetsAt"]) {
            if seconds > 100_000_000_000 { seconds /= 1000 }  // tolerate milliseconds
            reset = iso8601(Date(timeIntervalSince1970: seconds))
        } else if let text = window["resetsAt"] as? String, parsedDate(text) != nil {
            reset = text
        }
        let quota = Quota(usedPercent: clampPercent(used), resetsAt: reset)
        let isSession = finiteNumber(window["windowDurationMins"]).map { $0 <= 1440 } ?? (slot == "primary")
        if isSession { if session == nil { session = quota } } else if weekly == nil { weekly = quota }
    }
    guard session != nil || weekly != nil else { throw FetchError("Codex: no rate-limit windows reported", reason: .notLoggedIn) }
    return Usage(provider: "codex", updatedAt: iso8601(now), primary: session, secondary: weekly)
}

/// Host-only facts from the same response: window lengths (for pace) and the plan.
/// Never published to the widget; account ids and other fields are ignored.
struct CodexMeta: Equatable {
    var sessionWindow: TimeInterval?
    var weeklyWindow: TimeInterval?
    var plan: String?
    /// Remaining credit balance when the plan carries credits (not unlimited).
    var credits: Double?
}

func codexMeta(fromResponse data: Data) -> CodexMeta {
    var meta = CodexMeta()
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let limits = (object["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return meta }
    for slot in ["primary", "secondary"] {
        guard let window = limits[slot] as? [String: Any], let minutes = finiteNumber(window["windowDurationMins"]),
              minutes > 0 else { continue }
        if minutes <= 1440 { meta.sessionWindow = meta.sessionWindow ?? minutes * 60 }
        else { meta.weeklyWindow = meta.weeklyWindow ?? minutes * 60 }
    }
    if let plan = limits["planType"] as? String {
        let trimmed = plan.trimmingCharacters(in: .whitespaces)
        // Only a short plain word is shown; anything else is ignored.
        if (1...24).contains(trimmed.count), trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
           trimmed.lowercased() != "unknown" {
            meta.plan = trimmed.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    if let credits = limits["credits"] as? [String: Any], credits["hasCredits"] as? Bool == true,
       credits["unlimited"] as? Bool != true {
        let balance = finiteNumber(credits["balance"]) ?? (credits["balance"] as? String).flatMap(Double.init)
        if let balance, balance.isFinite, balance > 0 { meta.credits = balance }
    }
    return meta
}

struct CodexReading {
    let usage: Usage
    let meta: CodexMeta
}

/// Asks `codex app-server` for the current rate limits over newline-delimited JSON-RPC.
/// A configured home is passed as CODEX_HOME; otherwise the inherited environment decides.
func fetchCodexUsage(_ account: AccountConfig, timeout: TimeInterval = 20) throws -> CodexReading {
    _ = ignoreSigpipe
    guard let binary = resolveCLI("codex") else { throw FetchError("Codex: codex CLI not found", reason: .cliNotFound) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["app-server"]
    var environment = childEnvironment(removingClaudeVariables: false, executable: binary)
    if let home = account.directory { environment["CODEX_HOME"] = home }
    process.environment = environment
    process.currentDirectoryURL = realHome
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw FetchError("Codex: could not start codex app-server") }
    let pid = process.processIdentifier
    ChildProcesses.shared.add(pid, group: false)
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let grace = Date().addingTimeInterval(2)
        while process.isRunning && Date() < grace { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
        ChildProcesses.shared.remove(pid)
    }
    let deadline = Date().addingTimeInterval(timeout)
    let reader = output.fileHandleForReading.fileDescriptor
    var buffer = Data()

    func send(_ line: String) throws {
        do { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        catch { throw FetchError("Codex: app-server closed its input") }
    }
    func response(id: Int) throws -> Data {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   finiteNumber(object["id"]).map({ Int($0) }) == id {
                    return line
                }
            }
            guard let chunk = readChunk(reader, until: deadline) else { throw FetchError("Codex: app-server timed out") }
            if chunk.isEmpty { throw FetchError("Codex: app-server exited early") }
            buffer.append(chunk)
        }
    }

    try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-limits","title":"AI Limits","version":"1"}}}"#)
    let initialized = try response(id: 1)
    if let object = (try? JSONSerialization.jsonObject(with: initialized)) as? [String: Any], object["error"] != nil {
        throw FetchError("Codex: app-server rejected initialize")
    }
    try send(#"{"method":"initialized"}"#)
    try send(#"{"id":2,"method":"account/rateLimits/read"}"#)
    let line = try response(id: 2)
    return CodexReading(usage: try codexUsage(fromResponse: line, now: Date()), meta: codexMeta(fromResponse: line))
}

// MARK: - Claude: terminal text

/// Strips terminal escapes. Absolute cursor moves and CR/LF become line breaks;
/// horizontal cursor moves become a space so words stay apart. Whitespace is collapsed.
func terminalLines(_ raw: String) -> [String] {
    let scalars = Array(raw.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\u{1B}" {
            guard index + 1 < scalars.count else { break }
            let next = scalars[index + 1]
            if next == "[" {
                var end = index + 2
                while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) { end += 1 }
                guard end < scalars.count else { break }
                switch scalars[end] {
                case "H", "f": output.append("\n")
                case "C", "G": output.append(" ")
                default: break
                }
                index = end + 1
            } else if ["]", "P", "^", "_", "X"].contains(next) {
                var end = index + 2
                while end < scalars.count {
                    if scalars[end] == "\u{07}" { end += 1; break }
                    if scalars[end] == "\u{1B}", end + 1 < scalars.count, scalars[end + 1] == "\\" { end += 2; break }
                    end += 1
                }
                index = end
            } else {
                var end = index + 1
                while end < scalars.count, (0x20...0x2F).contains(scalars[end].value) { end += 1 }
                index = min(end + 1, scalars.count)
            }
            continue
        }
        if scalar == "\r" || scalar == "\n" {
            output.append("\n")
        } else if scalar == "\t" {
            output.append(" ")
        } else if scalar.value >= 0x20, scalar.value != 0x7F, !(0x80...0x9F).contains(scalar.value) {
            output.append(scalar)
        }
        index += 1
    }
    return String(output).split(separator: "\n").map {
        $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }.filter { !$0.isEmpty }
}

func containsTrustPrompt(_ lines: [String]) -> Bool {
    let compact = lines.joined().lowercased().filter { !$0.isWhitespace }
    return compact.contains("trustthisfolder") || compact.contains("trustthefilesinthisfolder")
}

private func firstMatch(_ pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
}

private let monthNumbers = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

/// "8:29am", "5am", "Nov 10 at 4:59am" (whitespace optional) in `zone`, relative to `now`.
/// A bare time is its next occurrence; a dated reset uses the current year, or the next one
/// when that date would be more than a day in the past.
func parseClaudeReset(_ text: String, zone: TimeZone, now: Date) -> Date? {
    let compact = text.lowercased().filter { !$0.isWhitespace && $0 != "," }
    guard let parts = firstMatch(#"^(?:([a-z]{3})[a-z]*\.?(\d{1,2})(?:at)?)?(\d{1,2})(?::(\d{2}))?(am|pm)?$"#, in: compact),
          let hourText = parts[3], var hour = Int(hourText) else { return nil }
    let minute = parts[4].flatMap { Int($0) } ?? 0
    if let meridiem = parts[5] {
        guard (1...12).contains(hour) else { return nil }
        if meridiem == "am" { hour = hour == 12 ? 0 : hour } else if hour < 12 { hour += 12 }
    } else if parts[4] == nil {
        return nil  // a bare number is not a time
    }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    if let monthText = parts[1], let dayText = parts[2] {
        guard let month = monthNumbers[monthText], let day = Int(dayText), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: now)
        guard let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        else { return nil }
        if candidate < now.addingTimeInterval(-86_400) {
            return calendar.date(from: DateComponents(year: year + 1, month: month, day: day, hour: hour, minute: minute))
        }
        return candidate
    }
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    guard let today = calendar.date(from: components) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
}

struct ClaudeUsageReading {
    let usage: Usage
    let models: [ModelQuota]
    /// All three main pieces are present: used to stop reading early.
    var isComplete: Bool { usage.primary != nil && usage.secondary?.resetsAt != nil }
}

/// Pure parser for the `/usage` screen: terminal text (escapes allowed) + now -> usage.
/// Percentages on the screen are USED percentages.
func parseClaudeUsage(_ raw: String, now: Date) throws -> ClaudeUsageReading {
    let lines = terminalLines(raw)
    if containsTrustPrompt(lines) {
        throw FetchError("Claude: the probe folder is not trusted yet (open claude there once and confirm)", reason: .probeNotTrusted)
    }
    // Split into sections, each starting at a "Current session" / "Current week (X)" header.
    var sections: [(title: String?, body: String)] = []
    let header = try! NSRegularExpression(pattern: #"Current\s*(?:session|week\s*\(([^)]*)\))"#, options: [.caseInsensitive])
    for line in lines {
        let range = NSRange(line.startIndex..., in: line)
        let matches = header.matches(in: line, range: range)
        if matches.isEmpty {
            if !sections.isEmpty { sections[sections.count - 1].body += "\n" + line }
            continue
        }
        if let first = matches.first, let prefix = Range(NSRange(location: 0, length: first.range.location), in: line),
           !sections.isEmpty {
            sections[sections.count - 1].body += "\n" + line[prefix]
        }
        for (offset, match) in matches.enumerated() {
            let title = Range(match.range(at: 1), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = offset + 1 < matches.count ? matches[offset + 1].range.location : range.length
            let body = Range(NSRange(location: bodyStart, length: bodyEnd - bodyStart), in: line).map { String(line[$0]) } ?? ""
            sections.append((title, body))
        }
    }
    var session: Quota?
    var week: Quota?
    var models: [ModelQuota] = []
    for section in sections {
        guard let percentText = firstMatch(#"(\d+(?:\.\d+)?)\s*%\s*used"#, in: section.body)?[1],
              let used = Double(percentText) else { continue }
        var resetsAt: String?
        if let resetText = firstMatch(#"Resets?\s*([^\n]*)"#, in: section.body)?[1] {
            var timeText = resetText
            var zone = TimeZone.current
            if let zoneParts = firstMatch(#"^(.*?)\(\s*([A-Za-z][A-Za-z0-9_+\-/ ]*?)\s*\)"#, in: resetText) {
                timeText = zoneParts[1] ?? ""
                // Any IANA name; a bare abbreviation ("PST") as a fallback; else the system zone.
                if let name = zoneParts[2]?.replacingOccurrences(of: " ", with: ""),
                   let named = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) {
                    zone = named
                }
            }
            resetsAt = parseClaudeReset(timeText, zone: zone, now: now).map(iso8601)
        }
        let quota = Quota(usedPercent: clampPercent(used), resetsAt: resetsAt)
        guard let title = section.title else { session = quota; continue }
        if title.lowercased().filter({ !$0.isWhitespace }) == "allmodels" { week = quota; continue }
        guard !title.isEmpty else { continue }
        let id = "claude-weekly-scoped-" + title.lowercased().split(separator: " ").joined(separator: "-")
        let model = ModelQuota(id: id, title: title, quota: quota)
        // A later repaint of the same section is fresher.
        if let existing = models.firstIndex(where: { $0.id == id }) { models[existing] = model } else { models.append(model) }
    }
    guard session != nil || week != nil else {
        throw FetchError("Claude: no \"Current session\" or \"Current week\" section in /usage output", reason: .notLoggedIn)
    }
    return ClaudeUsageReading(usage: Usage(provider: "claude", updatedAt: iso8601(now), primary: session, secondary: week),
                              models: models)
}

// MARK: - Claude: pseudo-terminal session

/// Only `oauthAccount.subscriptionCreatedAt` is taken from the profile state file.
func claudeSubscriptionAnchor(_ account: AccountConfig) -> String? {
    guard account.kind == .claude, let object = readJSONObject(account.claudeStateFile),
          let anchor = (object["oauthAccount"] as? [String: Any])?["subscriptionCreatedAt"] as? String,
          nextPayment(anchor: anchor, now: Date()) != nil else { return nil }
    return anchor
}

var billingURL: URL { realHome.appendingPathComponent("Library/Application Support/AILimits/billing.json") }

/// Manual payment anchors keyed by account id; malformed keys and entries are ignored.
func loadBillingOverrides() -> [String: String] {
    guard let billing = readJSONObject(billingURL) else { return [:] }
    var result: [String: String] = [:]
    for (id, value) in billing where isValidAccountID(id) {
        if let anchor = value as? String, nextPayment(anchor: anchor, now: Date()) != nil { result[id] = anchor }
    }
    return result
}

func claudeProbeDirectory() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let directory: URL
    if let custom = environment["AI_LIMITS_PROBE_DIR"], !custom.isEmpty {
        directory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    } else {
        directory = realHome.appendingPathComponent("Library/Application Support/AILimits/ClaudeProbe")
    }
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { throw FetchError("Claude: cannot create the probe folder") }
    return directory
}

private let TIOCSWINSZ_REQUEST: UInt = 0x8008_7467  // _IOW('t', 103, struct winsize)

private final class PseudoTerminalChild {
    let master: Int32
    let pid: pid_t
    private var closed = false

    init(executable: String, arguments: [String], environment: [String: String],
         directory: String, rows: UInt16, columns: UInt16) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw FetchError("Claude: no pseudo-terminal available") }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            close(master); throw FetchError("Claude: pseudo-terminal setup failed")
        }
        let slavePath = String(cString: name)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_REQUEST, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { close(master); throw FetchError("Claude: could not start claude") }
        self.master = master
        self.pid = child
        ChildProcesses.shared.add(child, group: true)
    }

    var hasClosed: Bool { closed }

    /// Reads for up to `seconds`; `done(collected, quietSeconds)` may end the read early.
    func read(for seconds: TimeInterval, done: (Data, TimeInterval) -> Bool) -> Data {
        var collected = Data()
        let deadline = Date().addingTimeInterval(seconds)
        var lastOutput = Date()
        while !closed && Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.2))
            if let chunk = readChunk(master, until: slice) {
                if chunk.isEmpty { closed = true } else { collected.append(chunk); lastOutput = Date() }
            }
            if done(collected, Date().timeIntervalSince(lastOutput)) { break }
        }
        return collected
    }

    func resize(rows: UInt16, columns: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_REQUEST, &size)
        kill(pid, SIGWINCH)
    }

    /// SIGTERM to the child's process group, SIGKILL after a short grace, then reap.
    func stop() {
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        var status: Int32 = 0
        var reaped = false
        let grace = Date().addingTimeInterval(1.5)
        while Date() < grace {
            if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
            usleep(50_000)
        }
        if !reaped {
            kill(target, SIGKILL)
            _ = waitpid(pid, &status, 0)
        } else {
            kill(target, SIGKILL)  // leftovers in the child's own group, if any
        }
        close(master)
        ChildProcesses.shared.remove(pid)
    }
}

/// Runs `claude /usage` for one Claude account in a pseudo-terminal. The first paint may show
/// cached numbers, so the first ~10 s are discarded; a window resize then forces one full
/// repaint with fresh values, and only those bytes are parsed.
func fetchClaudeUsage(_ account: AccountConfig) throws -> ClaudeUsageReading {
    guard let binary = resolveCLI("claude") else { throw FetchError("Claude: claude CLI not found", reason: .cliNotFound) }
    let directory = try claudeProbeDirectory()
    // CLAUDE_* variables are dropped, so the default login never inherits a CLAUDE_CONFIG_DIR.
    var environment = childEnvironment(removingClaudeVariables: true, executable: binary)
    environment["TERM"] = "xterm-256color"
    if let configDirectory = account.directory { environment["CLAUDE_CONFIG_DIR"] = configDirectory }
    let child = try PseudoTerminalChild(executable: binary, arguments: ["/usage"], environment: environment,
                                        directory: directory.path, rows: 50, columns: 160)
    defer { child.stop() }

    var trustPrompt = false
    var seenBytes = 0
    let warmup = child.read(for: 10) { data, _ in
        guard data.count != seenBytes else { return false }
        seenBytes = data.count
        trustPrompt = containsTrustPrompt(terminalLines(String(decoding: data, as: UTF8.self)))
        return trustPrompt
    }
    if trustPrompt {
        throw FetchError("Claude: the probe folder is not trusted yet (open claude there once and confirm)", reason: .probeNotTrusted)
    }
    if child.hasClosed && warmup.isEmpty { throw FetchError("Claude: claude exited without output") }

    child.resize(rows: 60, columns: 170)
    let fresh = child.read(for: 5) { data, quiet in
        guard quiet >= 1.5, !data.isEmpty else { return false }
        return (try? parseClaudeUsage(String(decoding: data, as: UTF8.self), now: Date()))?.isComplete ?? false
    }
    return try parseClaudeUsage(String(decoding: fresh, as: UTF8.self), now: Date())
}
