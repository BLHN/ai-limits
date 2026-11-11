import SwiftUI

// Host-only content of the menu bar popover: limits with pace, and local analytics.
// Plain values in, no store references, so the preview tool can render it with fixtures.

enum PopoverTab: String { case limits, analytics }

private var hairline: Color { Palette.text.opacity(0.08) }

private func dayCaption(_ day: Int) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    // Midday: a few zones skip local midnight on their DST day.
    let parts = calendar.dateComponents([.month, .day], from: usageDayDate(day).addingTimeInterval(12 * 3600))
    return shortDayMonth(day: parts.day ?? 0, month: parts.month ?? 1)
}

let switchSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
let growSpring = Animation.spring(response: 0.55, dampingFraction: 0.86)

/// Text-only segmented switch; native segmented controls do not match the panel's ink.
/// The selection pill slides between options. The change itself is not animated: an animated
/// layout change makes the popover's hosting view drift while the window resizes, so views
/// that should move with the selection carry their own scoped animation.
struct SegmentSwitch<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var fontSize: CGFloat = 12
    var height: CGFloat = 24
    @Namespace private var pill
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected || hovered == index ? Palette.text : Palette.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5).fill(Palette.text.opacity(0.12))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else if hovered == index {
                                RoundedRectangle(cornerRadius: 5).fill(Palette.text.opacity(0.05))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? index : (hovered == index ? nil : hovered) }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .animation(reduceMotion ? nil : switchSpring, value: selection)
        .background(RoundedRectangle(cornerRadius: 7).stroke(Palette.text.opacity(0.10), lineWidth: 1))
    }
}

/// Plain button that dips slightly while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Fades its content in and grows its bars from zero each time it appears.
struct GrowOnAppear<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = enabled && !reduceMotion
        content()
            .environment(\.barGrowth, active && !grown ? 0 : 1)
            .opacity(active && !grown ? 0 : 1)
            .offset(y: active && !grown ? 6 : 0)
            .onAppear { withAnimation(growSpring) { grown = true } }
            .onDisappear { grown = false }
    }
}

/// Shows its content at its natural height; once that exceeds `maxHeight` the content scrolls
/// inside a box of exactly `maxHeight`. nil (static renders) never scrolls. The content stays
/// pinned to the top either way, so a height change never shifts what is already on screen.
struct ScrollingPanel<Content: View>: View {
    let maxHeight: CGFloat?
    /// A new value starts the scroll position at the top again (the popover's tab).
    var resetKey: AnyHashable = 0
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        if let maxHeight, height > maxHeight {
            ScrollView(.vertical) { measured }
                .scrollIndicators(.automatic)
                .id(resetKey)
                .frame(height: maxHeight)
        } else {
            measured
        }
    }

    private var measured: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ScrollingContentHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ScrollingContentHeightKey.self) { value in
                if value > 0, abs(value - height) >= 0.5 { height = value }
            }
    }
}

private struct ScrollingContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Faint highlight under a row while the pointer is over it.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.text.opacity(hovering ? 0.06 : 0)).padding(.horizontal, -6))
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

struct PopoverContent: View {
    let accounts: [AccountRow]
    let now: Date
    var sourceError = false
    /// Problem with accounts.json, shown as a muted amber line on the limits tab.
    var notice: String? = nil
    let usage: UsageDays
    let prices: [String: ModelPrice]
    /// Date of the newest price layer in use (download, else the built-in table).
    let pricesAsOf: Date
    /// First scan of this session still running: aggregates may be old or empty.
    let firstScanRunning: Bool
    let lastScan: Date?
    let history: [HistorySample]
    let codexPlan: String?
    /// Login emails are shown masked.
    var hideEmails = false
    /// Tallest the whole popover may get (screen height minus a margin); nil never scrolls.
    var maxHeight: CGFloat?
    /// Off for static renders, where nothing ever appears.
    var animated = true
    /// Height the content wants, reported after each layout; the popover window follows it.
    var onHeight: ((CGFloat) -> Void)?
    /// Open the account setup (empty state) or jump to one failing account.
    var onSetUp: (() -> Void)?
    var onFix: ((String) -> Void)?
    @State private var tab: PopoverTab
    @State private var period: UsagePeriod
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(accounts: [AccountRow], now: Date, sourceError: Bool = false, notice: String? = nil, usage: UsageDays, prices: [String: ModelPrice],
         pricesAsOf: Date = builtInPricesDate, firstScanRunning: Bool, lastScan: Date?, history: [HistorySample], codexPlan: String?,
         hideEmails: Bool = false, maxHeight: CGFloat? = nil,
         tab: PopoverTab = .limits, period: UsagePeriod = .week, animated: Bool = true,
         onHeight: ((CGFloat) -> Void)? = nil, onSetUp: (() -> Void)? = nil, onFix: ((String) -> Void)? = nil) {
        self.animated = animated
        self.hideEmails = hideEmails
        self.maxHeight = maxHeight
        self.onHeight = onHeight
        self.onSetUp = onSetUp
        self.onFix = onFix
        self.accounts = accounts
        self.now = now
        self.sourceError = sourceError
        self.notice = notice
        self.usage = usage
        self.prices = prices
        self.pricesAsOf = pricesAsOf
        self.firstScanRunning = firstScanRunning
        self.lastScan = lastScan
        self.history = history
        self.codexPlan = codexPlan
        _tab = State(initialValue: tab)
        _period = State(initialValue: period)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The tab switch stays put; only the pane below it scrolls when it is taller than the screen allows.
            SegmentSwitch(options: [(PopoverTab.limits, L("Limits", "Лимиты")), (.analytics, L("Analytics", "Аналитика"))], selection: $tab)
                .padding(.bottom, 14)
            ScrollingPanel(maxHeight: maxHeight.map { max(200, $0 - 16 * 2 - 24 - 14) }, resetKey: tab) {
                // Tabs swap without a transition; the arriving pane fades itself in (GrowOnAppear).
                if tab == .limits {
                    GrowOnAppear(enabled: animated) {
                        LimitsSummary(accounts: accounts, now: now, size: .panel, sourceError: sourceError,
                                      showsPace: true, showsPin: false, notice: notice, onSetUp: onSetUp, onFix: onFix,
                                      hideEmails: hideEmails)
                    }
                } else {
                    GrowOnAppear(enabled: animated) {
                        AnalyticsPane(accounts: accounts, now: now, usage: usage, prices: prices, pricesAsOf: pricesAsOf,
                                      firstScanRunning: firstScanRunning, lastScan: lastScan,
                                      history: history, codexPlan: codexPlan, hideEmails: hideEmails, period: $period)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { height in
            if height > 0 { onHeight?(height) }
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// "claude-sonnet-5-5" reads as "Sonnet 5.5"; other ids stay as they are.
func displayModelName(_ id: String) -> String {
    guard id.hasPrefix("claude-") else { return id }
    let parts = id.dropFirst(7).split(separator: "-")
    guard let family = parts.first else { return id }
    // Date stamps and other long numeric suffixes are not part of the version.
    let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
    let name = family.prefix(1).uppercased() + family.dropFirst()
    return version.isEmpty ? name : name + " " + version.joined(separator: ".")
}

/// One answer per screen: what the period cost, who spent it, on which models, and how the days went.
struct AnalyticsPane: View {
    let accounts: [AccountRow]
    let now: Date
    let usage: UsageDays
    let prices: [String: ModelPrice]
    let pricesAsOf: Date
    let firstScanRunning: Bool
    let lastScan: Date?
    let history: [HistorySample]
    let codexPlan: String?
    var hideEmails = false
    @Binding var period: UsagePeriod

    private typealias Models = [(model: String, counters: TokenCounters)]
    private struct Line: Identifiable {
        let id: String
        let title: String
        let tokens: Int64
        let cost: Double?
    }

    private var today: Int { usageDay(epoch: now.timeIntervalSince1970) }

    private func line(_ id: String, _ title: String, _ models: Models) -> Line {
        Line(id: id, title: title, tokens: models.reduce(0) { $0 + $1.counters.total },
             cost: estimatedCost(models, prices: prices))
    }

    var body: some View {
        let perProvider = UsageProvider.allCases.map { provider in
            (provider, usageModels(usage, provider: provider, lastDays: period.days, today: today))
        }
        let all: Models = perProvider.flatMap { $0.1 }
        let total = line("total", "", all)
        let sections = perProvider.map { provider, models in
            (line(provider.rawValue, provider.title, models),
             models.filter { !$0.counters.isZero }
                .map { line($0.model, displayModelName($0.model), [$0]) }
                .sorted { ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens) }
                .prefix(4))
        }
        let missing = unpricedModels(all, prices: prices)
        let pricesDay = dayCaption(usageDay(epoch: pricesAsOf.timeIntervalSince1970))
        let priceNote = L("Equivalent at API prices as of \(pricesDay), not what the subscription charges",
                          "Эквивалент по ценам API от \(pricesDay), а не списание по подписке")

        VStack(alignment: .leading, spacing: 0) {
            SegmentSwitch(options: UsagePeriod.allCases.map { ($0, $0.title) }, selection: $period,
                          fontSize: 11, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(total))
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(total.tokens == 0 ? Palette.muted : Palette.text).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(switchSpring, value: period)
                Text(caption(total))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(switchSpring, value: period)
            }
            .padding(.top, 16).padding(.bottom, 14)
            .help(priceNote)
            .accessibilityElement(children: .combine)

            if total.tokens > 0 {
                ForEach(sections, id: \.0.id) { provider, models in
                    Rectangle().fill(hairline).frame(height: 1)
                    VStack(spacing: 3) {
                        HStack(spacing: 10) {
                            Text(provider.title).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.text).frame(width: 56, alignment: .leading)
                            ShareBar(fraction: share(provider, of: total))
                            Text(value(provider))
                                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(provider.tokens == 0 ? Palette.muted : Palette.text)
                                .lineLimit(1).frame(width: 76, alignment: .trailing)
                                .contentTransition(.numericText())
                                .animation(switchSpring, value: period)
                        }
                        .frame(height: 20)
                        .help("\(compactTokens(provider.tokens)) \(tokensWord(provider.tokens))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(provider.title): \(value(provider))")
                        ForEach(Array(models)) { model in
                            HStack(spacing: 10) {
                                Text(model.title).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(compactTokens(model.tokens)).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(Palette.muted).lineLimit(1)
                                Text(model.cost.map(compactDollars) ?? L("no price", "без цены"))
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(Palette.text.opacity(0.88))
                                    .lineLimit(1).frame(width: 76, alignment: .trailing)
                            }
                            .frame(height: 16)
                            .modifier(HoverRow())
                            .transition(.opacity)
                            .help(model.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(model.title): \(compactTokens(model.tokens)) \(tokensWord(model.tokens)), \(value(model))")
                        }
                    }
                    .padding(.vertical, 10)
                }
            }

            Rectangle().fill(hairline).frame(height: 1)
            DailyStrip(days: dailyTotals(usage, today: today), highlighted: period.days).padding(.vertical, 12)
            Rectangle().fill(hairline).frame(height: 1)
            ForecastBlock(accounts: accounts, now: now, hideEmails: hideEmails).padding(.top, 12)

            if !missing.isEmpty {
                Text(L("No price: ", "Без цены: ") + unpricedCaption(missing))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.top, 10)
                    .help(L("These models are not in the total", "Эти модели не вошли в сумму"))
            }
        }
    }

    private func headline(_ total: Line) -> String {
        if total.tokens == 0 { return "—" }
        if let cost = total.cost { return "≈ " + compactDollars(cost) }
        return compactTokens(total.tokens)
    }

    private func caption(_ total: Line) -> String {
        if total.tokens == 0 { return firstScanRunning ? L("Counting…", "Считаю…") : L("No data for this period", "Нет данных за период") }
        let scanning = firstScanRunning ? L(" · counting…", " · считаю…") : ""
        if total.cost == nil { return tokensWord(total.tokens) + scanning }
        return L("at API prices · ", "по ценам API · ") + "\(compactTokens(total.tokens)) \(tokensWord(total.tokens))" + scanning
    }

    /// Dollars when the line has a price, tokens otherwise.
    private func value(_ line: Line) -> String {
        if line.tokens == 0 { return "—" }
        if let cost = line.cost { return compactDollars(cost) }
        return compactTokens(line.tokens)
    }

    private func share(_ line: Line, of total: Line) -> Double {
        if let cost = line.cost, let whole = total.cost, whole > 0 { return cost / whole }
        return total.tokens > 0 ? Double(line.tokens) / Double(total.tokens) : 0
    }
}

/// Thin share bar in the meter's ink.
private struct ShareBar: View {
    let fraction: Double
    @Environment(\.barGrowth) private var growth
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.text.opacity(0.10))
                if fraction > 0 {
                    Capsule().fill(Palette.text.opacity(0.82))
                        .frame(width: max(4, proxy.size.width * min(1, fraction)) * growth)
                        .animation(switchSpring, value: fraction)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Thirty days of tokens; the days of the selected period are bright, the rest recede.
/// Bars rise one after another, and the bar under the pointer names its day in the caption.
struct DailyStrip: View {
    let days: [DailyTotal]
    let highlighted: Int
    private let height: CGFloat = 40
    @Environment(\.barGrowth) private var growth
    @State private var hovered: Int?

    var body: some View {
        let scale = Double(max(1, days.map(\.total).max() ?? 1))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days.indices, id: \.self) { index in
                    let day = days[index]
                    let active = index >= days.count - highlighted
                    let lit = hovered == index
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Palette.text.opacity(day.total == 0 ? 0.08 : lit ? 1 : active ? 0.82 : 0.20))
                            .frame(height: day.total == 0 ? 1 : max(2, height * Double(day.total) / scale) * growth)
                            .animation(growSpring.delay(Double(index) * 0.012), value: growth)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.1)) { hovered = inside ? index : (hovered == index ? nil : hovered) }
                    }
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Tokens per day, last 30 days", "Токены по дням за 30 дней"))
            HStack(spacing: 0) {
                Text(days.first.map { dayCaption($0.day) } ?? "")
                Spacer(minLength: 6)
                if let hovered, days.indices.contains(hovered) {
                    Text("\(dayCaption(days[hovered].day)) · \(compactTokens(days[hovered].total))")
                        .foregroundStyle(Palette.text)
                } else {
                    Text(L("tokens per day", "токены по дням"))
                }
                Spacer(minLength: 6)
                Text(L("today", "сегодня"))
            }
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(1)
        }
    }
}

/// When each limit of each account runs out at the current pace.
struct ForecastBlock: View {
    let accounts: [AccountRow]
    let now: Date
    var hideEmails = false

    private func window(_ meter: Meter, _ account: AccountRow) -> TimeInterval? {
        if meter.id == "session" { return account.kind == .claude ? claudeSessionWindow : nil }
        return account.weeklyWindow ?? weekWindow
    }

    private func forecast(_ meter: Meter, _ account: AccountRow) -> (text: String, ink: Color) {
        let quota = meter.quota
        // Unknown or past resets keep shortReset's own wording instead of a prefixed date.
        let reset = parsedDate(quota.resetsAt).flatMap { $0 > now ? resetMoment($0, now: now) : nil }
        if quota.remaining == 0 {
            return (reset.map { L("empty until ", "пусто до ") + $0.text } ?? shortReset(quota, now: now), Palette.red)
        }
        guard let window = window(meter, account), let pace = paceReading(quota, window: window, now: now) else {
            return (reset != nil ? L("resets ", "сброс ") + shortReset(quota, now: now) : shortReset(quota, now: now), Palette.muted)
        }
        if let runsOut = pace.runsOut { return (L("runs out ", "кончится ") + paceMoment(runsOut, now: now), Palette.amber) }
        return (L("lasts until reset", "хватит до сброса"), Palette.muted)
    }

    var body: some View {
        // More than four accounts: tighter rows so eight fit without a wall of text.
        let compact = accounts.count > 4
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            Text(L("Limit forecast", "Прогноз по лимитам")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            ForEach(accounts) { account in
                let items = meters(for: account)
                let identity = identityLine(plan: account.plan, email: account.email, hideEmails: hideEmails)
                HStack(alignment: .top, spacing: 10) {
                    // No room for the login next to the forecast: it is in the name's tooltip.
                    Text(account.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
                        .lineLimit(1).minimumScaleFactor(0.85).frame(width: 84, alignment: .leading)
                        .help(identity.map { "\(account.name): \($0)" } ?? account.name)
                    VStack(spacing: compact ? 1 : 2) {
                        if items.isEmpty {
                            Text(L("no data", "нет данных")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(items) { meter in
                            let reading = forecast(meter, account)
                            HStack(spacing: 8) {
                                Text(meter.label).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    .lineLimit(1).frame(width: 48, alignment: .leading)
                                Text(percentText(meter.quota)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(quotaInk(meter.quota)).frame(width: 36, alignment: .trailing)
                                Spacer(minLength: 4)
                                Text(reading.text).font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(reading.ink).lineLimit(1).minimumScaleFactor(0.85)
                            }
                            .frame(height: compact ? 15 : 16)
                            .modifier(HoverRow())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L("\(account.name), \(meter.label): \(percentText(meter.quota)) left, \(reading.text)",
                                                 "\(account.name), \(meter.label): осталось \(percentText(meter.quota)), \(reading.text)"))
                        }
                    }
                }
            }
        }
        .help(L("Linear forecast: the current rate extended to the end of the window",
                "Линейный прогноз: текущий расход продлён до конца окна"))
    }
}
