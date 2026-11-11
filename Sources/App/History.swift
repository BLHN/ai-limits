import Foundation
import Observation

// Host-only limit history: one JSON line per account sample in
// ~/Library/Application Support/AILimits/history.jsonl (mode 0600). Only the fixed
// account id, a timestamp and remaining percentages are stored.

var historyURL: URL { appDataFolder.appendingPathComponent("history.jsonl") }

private let historyRetention: TimeInterval = 30 * 86_400
private let historyMinimumGap: TimeInterval = 600

struct HistorySample: Equatable {
    let t: Date
    let id: String
    let s: Double?
    let w: Double?
    let m: [String: Double]

    /// Same numbers, ignoring the timestamp.
    func sameValues(as other: HistorySample) -> Bool { s == other.s && w == other.w && m == other.m }
}

private func roundedRemaining(_ quota: Quota?) -> Double? {
    quota.map { ($0.remaining * 10).rounded() / 10 }
}

func historySample(id: String, usage: Usage, models: [ModelQuota], at date: Date) -> HistorySample {
    var byModel: [String: Double] = [:]
    for model in models { byModel[model.id] = roundedRemaining(model.quota) }
    return HistorySample(t: date, id: id, s: roundedRemaining(usage.primary), w: roundedRemaining(usage.secondary), m: byModel)
}

/// A changed reading is always recorded; an unchanged one at most every 10 minutes.
func shouldRecord(_ sample: HistorySample, after last: HistorySample?) -> Bool {
    guard let last else { return true }
    return !sample.sameValues(as: last) || sample.t.timeIntervalSince(last.t) >= historyMinimumGap
}

func historyLine(_ sample: HistorySample) -> Data {
    let object: [String: Any] = [
        "t": iso8601(sample.t), "id": sample.id,
        "s": sample.s.map { $0 as Any } ?? NSNull(),
        "w": sample.w.map { $0 as Any } ?? NSNull(),
        "m": sample.m
    ]
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    data.append(0x0A)
    return data
}

func parseHistoryLine<S: Sequence>(_ bytes: S) -> HistorySample? where S.Element == UInt8 {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
          let t = parsedDate(object["t"] as? String), let id = object["id"] as? String,
          isValidAccountID(id) else { return nil }
    func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    var models: [String: Double] = [:]
    for (key, value) in (object["m"] as? [String: Any]) ?? [:] { if let value = number(value) { models[key] = value } }
    return HistorySample(t: t, id: id, s: number(object["s"]), w: number(object["w"]), m: models)
}

/// Samples from the last 30 days, oldest first.
func pruneHistory(_ samples: [HistorySample], now: Date) -> [HistorySample] {
    let cutoff = now.addingTimeInterval(-historyRetention)
    return samples.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
}

struct HistoryPoint: Equatable {
    let t: Date
    let value: Double
}

/// Weekly remaining of one account over the last `days` days, oldest first.
func weeklyPoints(_ samples: [HistorySample], id: String, now: Date, days: Double = 7) -> [HistoryPoint] {
    let start = now.addingTimeInterval(-days * 86_400)
    return samples.filter { $0.id == id && $0.t >= start && $0.t <= now.addingTimeInterval(60) }
        .compactMap { sample in sample.w.map { HistoryPoint(t: sample.t, value: $0) } }
        .sorted { $0.t < $1.t }
}

/// Appends samples off the main thread and keeps the last 8 days in memory for the sparklines.
@MainActor @Observable final class HistoryLog {
    private(set) var recent: [HistorySample] = []

    @ObservationIgnored private let writer: HistoryWriter

    init(url: URL = historyURL) {
        writer = HistoryWriter(url: url)
        writer.start { [weak self] slice in Task { @MainActor in self?.recent = slice } }
    }

    func record(id: String, usage: Usage, models: [ModelQuota], now: Date = Date()) {
        writer.record(historySample(id: id, usage: usage, models: models, at: now))
    }
}

/// File side of the history; all state is confined to its serial utility queue.
private final class HistoryWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "ai-limits.history", qos: .utility)
    private var all: [HistorySample] = []
    private var last: [String: HistorySample] = [:]
    private var onChange: (([HistorySample]) -> Void)?

    init(url: URL) { self.url = url }

    func start(onChange: @escaping ([HistorySample]) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            let loaded = Self.load(url)
            all = pruneHistory(loaded, now: Date())
            for sample in all { last[sample.id] = sample }
            pruneIfDue(original: loaded.count)
            publishRecent()
        }
    }

    func record(_ sample: HistorySample) {
        queue.async { [self] in
            guard shouldRecord(sample, after: last[sample.id]) else { return }
            last[sample.id] = sample
            all.append(sample)
            append(historyLine(sample))
            pruneIfDue(original: all.count)
            publishRecent()
        }
    }

    private static func load(_ url: URL) -> [HistorySample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { parseHistoryLine($0) }
    }

    private func append(_ line: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fchmod(fd, 0o600)
    }

    /// Rewrites the file without samples older than 30 days, at most once a day.
    private func pruneIfDue(original: Int) {
        let key = "historyPrunedAt"
        let now = Date()
        if let previous = appDefaults.object(forKey: key) as? Date, now.timeIntervalSince(previous) < 86_400 { return }
        appDefaults.set(now, forKey: key)
        let kept = pruneHistory(all, now: now)
        guard kept.count < original else { return }
        all = kept
        var data = Data()
        for sample in kept { data.append(historyLine(sample)) }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }

    private func publishRecent() {
        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        onChange?(all.filter { $0.t >= cutoff })
    }
}
