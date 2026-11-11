import Foundation
import Darwin
import Observation

// Host-only token analytics from the local CLI logs.
//
// Privacy: from each log line only the timestamp, the model name, the four token counters
// and the ids used for dedupe are taken; the ids are kept only as 64-bit FNV-1a hashes.
// Paths are stored only as 64-bit hashes too. Conversation text, prompts, file contents,
// working directories and account data are never decoded, kept, printed or logged.
//
// Scale: tens of gigabytes of logs. Files are streamed in fixed chunks, lines are
// prefiltered with memmem before any JSON work, only the needed fields are located by a
// minimal byte-level walker, and per-file offsets make later scans incremental.

// MARK: - Counters and aggregates

struct TokenCounters: Equatable {
    /// Fresh (non-cached) input.
    var input: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    /// Claude 1-hour cache writes: a subset of `cacheWrite`, used only for the cost estimate.
    var cacheWrite1h: Int64 = 0

    var total: Int64 { input + cacheWrite + cacheRead + output }
    var isZero: Bool { total == 0 }

    static func += (lhs: inout TokenCounters, rhs: TokenCounters) {
        lhs.input += rhs.input
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
        lhs.output += rhs.output
        lhs.cacheWrite1h += rhs.cacheWrite1h
    }
}

extension TokenCounters: Codable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        input = try container.decode(Int64.self)
        cacheWrite = try container.decode(Int64.self)
        cacheRead = try container.decode(Int64.self)
        output = try container.decode(Int64.self)
        cacheWrite1h = container.isAtEnd ? 0 : try container.decode(Int64.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(input)
        try container.encode(cacheWrite)
        try container.encode(cacheRead)
        try container.encode(output)
        try container.encode(cacheWrite1h)
    }
}

enum UsageProvider: String, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
}

/// day index (days since 1970-01-01 in the system time zone) -> provider -> model -> counters
typealias UsageDays = [Int: [String: [String: TokenCounters]]]

/// Local day of a timestamp. The offset is taken for that very moment, so days around a
/// DST switch keep their own offset instead of one fixed for the whole range.
func usageDay(epoch: Double, zone: TimeZone = .current) -> Int {
    let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: epoch))
    return Int(floor((epoch + Double(offset)) / 86_400))
}

/// Local midnight that starts `day` (the offset is looked up twice to land across a switch).
func usageDayDate(_ day: Int, zone: TimeZone = .current) -> Date {
    let wall = Double(day) * 86_400
    let guess = wall - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: wall)))
    return Date(timeIntervalSince1970: wall - Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: guess))))
}

enum UsagePeriod: Int, CaseIterable {
    case today, week, month
    var days: Int { [1, 7, 30][rawValue] }
    var title: String { [L("Today", "Сегодня"), L("7 days", "7 дней"), L("30 days", "30 дней")][rawValue] }
}

func usageModels(_ days: UsageDays, provider: UsageProvider, lastDays: Int, today: Int) -> [(model: String, counters: TokenCounters)] {
    var byModel: [String: TokenCounters] = [:]
    for day in (today - lastDays + 1)...today {
        for (model, counters) in days[day]?[provider.rawValue] ?? [:] { byModel[model, default: TokenCounters()] += counters }
    }
    return byModel.filter { !$0.value.isZero }.map { ($0.key, $0.value) }
        .sorted { $0.counters.total != $1.counters.total ? $0.counters.total > $1.counters.total : $0.model < $1.model }
}

func usageTotals(_ days: UsageDays, provider: UsageProvider, lastDays: Int, today: Int) -> TokenCounters {
    var sum = TokenCounters()
    for entry in usageModels(days, provider: provider, lastDays: lastDays, today: today) { sum += entry.counters }
    return sum
}

/// Top models with their token totals; the rest is folded into "other" ("другие").
func foldedModels(_ models: [(model: String, counters: TokenCounters)], limit: Int = 4) -> [(name: String, tokens: Int64)] {
    guard models.count > limit else { return models.map { ($0.model, $0.counters.total) } }
    let head = models.prefix(limit - 1).map { ($0.model, $0.counters.total) }
    let rest = models.dropFirst(limit - 1).reduce(Int64(0)) { $0 + $1.counters.total }
    return head + [(L("other", "другие"), rest)]
}

struct DailyTotal: Equatable {
    let day: Int
    let claude: Int64
    let codex: Int64
    var total: Int64 { claude + codex }
}

func dailyTotals(_ days: UsageDays, today: Int, count: Int = 30) -> [DailyTotal] {
    ((today - count + 1)...today).map { day in
        let sums = UsageProvider.allCases.map { provider in
            (days[day]?[provider.rawValue] ?? [:]).values.reduce(Int64(0)) { $0 + $1.total }
        }
        return DailyTotal(day: day, claude: sums[0], codex: sums[1])
    }
}

// MARK: - Formatting

/// English "999", "12.3K", "1.2M", "3.4B", "1.1T"; Russian "999", "12,3 тыс", "1,2 млн", "3,4 млрд", "1,1 трлн".
func compactTokens(_ value: Int64) -> String {
    let magnitude = Double(abs(value))
    let russian = L10n.language == .ru
    let units: [(Double, String)] = russian ? [(1e12, " трлн"), (1e9, " млрд"), (1e6, " млн"), (1e3, " тыс")]
                                            : [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
    for (scale, name) in units where magnitude >= scale * 0.9995 {
        let scaled = magnitude / scale
        var text = scaled >= 99.95 ? String(Int(scaled.rounded())) : String(format: "%.1f", scaled)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return (value < 0 ? "-" : "") + (russian ? text.replacingOccurrences(of: ".", with: ",") : text) + name
    }
    return String(value)
}

/// English "$4.56", "$87", "$12,345"; Russian "$4,56", "$87", "$12 345" (narrow no-break space).
func compactDollars(_ value: Double) -> String {
    let russian = L10n.language == .ru
    if value < 10 {
        let text = String(format: "%.2f", value)
        return "$" + (russian ? text.replacingOccurrences(of: ".", with: ",") : text)
    }
    let whole = Int(value.rounded())
    var digits = Array(String(whole))
    var index = digits.count - 3
    while index > 0 { digits.insert(russian ? "\u{202F}" : ",", at: index); index -= 3 }
    return "$" + String(digits)
}

// Prices, layers and the cost estimate live in Prices.swift.

// MARK: - Hashing

struct FNV64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func add(_ pointer: UnsafePointer<UInt8>, _ count: Int) {
        var hash = value
        for index in 0..<count {
            hash ^= UInt64(pointer[index])
            hash = hash &* 0x0000_0100_0000_01B3
        }
        value = hash
    }
    mutating func add(_ text: String) {
        var copy = text
        copy.withUTF8 { add($0.baseAddress!, $0.count) }
    }
    mutating func add(byte: UInt8) { var b = byte; add(&b, 1) }
}

func pathKey(_ path: String) -> UInt64 {
    var hash = FNV64()
    hash.add(path)
    return hash.value
}

// MARK: - Minimal JSON walker

/// Byte-level view of one JSON line. It only locates members and decodes the few scalar
/// values the scanner needs; everything else is skipped without being decoded.
struct RawJSON {
    let p: UnsafePointer<UInt8>
    let end: Int

    private static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C

    func skipSpace(_ index: Int) -> Int {
        var i = index
        while i < end, p[i] == 0x20 || p[i] == 0x09 || p[i] == 0x0D || p[i] == 0x0A { i += 1 }
        return i
    }

    /// `index` at an opening quote; returns the index after the closing quote.
    func skipString(_ index: Int) -> Int? {
        var i = index + 1
        while i < end {
            guard let found = memchr(p + i, Int32(Self.quote), end - i) else { return nil }
            let k = UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - p
            var slashes = 0
            var b = k - 1
            while b > index, p[b] == Self.backslash { slashes += 1; b -= 1 }
            if slashes % 2 == 0 { return k + 1 }
            i = k + 1
        }
        return nil
    }

    func skipValue(_ index: Int) -> Int? {
        guard index < end else { return nil }
        switch p[index] {
        case Self.quote:
            return skipString(index)
        case 0x7B, 0x5B:  // { [
            var depth = 0
            var i = index
            while i < end {
                let c = p[i]
                if c == Self.quote {
                    guard let next = skipString(i) else { return nil }
                    i = next
                    continue
                }
                if c == 0x7B || c == 0x5B { depth += 1 } else if c == 0x7D || c == 0x5D {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        default:
            var i = index
            while i < end, p[i] != 0x2C, p[i] != 0x7D, p[i] != 0x5D, p[i] != 0x20 { i += 1 }
            return i
        }
    }

    /// Visits each member of the object at `range`; `visit(key, value)` returns false to stop.
    /// `key` excludes the quotes; `value` is the raw value range.
    @discardableResult
    func forEachMember(_ range: Range<Int>, _ visit: (Range<Int>, Range<Int>) -> Bool) -> Bool {
        var i = skipSpace(range.lowerBound)
        guard i < range.upperBound, p[i] == 0x7B else { return false }
        i = skipSpace(i + 1)
        if i < range.upperBound, p[i] == 0x7D { return true }
        while i < range.upperBound {
            guard p[i] == Self.quote, let keyEnd = skipString(i) else { return false }
            let key = (i + 1)..<(keyEnd - 1)
            i = skipSpace(keyEnd)
            guard i < range.upperBound, p[i] == 0x3A else { return false }
            let valueStart = skipSpace(i + 1)
            guard let valueEnd = skipValue(valueStart), valueEnd <= range.upperBound else { return false }
            if !visit(key, valueStart..<valueEnd) { return true }
            i = skipSpace(valueEnd)
            guard i < range.upperBound else { return false }
            if p[i] == 0x7D { return true }
            guard p[i] == 0x2C else { return false }
            i = skipSpace(i + 1)
        }
        return false
    }

    func equals(_ range: Range<Int>, _ bytes: [UInt8]) -> Bool {
        range.count == bytes.count && bytes.withUnsafeBufferPointer { memcmp(p + range.lowerBound, $0.baseAddress!, bytes.count) == 0 }
    }

    /// String value range (with quotes) equal to `bytes` (without quotes).
    func stringEquals(_ range: Range<Int>, _ bytes: [UInt8]) -> Bool {
        range.count == bytes.count + 2 && p[range.lowerBound] == Self.quote
            && equals((range.lowerBound + 1)..<(range.upperBound - 1), bytes)
    }

    func isObject(_ range: Range<Int>) -> Bool { !range.isEmpty && p[range.lowerBound] == 0x7B }

    /// Inner byte range of a string value without escapes; nil for non-strings or escaped strings.
    func plainString(_ range: Range<Int>) -> Range<Int>? {
        guard range.count >= 2, p[range.lowerBound] == Self.quote, p[range.upperBound - 1] == Self.quote else { return nil }
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        if memchr(p + inner.lowerBound, Int32(Self.backslash), inner.count) != nil { return nil }
        return inner
    }

    func string(_ range: Range<Int>) -> String? {
        if let inner = plainString(range) {
            return String(decoding: UnsafeBufferPointer(start: p + inner.lowerBound, count: inner.count), as: UTF8.self)
        }
        guard range.count >= 2, p[range.lowerBound] == Self.quote else { return nil }
        let data = Data(bytes: p + range.lowerBound, count: range.count)
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
    }

    /// Non-negative integer value; a fractional number is truncated; anything else is nil.
    func integer(_ range: Range<Int>) -> Int64? {
        var value: Int64 = 0
        var digits = 0
        for i in range {
            let c = p[i]
            if c >= 0x30 && c <= 0x39 {
                let (product, overflow1) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = product.addingReportingOverflow(Int64(c - 0x30))
                if overflow1 || overflow2 { return nil }
                value = sum
                digits += 1
            } else if c == 0x2E, digits > 0 {  // fractional part is dropped
                return value
            } else {
                return nil
            }
        }
        return digits > 0 ? value : nil
    }

    /// Epoch seconds of an ISO8601 string value: "YYYY-MM-DDTHH:MM:SS(.fff)(Z|±HH:MM)".
    func timestamp(_ range: Range<Int>) -> Double? {
        guard let inner = plainString(range), inner.count >= 20 else { return nil }
        let s = p + inner.lowerBound
        let n = inner.count
        func digits(_ at: Int, _ count: Int) -> Int? {
            var value = 0
            for i in at..<(at + count) {
                let c = s[i]
                guard c >= 0x30 && c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard s[4] == 0x2D, s[7] == 0x2D, s[10] == 0x54 || s[10] == 0x20, s[13] == 0x3A, s[16] == 0x3A,
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var i = 19
        var fraction = 0.0
        if i < n, s[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < n, s[i] >= 0x30 && s[i] <= 0x39 { fraction += Double(s[i] - 0x30) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        guard i < n else { return nil }
        if s[i] == 0x5A {  // Z
            offset = 0
        } else if s[i] == 0x2B || s[i] == 0x2D, i + 6 <= n, let oh = digits(i + 1, 2), let om = digits(i + 4, 2) {
            offset = (oh * 3600 + om * 60) * (s[i] == 0x2D ? -1 : 1)
        } else {
            return nil
        }
        // Days from civil (Howard Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }
}

// MARK: - Line parsers

struct UsageRecord {
    let hash: UInt64
    let day: Int
    let provider: UsageProvider
    let model: String
    let counters: TokenCounters
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// memmem needles, allocated once.
final class Needle: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    let count: Int
    init(_ text: String) {
        let utf8 = Array(text.utf8)
        count = utf8.count
        pointer = .allocate(capacity: count)
        pointer.initialize(from: utf8, count: count)
    }
    func found(in line: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        memmem(line, length, pointer, count) != nil
    }
}

private enum Keys {
    static let type = bytes("type"), message = bytes("message"), requestId = bytes("requestId")
    static let timestamp = bytes("timestamp"), id = bytes("id"), model = bytes("model"), usage = bytes("usage")
    static let assistant = bytes("assistant"), synthetic = bytes("<synthetic>")
    static let inputTokens = bytes("input_tokens"), cacheCreation = bytes("cache_creation_input_tokens")
    static let cacheRead = bytes("cache_read_input_tokens"), outputTokens = bytes("output_tokens")
    static let cacheCreationDetail = bytes("cache_creation"), ephemeral1h = bytes("ephemeral_1h_input_tokens")
    static let cachedInput = bytes("cached_input_tokens"), cacheWriteInput = bytes("cache_write_input_tokens")
    static let payload = bytes("payload"), responseId = bytes("response_id")
    static let tokenUsageRecord = bytes("token_usage_record"), turnContext = bytes("turn_context")
    static let eventMsg = bytes("event_msg"), tokenCount = bytes("token_count"), info = bytes("info")
    static let totalTokenUsage = bytes("total_token_usage"), lastTokenUsage = bytes("last_token_usage")
    static let totalTokens = bytes("total_tokens")
}

private let needleUsage = Needle("\"usage\"")
private let needleAssistant = Needle("\"assistant\"")
private let needleTokenUsageRecord = Needle("\"token_usage_record\"")
private let needleTurnContext = Needle("\"turn_context\"")
private let needleTokenCount = Needle("\"token_count\"")

/// Interns model names so records share one String per distinct model.
final class ModelNames {
    private var names: [UInt64: String] = [:]
    func name(_ json: RawJSON, _ range: Range<Int>) -> String? {
        guard let inner = json.plainString(range) else { return json.string(range) }
        var hash = FNV64()
        hash.add(json.p + inner.lowerBound, inner.count)
        if let known = names[hash.value] { return known }
        guard let text = json.string(range), !text.isEmpty, text.count <= 80 else { return nil }
        names[hash.value] = text
        return text
    }
}

/// Claude Code transcript line -> record. Counts `type == "assistant"` lines that carry
/// message.usage; skips the "<synthetic>" model. Dedupe key: (message.id, requestId).
func parseClaudeLine(_ line: UnsafePointer<UInt8>, _ length: Int, names: ModelNames) -> UsageRecord? {
    guard needleUsage.found(in: line, length), needleAssistant.found(in: line, length) else { return nil }
    let json = RawJSON(p: line, end: length)
    var typeOK = false
    var message: Range<Int>?, requestId: Range<Int>?, timestamp: Range<Int>?
    json.forEachMember(0..<length) { key, value in
        if json.equals(key, Keys.type) { typeOK = json.stringEquals(value, Keys.assistant) }
        else if json.equals(key, Keys.message) { message = value }
        else if json.equals(key, Keys.requestId) { requestId = value }
        else if json.equals(key, Keys.timestamp) { timestamp = value }
        return true
    }
    guard typeOK, let message, json.isObject(message), let timestamp, let epoch = json.timestamp(timestamp) else { return nil }
    var id: Range<Int>?, model: Range<Int>?, usage: Range<Int>?
    json.forEachMember(message) { key, value in
        if json.equals(key, Keys.id) { id = value }
        else if json.equals(key, Keys.model) { model = value }
        else if json.equals(key, Keys.usage) { usage = value }
        return true
    }
    guard let usage, json.isObject(usage), let model, !json.stringEquals(model, Keys.synthetic),
          let modelName = names.name(json, model) else { return nil }
    var counters = TokenCounters()
    json.forEachMember(usage) { key, value in
        if json.equals(key, Keys.inputTokens) { counters.input = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.cacheCreation) { counters.cacheWrite = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.cacheRead) { counters.cacheRead = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.outputTokens) { counters.output = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.cacheCreationDetail), json.isObject(value) {
            json.forEachMember(value) { inner, number in
                if json.equals(inner, Keys.ephemeral1h) { counters.cacheWrite1h = json.integer(number) ?? 0; return false }
                return true
            }
        }
        return true
    }
    // The 1-hour part is a subset of all cache writes.
    counters.cacheWrite1h = min(counters.cacheWrite1h, counters.cacheWrite)
    var hash = FNV64()
    hash.add(byte: 0x63)  // "c"
    if let id, let inner = json.plainString(id) { hash.add(line + inner.lowerBound, inner.count) }
    hash.add(byte: 0x7C)
    if let requestId, let inner = json.plainString(requestId) { hash.add(line + inner.lowerBound, inner.count) }
    guard id != nil || requestId != nil else { return nil }
    return UsageRecord(hash: hash.value, day: usageDay(epoch: epoch), provider: .claude, model: modelName, counters: counters)
}

/// Codex usage object -> counters. input_tokens includes cached input, output includes reasoning.
private func codexCounters(_ json: RawJSON, _ usage: Range<Int>) -> TokenCounters {
    var input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0
    json.forEachMember(usage) { key, value in
        if json.equals(key, Keys.inputTokens) { input = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.cachedInput) { cached = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.cacheWriteInput) { cacheWrite = json.integer(value) ?? 0 }
        else if json.equals(key, Keys.outputTokens) { output = json.integer(value) ?? 0 }
        return true
    }
    let fresh = max(0, input - cached)
    // Cache writes are assumed to be part of input_tokens when they fit (always 0 so far).
    let freshInput = cacheWrite <= fresh ? fresh - cacheWrite : fresh
    return TokenCounters(input: freshInput, cacheWrite: cacheWrite, cacheRead: cached, output: output)
}

/// Per-file Codex state machine: tracks the model from turn_context lines, counts
/// token_usage_record lines, and keeps token_count events as a fallback for files
/// that have no token_usage_record at all.
struct CodexFileParser {
    var model: String?
    var sawUsageRecords: Bool
    var lastTotal: Int64?
    let pathHash: UInt64
    private(set) var records: [UsageRecord] = []
    private var fallback: [UsageRecord] = []

    init(model: String?, sawUsageRecords: Bool, lastTotal: Int64?, pathHash: UInt64) {
        self.model = model
        self.sawUsageRecords = sawUsageRecords
        self.lastTotal = lastTotal
        self.pathHash = pathHash
    }

    /// Records to merge: token_usage_record ones, or the token_count fallback when the
    /// file never had a token_usage_record line.
    var output: [UsageRecord] { sawUsageRecords ? records : records + fallback }

    private func topLevel(_ json: RawJSON, _ length: Int, wantType: [UInt8]) -> (payload: Range<Int>, timestamp: Range<Int>?)? {
        var typeOK = false, typeSeen = false
        var payload: Range<Int>?, timestamp: Range<Int>?
        json.forEachMember(0..<length) { key, value in
            if json.equals(key, Keys.type) {
                typeSeen = true
                typeOK = json.stringEquals(value, wantType)
                return typeOK  // stop early on another line type
            }
            if json.equals(key, Keys.payload) { payload = value }
            else if json.equals(key, Keys.timestamp) { timestamp = value }
            return true
        }
        guard typeSeen, typeOK, let payload, json.isObject(payload) else { return nil }
        return (payload, timestamp)
    }

    mutating func consume(_ line: UnsafePointer<UInt8>, _ length: Int, names: ModelNames) {
        let json = RawJSON(p: line, end: length)
        if needleTokenUsageRecord.found(in: line, length) {
            guard let (payload, timestamp) = topLevel(json, length, wantType: Keys.tokenUsageRecord),
                  let timestamp, let epoch = json.timestamp(timestamp) else { return }
            var responseId: Range<Int>?, usage: Range<Int>?
            json.forEachMember(payload) { key, value in
                if json.equals(key, Keys.responseId) { responseId = value }
                else if json.equals(key, Keys.usage) { usage = value }
                return true
            }
            guard let responseId, let inner = json.plainString(responseId), !inner.isEmpty,
                  let usage, json.isObject(usage) else { return }
            sawUsageRecords = true
            fallback.removeAll()
            var hash = FNV64()
            hash.add(byte: 0x78)  // "x"
            hash.add(line + inner.lowerBound, inner.count)
            records.append(UsageRecord(hash: hash.value, day: usageDay(epoch: epoch), provider: .codex,
                                       model: model ?? "unknown", counters: codexCounters(json, usage)))
            return
        }
        if needleTurnContext.found(in: line, length) {
            guard let (payload, _) = topLevel(json, length, wantType: Keys.turnContext) else { return }
            json.forEachMember(payload) { key, value in
                if json.equals(key, Keys.model) {
                    if let name = names.name(json, value) { model = name }
                    return false
                }
                return true
            }
            return
        }
        if !sawUsageRecords, needleTokenCount.found(in: line, length) {
            guard let (payload, timestamp) = topLevel(json, length, wantType: Keys.eventMsg),
                  let timestamp, let epoch = json.timestamp(timestamp) else { return }
            var isTokenCount = false
            var info: Range<Int>?
            json.forEachMember(payload) { key, value in
                if json.equals(key, Keys.type) { isTokenCount = json.stringEquals(value, Keys.tokenCount) }
                else if json.equals(key, Keys.info) { info = value }
                return true
            }
            guard isTokenCount, let info, json.isObject(info) else { return }
            var total: Range<Int>?, last: Range<Int>?
            json.forEachMember(info) { key, value in
                if json.equals(key, Keys.totalTokenUsage) { total = value }
                else if json.equals(key, Keys.lastTokenUsage) { last = value }
                return true
            }
            guard let total, json.isObject(total), let last, json.isObject(last) else { return }
            var cumulative: Int64?
            json.forEachMember(total) { key, value in
                if json.equals(key, Keys.totalTokens) { cumulative = json.integer(value); return false }
                return true
            }
            guard let cumulative, cumulative != lastTotal else { return }
            lastTotal = cumulative
            var hash = FNV64()
            hash.add(byte: 0x74)  // "t"
            var key = pathHash
            withUnsafeBytes(of: &key) { hash.add($0.bindMemory(to: UInt8.self).baseAddress!, 8) }
            var value = cumulative
            withUnsafeBytes(of: &value) { hash.add($0.bindMemory(to: UInt8.self).baseAddress!, 8) }
            fallback.append(UsageRecord(hash: hash.value, day: usageDay(epoch: epoch), provider: .codex,
                                        model: model ?? "unknown", counters: codexCounters(json, last)))
        }
    }
}

// MARK: - Chunked line reader

/// Streams `path` from `offset` in fixed-size chunks and calls `line` for every complete
/// line (without the newline). Lines spanning chunks are joined. A trailing partial line is
/// left for the next scan. Returns the offset after the last complete line, the file
/// position reached and the bytes read.
func readLines(path: String, from offset: Int64, chunkSize: Int,
               line: (UnsafePointer<UInt8>, Int) -> Void) -> (committed: Int64, reached: Int64, bytesRead: Int64)? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)  // do not evict the user's page cache with tens of gigabytes
    guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return nil }
    let size = max(1, chunkSize)
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    var carry: [UInt8] = []
    var position = offset
    var committed = offset
    var bytesRead: Int64 = 0
    while true {
        let count = read(fd, buffer, size)
        if count < 0 { if errno == EINTR { continue }; break }
        if count == 0 { break }
        bytesRead += Int64(count)
        var start = 0
        while start < count {
            guard let found = memchr(buffer + start, 0x0A, count - start) else { break }
            let newline = found.assumingMemoryBound(to: UInt8.self) - buffer
            if carry.isEmpty {
                line(UnsafePointer(buffer + start), newline - start)
            } else {
                carry.append(contentsOf: UnsafeBufferPointer(start: buffer + start, count: newline - start))
                carry.withUnsafeBufferPointer { line($0.baseAddress!, $0.count) }
                carry = []
            }
            start = newline + 1
            committed = position + Int64(start)
        }
        if start < count { carry.append(contentsOf: UnsafeBufferPointer(start: buffer + start, count: count - start)) }
        position += Int64(count)
    }
    return (committed, position, bytesRead)
}

// MARK: - Cache

struct ScanFileState: Codable, Equatable {
    var size: Int64
    var mtime: Double
    var offset: Int64
    /// Codex: last turn_context model, whether token_usage_record lines exist, last cumulative total.
    var model: String?
    var records: Bool?
    var lastTotal: Int64?
}

struct UsageCacheFile: Codable {
    var version: Int
    /// Time zone identifier the day indexes were computed in.
    var zone: String?
    var files: [String: ScanFileState]
    var days: [String: [String: [String: TokenCounters]]]
}

/// 2: counters carry the Claude 1-hour cache writes. 3: days are in the system zone, stored
/// in `zone`. Older caches, or a cache from another zone, are rescanned.
private let usageCacheVersion = 3

private func usableCache(_ data: Data?) -> UsageCacheFile? {
    guard let data, let file = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
          file.version == usageCacheVersion, file.zone == TimeZone.current.identifier else { return nil }
    return file
}
private let seenMagic: [UInt8] = Array("AILSEEN1".utf8)

var defaultUsageCacheURL: URL {
    if let custom = ProcessInfo.processInfo.environment["AI_LIMITS_USAGE_CACHE"], !custom.isEmpty {
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    }
    return appDataFolder.appendingPathComponent("usage-cache.json")
}

/// The dedupe hashes live next to the JSON cache in a compact binary file.
func seenURL(for cacheURL: URL) -> URL { cacheURL.deletingPathExtension().appendingPathExtension("seen") }

struct UsageState {
    var files: [UInt64: ScanFileState] = [:]
    var days: UsageDays = [:]
    /// record hash -> day index, so hashes of dropped days can be dropped too.
    var seen: [UInt64: Int32] = [:]
}

func loadUsageDays(_ cacheURL: URL) -> UsageDays? {
    guard let file = usableCache(try? Data(contentsOf: cacheURL)) else { return nil }
    return decodeDays(file.days)
}

private func decodeDays(_ raw: [String: [String: [String: TokenCounters]]]) -> UsageDays {
    var days: UsageDays = [:]
    for (key, value) in raw { if let day = Int(key) { days[day] = value } }
    return days
}

func loadUsageState(_ cacheURL: URL) -> UsageState {
    guard let file = usableCache(try? Data(contentsOf: cacheURL)) else { return UsageState() }
    var state = UsageState()
    for (key, value) in file.files { if let hash = UInt64(key, radix: 16) { state.files[hash] = value } }
    state.days = decodeDays(file.days)
    if let seen = try? Data(contentsOf: seenURL(for: cacheURL)), seen.count >= 8, Array(seen.prefix(8)) == seenMagic {
        let count = (seen.count - 8) / 12
        state.seen.reserveCapacity(count)
        seen.withUnsafeBytes { raw in
            for index in 0..<count {
                let base = 8 + index * 12
                let hash = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: UInt64.self))
                let day = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 8, as: Int32.self))
                state.seen[hash] = day
            }
        }
    } else {
        // Without the dedupe set the offsets cannot be trusted: start over.
        return UsageState()
    }
    return state
}

private func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func saveUsageState(_ state: UsageState, to cacheURL: URL) throws {
    var files: [String: ScanFileState] = [:]
    for (key, value) in state.files { files[String(key, radix: 16)] = value }
    var days: [String: [String: [String: TokenCounters]]] = [:]
    for (key, value) in state.days { days[String(key)] = value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var seen = Data(seenMagic)
    seen.reserveCapacity(8 + state.seen.count * 12)
    for (hash, day) in state.seen {
        var h = hash.littleEndian, d = day.littleEndian
        withUnsafeBytes(of: &h) { seen.append(contentsOf: $0) }
        withUnsafeBytes(of: &d) { seen.append(contentsOf: $0) }
    }
    // Hashes first: a cache JSON without its dedupe file would be discarded on load.
    try writePrivate(seen, to: seenURL(for: cacheURL))
    try writePrivate(encoder.encode(UsageCacheFile(version: usageCacheVersion, zone: TimeZone.current.identifier,
                                                                     files: files, days: days)), to: cacheURL)
}

// MARK: - Scanner

/// Log folders to scan; derived from the accounts (Accounts.swift).
struct UsageSources: Equatable {
    var claudeRoots: [URL]
    var codexRoots: [URL]
}

struct ScanOutcome {
    var days: UsageDays
    var filesConsidered = 0
    var filesScanned = 0
    var filesRescanned = 0
    var bytesRead: Int64 = 0
    var recordsFound = 0
    var recordsAdded = 0
    var seconds: Double = 0
}

private struct ScanJob {
    let path: String
    let key: UInt64
    let provider: UsageProvider
    let size: Int64
    let mtime: Double
    let start: Int64
    let previous: ScanFileState?
}

private struct JobResult {
    let key: UInt64
    let state: ScanFileState?
    let records: [UsageRecord]
    let bytesRead: Int64
}

/// Lists *.jsonl files under `root` modified at or after `cutoff`.
private func listFiles(_ root: URL, provider: UsageProvider, cutoff: Date) -> [(String, UsageProvider, Int64, Double)] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants]) else { return [] }
    var result: [(String, UsageProvider, Int64, Double)] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
              let modified = values.contentModificationDate, modified >= cutoff else { continue }
        result.append((url.path, provider, Int64(values.fileSize ?? 0), modified.timeIntervalSince1970))
    }
    return result
}

private func runJob(_ job: ScanJob, chunkSize: Int) -> JobResult {
    let names = ModelNames()
    var records: [UsageRecord] = []
    let fresh = job.start == 0
    var codex = CodexFileParser(model: fresh ? nil : job.previous?.model,
                                sawUsageRecords: fresh ? false : (job.previous?.records ?? false),
                                lastTotal: fresh ? nil : job.previous?.lastTotal, pathHash: job.key)
    let outcome = readLines(path: job.path, from: job.start, chunkSize: chunkSize) { line, length in
        switch job.provider {
        case .claude: if let record = parseClaudeLine(line, length, names: names) { records.append(record) }
        case .codex: codex.consume(line, length, names: names)
        }
    }
    guard let outcome else { return JobResult(key: job.key, state: job.previous, records: [], bytesRead: 0) }
    if job.provider == .codex { records = codex.output }
    let state = ScanFileState(size: max(job.size, outcome.reached), mtime: job.mtime, offset: outcome.committed,
                              model: job.provider == .codex ? codex.model : nil,
                              records: job.provider == .codex ? codex.sawUsageRecords : nil,
                              lastTotal: job.provider == .codex ? codex.lastTotal : nil)
    return JobResult(key: job.key, state: state, records: records, bytesRead: outcome.bytesRead)
}

/// One synchronous scan. With `cacheURL` nil nothing is loaded or saved.
func scanUsage(sources: UsageSources, cacheURL: URL?, now: Date = Date(),
               chunkSize: Int = 2 << 20, concurrency: Int = 4) -> ScanOutcome {
    let started = Date()
    var state = cacheURL.map(loadUsageState) ?? UsageState()
    let today = usageDay(epoch: now.timeIntervalSince1970)
    let keepFrom = today - 30
    state.days = state.days.filter { $0.key >= keepFrom && $0.key <= today + 1 }
    state.seen = state.seen.filter { Int($0.value) >= keepFrom }

    let cutoff = now.addingTimeInterval(-31 * 86_400)
    var listed: [(String, UsageProvider, Int64, Double)] = []
    for root in sources.claudeRoots { listed += listFiles(root, provider: .claude, cutoff: cutoff) }
    for root in sources.codexRoots { listed += listFiles(root, provider: .codex, cutoff: cutoff) }

    var outcome = ScanOutcome(days: [:])
    outcome.filesConsidered = listed.count
    var jobs: [ScanJob] = []
    var keptFiles: [UInt64: ScanFileState] = [:]
    for (path, provider, size, mtime) in listed {
        let key = pathKey(path)
        let previous = state.files[key]
        if let previous, previous.size == size, previous.mtime == mtime {
            keptFiles[key] = previous
            continue
        }
        var start: Int64 = 0
        if let previous, size >= previous.size, previous.offset <= size { start = previous.offset }
        if previous != nil && start == 0 { outcome.filesRescanned += 1 }
        jobs.append(ScanJob(path: path, key: key, provider: provider, size: size, mtime: mtime, start: start, previous: previous))
    }
    // Large files first so the parallel batches stay balanced.
    jobs.sort { ($0.size - $0.start) > ($1.size - $1.start) }
    outcome.filesScanned = jobs.count

    let batchSize = max(1, concurrency) * 8
    var index = 0
    while index < jobs.count {
        let batch = Array(jobs[index..<min(jobs.count, index + batchSize)])
        index += batch.count
        var results = [JobResult?](repeating: nil, count: batch.count)
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, concurrency)
        queue.qualityOfService = .utility
        for (position, job) in batch.enumerated() {
            queue.addOperation {
                let result = runJob(job, chunkSize: chunkSize)
                lock.lock(); results[position] = result; lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        for result in results.compactMap({ $0 }) {
            if let fileState = result.state { keptFiles[result.key] = fileState }
            outcome.bytesRead += result.bytesRead
            outcome.recordsFound += result.records.count
            for record in result.records where record.day >= keepFrom && record.day <= today + 1 {
                guard state.seen[record.hash] == nil else { continue }
                state.seen[record.hash] = Int32(record.day)
                state.days[record.day, default: [:]][record.provider.rawValue, default: [:]][record.model, default: TokenCounters()] += record.counters
                outcome.recordsAdded += 1
            }
        }
    }
    state.files = keptFiles
    if let cacheURL { try? saveUsageState(state, to: cacheURL) }
    outcome.days = state.days
    outcome.seconds = Date().timeIntervalSince(started)
    return outcome
}

// MARK: - App-side monitor

/// Models with tokens in the last 30 days and no price ("unknown" Codex turns are not models).
func unpricedRecentModels(_ days: UsageDays, prices: [String: ModelPrice], today: Int) -> [String] {
    UsageProvider.allCases.flatMap { provider in
        unpricedModels(usageModels(days, provider: provider, lastDays: 30, today: today), prices: prices)
    }.filter { $0 != "unknown" }
}

@MainActor @Observable final class UsageMonitor {
    private(set) var days: UsageDays = [:]
    private(set) var priceBook = PriceBook.builtIn
    private(set) var scanning = false
    private(set) var lastScan: Date?
    /// Log folders of the configured accounts; nil until the accounts are known (no scan before).
    var sources: UsageSources? {
        didSet { if sources != oldValue { requestScan(force: true) } }
    }

    /// After every scan: models with tokens in the last 30 days and no price.
    @ObservationIgnored var onScan: (([String]) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "ai-limits.usage", qos: .utility)
    /// A forced scan asked for while one ran (new sources, new time zone): run it afterwards.
    @ObservationIgnored private var rescanPending = false

    init(cacheURL: URL = defaultUsageCacheURL) {
        self.cacheURL = cacheURL
        let url = cacheURL
        Task {
            let (cached, book) = await Task.detached(priority: .utility) { (loadUsageDays(url), loadPriceBook()) }.value
            if let cached, lastScan == nil { days = cached }
            self.priceBook = book
            requestScan(force: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestScan(force: true) }
        }
        timer?.tolerance = 30
    }

    /// Re-reads the price layers (after a download or an edited prices.json).
    func reloadPrices() {
        Task {
            let book = await Task.detached(priority: .utility) { loadPriceBook() }.value
            self.priceBook = book
        }
    }

    /// Debounced: ignored while a scan runs or within a minute of the last one unless forced.
    func requestScan(force: Bool = false) {
        guard let sources else { return }
        guard !scanning else { if force { rescanPending = true }; return }
        if !force, let lastScan, Date().timeIntervalSince(lastScan) < 60 { return }
        scanning = true
        let url = cacheURL
        queue.async {
            let outcome = scanUsage(sources: sources, cacheURL: url)
            let book = loadPriceBook()
            let unpriced = unpricedRecentModels(outcome.days, prices: book.prices,
                                                today: usageDay(epoch: Date().timeIntervalSince1970))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.days = outcome.days
                self.priceBook = book
                self.lastScan = Date()
                self.scanning = false
                self.onScan?(unpriced)
                if self.rescanPending {
                    self.rescanPending = false
                    self.requestScan(force: true)
                }
            }
        }
    }
}

// MARK: - CLI report

private func countersLine(_ c: TokenCounters) -> String {
    "total=\(c.total) input=\(c.input) cache_write=\(c.cacheWrite) cache_write_1h=\(c.cacheWrite1h) cache_read=\(c.cacheRead) output=\(c.output)"
}

/// `AILimits --analytics [--no-cache]`: one synchronous scan, aggregates only.
func runAnalyticsReport(useCache: Bool) {
    let cacheURL = useCache ? defaultUsageCacheURL : nil
    let sources = UsageSources(configuration: loadAccountsConfiguration())
    let outcome = scanUsage(sources: sources, cacheURL: cacheURL)
    let today = usageDay(epoch: Date().timeIntervalSince1970)
    let book = loadPriceBook()
    let periodNames = ["today", "7d", "30d"]
    print("AI Limits analytics: local CLI logs, days in \(TimeZone.current.identifier)")
    for provider in UsageProvider.allCases {
        for period in UsagePeriod.allCases {
            let totals = usageTotals(outcome.days, provider: provider, lastDays: period.days, today: today)
            print("\(provider.rawValue) \(periodNames[period.rawValue]): \(countersLine(totals))")
        }
    }
    print("models, 30d:")
    for provider in UsageProvider.allCases {
        for entry in usageModels(outcome.days, provider: provider, lastDays: 30, today: today) {
            let source = priceKey(for: entry.model, in: book.prices).flatMap { book.sources[$0]?.rawValue } ?? "no price"
            print("  \(provider.rawValue) \(entry.model): \(countersLine(entry.counters)) price=\(source)")
        }
    }
    print("estimated API cost, USD (prices as of \(iso8601(book.asOf))):")
    for provider in UsageProvider.allCases {
        let costs = UsagePeriod.allCases.map { period -> String in
            let models = usageModels(outcome.days, provider: provider, lastDays: period.days, today: today)
            let value = estimatedCost(models, prices: book.prices).map { String(format: "%.2f", $0) } ?? "n/a"
            return "\(periodNames[period.rawValue])=\(value)"
        }
        print("  \(provider.rawValue): \(costs.joined(separator: " "))")
    }
    let unpriced = UsageProvider.allCases.flatMap {
        unpricedModels(usageModels(outcome.days, provider: $0, lastDays: 30, today: today), prices: book.prices)
    }
    print("unpriced models, 30d: \(unpriced.isEmpty ? "none" : unpriced.joined(separator: ", "))")
    print("files: considered=\(outcome.filesConsidered) scanned=\(outcome.filesScanned) rescanned_from_zero=\(outcome.filesRescanned)")
    print("bytes_read=\(outcome.bytesRead) records_found=\(outcome.recordsFound) records_added=\(outcome.recordsAdded)")
    print("seconds=\(String(format: "%.2f", outcome.seconds)) cache=\(useCache ? "on" : "off")")
}
