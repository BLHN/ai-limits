import AppKit
import SwiftUI
@main struct Preview {
    @MainActor static func render<V: View>(_ view: V, _ path: String) throws {
        let renderer = ImageRenderer(content: view.background(Palette.background).preferredColorScheme(.dark))
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    @MainActor static func main() throws {
        // Fixed zone so the captions do not depend on the machine.
        setenv("TZ", "UTC", 1); tzset(); NSTimeZone.resetSystemTimeZone()
        let now = parsedDate("2026-11-10T00:30:00Z")!
        func q(_ used: Double, _ reset: String) -> Quota { Quota(usedPercent: used, resetsAt: reset) }
        let fresh = "2026-11-10T00:29:30Z"
        let rows = [
            AccountRow(id: "codex", name: "Codex", kind: .codex,
                usage: Usage(provider: "codex", updatedAt: fresh, primary: nil, secondary: q(78, "2026-11-11T09:34:34Z")),
                models: [], billingAnchor: "2026-08-15T12:00:00+00:00"),
            AccountRow(id: "claude-1", name: "Claude 1", kind: .claude,
                usage: Usage(provider: "claude", updatedAt: fresh, primary: q(0, "2026-11-10T02:34:00Z"), secondary: q(99, "2026-11-16T22:34:00Z")),
                models: [ModelQuota(id: "f", title: "Fable", quota: q(100, "2026-11-16T22:34:00Z"))], billingAnchor: "2026-10-25T12:00:00Z"),
            AccountRow(id: "claude-2", name: "Claude 2", kind: .claude,
                usage: Usage(provider: "claude", updatedAt: fresh, primary: q(40, "2026-11-10T03:34:00Z"), secondary: q(14, "2026-11-16T11:00:00Z")),
                models: [ModelQuota(id: "f", title: "Fable", quota: q(38, "2026-11-15T22:34:00Z"))], billingAnchor: "2026-10-12")
        ]
        let dir = CommandLine.arguments[1]
        try render(LimitsSummary(accounts: rows, now: now, size: .medium).padding(12).frame(width: 344, height: 164), dir + "/medium.png")
        try render(LimitsSummary(accounts: rows, now: now, size: .large).padding(18).frame(width: 338, height: 354), dir + "/large.png")
        try render(LimitsSummary(accounts: rows, now: now, size: .panel).padding(18).frame(width: 380), dir + "/panel.png")

        // One and four accounts, the empty state and an accounts.json warning.
        let four = rows + [AccountRow(id: "claude-3", name: "Claude Work", kind: .claude,
            usage: Usage(provider: "claude", updatedAt: fresh, primary: q(100, "2026-11-10T04:00:00Z"), secondary: q(55, "2026-11-14T08:00:00Z")),
            models: [], billingAnchor: "2026-10-12")]
        let single = [rows[1]]
        try render(LimitsSummary(accounts: single, now: now, size: .medium).padding(12).frame(width: 344, height: 164), dir + "/medium-1.png")
        try render(LimitsSummary(accounts: four, now: now, size: .medium).padding(12).frame(width: 344, height: 164), dir + "/medium-4.png")
        try render(LimitsSummary(accounts: single, now: now, size: .large).padding(18).frame(width: 338, height: 354), dir + "/large-1.png")
        try render(LimitsSummary(accounts: four, now: now, size: .large).padding(18).frame(width: 338, height: 354), dir + "/large-4.png")
        let fourClaude = [rows[1], rows[2], rows[2], rows[1]].enumerated().map { index, row in
            AccountRow(id: "c\(index)", name: "Claude \(index + 1)", kind: .claude, usage: row.usage, models: row.models, billingAnchor: row.billingAnchor)
        }
        try render(LimitsSummary(accounts: fourClaude, now: now, size: .large).padding(18).frame(width: 338, height: 354), dir + "/large-4-claude.png")
        try render(LimitsSummary(accounts: [], now: now, size: .medium).padding(12).frame(width: 344, height: 164), dir + "/medium-empty.png")
        try render(LimitsSummary(accounts: [], now: now, size: .panel).padding(18).frame(width: 380), dir + "/panel-empty.png")
        // The notice comes from the real parser, so it is in the language being rendered (AI_LIMITS_LANG).
        let duplicate = #"{"accounts":[{"id":"codex","type":"codex"},{"id":"claude-1","type":"claude"},{"id":"claude-1","type":"claude"},{"id":"x","type":"gemini"},{"id":"y","type":"claude","configDir":"rel"}]}"#
        let notice = resolveAccounts(fileData: Data(duplicate.utf8), home: URL(fileURLWithPath: "/Users/preview"),
                                     isExecutable: { _ in false }, findCLI: { _, _ in nil }).warning
        try render(LimitsSummary(accounts: rows, now: now, size: .panel, notice: notice).padding(18).frame(width: 380), dir + "/panel-warning.png")
        // Failed fetches: no numbers yet (trust prompt, CLI missing) and stale numbers with a failing check.
        let failing = [
            AccountRow(id: "codex", name: "Codex", kind: .codex, usage: nil, failure: .cliNotFound),
            AccountRow(id: "claude-1", name: "Claude 1", kind: .claude, usage: nil, failure: .probeNotTrusted),
            AccountRow(id: "claude-2", name: "Claude 2", kind: .claude,
                usage: Usage(provider: "claude", updatedAt: "2026-11-09T23:40:00Z", primary: q(40, "2026-11-10T03:34:00Z"), secondary: q(14, "2026-11-16T11:00:00Z")),
                models: [], billingAnchor: "2026-10-12", failure: .failed),
            AccountRow(id: "claude-3", name: "Claude Work", kind: .claude, usage: nil, failure: .notLoggedIn)
        ]
        try render(LimitsSummary(accounts: failing, now: now, size: .panel, showsPace: true, showsPin: false).padding(18).frame(width: 380), dir + "/panel-errors.png")
        try render(PopoverContent(accounts: failing, now: now, usage: [:], prices: [:], firstScanRunning: false, lastScan: nil,
                                  history: [], codexPlan: nil, tab: .limits, animated: false), dir + "/popover-errors.png")

        // Popover fixtures: 30 days of token usage, a week of limit history, a Codex plan.
        let today = usageDay(epoch: now.timeIntervalSince1970)
        var seed: UInt64 = 42
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        var usage: UsageDays = [:]
        let claudeModels: [(String, Double)] = [("claude-opus-5-5", 0.70), ("claude-sonnet-5-5", 0.22), ("claude-fable-5-1", 0.05),
                                                ("claude-fable-5-2", 0.02), ("claude-haiku-5-5", 0.01)]
        let codexModels: [(String, Double)] = [("gpt-6.1-terra", 0.45), ("gpt-6-astra", 0.34), ("gpt-6.1-sol", 0.21)]
        func counters(_ total: Double) -> TokenCounters {
            TokenCounters(input: Int64(total * 0.0005), cacheWrite: Int64(total * 0.026), cacheRead: Int64(total * 0.97), output: Int64(total * 0.0035))
        }
        for offset in 0..<30 {
            let day = today - offset
            let weekday = (day + 4) % 7
            let quiet = weekday == 5 || weekday == 6
            let claudeTotal = (offset == 6 ? 3.1e9 : (quiet ? 0.35e9 : 1.2e9)) * (0.6 + noise() * 0.8) * (offset == 0 ? 0.35 : 1)
            let codexTotal = (offset > 20 ? 0.04e9 : 0.14e9) * (0.3 + noise() * 1.4) * (offset == 0 ? 0.2 : 1)
            for (model, share) in claudeModels { usage[day, default: [:]]["claude", default: [:]][model] = counters(claudeTotal * share) }
            for (model, share) in codexModels { usage[day, default: [:]]["codex", default: [:]][model] = counters(codexTotal * share) }
        }
        var history: [HistorySample] = []
        for step in 0..<(7 * 24) {
            let t = now.addingTimeInterval(Double(step - 7 * 24) * 3600)
            let h = Double(step)
            history.append(HistorySample(t: t, id: "codex", s: nil, w: max(0, 100 - h * 0.62 - noise() * 2), m: [:]))
            history.append(HistorySample(t: t, id: "claude-1", s: nil, w: step < 30 ? 40 - h : max(1, 100 - (h - 30) * 0.9), m: [:]))
        }
        history.append(HistorySample(t: now.addingTimeInterval(-600), id: "claude-2", s: nil, w: 86, m: [:]))
        // Built-in prices with three models removed, so the footnote lists unpriced models ("…and 1 more").
        var partial = builtInPrices
        for key in ["claude-haiku-5-5", "claude-fable-5-2", "gpt-6.1-sol"] { partial[key] = nil }
        func popover(_ tab: PopoverTab, _ period: UsagePeriod = .week, prices: [String: ModelPrice] = builtInPrices, plan: String = "Plus") -> some View {
            PopoverContent(accounts: rows, now: now, usage: usage, prices: prices, pricesAsOf: builtInPricesDate, firstScanRunning: false,
                           lastScan: now.addingTimeInterval(-130), history: history, codexPlan: plan, tab: tab, period: period, animated: false)
        }
        try render(popover(.limits), dir + "/popover-limits.png")
        try render(popover(.analytics), dir + "/popover-analytics.png")
        try render(popover(.analytics, .month, prices: partial, plan: L("Plus · 120 credits", "Plus · кредиты 120")), dir + "/popover-analytics-unpriced.png")
        try render(popover(.analytics, .today), dir + "/popover-analytics-today.png")
        try render(PopoverContent(accounts: rows, now: now, usage: [:], prices: [:], firstScanRunning: true, lastScan: nil,
                                  history: [], codexPlan: nil, tab: .analytics, period: .month, animated: false), dir + "/popover-analytics-empty.png")
    }
}
