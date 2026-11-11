import Foundation

// Host-only API price tables for the "≈ $N at API prices" estimate.
//
// NETWORK: this file holds the ONLY network code of the app. It downloads exactly two public
// pricing pages (the compile-time constants in `PriceVendor.url`) with an ephemeral URLSession:
// GET only, no cookies, no credentials, no cache, a fixed User-Agent, 20 s timeout, 2 MB cap,
// redirects to any other host refused. Nothing derived from user data (logs, models, tokens,
// paths, accounts) is ever sent. Limits are still fetched only through the user's CLIs.
//
// Layers, merged per model key, highest priority first:
//   1. prices.json       — written by the user (optional),
//   2. prices-auto.json  — downloaded and validated by this file,
//   3. builtInPrices     — reference table compiled into the app.
// Lookup: the longest key that is a prefix of the log model name.

// MARK: - Model price

/// USD per million tokens. `cacheWrite` is the 5-minute cache write, `cacheWrite1h` the 1-hour one.
struct ModelPrice: Equatable {
    var input: Double
    var cacheWrite: Double
    var cacheWrite1h: Double
    var cacheRead: Double
    var output: Double

    /// A missing 1-hour price falls back to the 5-minute one (the pre-1h behaviour).
    init(input: Double, cacheWrite: Double, cacheWrite1h: Double? = nil, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h ?? cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }
}

enum PriceSource: String {
    case user = "prices.json"
    case downloaded = "prices-auto.json"
    case builtin = "built-in"
}

enum PriceVendor: String, CaseIterable {
    case anthropic, openai

    /// Compile-time constants: the only URLs the app ever requests.
    var url: URL {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
        case .openai: return URL(string: "https://developers.openai.com/api/docs/pricing.md")!
        }
    }

    func parse(_ markdown: String) -> [String: ModelPrice] {
        switch self {
        case .anthropic: return parseAnthropicPricing(markdown)
        case .openai: return parseOpenAIPricing(markdown)
        }
    }
}

// MARK: - Built-in reference table

/// Date the built-in table was checked against the official pages.
let builtInPricesDateText = "2026-11-10"
var builtInPricesDate: Date { parsedDate(builtInPricesDateText + "T00:00:00Z") ?? Date(timeIntervalSince1970: 0) }

let builtInPrices: [String: ModelPrice] = {
    func claude(_ i: Double, _ w5: Double, _ w1: Double, _ r: Double, _ o: Double) -> ModelPrice {
        ModelPrice(input: i, cacheWrite: w5, cacheWrite1h: w1, cacheRead: r, output: o)
    }
    func openai(_ i: Double, _ r: Double, _ o: Double) -> ModelPrice {
        ModelPrice(input: i, cacheWrite: i, cacheWrite1h: i, cacheRead: r, output: o)
    }
    return [
        "claude-fable-5-2": claude(8, 10, 16, 0.20, 40),
        "claude-fable-5-1": claude(10, 12.50, 20, 0.25, 50),
        "claude-fable-5": claude(10, 12.50, 20, 1, 50),
        "claude-opus-5-5": claude(4, 5, 8, 0.20, 20),
        "claude-opus-5": claude(5, 6.25, 10, 0.50, 25),
        "claude-sonnet-5-5": claude(2, 2.50, 4, 0.10, 10),
        "claude-sonnet-5": claude(2, 2.50, 4, 0.20, 10),
        // Haiku 5.5: the "up to 100,000 tokens" tier.
        "claude-haiku-5-5": claude(0.10, 0.125, 0.20, 0.01, 0.50),
        "claude-haiku-4-5": claude(1, 1.25, 2, 0.10, 5),
        "gpt-6-astra": openai(10, 1, 50),
        "gpt-6.1-sol": openai(2, 0.10, 10),
        "gpt-6.1-terra": openai(1, 0.05, 5),
    ]
}()

// MARK: - Paths

var pricesURL: URL { appDataFolder.appendingPathComponent("prices.json") }

var defaultAutoPricesURL: URL {
    if let custom = ProcessInfo.processInfo.environment["AI_LIMITS_PRICES_AUTO"], !custom.isEmpty {
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
    }
    return appDataFolder.appendingPathComponent("prices-auto.json")
}

// MARK: - User file (prices.json)

private func priceNumber(_ entry: [String: Any], _ key: String) -> Double? {
    guard let number = entry[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
    return number.doubleValue
}

/// `{"prefix": {"input": .., "cacheWrite": .., "cacheWrite1h": .., "cacheRead": .., "output": ..}}`.
/// Missing fields are 0, except a missing cacheWrite1h which equals cacheWrite.
func parsePrices(_ data: Data) -> [String: ModelPrice] {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    var result: [String: ModelPrice] = [:]
    for (prefix, value) in object {
        guard !prefix.isEmpty, let entry = value as? [String: Any] else { continue }
        result[prefix] = ModelPrice(input: priceNumber(entry, "input") ?? 0, cacheWrite: priceNumber(entry, "cacheWrite") ?? 0,
                                    cacheWrite1h: priceNumber(entry, "cacheWrite1h"),
                                    cacheRead: priceNumber(entry, "cacheRead") ?? 0, output: priceNumber(entry, "output") ?? 0)
    }
    return result
}

func loadPrices(_ url: URL = pricesURL) -> [String: ModelPrice] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return parsePrices(data)
}

// MARK: - Downloaded file (prices-auto.json)

struct AutoPrices: Equatable {
    /// Last time at least one vendor was accepted.
    var fetchedAt: Date?
    /// Last attempt, successful or not (drives the throttle).
    var lastAttemptAt: Date?
    var vendorFetchedAt: [String: Date] = [:]
    var models: [String: ModelPrice] = [:]
    var vendorOf: [String: String] = [:]
}

private func isoDate(_ value: Any?) -> Date? { parsedDate(value as? String) }

func parseAutoPrices(_ data: Data) -> AutoPrices {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return AutoPrices() }
    var result = AutoPrices(fetchedAt: isoDate(object["fetchedAt"]), lastAttemptAt: isoDate(object["lastAttemptAt"]))
    for (vendor, value) in object["vendors"] as? [String: Any] ?? [:] {
        if let date = isoDate((value as? [String: Any])?["fetchedAt"]) { result.vendorFetchedAt[vendor] = date }
    }
    for (key, value) in object["models"] as? [String: Any] ?? [:] {
        guard !key.isEmpty, let entry = value as? [String: Any],
              let input = priceNumber(entry, "input"), let output = priceNumber(entry, "output"),
              let cacheRead = priceNumber(entry, "cacheRead") else { continue }
        let cacheWrite = priceNumber(entry, "cacheWrite") ?? input
        result.models[key] = ModelPrice(input: input, cacheWrite: cacheWrite, cacheWrite1h: priceNumber(entry, "cacheWrite1h"),
                                        cacheRead: cacheRead, output: output)
        if let vendor = entry["vendor"] as? String { result.vendorOf[key] = vendor }
    }
    return result
}

func encodeAutoPrices(_ prices: AutoPrices) -> Data {
    var object: [String: Any] = [:]
    if let fetchedAt = prices.fetchedAt { object["fetchedAt"] = iso8601(fetchedAt) }
    if let lastAttemptAt = prices.lastAttemptAt { object["lastAttemptAt"] = iso8601(lastAttemptAt) }
    object["vendors"] = prices.vendorFetchedAt.mapValues { ["fetchedAt": iso8601($0)] }
    var models: [String: Any] = [:]
    for (key, price) in prices.models {
        var entry: [String: Any] = ["input": price.input, "cacheWrite": price.cacheWrite, "cacheWrite1h": price.cacheWrite1h,
                                    "cacheRead": price.cacheRead, "output": price.output]
        if let vendor = prices.vendorOf[key] { entry["vendor"] = vendor }
        models[key] = entry
    }
    object["models"] = models
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
}

func loadAutoPrices(_ url: URL = defaultAutoPricesURL) -> AutoPrices {
    guard let data = try? Data(contentsOf: url) else { return AutoPrices() }
    return parseAutoPrices(data)
}

/// Writes through a 0600 temporary file in the same folder, then renames it into place.
func writeAtomicallyPrivate(_ data: Data, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var ok = true
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written < 0 { if errno == EINTR { continue }; ok = false; break }
            offset += written
        }
    }
    if fsync(fd) != 0 { ok = false }
    close(fd)
    guard ok, rename(temporary.path, url.path) == 0 else {
        unlink(temporary.path)
        throw CocoaError(.fileWriteUnknown)
    }
}

// MARK: - Merged book

struct PriceBook {
    var prices: [String: ModelPrice] = [:]
    var sources: [String: PriceSource] = [:]
    var downloadedAt: Date?
    var vendorFetchedAt: [String: Date] = [:]
    var userKeys = 0

    /// Date of the newest layer in use: the download, else the built-in table.
    var asOf: Date { downloadedAt ?? builtInPricesDate }

    static var builtIn: PriceBook { mergePriceLayers(user: [:], downloaded: AutoPrices(), builtin: builtInPrices) }
}

func mergePriceLayers(user: [String: ModelPrice], downloaded: AutoPrices, builtin: [String: ModelPrice]) -> PriceBook {
    var book = PriceBook()
    for (key, price) in builtin { book.prices[key] = price; book.sources[key] = .builtin }
    for (key, price) in downloaded.models { book.prices[key] = price; book.sources[key] = .downloaded }
    for (key, price) in user { book.prices[key] = price; book.sources[key] = .user }
    book.downloadedAt = downloaded.models.isEmpty ? nil : downloaded.fetchedAt
    book.vendorFetchedAt = downloaded.vendorFetchedAt
    book.userKeys = user.count
    return book
}

func loadPriceBook(userURL: URL = pricesURL, autoURL: URL = defaultAutoPricesURL) -> PriceBook {
    mergePriceLayers(user: loadPrices(userURL), downloaded: loadAutoPrices(autoURL), builtin: builtInPrices)
}

/// Longest-prefix match on the model name.
func price(for model: String, in prices: [String: ModelPrice]) -> ModelPrice? {
    priceKey(for: model, in: prices).flatMap { prices[$0] }
}

func priceKey(for model: String, in prices: [String: ModelPrice]) -> String? {
    prices.keys.filter { model.hasPrefix($0) }.max { $0.count != $1.count ? $0.count < $1.count : $0 > $1 }
}

/// Cost of one model's counters in USD. 1-hour cache writes are a subset of all cache writes.
func cost(of c: TokenCounters, at rate: ModelPrice) -> Double {
    let longWrites = min(c.cacheWrite1h, c.cacheWrite)
    return (Double(c.input) * rate.input + Double(c.cacheWrite - longWrites) * rate.cacheWrite
            + Double(longWrites) * rate.cacheWrite1h + Double(c.cacheRead) * rate.cacheRead
            + Double(c.output) * rate.output) / 1_000_000
}

/// Estimated API cost of the priced models; nil when no model has a price.
func estimatedCost(_ models: [(model: String, counters: TokenCounters)], prices: [String: ModelPrice]) -> Double? {
    var total = 0.0
    var priced = false
    for entry in models {
        guard let rate = price(for: entry.model, in: prices) else { continue }
        priced = true
        total += cost(of: entry.counters, at: rate)
    }
    return priced ? total : nil
}

/// Models with tokens and no price, by descending token total.
func unpricedModels(_ models: [(model: String, counters: TokenCounters)], prices: [String: ModelPrice]) -> [String] {
    models.filter { !$0.counters.isZero && price(for: $0.model, in: prices) == nil }.map(\.model)
}

/// "a, b" or "a, b and 3 more" ("a, b и ещё 3").
func unpricedCaption(_ names: [String]) -> String {
    let head = names.prefix(2).joined(separator: ", ")
    return names.count > 2 ? head + L(" and \(names.count - 2) more", " и ещё \(names.count - 2)") : head
}

// MARK: - Markdown table parsing

private struct MarkdownTable {
    let header: [String]
    let rows: [[String]]

    func column(_ name: String) -> Int? { header.firstIndex(of: name) }
}

private func splitRow(_ line: Substring) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("|") { text.removeFirst() }
    if text.hasSuffix("|") { text.removeLast() }
    return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isSeparatorRow(_ cells: [String]) -> Bool {
    !cells.isEmpty && cells.allSatisfy { cell in
        let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !core.isEmpty && core.allSatisfy { $0 == "-" }
    }
}

/// Removes `<sup>…</sup>` with its content (footnote marks), then any other tag.
private func stripTags(_ text: String) -> String {
    var s = text
    while let open = s.range(of: "<sup", options: .caseInsensitive),
          let close = s.range(of: "</sup>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
        s.removeSubrange(open.lowerBound..<close.upperBound)
    }
    return s.replacingOccurrences(of: "<[A-Za-z/][^>]*>", with: "", options: .regularExpression)
}

private func headerName(_ cell: String) -> String {
    stripTags(cell).replacingOccurrences(of: "*", with: "").lowercased()
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Every pipe table in document order: a header row, a separator row, then body rows.
private func markdownTables(_ markdown: String) -> [MarkdownTable] {
    var tables: [MarkdownTable] = []
    var block: [[String]] = []
    func flush() {
        if block.count >= 2, isSeparatorRow(block[1]) {
            let header = block[0].map(headerName)
            tables.append(MarkdownTable(header: header, rows: block.dropFirst(2).filter { $0.count == header.count }))
        }
        block = []
    }
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { block.append(splitRow(line)) } else { flush() }
    }
    flush()
    return tables
}

/// "$0.20 / MTok<sup>1</sup>" -> 0.2; "-" or text without a dollar amount -> nil.
func pricingCellValue(_ cell: String) -> Double? {
    let s = stripTags(cell)
    guard let dollar = s.firstIndex(of: "$") else { return nil }
    let rest = s[s.index(after: dollar)...].drop { $0 == " " }
    let digits = rest.prefix { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }.replacingOccurrences(of: ",", with: "")
    guard let value = Double(digits), value.isFinite else { return nil }
    return value
}

/// Markdown links become their text, parenthesised groups are dropped, tags removed.
private func modelCellText(_ cell: String) -> String {
    var s = stripTags(cell)
    s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    var out = ""
    var depth = 0
    for ch in s {
        if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
    }
    return out.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
}

/// "Claude Fable 5.2" -> "claude-fable-5-2".
func anthropicModelKey(_ cell: String) -> String? {
    let key = modelCellText(cell).replacingOccurrences(of: ".", with: "-")
    guard !key.isEmpty, key.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }) else { return nil }
    return key
}

/// "gpt-5.5 (<272K context length)" -> "gpt-5.5"; dots are kept (they appear in log names).
func openAIModelKey(_ cell: String) -> String? {
    let key = modelCellText(cell)
    guard !key.isEmpty, key.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }) else { return nil }
    return key
}

/// Only the first table with the full "Model pricing" header counts; within it the first row
/// of a model key wins (Haiku 5.5: the up-to-100k tier).
func parseAnthropicPricing(_ markdown: String) -> [String: ModelPrice] {
    for table in markdownTables(markdown) {
        guard let model = table.column("model"), let input = table.column("base input tokens"),
              let write5m = table.column("5m cache writes"), let write1h = table.column("1h cache writes"),
              let read = table.column("cache hits and refreshes"), let output = table.column("output tokens") else { continue }
        var result: [String: ModelPrice] = [:]
        for row in table.rows {
            guard let key = anthropicModelKey(row[model]), result[key] == nil,
                  let i = pricingCellValue(row[input]), let w5 = pricingCellValue(row[write5m]),
                  let w1 = pricingCellValue(row[write1h]), let r = pricingCellValue(row[read]),
                  let o = pricingCellValue(row[output]) else { continue }
            result[key] = ModelPrice(input: i, cacheWrite: w5, cacheWrite1h: w1, cacheRead: r, output: o)
        }
        return result
    }
    return [:]
}

/// Text-token tables only: the long "Short context …" table or the plain 4-column one. Batch,
/// Flex, Fast and Ultrafast sections repeat model ids later; the first occurrence of an id wins.
/// A missing cached price ("-") means no cache discount.
func parseOpenAIPricing(_ markdown: String) -> [String: ModelPrice] {
    var result: [String: ModelPrice] = [:]
    for table in markdownTables(markdown) {
        guard let model = table.column("model") else { continue }
        let columns: (Int, Int, Int)?
        if let i = table.column("short context input"), let o = table.column("short context output"),
           let c = table.column("short context cached input") {
            columns = (i, o, c)
        } else if Set(table.header) == ["model", "input", "output", "cached input"], table.header.count == 4 {
            columns = (table.column("input")!, table.column("output")!, table.column("cached input")!)
        } else {
            columns = nil
        }
        guard let (inputColumn, outputColumn, cachedColumn) = columns else { continue }
        for row in table.rows {
            guard let key = openAIModelKey(row[model]), result[key] == nil,
                  let input = pricingCellValue(row[inputColumn]), let output = pricingCellValue(row[outputColumn]) else { continue }
            let cached = pricingCellValue(row[cachedColumn]) ?? input
            result[key] = ModelPrice(input: input, cacheWrite: input, cacheWrite1h: input, cacheRead: cached, output: output)
        }
    }
    return result
}

/// nil when the vendor's result may be used; otherwise the reason it is rejected.
func priceValidationFailure(_ models: [String: ModelPrice]) -> String? {
    if models.count < 5 { return "too few models (\(models.count) < 5)" }
    for key in models.keys.sorted() {
        let p = models[key]!
        for value in [p.input, p.cacheWrite, p.cacheWrite1h, p.cacheRead, p.output] where !(value > 0 && value < 1000) {
            return "\(key): price out of range (\(value))"
        }
        if p.output < p.input { return "\(key): output price below input price" }
        if p.cacheRead > p.input { return "\(key): cache read price above input price" }
    }
    return nil
}

// MARK: - Schedule decision

enum PriceRefreshReason: Equatable { case stale, unpricedModel }

let priceStaleAfter: TimeInterval = 7 * 86_400
let priceOutOfTurnSpacing: TimeInterval = 86_400
let priceCheckSpacing: TimeInterval = 3600

/// Pure decision used by the hourly check. Nothing within an hour of the last attempt; a
/// download older than 7 days (or none) is refreshed; an unpriced model with recent tokens
/// triggers an out-of-turn refresh at most once per 24 h of attempts (failed ones included).
func priceRefreshDecision(now: Date, fetchedAt: Date?, lastAttemptAt: Date?, hasUnpricedRecentModel: Bool) -> PriceRefreshReason? {
    if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < priceCheckSpacing, now >= lastAttemptAt { return nil }
    if fetchedAt.map({ now.timeIntervalSince($0) >= priceStaleAfter }) ?? true { return .stale }
    if hasUnpricedRecentModel, lastAttemptAt.map({ now.timeIntervalSince($0) >= priceOutOfTurnSpacing }) ?? true {
        return .unpricedModel
    }
    return nil
}

// MARK: - Download

struct PriceFetchError: Error, CustomStringConvertible {
    let description: String
}

private let maxPricingPageBytes = 2 << 20

var appVersionString: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
}

/// Refuses redirects to another host or scheme and answers no authentication challenge.
private final class PricingFetchDelegate: NSObject, URLSessionTaskDelegate {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme == "https", url.host == host, request.httpMethod ?? "GET" == "GET" else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { return (.performDefaultHandling, nil) }
        return (.cancelAuthenticationChallenge, nil)
    }
}

private func pricingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 20
    configuration.httpMaximumConnectionsPerHost = 1
    return URLSession(configuration: configuration)
}

func fetchPricingPage(_ vendor: PriceVendor) async throws -> String {
    let url = vendor.url
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("AILimits/\(appVersionString)", forHTTPHeaderField: "User-Agent")
    let session = pricingSession()
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request, delegate: PricingFetchDelegate(host: url.host ?? ""))
    guard let http = response as? HTTPURLResponse else { throw PriceFetchError(description: "no HTTP response") }
    guard http.statusCode == 200 else { throw PriceFetchError(description: "HTTP \(http.statusCode)") }
    guard http.url?.host == url.host else { throw PriceFetchError(description: "redirected to another host") }
    if http.expectedContentLength > Int64(maxPricingPageBytes) { throw PriceFetchError(description: "response over 2 MB") }
    var data = Data()
    data.reserveCapacity(64 << 10)
    for try await byte in bytes {
        data.append(byte)
        if data.count > maxPricingPageBytes { throw PriceFetchError(description: "response over 2 MB") }
    }
    guard let text = String(data: data, encoding: .utf8) else { throw PriceFetchError(description: "response is not UTF-8") }
    return text
}

struct VendorUpdateOutcome {
    let vendor: PriceVendor
    let parsed: Int
    let failure: String?
    var accepted: Bool { failure == nil }
}

/// Merges a vendor's validated result into `previous`; a rejected vendor keeps its old models.
func applyVendorResult(_ previous: AutoPrices, vendor: PriceVendor, models: [String: ModelPrice], now: Date) -> AutoPrices {
    var next = previous
    for (key, owner) in previous.vendorOf where owner == vendor.rawValue {
        next.models[key] = nil
        next.vendorOf[key] = nil
    }
    for (key, price) in models {
        next.models[key] = price
        next.vendorOf[key] = vendor.rawValue
    }
    next.vendorFetchedAt[vendor.rawValue] = now
    next.fetchedAt = now
    return next
}

/// Fetches, parses and validates both pages, then writes `autoURL` (also after a failed
/// attempt, so the attempt time is persisted for the throttle).
func performPriceUpdate(autoURL: URL = defaultAutoPricesURL, now: Date = Date()) async -> (outcomes: [VendorUpdateOutcome], writeError: String?) {
    var state = loadAutoPrices(autoURL)
    var outcomes: [VendorUpdateOutcome] = []
    for vendor in PriceVendor.allCases {
        do {
            let models = vendor.parse(try await fetchPricingPage(vendor))
            if let failure = priceValidationFailure(models) {
                outcomes.append(VendorUpdateOutcome(vendor: vendor, parsed: models.count, failure: failure))
            } else {
                state = applyVendorResult(state, vendor: vendor, models: models, now: now)
                outcomes.append(VendorUpdateOutcome(vendor: vendor, parsed: models.count, failure: nil))
            }
        } catch let error as PriceFetchError {
            outcomes.append(VendorUpdateOutcome(vendor: vendor, parsed: 0, failure: "fetch failed: \(error.description)"))
        } catch let error as URLError {
            outcomes.append(VendorUpdateOutcome(vendor: vendor, parsed: 0, failure: "fetch failed: URLError \(error.code.rawValue)"))
        } catch {
            outcomes.append(VendorUpdateOutcome(vendor: vendor, parsed: 0, failure: "fetch failed"))
        }
    }
    state.lastAttemptAt = now
    do {
        try writeAtomicallyPrivate(encodeAutoPrices(state), to: autoURL)
        return (outcomes, nil)
    } catch {
        return (outcomes, "could not write \(autoURL.lastPathComponent)")
    }
}

// MARK: - App-side scheduler

@MainActor final class PriceUpdater {
    /// Called on the main actor after prices-auto.json was rewritten.
    var onUpdate: (() -> Void)?

    private let autoURL: URL
    private var running = false
    private var unpricedRecent = false
    private var timer: Timer?

    init(autoURL: URL = defaultAutoPricesURL) {
        self.autoURL = autoURL
        timer = Timer.scheduledTimer(withTimeInterval: priceCheckSpacing, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer?.tolerance = 300
        Task { @MainActor in self.check() }
    }

    /// The usage scan reports whether a model with tokens in the last 30 days has no price.
    func noteUnpricedModels(_ any: Bool) {
        unpricedRecent = any
        if any { check() }
    }

    func check() {
        guard !running else { return }
        let url = autoURL, unpriced = unpricedRecent
        running = true
        Task {
            let state = await Task.detached(priority: .utility) { loadAutoPrices(url) }.value
            let due = priceRefreshDecision(now: Date(), fetchedAt: state.fetchedAt, lastAttemptAt: state.lastAttemptAt,
                                           hasUnpricedRecentModel: unpriced) != nil
            running = false
            if due { run() }
        }
    }

    /// Menu "Update prices": refresh now regardless of the schedule.
    func refreshNow() { run() }

    private func run() {
        guard !running else { return }
        running = true
        let url = autoURL
        Task {
            _ = await Task.detached(priority: .utility) { await performPriceUpdate(autoURL: url) }.value
            running = false
            onUpdate?()
        }
    }
}

// MARK: - CLI

private func priceText(_ value: Double) -> String {
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// `AILimits --prices`: the merged table with the source layer of every key, and the dates.
func runPricesReport() {
    let autoURL = defaultAutoPricesURL
    let downloaded = loadAutoPrices(autoURL)
    let book = loadPriceBook(autoURL: autoURL)
    print("AI Limits API prices, USD per million tokens (input / cache write 5m / cache write 1h / cache read / output)")
    for key in book.prices.keys.sorted() {
        let p = book.prices[key]!
        let source = book.sources[key]?.rawValue ?? "?"
        print("  \(key.padding(toLength: 22, withPad: " ", startingAt: 0)) \(source.padding(toLength: 16, withPad: " ", startingAt: 0)) "
              + [p.input, p.cacheWrite, p.cacheWrite1h, p.cacheRead, p.output].map(priceText).joined(separator: " / "))
    }
    print("built-in table: \(builtInPricesDateText), \(builtInPrices.count) models")
    if let fetchedAt = downloaded.fetchedAt {
        print("prices-auto.json: fetched \(iso8601(fetchedAt)), \(downloaded.models.count) models")
    } else {
        print("prices-auto.json: none")
    }
    for vendor in PriceVendor.allCases {
        print("  \(vendor.rawValue): \(downloaded.vendorFetchedAt[vendor.rawValue].map(iso8601) ?? "never accepted")")
    }
    if let attempt = downloaded.lastAttemptAt { print("last download attempt: \(iso8601(attempt))") }
    print("prices.json: \(book.userKeys == 0 ? "none" : "\(book.userKeys) keys")")
    print("footnote date: \(iso8601(book.asOf))")
}

/// `AILimits --update-prices`: one live fetch + parse + validate, then writes prices-auto.json.
func runUpdatePrices() -> Bool {
    let autoURL = defaultAutoPricesURL
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var value: ([VendorUpdateOutcome], String?) = ([], nil) }
    let box = Box()
    Task.detached {
        box.value = await performPriceUpdate(autoURL: autoURL)
        semaphore.signal()
    }
    semaphore.wait()
    let (outcomes, writeError) = box.value
    for outcome in outcomes {
        let verdict = outcome.failure.map { "rejected: \($0)" } ?? "accepted"
        print("\(outcome.vendor.rawValue): parsed \(outcome.parsed) models, \(verdict)")
    }
    if let writeError {
        print("FAIL: \(writeError)")
        return false
    }
    let saved = loadAutoPrices(autoURL)
    print("wrote \(autoURL.lastPathComponent): \(saved.models.count) models, fetchedAt \(saved.fetchedAt.map(iso8601) ?? "none")")
    return outcomes.contains { $0.accepted }
}
