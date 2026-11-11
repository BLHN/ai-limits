import SwiftUI

enum SummarySize { case panel, medium, large }

/// Reset moment without a preposition: "07:34" today, "Nov 16, 03:34" ("16 ноя, 03:34") otherwise.
func resetMoment(_ date: Date, now: Date) -> (text: String, today: Bool) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    if calendar.isDate(date, inSameDayAs: now) { return (time, true) }
    return ("\(shortDayMonth(day: parts.day ?? 0, month: parts.month ?? 1)), \(time)", false)
}

/// Reset moment as a short caption: "at 07:34" ("в 07:34") today, "Nov 16, 03:34" otherwise.
func shortReset(_ quota: Quota?, now: Date) -> String {
    guard quota != nil else { return L("no data", "нет данных") }
    guard let date = parsedDate(quota?.resetsAt) else { return L("reset unknown", "сброс неизвестен") }
    if date <= now { return L("awaiting reset", "ждём сброса") }
    let moment = resetMoment(date, now: now)
    return moment.today ? L("at ", "в ") + moment.text : moment.text
}

func quotaInk(_ quota: Quota?) -> Color {
    guard let quota else { return Palette.muted }
    return quota.remaining == 0 ? Palette.red : quota.remaining <= 15 ? Palette.amber : Palette.text
}

func percentText(_ quota: Quota?) -> String {
    quota.map { "\(Int($0.remaining.rounded()))%" } ?? "—"
}

func paymentInk(_ anchor: String?, now: Date) -> Color {
    (paymentDaysAway(anchor: anchor, now: now) ?? .max) <= 3 ? Palette.amber : Palette.muted
}

/// Filled light button: the one primary action of a view.
struct FilledButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.background)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Palette.text.opacity(enabled ? (configuration.isPressed ? 0.75 : 0.92) : 0.30)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Outlined button for secondary actions.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(enabled ? Palette.text : Palette.muted.opacity(0.6))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Palette.text.opacity(configuration.isPressed ? 0.12 : hovering && enabled ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.text.opacity(enabled ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

/// Text-only link: muted ink that brightens under the pointer.
struct LinkButtonStyle: ButtonStyle {
    var size: CGFloat = 11
    var weight: Font.Weight = .medium
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: weight))
            .foregroundStyle(hovering || configuration.isPressed ? Palette.text : Palette.text.opacity(0.78))
            .underline(hovering)
            .contentShape(Rectangle())
            .onHover { inside in hovering = inside }
    }
}

/// One limit of one account, in display order: session, week, then per-model windows.
struct Meter: Identifiable {
    let id: String
    let label: String
    let quota: Quota
    /// Model windows usually reset with the weekly one; then the caption would only repeat it.
    let showsReset: Bool
}

func meters(for account: AccountRow) -> [Meter] {
    var result: [Meter] = []
    if let session = account.usage?.primary {
        result.append(Meter(id: "session", label: L("Session", "Сеанс"), quota: session, showsReset: true))
    }
    let weekly = account.usage?.secondary
    if let weekly {
        result.append(Meter(id: "week", label: L("Week", "Неделя"), quota: weekly, showsReset: true))
    }
    for model in account.models {
        let same = parsedDate(model.quota.resetsAt) == parsedDate(weekly?.resetsAt)
        result.append(Meter(id: model.id, label: model.title, quota: model.quota, showsReset: !same))
    }
    return result
}

/// 0…1 multiplier for bar lengths; the popover drives it to grow bars in. Widgets keep the default.
private struct BarGrowthKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var barGrowth: Double {
        get { self[BarGrowthKey.self] }
        set { self[BarGrowthKey.self] = newValue }
    }
}

/// Remaining share as a thin bar. An exhausted limit keeps a faint red track so it still reads.
struct MeterBar: View {
    let quota: Quota
    let height: CGFloat
    @Environment(\.barGrowth) private var growth

    var body: some View {
        let ink = quotaInk(quota)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(quota.remaining == 0 ? Palette.red.opacity(0.28) : Palette.text.opacity(0.10))
                if quota.remaining > 0 {
                    Capsule().fill(ink.opacity(ink == Palette.text ? 0.82 : 1))
                        .frame(width: max(height, proxy.size.width * quota.remaining / 100) * growth)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private func meterAccessibility(_ meter: Meter) -> String {
    let left = percentWords(Int(meter.quota.remaining.rounded()))
    return L("\(meter.label): \(left) left. ", "\(meter.label): осталось \(left). ") + resetDetail(meter.quota)
}

/// Panel and large widget: label, bar, percent and reset caption on one line.
struct MeterLine: View {
    let meter: Meter
    let now: Date
    var height: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(meter.label).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .lineLimit(1).frame(width: 46, alignment: .leading)
            MeterBar(quota: meter.quota, height: 4)
            Text(percentText(meter.quota))
                .font(.system(size: 14, weight: .medium)).monospacedDigit()
                .foregroundStyle(quotaInk(meter.quota))
                .lineLimit(1).frame(width: 42, alignment: .trailing)
            Text(meter.showsReset ? shortReset(meter.quota, now: now) : "")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                .lineLimit(1).minimumScaleFactor(0.9)
                .frame(width: 86, alignment: .trailing)
                .help("\(resetLabel(meter.quota, now: now)). \(resetDetail(meter.quota))")
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meterAccessibility(meter))
    }
}

/// Medium widget: label and percent above the bar, reset caption below it.
struct MeterStack: View {
    let meter: Meter
    let now: Date
    /// Four narrow columns: slightly smaller label and percent so both still fit.
    var compact = false
    /// The medium widget is too short for a third caption; the panel carries model resets.
    private var showsReset: Bool { meter.id == "session" || meter.id == "week" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // "Session" next to "100%" is a few points too wide for four columns: shrink, not truncate.
                // Only when the full size does not fit; a scale factor alone also shrinks it in wide columns.
                let label = Text(meter.label).font(.system(size: compact ? 9 : 10)).foregroundStyle(Palette.muted)
                ViewThatFits(in: .horizontal) {
                    label.lineLimit(1).fixedSize()
                    label.lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Text(percentText(meter.quota))
                    .font(.system(size: compact ? 11 : 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(quotaInk(meter.quota)).lineLimit(1).fixedSize()
            }
            MeterBar(quota: meter.quota, height: 3)
            if showsReset {
                Text(shortReset(meter.quota, now: now))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(Palette.muted)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meterAccessibility(meter))
    }
}

/// Muted pace caption aligned with the meter bar; overspend reads amber.
struct PaceLine: View {
    let pace: PaceReading
    let now: Date

    private var ink: Color {
        if case .overspend = pace.status { return Palette.amber }
        return Palette.muted
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(paceCaption(pace, now: now))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(ink)
                .lineLimit(1).minimumScaleFactor(0.9)
            Spacer(minLength: 0)
        }
        .padding(.leading, 56)
        .frame(height: 14)
        .help(L("Pace: share of the limit used vs. share of the window elapsed",
                 "Темп: доля использованного лимита против прошедшей доли окна"))
    }
}

struct LimitsSummary: View {
    let accounts: [AccountRow]
    let now: Date
    let size: SummarySize
    var sourceError = false
    /// Menu bar popover: a pace caption under each weekly meter, no pin glyph in the footer.
    var showsPace = false
    var showsPin = true
    /// Problem with accounts.json, shown as one muted amber line (host only).
    var notice: String? = nil
    /// Host only: opens the account setup from the empty state.
    var onSetUp: (() -> Void)? = nil
    /// Host only: opens the account setup on the account with this id from its failure hint.
    var onFix: ((String) -> Void)? = nil
    /// Host only: login emails are shown masked ("d•••@example.com").
    var hideEmails = false

    private func isStale(_ account: AccountRow) -> Bool {
        (measurementAge(account.usage, now: now) ?? .infinity) > 180
    }
    private var stale: Bool { sourceError || accounts.contains(where: isStale) }
    private var hairline: Color { Palette.text.opacity(0.08) }

    /// Secondary fact about an account: a delayed measurement outranks the payment date.
    @ViewBuilder private func accountNote(_ account: AccountRow, short: Bool) -> some View {
        if isStale(account) {
            Text(ageLabel(account.usage, now: now)).foregroundStyle(Palette.amber)
                .help(L("Time since the last measurement", "Время с последнего измерения"))
        } else if let payment = paymentLabel(anchor: account.billingAnchor, now: now, short: short) {
            Text(payment).foregroundStyle(paymentInk(account.billingAnchor, now: now))
                .help(L("Estimate: monthly from the subscription start date", "Оценка: ежемесячно от даты начала подписки"))
        }
    }

    // MARK: Medium widget — one column per account

    private var columns: some View {
        let compact = accounts.count >= 4
        return HStack(alignment: .top, spacing: compact ? 7 : 11) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.name).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.75)
                    let items = meters(for: account)
                    VStack(alignment: .leading, spacing: 6) {
                        if items.isEmpty {
                            Text(L("no data", "нет данных")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        ForEach(items) { MeterStack(meter: $0, now: now, compact: compact) }
                    }.padding(.top, 6)
                    Spacer(minLength: 3)
                    accountNote(account, short: true)
                        .font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if index < accounts.count - 1 {
                    Rectangle().fill(hairline).frame(width: 1)
                }
            }
        }
    }

    /// Main remaining figure of an account: the week, else the session.
    private func headlineQuota(_ account: AccountRow) -> Quota? {
        account.usage?.secondary ?? account.usage?.primary
    }

    /// Medium widget with more than 4 accounts: two columns of cells, filled top to bottom,
    /// each with the name, the week (else session) remaining and its bar.
    private var grid: some View {
        let half = (accounts.count + 1) / 2
        let columns = [Array(accounts.prefix(half)), Array(accounts.dropFirst(half))]
        return HStack(alignment: .top, spacing: 11) {
            ForEach(0..<2, id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(columns[column].enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Spacer(minLength: 4) }
                        gridCell(account)
                    }
                    if columns[column].count < half { Spacer(minLength: 4); Color.clear.frame(height: 24) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if column == 0 { Rectangle().fill(hairline).frame(width: 1) }
            }
        }
    }

    private func gridCell(_ account: AccountRow) -> some View {
        let quota = headlineQuota(account)
        // A delayed measurement (older than 3 min): an amber clock and a muted figure, as the
        // columns layout shows an amber age; the cell has no room for the age text itself.
        let delayed = quota != nil && isStale(account)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(account.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if delayed {
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.amber)
                }
                Text(percentText(quota)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(delayed ? Palette.muted : quotaInk(quota)).lineLimit(1).fixedSize()
            }
            Group {
                if let quota { MeterBar(quota: quota, height: 3) } else { Capsule().fill(Palette.text.opacity(0.10)) }
            }.frame(height: 3)
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((quota.map { L("\(account.name): \(percentWords(Int($0.remaining.rounded()))) left",
                                           "\(account.name): осталось \(percentWords(Int($0.remaining.rounded())))") }
                             ?? L("\(account.name): no data", "\(account.name): нет данных"))
                            + (delayed ? ", " + ageLabel(account.usage, now: now) : ""))
        .help(delayed ? ageLabel(account.usage, now: now) : "")
    }

    // MARK: Large widget with more than 4 accounts — one row per account

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Limits").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Text(L("remaining", "остаток")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(.bottom, 6)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(L("Session", "Сеанс")).frame(width: 46, alignment: .trailing)
                Text(L("Week", "Неделя")).frame(width: 46, alignment: .trailing)
                Color.clear.frame(width: 50, height: 1)
            }
            .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            .padding(.bottom, 3)
            ForEach(accounts) { account in
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Text(account.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if account.usage?.primary == nil && account.usage?.secondary == nil {
                        Text(L("no data", "нет данных")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    } else {
                        Text(account.usage?.primary.map { percentText($0) } ?? "")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(quotaInk(account.usage?.primary)).lineLimit(1)
                            .frame(width: 46, alignment: .trailing)
                        Text(percentText(account.usage?.secondary))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(quotaInk(account.usage?.secondary)).lineLimit(1)
                            .frame(width: 46, alignment: .trailing)
                        Group {
                            if let week = account.usage?.secondary { MeterBar(quota: week, height: 3) } else { Color.clear }
                        }.frame(width: 50, height: 3)
                    }
                }
                .frame(height: 25)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(compactAccessibility(account))
            }
            Rectangle().fill(hairline).frame(height: 1)
            Spacer(minLength: 0)
            footer.padding(.top, 6)
        }
    }

    private func compactAccessibility(_ account: AccountRow) -> String {
        let items = meters(for: account).filter { $0.id == "session" || $0.id == "week" }
        guard !items.isEmpty else { return L("\(account.name): no data", "\(account.name): нет данных") }
        let parts = items.map { L("\($0.label) \(percentWords(Int($0.quota.remaining.rounded()))) left",
                                  "\($0.label): осталось \(percentWords(Int($0.quota.remaining.rounded())))") }
        return account.name + ": " + parts.joined(separator: ", ")
    }

    // MARK: Panel and large widget — one block per account

    private var freshest: Date? {
        accounts.compactMap { parsedDate($0.usage?.updatedAt) }.min()
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 4) {
            if stale {
                Text(L("Data delayed", "Данные задерживаются")).foregroundStyle(Palette.amber)
            } else if size == .large, let measured = freshest {
                // WidgetKit keeps a relative date ticking between timeline reloads; the locale
                // makes its units match the chosen language rather than the system one.
                (Text(L("Updated ", "Обновлено ")) + Text(measured, style: .relative) + Text(L(" ago", " назад")))
                    .foregroundStyle(Palette.muted)
                    .environment(\.locale, L10n.locale)
            } else if let oldest = accounts.compactMap({ measurementAge($0.usage, now: now) }).max() {
                Text(oldest < 60 ? L("Updated \(Int(oldest)) s ago", "Обновлено \(Int(oldest)) с назад")
                                 : L("Updated \(Int(oldest / 60)) min ago", "Обновлено \(Int(oldest / 60)) мин назад"))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            if size == .panel && showsPin {
                Image(systemName: "pin").foregroundStyle(Palette.muted).accessibilityLabel(L("Always on top", "Поверх окон"))
            }
        }.font(.system(size: 11)).monospacedDigit().lineLimit(1)
    }

    private var blocks: some View {
        let roomy = size == .panel
        // More than four accounts in the panel: shorter blocks so eight still read at a glance.
        let crowded = roomy && accounts.count > 4
        let pairs = size == .panel ? sameLoginPairs(accounts) : []
        // Four accounts in the large widget: tighter blocks; with many meters the title goes too.
        let dense = size == .large && accounts.count >= 4
        let showsTitle = !dense || accounts.reduce(0) { $0 + max(1, meters(for: $1).count) } <= 10
        return VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI Limits").font(.system(size: dense ? 13 : 15, weight: .semibold)).foregroundStyle(Palette.text)
                    Spacer()
                    Text(L("remaining", "остаток")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(.bottom, notice == nil && pairs.isEmpty ? (roomy ? (crowded ? 10 : 14) : dense ? 6 : 10) : 6)
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.8))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, roomy ? 10 : 8)
                    .help(notice)
            }
            ForEach(pairs, id: \.later) { pair in
                sameLoginLine(pair).padding(.bottom, 8)
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { _, account in
                Rectangle().fill(hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: roomy ? (crowded ? 4 : 6) : dense ? 1 : 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(account.name).font(.system(size: dense ? 12 : 13, weight: .semibold))
                                .foregroundStyle(Palette.text).lineLimit(1)
                            Spacer()
                            accountNote(account, short: false).font(.system(size: 11)).monospacedDigit()
                        }
                        if size == .panel, let identity = identityLine(plan: account.plan, email: account.email, hideEmails: hideEmails) {
                            Text(identity).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .lineLimit(1).truncationMode(.middle)
                                .help(L("Plan and login of this account, as its CLI reports them", "Тариф и вход этого аккаунта по данным его CLI"))
                        }
                    }
                    let items = meters(for: account)
                    if items.isEmpty {
                        if let failure = account.failure {
                            // No numbers yet: the reason replaces "No limits reported".
                            failureLine(failure, account: account)
                        } else {
                            Text(L("No limits reported", "Сервис не передал лимиты")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    } else if let failure = account.failure, isStale(account) {
                        // Old numbers stay; a muted amber line says why they are not updating.
                        failureLine(failure, account: account)
                    }
                    VStack(spacing: roomy ? 2 : 0) {
                        ForEach(items) { meter in
                            MeterLine(meter: meter, now: now, height: dense ? 15 : 18)
                            if showsPace && meter.id == "week",
                               let pace = paceReading(meter.quota, window: account.weeklyWindow ?? weekWindow, now: now) {
                                PaceLine(pace: pace, now: now)
                            }
                        }
                    }
                }.padding(.vertical, roomy ? (crowded ? 8 : 12) : dense ? 5 : 11)
            }
            Rectangle().fill(hairline).frame(height: 1)
            if size == .large { Spacer(minLength: 0) }
            footer.padding(.top, roomy ? (crowded ? 10 : 12) : dense ? 6 : 9)
        }
    }

    /// Amber note that two accounts are signed into the same login; Fix opens the later one's card.
    @ViewBuilder private func sameLoginLine(_ pair: SameLoginPair) -> some View {
        let earlier = accounts.first { $0.id == pair.earlier }
        let later = accounts.first { $0.id == pair.later }
        let title = sameLoginTitle(earlier?.name ?? pair.earlier, later?.name ?? pair.later)
        let hint = sameLoginHint(later?.name ?? pair.later, kind: later?.kind ?? .claude)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.8))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onFix {
                Button(L("Fix", "Исправить")) { onFix(pair.later) }
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityLabel(L("Fix \(later?.name ?? pair.later)", "Исправить: \(later?.name ?? pair.later)"))
            }
        }
        .help(hint)
    }

    /// Amber reason for a failed check; in the host it opens the account setup on this account.
    @ViewBuilder private func failureLine(_ failure: FetchFailure, account: AccountRow) -> some View {
        let hint = Text(onFix == nil ? fetchHint(failure, kind: account.kind) : fixHint(failure, kind: account.kind)).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.8))
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        if let onFix {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                hint.onTapGesture { onFix(account.id) }
                Spacer(minLength: 0)
                Button(L("Fix", "Исправить")) { onFix(account.id) }
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityLabel(L("Fix \(account.name)", "Исправить: \(account.name)"))
            }
            .help(fetchHintDetail(failure, kind: account.kind))
        } else {
            hint.help(fetchHintDetail(failure, kind: account.kind))
        }
    }

    /// Nothing configured or detected: a short setup note instead of empty blocks.
    private var setupNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Limits").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                .padding(.bottom, 4)
            if size == .panel {
                Text(SetupText.emptyTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                Text(SetupText.emptyBody).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let onSetUp {
                    Button(L("Set up accounts", "Настроить аккаунты"), action: onSetUp)
                        .buttonStyle(FilledButtonStyle())
                        .padding(.top, 6)
                } else {
                    Text(SetupText.emptyHint).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(SetupText.widgetEmpty).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if let notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: size == .panel ? nil : .infinity, alignment: .topLeading)
    }

    var body: some View {
        Group {
            if accounts.isEmpty { setupNote }
            else if size == .medium { mediumWidgetUsesGrid(accountCount: accounts.count) ? AnyView(grid) : AnyView(columns) }
            else if size == .large && largeWidgetUsesList(accountCount: accounts.count) { compactList }
            else { blocks }
        }
        .accessibilityElement(children: .contain)
    }
}
