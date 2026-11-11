import SwiftUI
import WidgetKit

struct LimitsEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountRow]
}

struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: Date(), accounts: placeholderRows)
    }
    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        completion(LimitsEntry(date: Date(), accounts: PublishedSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let now = Date()
        // macOS owns the actual cadence; this is a requested refresh, not a guarantee.
        let accounts = PublishedSnapshot.load()
        // Future entries age the last measurement honestly even when refresh is delayed.
        let entries = (0...60).map { minute in
            LimitsEntry(date: now.addingTimeInterval(Double(minute) * 60), accounts: accounts)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
    }
}

struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LimitsEntry

    var body: some View {
        LimitsSummary(accounts: entry.accounts, now: entry.date,
                      size: family == .systemMedium ? .medium : .large)
            .padding(family == .systemMedium ? 12 : 18)
            .containerBackground(Palette.background, for: .widget)
            .preferredColorScheme(.dark)
            .widgetURL(URL(string: "ailimits://show"))
    }
}

@main struct AllAccountsWidget: Widget {
    let kind = limitsWidgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName(L("All accounts", "Все аккаунты"))
        .description(L("Remaining limits and reset times of your AI accounts at a glance",
                       "Остатки лимитов и время сброса ваших AI-аккаунтов на одном экране"))
        .contentMarginsDisabled()
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
