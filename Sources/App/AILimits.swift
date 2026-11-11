import AppKit
import SwiftUI
import Observation
import WidgetKit
import ServiceManagement

// The host app fetches quotas itself by launching the user's installed `codex` and
// `claude` CLIs (see Fetchers.swift). It reads only oauthAccount.subscriptionCreatedAt
// from the Claude profile state files and an optional user-edited billing.json. It never
// reads credentials, changes accounts, or makes network/model requests of its own.
// Analytics.swift reads token counters from the local CLI logs; History.swift keeps a
// local history of remaining percentages.

private let codexInterval: TimeInterval = 60
private let claudeInterval: TimeInterval = 120

/// Publishes are serialized so an older result never overwrites a newer file.
private let publishQueue = DispatchQueue(label: "ai-limits.publish")

/// Writes the sanitized snapshot for the widget. Returns true when the file content changed.
func publish(_ rows: [AccountRow]) throws -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let published = try encoder.encode(PublishedSnapshot(rows: rows))
    let destination = publishedSnapshotURL
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let changed = (try? Data(contentsOf: destination)) != published
    if changed {
        try published.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    return changed
}

private func billingModificationDate() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: billingURL.path))?[.modificationDate] as? Date
}

/// Short remaining summary for the menu bar tooltip.
func remainingSummary(_ accounts: [AccountRow]) -> String {
    let lines = accounts.map { account -> String in
        let parts = [account.usage?.primary.map { L("session", "сеанс") + " \(Int($0.remaining.rounded()))%" },
                     account.usage?.secondary.map { L("week", "неделя") + " \(Int($0.remaining.rounded()))%" }].compactMap { $0 }
        return "\(account.name): \(parts.isEmpty ? L("no data", "нет данных") : parts.joined(separator: ", "))"
    }
    return ([L("AI Limits — remaining", "AI Limits — остаток")] + lines).joined(separator: "\n")
}

@MainActor @Observable final class QuotaStore {
    private(set) var usages: [String: Usage] = [:]
    private(set) var models: [String: [ModelQuota]] = [:]
    private var claudeAnchors: [String: String] = [:]
    private var billing: [String: String] = [:]
    /// Category of the last failure per account; cleared by the next success. No CLI text is kept.
    private(set) var lastErrors: [String: FetchFailure] = [:]
    /// Window lengths and plan from the Codex response. Host-only, never published.
    private(set) var codexMeta: CodexMeta?
    /// Resolved accounts; nil until the first load finishes (nothing is fetched or published before).
    private(set) var configuration: AccountsConfiguration?
    var now = Date()
    @ObservationIgnored let history = HistoryLog()

    @ObservationIgnored var onTick: (() -> Void)?
    /// Called with every newly applied account configuration (the analytics follow its log roots).
    @ObservationIgnored var onConfiguration: ((AccountsConfiguration) -> Void)?
    /// .distantFuture marks a fetch in flight; .distantPast means "due now".
    @ObservationIgnored private var nextDue: [String: Date] = [:]
    @ObservationIgnored private var rerunRequested: Set<String> = []
    @ObservationIgnored private var claudeChainRunning = false
    @ObservationIgnored private var billingDate: Date?
    @ObservationIgnored private var accountsDate: Date?
    @ObservationIgnored private var configurationLoading = false
    @ObservationIgnored private var configurationLoadedAt = Date.distantPast
    /// Rows shown before the configuration is known: the last published ones.
    @ObservationIgnored private let seedSlots: [AccountSlot]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    @ObservationIgnored private var pendingWidgetReload = false

    private var slots: [AccountSlot] { configuration?.slots ?? seedSlots }

    var extras: [String: AccountExtras] {
        var result: [String: AccountExtras] = [:]
        for slot in slots {
            result[slot.id] = AccountExtras(models: models[slot.id] ?? [],
                                            billingAnchor: billing[slot.id] ?? claudeAnchors[slot.id],
                                            weeklyWindow: slot.kind == .codex ? codexMeta?.weeklyWindow : weekWindow,
                                            failure: lastErrors[slot.id])
        }
        return result
    }
    var accounts: [AccountRow] { rows(for: slots, usages: usages, extras: extras) }
    /// Every account's latest fetch failed: the panel then shows the delayed-data note.
    var allFetchersFailing: Bool { !slots.isEmpty && slots.allSatisfy { lastErrors[$0.id] != nil } }
    /// Problem with accounts.json for the muted amber line.
    var configurationWarning: String? { configuration?.warning }

    init() {
        // Seed from the last published file so the panel is not empty before the first fetch.
        let published = PublishedSnapshot.loadPublished()
        seedSlots = published?.map { AccountSlot(id: $0.id, kind: $0.kind, name: $0.name) } ?? placeholderSlots
        for row in published ?? [] {
            if let usage = row.usage { usages[row.id] = usage }
            models[row.id] = row.models
            if row.kind == .claude, let anchor = row.billingAnchor { claudeAnchors[row.id] = anchor }
        }
        billingDate = billingModificationDate()
        accountsDate = accountsModificationDate()
        Task {
            billing = await Task.detached(priority: .utility) { loadBillingOverrides() }.value
        }
        reloadConfiguration()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        tick()
    }

    /// Requests an immediate fetch of every account; in-flight ones run again afterwards.
    func refreshNow() {
        for slot in slots {
            if nextDue[slot.id] == .distantFuture { rerunRequested.insert(slot.id) } else { nextDue[slot.id] = .distantPast }
        }
        tick()
    }

    /// Re-reads accounts.json (or re-detects the CLIs) off the main thread.
    private func reloadConfiguration() {
        guard !configurationLoading else { return }
        configurationLoading = true
        Task {
            let loaded = await Task.detached(priority: .utility) { loadAccountsConfiguration() }.value
            configurationLoading = false
            configurationLoadedAt = Date()
            apply(loaded)
        }
    }

    private func apply(_ loaded: AccountsConfiguration) {
        let previous = configuration
        guard loaded != previous else { return }
        configuration = loaded
        // An account whose type or folder changed is another login: drop its old numbers.
        for account in loaded.accounts {
            if let old = previous?.accounts.first(where: { $0.id == account.id }), old != account {
                usages[account.id] = nil
                models[account.id] = nil
                claudeAnchors[account.id] = nil
                lastErrors[account.id] = nil
                if nextDue[account.id] == .distantFuture { rerunRequested.insert(account.id) } else { nextDue[account.id] = .distantPast }
            }
        }
        let claude = loaded.claudeAccounts
        Task {
            let anchors = await Task.detached(priority: .utility) { () -> [String: String] in
                var anchors: [String: String] = [:]
                for account in claude { anchors[account.id] = claudeSubscriptionAnchor(account) }
                return anchors
            }.value
            for (id, anchor) in anchors { claudeAnchors[id] = anchor }
            publishCurrent()
        }
        onConfiguration?(loaded)
        publishCurrent()
        tick()
    }

    func tick() {
        now = Date()
        if pendingWidgetReload && now.timeIntervalSince(lastWidgetReload) >= 60 {
            WidgetCenter.shared.reloadTimelines(ofKind: limitsWidgetKind)
            lastWidgetReload = now
            pendingWidgetReload = false
        }
        let modified = billingModificationDate()
        if modified != billingDate {
            billingDate = modified
            Task {
                billing = await Task.detached(priority: .utility) { loadBillingOverrides() }.value
                publishCurrent()
            }
        }
        // Edits to accounts.json apply without a restart; without the file a CLI installed
        // later is picked up within a few minutes.
        let accountsModified = accountsModificationDate()
        if accountsModified != accountsDate {
            accountsDate = accountsModified
            reloadConfiguration()
        } else if let configuration, !configuration.fromFile, now.timeIntervalSince(configurationLoadedAt) >= 300 {
            reloadConfiguration()
        }
        guard let configuration else { onTick?(); return }
        if let codex = configuration.codex, (nextDue[codex.id] ?? .distantPast) <= now { runCodex(codex) }
        if !claudeChainRunning {
            let due = configuration.claudeAccounts.filter { (nextDue[$0.id] ?? .distantPast) <= now }
            if !due.isEmpty { runClaude(due) }
        }
        onTick?()
    }

    private func finish(_ id: String, interval: TimeInterval) {
        nextDue[id] = rerunRequested.remove(id) != nil ? .distantPast : Date().addingTimeInterval(interval)
    }

    private func runCodex(_ account: AccountConfig) {
        let id = account.id
        nextDue[id] = .distantFuture
        Task {
            let result = await Task.detached(priority: .utility) { Result { try fetchCodexUsage(account) } }.value
            switch result {
            case .success(let reading):
                usages[id] = reading.usage
                codexMeta = reading.meta
                lastErrors[id] = nil
                history.record(id: id, usage: reading.usage, models: [])
                publishCurrent()
            case .failure(let error):
                // Keep the previous measurement and its original timestamp.
                lastErrors[id] = fetchFailure(of: error)
            }
            finish(id, interval: codexInterval)
        }
    }

    /// Claude accounts run one after another, never in parallel.
    private func runClaude(_ accounts: [AccountConfig]) {
        claudeChainRunning = true
        Task {
            for account in accounts {
                nextDue[account.id] = .distantFuture
                let (result, anchor) = await Task.detached(priority: .utility) {
                    (Result { try fetchClaudeUsage(account) }, claudeSubscriptionAnchor(account))
                }.value
                if let anchor { claudeAnchors[account.id] = anchor }
                switch result {
                case .success(let reading):
                    usages[account.id] = reading.usage
                    models[account.id] = reading.models
                    lastErrors[account.id] = nil
                    history.record(id: account.id, usage: reading.usage, models: reading.models)
                    publishCurrent()
                case .failure(let error):
                    lastErrors[account.id] = fetchFailure(of: error)
                }
                finish(account.id, interval: claudeInterval)
            }
            claudeChainRunning = false
        }
    }

    private func publishCurrent() {
        // Before the accounts are known the rows are only a seed; publishing them could undo an edit.
        guard configuration != nil else { return }
        let snapshot = accounts
        Task {
            let changed = await withCheckedContinuation { continuation in
                publishQueue.async { continuation.resume(returning: (try? publish(snapshot)) ?? false) }
            }
            pendingWidgetReload = pendingWidgetReload || changed
        }
    }
}

struct Dashboard: View {
    let store: QuotaStore
    var body: some View {
        LimitsSummary(accounts: store.accounts, now: store.now,
            size: .panel, sourceError: store.allFetchersFailing, notice: store.configurationWarning)
            .padding(18)
            .frame(width: 380)
            .background(Palette.background)
            .preferredColorScheme(.dark)
    }
}

/// Popover root: binds the observable stores to the plain-value popover view.
/// It fills whatever size the popover has and lays the content out from the top-left corner,
/// reporting the content's own height so the popover can follow it. Letting the hosting view
/// size itself instead made it centre the content for a moment on every height change, and
/// the whole pane visibly dropped and slid back on a tab switch.
struct PopoverRoot: View {
    let store: QuotaStore
    let usage: UsageMonitor
    let onHeight: (CGFloat) -> Void
    var body: some View {
        GeometryReader { _ in content }
            .background(Palette.background)
    }
    private var content: some View {
        PopoverContent(accounts: store.accounts, now: store.now, sourceError: store.allFetchersFailing,
                       notice: store.configurationWarning,
                       usage: usage.days, prices: usage.priceBook.prices, pricesAsOf: usage.priceBook.asOf,
                       firstScanRunning: usage.scanning && usage.lastScan == nil, lastScan: usage.lastScan,
                       history: store.history.recent, codexPlan: codexPlanLabel(store.codexMeta), onHeight: onHeight)
    }
}

/// "Plus" or "Plus · 120 credits" ("Plus · кредиты 120"); nil when the response carried neither.
func codexPlanLabel(_ meta: CodexMeta?) -> String? {
    guard let meta else { return nil }
    var parts: [String] = []
    if let plan = meta.plan { parts.append(plan) }
    if let credits = meta.credits {
        let amount = credits < 10 ? String(format: "%.1f", credits) : String(Int(credits.rounded()))
        parts.append(L("\(amount) credits", "кредиты \(amount)"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private let floatingPanelKey = "floatingPanelVisible"

final class LimitsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSPopoverDelegate {
    var panel: LimitsPanel?
    let store = QuotaStore()
    let usage = UsageMonitor()
    let priceUpdater = PriceUpdater()
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let launchAtLoginItem = NSMenuItem(title: L("Launch at Login", "Запускать при входе"),
                                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let floatingPanelItem = NSMenuItem(title: L("Floating Panel", "Плавающая панель"),
                                               action: #selector(toggleFloatingPanel), keyEquivalent: "")
    private let popover = NSPopover()
    private let popoverWidth: CGFloat = 380
    /// When the transient popover closed; a click on the icon right after it must not reopen it.
    private var popoverClosedAt = Date.distantPast

    private var panelPreferred: Bool {
        get { UserDefaults.standard.object(forKey: floatingPanelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: floatingPanelKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: Dashboard(store: store))
        let size = hosting.fittingSize
        let window = LimitsPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = "AI Limits"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 20/255, green: 20/255, blue: 21/255, alpha: 1)
        window.contentView = hosting
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.setFrameAutosaveName("AILimitsPosition")
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("AILimitsPosition"), let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.maxX - size.width - 22, y: bounds.maxY - size.height - 22))
        }
        window.setContentSize(size)
        panel = window
        if panelPreferred { window.orderFrontRegardless() }
        let menu = NSMenu()
        let root = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L("Quit AI Limits", "Закрыть AI Limits"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = applicationMenu
        menu.addItem(root)
        NSApp.mainMenu = menu
        setUpStatusItem()
        setUpPopover()
        priceUpdater.onUpdate = { [weak self] in self?.usage.reloadPrices() }
        usage.onScan = { [weak self] unpriced in self?.priceUpdater.noteUnpricedModels(!unpriced.isEmpty) }
        store.onTick = { [weak self] in self?.updateTooltip() }
        store.onConfiguration = { [weak self] configuration in
            self?.usage.sources = UsageSources(configuration: configuration)
        }
        if let configuration = store.configuration { usage.sources = UsageSources(configuration: configuration) }
        // Days and reset times follow the system zone; a change re-buckets the analytics.
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            Task { @MainActor in self?.usage.requestScan(force: true) }
        }
        updateTooltip()
    }

    // MARK: Menu bar icon

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "AI Limits")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let refresh = NSMenuItem(title: L("Refresh Now", "Обновить сейчас"), action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        let updatePrices = NSMenuItem(title: L("Update Prices", "Обновить цены"), action: #selector(refreshPrices), keyEquivalent: "")
        updatePrices.target = self
        launchAtLoginItem.target = self
        floatingPanelItem.target = self
        let quit = NSMenuItem(title: L("Quit AI Limits", "Закрыть AI Limits"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusMenu.items = [refresh, updatePrices, floatingPanelItem, launchAtLoginItem, .separator(), quit]
        statusMenu.delegate = self
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePopover()
        }
    }

    // MARK: Popover

    private func setPopoverHeight(_ height: CGFloat) {
        let size = NSSize(width: popoverWidth, height: height.rounded(.up))
        guard height > 0, popover.contentSize != size else { return }
        popover.contentSize = size
    }

    private func setUpPopover() {
        let root = PopoverRoot(store: store, usage: usage) { [weak self] height in
            // Resizing from inside a SwiftUI layout pass is not allowed; the next turn is soon enough.
            DispatchQueue.main.async { self?.setPopoverHeight(height) }
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: popoverWidth, height: 440)
        // Lay the content out once now, so its real height is known before the first click.
        hosting.view.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: 440)
        hosting.view.layoutSubtreeIfNeeded()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // The mouse-down that closed a transient popover also arrives here as a click.
        if Date().timeIntervalSince(popoverClosedAt) < 0.35 { return }
        guard let button = statusItem?.button else { return }
        store.tick()
        usage.requestScan()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // While open, the popover takes each new content height at once; AppKit's resize
    // animation would only lag behind the already redrawn content. Opening and closing still animate.
    func popoverDidShow(_ notification: Notification) { popover.animates = false }
    func popoverWillClose(_ notification: Notification) { popover.animates = true }
    func popoverDidClose(_ notification: Notification) { popoverClosedAt = Date() }

    // MARK: Floating panel

    /// Shows the panel without touching the persisted preference (widget tap, app reopen).
    private func showPanel() {
        panel?.orderFrontRegardless()
    }

    /// The menu toggle is the only place that changes the persisted "Floating Panel" preference.
    @objc private func toggleFloatingPanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            panelPreferred = false
        } else {
            showPanel()
            panelPreferred = true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        floatingPanelItem.state = panel?.isVisible == true ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled: launchAtLoginItem.state = .on
        case .requiresApproval: launchAtLoginItem.state = .mixed
        default: launchAtLoginItem.state = .off
        }
    }

    @objc private func refreshNow() { store.refreshNow() }
    @objc private func refreshPrices() { priceUpdater.refreshNow() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change Launch at Login", "Не удалось изменить автозапуск")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateTooltip() {
        statusItem?.button?.toolTip = remainingSummary(store.accounts)
    }

    // Closing the panel keeps the quota publisher alive for WidgetKit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { ChildProcesses.shared.terminateAll() }
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "ailimits" }) { showPanel() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
}

// MARK: - Self-test

private struct SelfTestFailure: Error { let code: Int }
private func expect(_ condition: Bool, _ code: Int) throws { if !condition { throw SelfTestFailure(code: code) } }

/// Fixtures below assume this zone; the self-test pins it so it passes on any machine.
private func pinTimeZone(_ identifier: String) {
    setenv("TZ", identifier, 1)
    tzset()
    NSTimeZone.resetSystemTimeZone()
}

/// The accounts of the original single-user setup, as fixture rows.
private let legacySlots = [AccountSlot(id: "codex", kind: .codex, name: "Codex"),
                           AccountSlot(id: "claude-1", kind: .claude, name: "Claude 1"),
                           AccountSlot(id: "claude-2", kind: .claude, name: "Claude 2")]

@MainActor private func runSelfTest() throws {
    pinTimeZone("Asia/Tashkent")
    try expect(TimeZone.current.identifier == "Asia/Tashkent", 2)
    let legacyIDs = legacySlots.map(\.id)
    let measured = "2026-11-01T12:00:00Z"
    let usages = [
        "codex": Usage(provider: "codex", updatedAt: measured, primary: nil, secondary: Quota(usedPercent: 53, resetsAt: nil)),
        "claude-1": Usage(provider: "claude", updatedAt: measured,
                          primary: Quota(usedPercent: 0, resetsAt: nil), secondary: Quota(usedPercent: 100, resetsAt: nil))
    ]
    let result = rows(for: legacySlots, usages: usages)
    try expect(result.map(\.id) == legacyIDs, 1)
    try expect(result[0].usage?.primary == nil && result[0].usage?.secondary?.remaining == 47, 1)
    try expect(result[1].usage?.secondary?.remaining == 0 && result[2].usage == nil, 1)
    try expect(measurementAge(result[0].usage, now: parsedDate("2026-11-01T12:04:00Z")!) == 240, 1)
    try expect(withLanguage(.ru) { resetLabel(nil, now: Date()) } == "Сервис не передал лимит"
               && withLanguage(.en) { resetLabel(nil, now: Date()) } == "No limit reported", 1)
    try expect(rows(for: legacySlots, usages: nil).allSatisfy { $0.usage == nil }, 1)
    try expect(result.map(\.code) == ["CX", "CL", "CL"] && placeholderRows.map(\.name) == ["Codex", "Claude"], 1)

    // Claude /usage parser on verified cleaned lines (whitespace already removed).
    let now = parsedDate("2026-11-10T00:00:00Z")!  // 05:00 in Asia/Tashkent
    let sample = """
    Currentsession
    \u{2588}\u{258C}0%used
    Resets8:29am(Asia/Tashkent)
    Currentweek(allmodels)
    \u{2588}\u{2588}\u{2588}99%used
    ResetsNov10at4:59am(Asia/Tashkent)
    Currentweek(Fable)
    \u{2588}\u{2588}\u{2588}\u{2588}100%used
    ResetsNov10at4:59am(Asia/Tashkent)
    """
    let reading = try parseClaudeUsage(sample, now: now)
    try expect(reading.usage.primary?.usedPercent == 0 && reading.usage.primary?.remaining == 100, 10)
    try expect(reading.usage.primary?.resetsAt == "2026-11-10T03:29:00Z", 11)
    try expect(reading.usage.secondary?.remaining == 1, 12)
    // Nov 10 04:59 local is one minute in the past: stays in this year.
    try expect(reading.usage.secondary?.resetsAt == "2026-11-09T23:59:00Z", 13)
    try expect(reading.models.count == 1 && reading.models[0].id == "claude-weekly-scoped-fable"
               && reading.models[0].title == "Fable" && reading.models[0].quota.remaining == 0, 14)
    try expect(reading.usage.updatedAt == "2026-11-10T00:00:00Z" && reading.isComplete, 15)

    // Escaped terminal output with cursor positioning, no-minutes time, missing Resets line.
    let escaped = "\u{1B}[?25l\u{1B}]0;claude\u{07}\u{1B}[2;1HCurrent\u{1B}[9Gsession\u{1B}[3;1H\u{1B}[38;5;12m\u{2588}\u{1B}[0m 7%\u{1B}[1Cused"
        + "\u{1B}[4;1HResets 9pm (Asia/Tashkent)\u{1B}[6;1HCurrent week (all models)\u{1B}[7;1H 40% used\r\n"
        + "Current week (Sonnet only)\r\n 12.5% used\r\n Resets Nov 11 at 5am (Asia/Tashkent)\r\n"
    let partial = try parseClaudeUsage(escaped, now: now)
    try expect(partial.usage.primary?.usedPercent == 7, 20)
    try expect(partial.usage.primary?.resetsAt == "2026-11-10T16:00:00Z", 21)
    try expect(partial.usage.secondary?.usedPercent == 40 && partial.usage.secondary?.resetsAt == nil, 22)
    try expect(partial.models.count == 1 && partial.models[0].id == "claude-weekly-scoped-sonnet-only"
               && partial.models[0].quota.usedPercent == 12.5
               && partial.models[0].quota.resetsAt == "2026-11-11T00:00:00Z", 23)
    try expect(!partial.isComplete, 24)

    // Year rollover, near-past dates and bare time rollover to tomorrow.
    let utc = TimeZone(identifier: "UTC")!
    let yearEnd = parsedDate("2026-12-31T12:00:00Z")!
    try expect(parseClaudeReset("Jan 2 at 3pm", zone: utc, now: yearEnd) == parsedDate("2027-01-02T15:00:00Z"), 30)
    try expect(parseClaudeReset("Dec31at1am", zone: utc, now: yearEnd) == parsedDate("2026-12-31T01:00:00Z"), 31)
    try expect(parseClaudeReset("Dec29at1am", zone: utc, now: yearEnd) == parsedDate("2027-12-29T01:00:00Z"), 32)
    try expect(parseClaudeReset("11:30am", zone: utc, now: yearEnd) == parsedDate("2027-01-01T11:30:00Z"), 33)
    try expect(parseClaudeReset("12am", zone: utc, now: yearEnd) == parsedDate("2027-01-01T00:00:00Z"), 34)
    try expect(parseClaudeReset("soon", zone: utc, now: yearEnd) == nil, 35)

    // Any IANA zone in the suffix, an abbreviation, and no suffix (the system zone, pinned above).
    func sessionReset(_ suffix: String) throws -> String? {
        try parseClaudeUsage("Current session\n 10% used\n Resets 3pm\(suffix)", now: now).usage.primary?.resetsAt
    }
    try expect(try sessionReset(" (America/Argentina/Buenos_Aires)") == "2026-11-10T18:00:00Z"
               && (try sessionReset(" (Australia/Lord_Howe)")) == "2026-11-10T04:00:00Z"
               && (try sessionReset(" (Etc/GMT+5)")) == "2026-11-10T20:00:00Z"
               && (try sessionReset(" (America/Port-au-Prince)")) == "2026-11-10T20:00:00Z"
               && (try sessionReset(" (UTC)")) == "2026-11-10T15:00:00Z"
               && (try sessionReset("")) == "2026-11-10T10:00:00Z"
               && (try sessionReset(" (Not/AZone)")) == "2026-11-10T10:00:00Z", 36)

    // Trust prompt and missing sections are errors, never zeros.
    let failures = ["Do you trust this folder?\n1. Yes, I trust this folder",
                    "Quick safety check: Do you trust the files in this folder?",
                    "Refreshing\u{2026}", ""]
    for text in failures {
        try expect((try? parseClaudeUsage(text, now: now)) == nil, 40)
    }

    // Codex window classification on canned app-server responses.
    let weeklyOnly = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":78,"windowDurationMins":10080,"resetsAt":1794384000},"secondary":null}}}"#
    let codexWeekly = try codexUsage(fromResponse: Data(weeklyOnly.utf8), now: now)
    try expect(codexWeekly.primary == nil && codexWeekly.secondary?.remaining == 22, 50)
    try expect(codexWeekly.secondary?.resetsAt == iso8601(Date(timeIntervalSince1970: 1794384000)), 51)
    let both = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1794300000},"secondary":{"usedPercent":40.5,"windowDurationMins":10080,"resetsAt":null}}}}"#
    let codexBoth = try codexUsage(fromResponse: Data(both.utf8), now: now)
    try expect(codexBoth.primary?.usedPercent == 12 && codexBoth.secondary?.usedPercent == 40.5
               && codexBoth.secondary?.resetsAt == nil && codexBoth.provider == "codex", 52)
    for bad in [#"{"id":2,"error":{"code":-32600,"message":"x"}}"#,
                #"{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}"#, "not json"] {
        try expect((try? codexUsage(fromResponse: Data(bad.utf8), now: now)) == nil, 53)
    }

    // Model windows and billing anchors survive the publish round trip; only fixed keys are published.
    let enriched = rows(for: legacySlots, usages: ["codex": codexWeekly, "claude-1": reading.usage],
                        extras: ["claude-1": AccountExtras(models: reading.models, billingAnchor: "2026-10-28T20:00:00.000000Z"),
                                 "codex": AccountExtras(billingAnchor: "2026-08-13")])
    let published = try JSONEncoder().encode(PublishedSnapshot(rows: enriched))
    let text = String(decoding: published, as: UTF8.self)
    let roundTrip = try JSONDecoder().decode(PublishedSnapshot.self, from: published).displayRows
    try expect(roundTrip.map(\.id) == legacyIDs && roundTrip.map(\.kind) == [.codex, .claude, .claude]
               && roundTrip.map(\.name) == ["Codex", "Claude 1", "Claude 2"], 60)
    try expect(roundTrip[1].models.count == 1 && roundTrip[1].models[0].id == "claude-weekly-scoped-fable"
               && roundTrip[1].models[0].quota.remaining == 0
               && roundTrip[1].models[0].quota.resetsAt == "2026-11-09T23:59:00Z", 61)
    try expect(roundTrip[0].billingAnchor == "2026-08-13" && roundTrip[2].models.isEmpty
               && roundTrip[2].billingAnchor == nil && roundTrip[2].usage == nil, 62)
    try expect(!text.contains("@") && !text.contains("label") && !text.contains("limitId"), 63)
    let legacy = #"{"accounts":[{"id":"codex","name":"Codex","usage":null},{"id":"claude-1","name":"Claude 1","usage":null},{"id":"claude-2","name":"Claude 2","usage":null}]}"#
    let legacyRows = try JSONDecoder().decode(PublishedSnapshot.self, from: Data(legacy.utf8)).displayRows
    try expect(legacyRows.allSatisfy { $0.models.isEmpty && $0.billingAnchor == nil }
               && legacyRows.map(\.kind) == [.codex, .claude, .claude], 64)
    // Any 0-4 accounts with valid unique ids are a usable snapshot; anything else falls back.
    func snapshot(_ ids: [String]) -> PublishedSnapshot {
        PublishedSnapshot(rows: rows(for: ids.map { AccountSlot(id: $0, kind: .claude, name: $0) }, usages: nil))
    }
    try expect(snapshot([]).isValid && snapshot(["work"]).isValid && snapshot(["a", "b", "c", "d"]).isValid
               && !snapshot(["a", "b", "c", "d", "e"]).isValid && !snapshot(["a", "a"]).isValid
               && !snapshot(["someone@example.com"]).isValid, 66)
    try expect(withLanguage(.ru) { remainingSummary(enriched) }.contains("Claude 1: сеанс 100%, неделя 1%")
               && withLanguage(.ru) { remainingSummary(enriched) }.contains("Claude 2: нет данных"), 65)
    try expect(withLanguage(.en) { remainingSummary(enriched) }.contains("Claude 1: session 100%, week 1%")
               && withLanguage(.en) { remainingSummary(enriched) }.contains("Claude 2: no data"), 67)

    // Monthly payment estimate in Asia/Tashkent.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    try expect(nextPayment(anchor: "2026-01-31", now: day(2026, 2, 10, 15)) == day(2026, 2, 28)
               && nextPayment(anchor: "2026-03-15", now: day(2026, 11, 15, 23)) == day(2026, 11, 15)
               && nextPayment(anchor: "2026-10-28", now: day(2026, 11, 10, 3)) == day(2026, 11, 28)
               && nextPayment(anchor: "2026-01-31", now: day(2026, 3, 1, 9)) == day(2026, 3, 31)
               && nextPayment(anchor: "2026-08-13T10:00:00Z", now: day(2026, 11, 14)) == day(2026, 12, 13)
               && nextPayment(anchor: "2026-10-28T20:00:00.000000Z", now: day(2026, 11, 10)) == day(2026, 11, 29)
               && nextPayment(anchor: "2026-12-05", now: day(2026, 11, 10)) == day(2026, 12, 5)
               && nextPayment(anchor: "garbage", now: day(2026, 11, 10)) == nil
               && nextPayment(anchor: nil, now: day(2026, 11, 10)) == nil, 70)
    try expect(withLanguage(.ru) { paymentLabel(anchor: "2026-10-28", now: day(2026, 11, 10, 3)) } == "Оплата 28 ноя"
               && withLanguage(.ru) { paymentLabel(anchor: "2026-10-28", now: day(2026, 11, 10, 3), short: true) } == "Оплата 28.11"
               && withLanguage(.en) { paymentLabel(anchor: "2026-10-28", now: day(2026, 11, 10, 3)) } == "Payment Nov 28"
               && withLanguage(.en) { paymentLabel(anchor: "2026-10-28", now: day(2026, 11, 10, 3), short: true) } == "Due Nov 28"
               && paymentLabel(anchor: nil, now: Date()) == nil
               && paymentDaysAway(anchor: "2026-10-12", now: day(2026, 11, 10, 22)) == 2, 71)

    try runLocalizationSelfTest()
    // accounts.json problems are matched as English text; the Russian wording is checked in 330.
    try withLanguage(.en) { try runAccountsSelfTest() }
    try runFetchFailureSelfTest()
    try runAnalyticsSelfTest()
}

/// Fetch errors carry a typed reason; the UI maps it to fixed hints in both languages.
private func runFetchFailureSelfTest() throws {
    let now = Date()
    func reason(_ body: () throws -> Void) -> FetchFailure? {
        do { try body(); return nil } catch { return fetchFailure(of: error) }
    }
    try expect(reason { _ = try parseClaudeUsage("Do you trust the files in this folder?\n1. Yes, proceed", now: now) } == .probeNotTrusted
               && reason { _ = try parseClaudeUsage("Welcome to Claude Code\nSelect login method", now: now) } == .notLoggedIn
               && reason { _ = try codexUsage(fromResponse: Data(#"{"id":2,"error":{"code":-32600}}"#.utf8), now: now) } == .notLoggedIn
               && reason { _ = try codexUsage(fromResponse: Data(#"{"id":2,"result":{}}"#.utf8), now: now) } == .notLoggedIn
               && reason { _ = try codexUsage(fromResponse: Data(#"{"id":2,"result":{"rateLimits":{}}}"#.utf8), now: now) } == .notLoggedIn
               && reason { _ = try codexUsage(fromResponse: Data("not json".utf8), now: now) } == .failed
               && fetchFailure(of: CocoaError(.fileNoSuchFile)) == .failed
               && FetchError("x").reason == .failed, 340)
    try expect(withLanguage(.en) { [fetchHint(.probeNotTrusted, kind: .claude), fetchHint(.notLoggedIn, kind: .codex),
                                    fetchHint(.cliNotFound, kind: .claude), fetchHint(.cliNotFound, kind: .codex),
                                    fetchHint(.failed, kind: .claude)] }
               == ["Run claude once in the probe folder — see README", "Not logged in or no plan limits",
                   "claude not found", "codex not found", "Check failed — run AILimits --check"], 341)
    try expect(withLanguage(.ru) { [fetchHint(.probeNotTrusted, kind: .claude), fetchHint(.notLoggedIn, kind: .claude),
                                    fetchHint(.cliNotFound, kind: .claude), fetchHint(.cliNotFound, kind: .codex),
                                    fetchHint(.failed, kind: .codex)] }
               == ["Запустите claude в папке проверки — см. README", "Нет входа или у тарифа нет лимитов",
                   "claude не найден", "codex не найден", "Проверка не удалась — запустите AILimits --check"], 342)
    // The trust tooltip names the app's own folder and the commands; nothing account-specific.
    let detail = withLanguage(.en) { fetchHintDetail(.probeNotTrusted, kind: .claude) }
    try expect(detail.contains("~/Library/Application Support/AILimits/ClaudeProbe")
               && detail.contains("cd ~/Library/Application\\ Support/AILimits/ClaudeProbe && claude")
               && detail.contains("CLAUDE_CONFIG_DIR=<configDir> claude")
               && withLanguage(.ru) { fetchHintDetail(.probeNotTrusted, kind: .claude) }.contains("CLAUDE_CONFIG_DIR=<configDir> claude")
               && withLanguage(.ru) { fetchHintDetail(.notLoggedIn, kind: .codex) }.contains("API-ключу"), 343)
    // The failure reaches the row through the extras; it is never part of the published snapshot.
    let slot = AccountSlot(id: "claude-1", kind: .claude, name: "Claude")
    let failing = rows(for: [slot], usages: nil, extras: ["claude-1": AccountExtras(failure: .probeNotTrusted)])
    let encoded = String(decoding: try JSONEncoder().encode(PublishedSnapshot(rows: failing)), as: UTF8.self)
    try expect(failing[0].failure == .probeNotTrusted && !encoded.contains("probeNotTrusted") && !encoded.contains("failure"), 344)
    // Login-shell misses expire after the TTL so a CLI installed later is found; hits stay cached.
    var calls = 0
    var installed = false
    let locator = CLILocator(missTTL: 300) { _ in calls += 1; return installed ? "/opt/x/bin/tool" : nil }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = locator.shellLocate("tool", now: start)
    installed = true
    let cachedMiss = locator.shellLocate("tool", now: start.addingTimeInterval(299))
    let expired = locator.shellLocate("tool", now: start.addingTimeInterval(301))
    let cachedHit = locator.shellLocate("tool", now: start.addingTimeInterval(10_000))
    try expect(first == nil && cachedMiss == nil && expired == "/opt/x/bin/tool" && cachedHit == "/opt/x/bin/tool" && calls == 2, 345)
}

/// Language choice, plural forms and the English/Russian captions that have fixed widths.
private func runLocalizationSelfTest() throws {
    try expect(resolveLanguage(environment: ["AI_LIMITS_LANG": "ru"], defaults: "en", preferred: ["en-US"]) == .ru
               && resolveLanguage(environment: ["AI_LIMITS_LANG": "EN"], defaults: "ru", preferred: ["ru-RU"]) == .en
               && resolveLanguage(environment: ["AI_LIMITS_LANG": "de"], defaults: "ru", preferred: ["en"]) == .ru
               && resolveLanguage(environment: [:], defaults: nil, preferred: ["ru-RU", "en"]) == .ru
               && resolveLanguage(environment: [:], defaults: nil, preferred: ["uk-UA", "ru-RU"]) == .en
               && resolveLanguage(environment: [:], defaults: nil, preferred: []) == .en, 40)
    try expect([1, 2, 5, 11, 12, 21, 22, 25, 111, 101].map { ruPlural($0, "a", "b", "c") }
               == ["a", "b", "c", "c", "c", "a", "b", "c", "c", "a"], 41)
    try expect(withLanguage(.ru) { percentWords(1) + "|" + percentWords(3) + "|" + percentWords(47) } == "1 процент|3 процента|47 процентов"
               && withLanguage(.en) { percentWords(47) } == "47 percent"
               && withLanguage(.ru) { tokensWord(1) + "|" + tokensWord(5) + "|" + tokensWord(5_000) } == "токен|токенов|токенов"
               && withLanguage(.en) { tokensWord(1) + "|" + tokensWord(2) } == "token|tokens", 42)
    // 2026-11-10T00:00Z is 05:00 in Asia/Tashkent.
    let now = parsedDate("2026-11-10T00:00:00Z")!
    let today = Quota(usedPercent: 10, resetsAt: "2026-11-10T02:34:00Z")
    let later = Quota(usedPercent: 10, resetsAt: "2026-11-15T22:34:00Z")
    let past = Quota(usedPercent: 10, resetsAt: "2026-11-09T22:34:00Z")
    try expect(withLanguage(.en) { [shortReset(today, now: now), shortReset(later, now: now), shortReset(past, now: now), shortReset(nil, now: now)] }
               == ["at 07:34", "Nov 16, 03:34", "awaiting reset", "no data"]
               && withLanguage(.ru) { [shortReset(today, now: now), shortReset(later, now: now), shortReset(past, now: now), shortReset(nil, now: now)] }
               == ["в 07:34", "16 ноя, 03:34", "ждём сброса", "нет данных"], 43)
    let friday = parsedDate("2026-11-13T09:30:00Z")!  // Friday 14:30 local
    let tomorrow = parsedDate("2026-11-11T04:00:00Z")!
    try expect(withLanguage(.en) { [paceMoment(friday, now: now), paceMoment(tomorrow, now: now), paceMoment(now, now: now)] }
               == ["Fri, 14:30", "tomorrow, 09:00", "today, 05:00"]
               && withLanguage(.ru) { [paceMoment(friday, now: now), paceMoment(tomorrow, now: now), paceMoment(now, now: now)] }
               == ["пт, 14:30", "завтра, 09:00", "сегодня, 05:00"], 44)
    try expect(withLanguage(.en) { resetDetail(later) } == "Resets November 16, 03:34"
               && withLanguage(.ru) { resetDetail(later) } == "Сброс: 16 ноября, 03:34"
               && withLanguage(.en) { resetLabel(today, now: now) } == "Resets in 2 h 34 min"
               && withLanguage(.ru) { ageLabel(Usage(provider: "claude", updatedAt: "2026-11-09T23:55:00Z", primary: nil, secondary: nil), now: now) } == "5 мин назад"
               && withLanguage(.en) { ageLabel(Usage(provider: "claude", updatedAt: "2026-11-09T23:55:00Z", primary: nil, secondary: nil), now: now) } == "5 min ago", 45)
    let rows = withLanguage(.en) { meters(for: AccountRow(id: "c", name: "C", kind: .claude,
        usage: Usage(provider: "claude", updatedAt: nil, primary: today, secondary: later))).map(\.label) }
    try expect(rows == ["Session", "Week"] && withLanguage(.ru) { UsagePeriod.week.title } == "7 дней"
               && withLanguage(.en) { UsagePeriod.allCases.map(\.title) } == ["Today", "7 days", "30 days"], 46)
}

/// accounts.json parsing, defaults, fallback to detection, log roots. Strings and a fake home only:
/// the real Application Support files are never touched.
private func runAccountsSelfTest() throws {
    let home = URL(fileURLWithPath: "/Users/tester")
    let executable: (String) -> Bool = { $0 == "/opt/tools/claude" }
    func resolve(_ text: String?, codex: Bool = true, claude: Bool = true) -> AccountsConfiguration {
        resolveAccounts(fileData: text.map { Data($0.utf8) }, home: home, isExecutable: executable) { name, _ in
            (name == "codex" && codex) || (name == "claude" && claude) ? "/usr/local/bin/\(name)" : nil
        }
    }
    let valid = resolve(#"""
    {"accounts":[{"id":"codex","type":"codex"},
                 {"id":"claude-1","type":"claude","name":"Claude"},
                 {"id":"claude-2","type":"claude","name":"Claude Work","configDir":"~/.claude-work"}],
     "cli":{"claude":"/opt/tools/claude"}}
    """#)
    try expect(valid.fromFile && valid.warning == nil && valid.ids == ["codex", "claude-1", "claude-2"]
               && valid.accounts.map(\.name) == ["Codex", "Claude", "Claude Work"]
               && valid.accounts[0].directory == nil && valid.accounts[1].directory == nil
               && valid.accounts[2].directory == "/Users/tester/.claude-work"
               && valid.cli == ["claude": "/opt/tools/claude"] && valid.codex?.id == "codex", 300)

    // Default names: one Claude is "Claude", several are numbered in order; Codex home is kept.
    let one = resolve(#"{"accounts":[{"id":"main","type":"claude"},{"id":"cx","type":"codex","home":"/opt/codex-home"}]}"#)
    try expect(one.accounts.map(\.name) == ["Claude", "Codex"] && one.accounts[1].directory == "/opt/codex-home", 301)
    let two = resolve(#"{"accounts":[{"id":"a","type":"claude"},{"id":"b","type":"claude","name":"  "},{"id":"c","type":"claude","name":"Team"}]}"#)
    try expect(two.accounts.map(\.name) == ["Claude 1", "Claude 2", "Team"] && two.warning == nil, 302)

    // Bad entries are dropped with a warning; the rest stays.
    let duplicate = resolve(#"{"accounts":[{"id":"claude-1","type":"claude"},{"id":"claude-1","type":"claude","name":"X"}]}"#)
    try expect(duplicate.ids == ["claude-1"] && duplicate.accounts[0].name == "Claude"
               && duplicate.warning?.contains("duplicate") == true, 303)
    let badIDs = resolve(#"{"accounts":[{"id":"Claude_1","type":"claude"},{"id":"","type":"claude"},{"id":"a@b","type":"claude"},{"id":"\#(String(repeating: "x", count: 33))","type":"claude"},{"type":"claude"},{"id":"ok","type":"claude"}]}"#)
    try expect(badIDs.ids == ["ok"] && badIDs.warning?.hasPrefix("accounts.json: entry 1") == true
               && badIDs.warning?.contains("and 3 more") == true && !(badIDs.warning?.contains("a@b") ?? true), 304)
    let twoCodex = resolve(#"{"accounts":[{"id":"codex","type":"codex"},{"id":"codex-2","type":"codex"},{"id":"x","type":"gemini"},"nope"]}"#)
    try expect(twoCodex.ids == ["codex"] && twoCodex.warning?.contains("only one codex") == true, 305)
    let many = resolve(#"{"accounts":[\#((1...6).map { #"{"id":"c\#($0)","type":"claude"}"# }.joined(separator: ","))]}"#)
    try expect(many.ids == ["c1", "c2", "c3", "c4"] && many.accounts.last?.name == "Claude 4"
               && many.warning?.contains("first 4") == true, 306)
    let badPaths = resolve(#"{"accounts":[{"id":"a","type":"claude","configDir":"relative/dir"},{"id":"b","type":"claude"}],"cli":{"codex":"/nowhere/codex"}}"#)
    try expect(badPaths.ids == ["b"] && badPaths.cli.isEmpty && badPaths.warning?.contains("absolute") == true
               && badPaths.warning?.contains("cli.codex") == true, 307)

    // Unparseable or empty files fall back to detection with a warning; no file detects silently.
    for broken in ["{\"accounts\": [", "[]", #"{"accounts":{}}"#, #"{"accounts":[]}"#, #"{"accounts":[{"id":"Bad"}]}"#] {
        let fallback = resolve(broken, codex: false)
        try expect(!fallback.fromFile && fallback.ids == ["claude-1"] && fallback.accounts[0].name == "Claude"
                   && fallback.warning?.hasPrefix("accounts.json: ") == true, 310)
    }
    let detected = resolve(nil)
    try expect(!detected.fromFile && detected.warning == nil && detected.ids == ["codex", "claude-1"]
               && detected.accounts.map(\.name) == ["Codex", "Claude"], 311)
    try expect(resolve(nil, codex: false, claude: false).accounts.isEmpty && resolve(nil, claude: false).ids == ["codex"], 312)
    try expect(expandedPath("~", home: home) == "/Users/tester" && expandedPath("~/a/../b", home: home) == "/Users/tester/b"
               && expandedPath("~other/x", home: home) == nil && expandedPath("x", home: home) == nil, 313)

    // Log roots: <configDir or ~/.claude>/projects deduplicated; Codex home > $CODEX_HOME > ~/.codex.
    let roots = UsageSources(configuration: resolve(#"""
    {"accounts":[{"id":"a","type":"claude"},{"id":"b","type":"claude","configDir":"~/.claude-work"},
                 {"id":"c","type":"claude","configDir":"~/.claude/"},{"id":"codex","type":"codex"}]}
    """#), home: home, environment: ["CODEX_HOME": "~/codex-home"])
    try expect(roots.claudeRoots.map(\.path) == ["/Users/tester/.claude/projects", "/Users/tester/.claude-work/projects"]
               && roots.codexRoots.map(\.path) == ["/Users/tester/codex-home/sessions"], 320)
    let plain = UsageSources(configuration: detected, home: home, environment: [:])
    try expect(plain.claudeRoots.map(\.path) == ["/Users/tester/.claude/projects"]
               && plain.codexRoots.map(\.path) == ["/Users/tester/.codex/sessions"], 321)
    let explicit = UsageSources(configuration: one, home: home, environment: ["CODEX_HOME": "/elsewhere"])
    try expect(explicit.codexRoots.map(\.path) == ["/opt/codex-home/sessions"]
               && UsageSources(configuration: AccountsConfiguration(), home: home) == UsageSources(claudeRoots: [], codexRoots: []), 322)

    // History and billing keys follow the same id rule.
    try expect(parseHistoryLine(Data(#"{"t":"2026-11-10T00:00:00Z","id":"work-2","w":50}"#.utf8))?.id == "work-2", 323)

    // Russian UI wording of the same problems; the file name and JSON keys stay as typed.
    let russian = withLanguage(.ru) {
        resolve(#"{"accounts":[{"id":"a","type":"claude"},{"id":"a","type":"claude"},{"id":"b","type":"x"},{"id":"c","type":"claude","configDir":"rel"}]}"#)
    }
    try expect(russian.ids == ["a"] && russian.warning?.hasPrefix("accounts.json: запись 2: повторный id \"a\"; запись 3: type") == true
               && russian.warning?.hasSuffix("; и ещё 1") == true, 330)
}

/// Pace, history, prices, formatting, Codex meta and the log scanner on synthetic data.
@MainActor private func runAnalyticsSelfTest() throws {
    // Pace: a 7-day window that resets in 3.5 days is half elapsed.
    let now = parsedDate("2026-11-10T06:00:00Z")!
    let reset = iso8601(now.addingTimeInterval(3.5 * 86_400))
    try expect(paceReading(Quota(usedPercent: 52, resetsAt: reset), window: weekWindow, now: now)?.status == .onTrack, 100)
    try expect(paceReading(Quota(usedPercent: 30, resetsAt: reset), window: weekWindow, now: now)
               == PaceReading(status: .reserve(20), runsOut: nil), 101)
    let over = paceReading(Quota(usedPercent: 75, resetsAt: reset), window: weekWindow, now: now)
    // 75 % used after 3.5 days: 100 % after 4.667 days, i.e. 1.1667 days from now.
    try expect(over?.status == .overspend(25), 102)
    // Split into typed constants: the one-line form is too slow for older type checkers.
    let runsOutIn: Double = over?.runsOut?.timeIntervalSince(now) ?? 0
    let expectedRunsOutIn: Double = 3.5 * 86_400 / 0.75 - 3.5 * 86_400
    try expect(abs(runsOutIn - expectedRunsOutIn) < 1, 103)
    try expect(withLanguage(.ru) { paceCaption(over!, now: now) } == "Перерасход 25% · хватит до завтра, 15:00"
               && withLanguage(.en) { paceCaption(over!, now: now) } == "25% over pace · lasts until tomorrow, 15:00", 104)
    try expect(withLanguage(.ru) { paceCaption(PaceReading(status: .reserve(12), runsOut: nil), now: now) } == "Запас 12%"
               && withLanguage(.en) { paceCaption(PaceReading(status: .reserve(12), runsOut: nil), now: now) } == "12% under pace"
               && withLanguage(.en) { paceCaption(PaceReading(status: .onTrack, runsOut: nil), now: now) } == "On pace", 105)
    let barelyStarted = iso8601(now.addingTimeInterval(weekWindow - 3600))
    try expect(paceReading(Quota(usedPercent: 5, resetsAt: barelyStarted), window: weekWindow, now: now) == nil, 106)
    try expect(paceReading(Quota(usedPercent: 100, resetsAt: reset), window: weekWindow, now: now) == nil, 107)
    try expect(paceReading(Quota(usedPercent: 40, resetsAt: nil), window: weekWindow, now: now) == nil, 108)
    try expect(paceReading(Quota(usedPercent: 40, resetsAt: iso8601(now.addingTimeInterval(-60))), window: weekWindow, now: now) == nil, 109)
    // Session window: 2.5 h of 5 h elapsed, 80 % used runs out in 37.5 minutes.
    let session = paceReading(Quota(usedPercent: 80, resetsAt: iso8601(now.addingTimeInterval(9000))), window: claudeSessionWindow, now: now)
    try expect(session?.status == .overspend(30) && abs((session?.runsOut?.timeIntervalSince(now) ?? 0) - 2250) < 1, 110)

    // History: sampling rule, null round trip, pruning, weekly points.
    let usage = Usage(provider: "claude", updatedAt: nil, primary: nil, secondary: Quota(usedPercent: 33.33, resetsAt: nil))
    let first = historySample(id: "claude-1", usage: usage, models: [ModelQuota(id: "m", title: "M", quota: Quota(usedPercent: 10, resetsAt: nil))], at: now)
    try expect(first.s == nil && first.w == 66.7 && first.m == ["m": 90], 120)
    let line = historyLine(first)
    let text = String(decoding: line, as: UTF8.self)
    try expect(text.hasSuffix("\n") && text.contains("\"s\":null") && parseHistoryLine(line.dropLast()) == first, 121)
    try expect(shouldRecord(first, after: nil), 122)
    let unchanged = HistorySample(t: now.addingTimeInterval(300), id: first.id, s: nil, w: 66.7, m: ["m": 90])
    let changed = HistorySample(t: now.addingTimeInterval(300), id: first.id, s: nil, w: 60, m: ["m": 90])
    let later = HistorySample(t: now.addingTimeInterval(600), id: first.id, s: nil, w: 66.7, m: ["m": 90])
    try expect(!shouldRecord(unchanged, after: first) && shouldRecord(changed, after: first) && shouldRecord(later, after: first), 123)
    let old = HistorySample(t: now.addingTimeInterval(-31 * 86_400), id: "codex", s: nil, w: 1, m: [:])
    let pruned = pruneHistory([later, old, first], now: now)
    try expect(pruned == [first, later], 124)
    try expect(parseHistoryLine(Data(#"{"t":"2026-11-10T00:00:00Z","id":"someone@example.com","w":1}"#.utf8)) == nil, 125)
    try expect(weeklyPoints([first, changed, old], id: "claude-1", now: now.addingTimeInterval(400)).map(\.value) == [66.7, 60], 126)

    // Prices: longest prefix wins; unpriced models are ignored.
    let prices = parsePrices(Data(#"{"claude-opus":{"input":10,"cacheWrite":12.5,"cacheRead":1,"output":50},"claude-opus-5":{"input":5,"output":25},"x":"bad"}"#.utf8))
    try expect(prices.count == 2 && price(for: "claude-opus-5-5", in: prices)?.input == 5
               && price(for: "claude-opus-4-1", in: prices)?.cacheWrite == 12.5 && price(for: "gpt-5", in: prices) == nil, 130)
    let cost = estimatedCost([("claude-opus-5-5", TokenCounters(input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 1_000_000)),
                              ("gpt-5", TokenCounters(input: 5_000_000, cacheWrite: 0, cacheRead: 0, output: 0))], prices: prices)
    try expect(cost == 30 && estimatedCost([("gpt-5", TokenCounters(input: 1))], prices: prices) == nil, 131)

    // Compact numbers.
    try withLanguage(.ru) {
        try expect(compactTokens(0) == "0" && compactTokens(999) == "999" && compactTokens(1_000) == "1 тыс"
                   && compactTokens(12_345) == "12,3 тыс" && compactTokens(1_234_567) == "1,2 млн"
                   && compactTokens(999_999) == "1 млн" && compactTokens(3_400_000_000) == "3,4 млрд"
                   && compactTokens(123_456_789) == "123 млн" && compactTokens(2_000_000_000_000) == "2 трлн", 140)
        try expect(compactDollars(4.567) == "$4,57" && compactDollars(87.4) == "$87" && compactDollars(12345) == "$12\u{202F}345", 141)
    }
    try withLanguage(.en) {
        try expect(compactTokens(0) == "0" && compactTokens(999) == "999" && compactTokens(1_000) == "1K"
                   && compactTokens(12_345) == "12.3K" && compactTokens(1_234_567) == "1.2M"
                   && compactTokens(999_999) == "1M" && compactTokens(5_800_000_000) == "5.8B"
                   && compactTokens(300_000_000) == "300M" && compactTokens(2_000_000_000_000) == "2T"
                   && compactTokens(-12_345) == "-12.3K", 143)
        try expect(compactDollars(4.567) == "$4.57" && compactDollars(87.4) == "$87" && compactDollars(1520) == "$1,520"
                   && compactDollars(1_234_567) == "$1,234,567" && compactDollars(999.6) == "$1,000", 144)
    }
    let folded = withLanguage(.ru) {
        foldedModels([("a", TokenCounters(input: 50)), ("b", TokenCounters(input: 20)), ("c", TokenCounters(input: 15)),
                      ("d", TokenCounters(input: 10)), ("e", TokenCounters(input: 5))])
    }
    try expect(folded.map(\.name) == ["a", "b", "c", "другие"] && folded.last?.tokens == 15, 142)

    // Codex meta: window lengths, plan and credits; no account id kept.
    let metaLine = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":2},"planType":"plus","credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}},"accountId":"secret"}}"#
    let meta = codexMeta(fromResponse: Data(metaLine.utf8))
    try expect(meta == CodexMeta(sessionWindow: 18_000, weeklyWindow: 604_800, plan: "Plus", credits: 12.5), 150)
    try expect(withLanguage(.ru) { ["Plus · кредиты 12", "Plus · кредиты 13"].contains(codexPlanLabel(meta)) }
               && withLanguage(.en) { ["Plus · 12 credits", "Plus · 13 credits"].contains(codexPlanLabel(meta)) }, 151)
    try expect(codexMeta(fromResponse: Data("{}".utf8)) == CodexMeta() && codexPlanLabel(CodexMeta()) == nil, 152)

    // Timestamp parser agrees with Foundation.
    let stamp = "2026-11-09T21:15:42.123Z"
    let parsed = Array(("\"" + stamp + "\"").utf8).withUnsafeBufferPointer { RawJSON(p: $0.baseAddress!, end: $0.count).timestamp(0..<$0.count) }
    try expect(abs((parsed ?? 0) - parsedDate(stamp)!.timeIntervalSince1970) < 0.001, 160)
    let offsetStamp = Array("\"2026-11-10T02:15:42+05:00\"".utf8).withUnsafeBufferPointer { RawJSON(p: $0.baseAddress!, end: $0.count).timestamp(0..<$0.count) }
    try expect(offsetStamp == parsedDate("2026-11-09T21:15:42Z")!.timeIntervalSince1970, 161)
    let plusFive = TimeZone(identifier: "Asia/Tashkent")!
    try expect(usageDay(epoch: parsedDate("2026-11-09T19:00:00Z")!.timeIntervalSince1970, zone: plusFive)
               == usageDay(epoch: parsedDate("2026-11-10T18:59:59Z")!.timeIntervalSince1970, zone: plusFive), 162)

    // Days follow DST: New York leaves DST on 2026-11-01 and enters it on 2026-03-08.
    let newYork = TimeZone(identifier: "America/New_York")!
    func nyDay(_ stamp: String) -> Int { usageDay(epoch: parsedDate(stamp)!.timeIntervalSince1970, zone: newYork) }
    let nov1 = Int(parsedDate("2026-11-01T00:00:00Z")!.timeIntervalSince1970 / 86_400)
    try expect(nyDay("2026-11-01T03:59:59Z") == nov1 - 1 && nyDay("2026-11-01T04:00:00Z") == nov1
               && nyDay("2026-11-02T04:59:59Z") == nov1 && nyDay("2026-11-02T05:00:00Z") == nov1 + 1, 163)
    let mar8 = Int(parsedDate("2026-03-08T00:00:00Z")!.timeIntervalSince1970 / 86_400)
    try expect(nyDay("2026-03-08T04:59:59Z") == mar8 - 1 && nyDay("2026-03-08T05:00:00Z") == mar8
               && nyDay("2026-03-09T03:59:59Z") == mar8 && nyDay("2026-03-09T04:00:00Z") == mar8 + 1, 164)
    try expect(usageDayDate(nov1, zone: newYork) == parsedDate("2026-11-01T04:00:00Z")
               && usageDayDate(nov1 + 1, zone: newYork) == parsedDate("2026-11-02T05:00:00Z")
               && usageDayDate(mar8 + 1, zone: newYork) == parsedDate("2026-03-09T04:00:00Z")
               && usageDayDate(nov1, zone: plusFive) == parsedDate("2026-10-31T19:00:00Z"), 165)

    try runPricesSelfTest()
    try runScannerSelfTest()
}

/// Excerpt of the Anthropic pricing page with its traps: <sup> marks, a model cell with a link
/// in parentheses, two Haiku 5.5 tiers, a later fast-mode table and a repeated full-header table.
private let anthropicPricingExcerpt = """
## Model pricing

| Model                                                                       | Base input tokens     | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens          |
| :-------------------------------------------------------------------------- | :-------------------- | :-------------- | :-------------- | :----------------------- | :--------------------- |
| Claude Fable 5.2                                                            | $8 / MTok             | $10 / MTok      | $16 / MTok      | $0.20 / MTok<sup>1</sup> | $40 / MTok             |
| Claude Mythos 5.2 ([limited availability](https://support.claude.com/x/1))  | $8 / MTok             | $10 / MTok      | $16 / MTok      | $0.20 / MTok<sup>1</sup> | $40 / MTok             |
| Claude Opus 5.5                                                             | $4 / MTok             | $5 / MTok       | $8 / MTok       | $0.20 / MTok<sup>2</sup> | $20 / MTok             |
| Claude Sonnet 5                                                             | $2 / MTok<sup>3</sup> | $2.50 / MTok    | $4 / MTok       | $0.20 / MTok             | $10 / MTok<sup>3</sup> |
| Claude Sonnet 5.5                                                           | $2 / MTok             | $2.50 / MTok    | $4 / MTok       | $0.10 / MTok<sup>2</sup> | $10 / MTok             |
| Claude Haiku 5.5 (for prompts up to 100,000 tokens)                         | $0.10 / MTok          | $0.125 / MTok   | $0.20 / MTok    | $0.01 / MTok             | $0.50 / MTok           |
| Claude Haiku 5.5 (for prompts over 100,000 tokens)                          | $0.50 / MTok          | $0.625 / MTok   | $1 / MTok       | $0.05 / MTok             | $2.50 / MTok           |

*<sup>1 Cache hits are priced at 0.025x the base input price.</sup>*

### Fast mode pricing

| Model                           | Input          | Output         |
| ------------------------------- | -------------- | -------------- |
| Claude Fable 5.2                | $16 USD / MTok | $80 USD / MTok |
| Claude Opus 5.5                 | $8 USD / MTok  | $40 USD / MTok |

### Some later table

| Model           | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
| --------------- | ----------------- | --------------- | --------------- | ------------------------ | ------------- |
| Claude Opus 5.5 | $40 / MTok        | $50 / MTok      | $80 / MTok      | $2 / MTok                | $200 / MTok   |
| Claude Haiku 4.5 | $1 / MTok        | $1.25 / MTok    | $2 / MTok       | $0.10 / MTok             | $5 / MTok     |
"""

/// Excerpt of the OpenAI pricing page: the long Standard table, the plain 4-column table,
/// then a Batch section repeating the same ids with other prices.
private let openAIPricingExcerpt = """
### Standard pricing data

| Model | Short context input | Short context output | Short context cached input | Short context 30m write | Short context 12h write | Long context input | Long context output | Long context cached input | Long context 30m write | Long context 12h write |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-6-astra | $10.00 | $50.00 | $1.00 | $12.50 | $25.00 | $20.00 | $75.00 | $2.00 | $25.00 | $50.00 |
| gpt-6.1-sol | $2.00 | $10.00 | $0.10 | $2.50 | $5.00 | $4.00 | $15.00 | $0.20 | $5.00 | $10.00 |
| gpt-6.1-terra | $1.00 | $5.00 | $0.05 | $1.25 | $2.50 | $2.00 | $7.50 | $0.10 | $2.50 | $5.00 |
| gpt-5.5-pro (<272K context length) | $30.00 | $180.00 | - | - | - | $60.00 | $270.00 | - | - | - |

| Model | Input | Output | Cached input |
| --- | --- | --- | --- |
| gpt-5.4-mini | $0.75 | $4.50 | $0.075 |
| gpt-5 | $1.25 | $10.00 | $0.125 |

| Model | Modality | Input | Output | Cached input |
| --- | --- | --- | --- | --- |
| gpt-image-x | Image | $40.00 | $10.00 | $1.00 |

#### Batch

| Model | Short context input | Short context output | Short context cached input | Short context 30m write | Short context 12h write | Long context input | Long context output | Long context cached input | Long context 30m write | Long context 12h write |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-6-astra | $5.00 | $25.00 | $0.50 | - | - | $10.00 | $37.50 | $1.00 | - | - |

| Model | Input | Output | Cached input |
| --- | --- | --- | --- |
| gpt-5 | $0.625 | $5.00 | $0.0625 |
"""

/// Parsers, validation, layers, prefix lookup, cost with the 1-hour split, refresh throttle.
private func runPricesSelfTest() throws {
    let anthropic = parseAnthropicPricing(anthropicPricingExcerpt)
    try expect(anthropic.count == 6 && anthropic["claude-mythos-5-2"] != nil && anthropic["claude-haiku-4-5"] == nil, 200)
    try expect(anthropic["claude-fable-5-2"] == ModelPrice(input: 8, cacheWrite: 10, cacheWrite1h: 16, cacheRead: 0.2, output: 40), 201)
    try expect(anthropic["claude-opus-5-5"] == ModelPrice(input: 4, cacheWrite: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20), 202)
    try expect(anthropic["claude-sonnet-5"] == ModelPrice(input: 2, cacheWrite: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10), 203)
    try expect(anthropic["claude-haiku-5-5"] == ModelPrice(input: 0.1, cacheWrite: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01, output: 0.5), 204)
    try expect(priceValidationFailure(anthropic) == nil, 205)
    try expect(anthropicModelKey("Claude Opus 4.1 ([retired, except on X (Y)](https://x.y/z))") == "claude-opus-4-1"
               && pricingCellValue("$0.20 / MTok<sup>1</sup>") == 0.2 && pricingCellValue("-") == nil
               && pricingCellValue("$1,250.00") == 1250, 206)

    let openai = parseOpenAIPricing(openAIPricingExcerpt)
    try expect(openai.count == 6 && openai["gpt-image-x"] == nil, 210)
    try expect(openai["gpt-6-astra"] == ModelPrice(input: 10, cacheWrite: 10, cacheWrite1h: 10, cacheRead: 1, output: 50), 211)
    try expect(openai["gpt-6.1-sol"]?.cacheRead == 0.1 && openai["gpt-6.1-terra"]?.output == 5, 212)
    try expect(openai["gpt-5"] == ModelPrice(input: 1.25, cacheWrite: 1.25, cacheWrite1h: 1.25, cacheRead: 0.125, output: 10)
               && openai["gpt-5.4-mini"]?.cacheRead == 0.075, 213)
    try expect(openai["gpt-5.5-pro"]?.cacheRead == 30 && priceValidationFailure(openai) == nil, 214)

    // Validation rejects.
    let good = ModelPrice(input: 1, cacheWrite: 1.25, cacheRead: 0.1, output: 5)
    let four = Dictionary(uniqueKeysWithValues: (1...4).map { ("m\($0)", good) })
    try expect(priceValidationFailure(four)?.hasPrefix("too few") == true, 220)
    var bad = four; bad["m5"] = ModelPrice(input: 1, cacheWrite: 0, cacheRead: 0.1, output: 5)
    try expect(priceValidationFailure(bad)?.contains("out of range") == true, 221)
    bad["m5"] = ModelPrice(input: 5, cacheWrite: 5, cacheRead: 0.1, output: 1)
    try expect(priceValidationFailure(bad)?.contains("output") == true, 222)
    bad["m5"] = ModelPrice(input: 1, cacheWrite: 1, cacheRead: 2, output: 5)
    try expect(priceValidationFailure(bad)?.contains("cache read") == true, 223)
    bad["m5"] = ModelPrice(input: 1000, cacheWrite: 1000, cacheRead: 1, output: 2000)
    try expect(priceValidationFailure(bad) != nil, 224)
    try expect(priceValidationFailure([:]) != nil, 225)

    // Layers: user > downloaded > built-in, per key; a rejected vendor keeps its old models.
    let t0 = parsedDate("2026-11-12T00:00:00Z")!
    var auto = applyVendorResult(AutoPrices(), vendor: .anthropic, models: ["claude-opus-5-5": ModelPrice(input: 3, cacheWrite: 4, cacheRead: 0.1, output: 15),
                                                                            "claude-new-6": good], now: t0)
    auto = applyVendorResult(auto, vendor: .openai, models: ["gpt-6-astra": good], now: t0)
    let reparsed = parseAutoPrices(encodeAutoPrices(auto))
    try expect(reparsed == auto && reparsed.vendorOf["claude-new-6"] == "anthropic" && reparsed.fetchedAt == t0, 230)
    let replaced = applyVendorResult(auto, vendor: .openai, models: ["gpt-6.1-sol": good], now: t0.addingTimeInterval(60))
    try expect(replaced.models["gpt-6-astra"] == nil && replaced.models["claude-new-6"] == good
               && replaced.vendorFetchedAt["anthropic"] == t0, 231)
    let user = parsePrices(Data(#"{"claude-opus-5-5":{"input":1,"cacheWrite":2,"cacheRead":0.5,"output":9}}"#.utf8))
    try expect(user["claude-opus-5-5"]?.cacheWrite1h == 2, 232)
    let book = mergePriceLayers(user: user, downloaded: auto, builtin: builtInPrices)
    try expect(book.sources["claude-opus-5-5"] == .user && book.prices["claude-opus-5-5"]?.input == 1
               && book.sources["claude-new-6"] == .downloaded && book.sources["gpt-6-astra"] == .downloaded
               && book.sources["claude-sonnet-5-5"] == .builtin && book.asOf == t0, 233)
    try expect(PriceBook.builtIn.asOf == builtInPricesDate && PriceBook.builtIn.prices.count == 12
               && priceValidationFailure(builtInPrices) == nil, 234)

    // Longest prefix wins; suffixes on log names still match.
    let built = builtInPrices
    try expect(priceKey(for: "claude-opus-5-5-20261101", in: built) == "claude-opus-5-5"
               && priceKey(for: "claude-opus-5-20260601", in: built) == "claude-opus-5"
               && priceKey(for: "claude-fable-5-2", in: built) == "claude-fable-5-2"
               && priceKey(for: "claude-haiku-5-5[1m]", in: built) == "claude-haiku-5-5"
               && priceKey(for: "gpt-6.1-terra", in: built) == "gpt-6.1-terra"
               && priceKey(for: "gpt-6-luna", in: built) == nil, 240)

    // Cost: 1-hour writes at their own price, the rest of the writes at the 5-minute price.
    let opus = built["claude-opus-5-5"]!
    let counters = TokenCounters(input: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000, output: 1_000_000, cacheWrite1h: 400_000)
    try expect(abs(cost(of: counters, at: opus) - 30.4) < 1e-9, 250)
    let codex = TokenCounters(input: 2_000_000, cacheWrite: 0, cacheRead: 10_000_000, output: 100_000)
    try expect(abs(cost(of: codex, at: built["gpt-6.1-sol"]!) - (4 + 1 + 1)) < 1e-9, 251)
    try expect(unpricedModels([("gpt-6-luna", TokenCounters(input: 1)), ("gpt-6.1-sol", TokenCounters(input: 1)),
                               ("x", TokenCounters())], prices: built) == ["gpt-6-luna"], 252)
    try expect(unpricedCaption(["a", "b"]) == "a, b" && withLanguage(.ru) { unpricedCaption(["a", "b", "c", "d"]) } == "a, b и ещё 2"
               && withLanguage(.en) { unpricedCaption(["a", "b", "c", "d"]) } == "a, b and 2 more", 253)

    // The scanner counts the 1-hour part of cache writes.
    let line = #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":100,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":60,"ephemeral_1h_input_tokens":40},"output_tokens":4}}}"#
    let parsedLine = Array(line.utf8).withUnsafeBufferPointer { parseClaudeLine($0.baseAddress!, $0.count, names: ModelNames()) }
    try expect(parsedLine?.counters == TokenCounters(input: 1, cacheWrite: 100, cacheRead: 3, output: 4, cacheWrite1h: 40)
               && parsedLine?.counters.total == 108, 254)

    // Refresh throttle.
    let now = parsedDate("2026-11-20T12:00:00Z")!
    let hour: TimeInterval = 3600, day: TimeInterval = 86_400
    try expect(priceRefreshDecision(now: now, fetchedAt: nil, lastAttemptAt: nil, hasUnpricedRecentModel: false) == .stale, 260)
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 8 * day, lastAttemptAt: now - 2 * hour, hasUnpricedRecentModel: false) == .stale, 261)
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 8 * day, lastAttemptAt: now - 0.5 * hour, hasUnpricedRecentModel: true) == nil, 262)
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 2 * day, lastAttemptAt: now - 2 * day, hasUnpricedRecentModel: false) == nil, 263)
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 2 * day, lastAttemptAt: now - 25 * hour, hasUnpricedRecentModel: true) == .unpricedModel, 264)
    // A failed attempt 5 hours ago still blocks an out-of-turn refresh.
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 2 * day, lastAttemptAt: now - 5 * hour, hasUnpricedRecentModel: true) == nil, 265)
    try expect(priceRefreshDecision(now: now, fetchedAt: now - 2 * day, lastAttemptAt: nil, hasUnpricedRecentModel: true) == .unpricedModel, 266)
}

/// Synthetic transcripts in a temporary folder: dedupe, synthetic model, prefilter traps,
/// lines split across 7-byte chunks, incremental append, partial last line, shrink -> rescan.
private func runScannerSelfTest() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("ailimits-selftest-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    defer { try? manager.removeItem(at: root) }
    let claudeA = root.appendingPathComponent("claude-a/p1"), claudeB = root.appendingPathComponent("claude-b/p2")
    let codexRoot = root.appendingPathComponent("codex/2026/11/10")
    for folder in [claudeA, claudeB, codexRoot] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
    let sources = UsageSources(claudeRoots: [root.appendingPathComponent("claude-a"), root.appendingPathComponent("claude-b")],
                               codexRoots: [root.appendingPathComponent("codex")])
    let cache = root.appendingPathComponent("cache/usage-cache.json")
    let now = Date()
    let ts = iso8601(now.addingTimeInterval(-60))
    let today = usageDay(epoch: now.timeIntervalSince1970)
    func assistant(_ id: String, _ request: String, _ model: String, _ c: [Int], text: String = "hi") -> String {
        #"{"parentUuid":null,"isSidechain":false,"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(c[0]),"cache_creation_input_tokens":\#(c[1]),"cache_read_input_tokens":\#(c[2]),"cache_creation":{"ephemeral_5m_input_tokens":0},"output_tokens":\#(c[3]),"service_tier":"standard"}},"requestId":"\#(request)","type":"assistant","uuid":"u","timestamp":"\#(ts)"}"#
    }
    let userTrap = #"{"type":"user","message":{"role":"user","content":"quoted \"usage\":{\"input_tokens\":999} and \"assistant\""},"timestamp":"\#(ts)"}"#
    let fileA = claudeA.appendingPathComponent("s1.jsonl"), fileB = claudeB.appendingPathComponent("s2.jsonl")
    try (assistant("msg_1", "req_1", "claude-opus-5-5", [10, 100, 1000, 5], text: #"say \"usage\":{ ok"#) + "\n"
         + assistant("msg_1", "req_1", "claude-opus-5-5", [10, 100, 1000, 5]) + "\n"
         + assistant("msg_s", "req_s", "<synthetic>", [7, 7, 7, 7]) + "\n" + userTrap + "\n"
         + assistant("msg_2", "req_2", "claude-sonnet-5-5", [1, 2, 3, 4]) + "\n").write(to: fileA, atomically: false, encoding: .utf8)
    try (assistant("msg_1", "req_1", "claude-opus-5-5", [10, 100, 1000, 5]) + "\n"
         + assistant("msg_3", "req_3", "claude-opus-5-5", [20, 0, 0, 30]) + "\n").write(to: fileB, atomically: false, encoding: .utf8)
    func record(_ id: String, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(ts)","type":"token_usage_record","ordinal":1,"payload":{"thread_id":"t","response_id":"\#(id)","usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":1,"total_tokens":\#(input + output)},"turn_token_usage":{}}}"#
    }
    func turn(_ model: String) -> String { #"{"timestamp":"\#(ts)","type":"turn_context","payload":{"cwd":"/x","model":"\#(model)"}}"# }
    func tokenCount(total: Int, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
    }
    let codexTrap = #"{"timestamp":"\#(ts)","type":"response_item","payload":{"type":"message","content":"\"token_usage_record\" \"turn_context\" \"token_count\""}}"#
    let codexA = codexRoot.appendingPathComponent("rollout-a.jsonl"), codexB = codexRoot.appendingPathComponent("rollout-b.jsonl")
    try ([#"{"timestamp":"\#(ts)","type":"session_meta","payload":{"cwd":"/x"}}"#, record("resp_0", input: 1, cached: 0, output: 1),
          turn("gpt-5.5-codex"), record("resp_1", input: 1000, cached: 800, output: 50),
          tokenCount(total: 1050, input: 1000, cached: 800, output: 50), codexTrap,
          record("resp_1", input: 1000, cached: 800, output: 50)].joined(separator: "\n") + "\n")
        .write(to: codexA, atomically: false, encoding: .utf8)
    try ([turn("gpt-old"), tokenCount(total: 100, input: 90, cached: 40, output: 10), tokenCount(total: 100, input: 90, cached: 40, output: 10),
          tokenCount(total: 250, input: 140, cached: 100, output: 10)].joined(separator: "\n") + "\n")
        .write(to: codexB, atomically: false, encoding: .utf8)

    func scan() -> ScanOutcome { scanUsage(sources: sources, cacheURL: cache, now: now, chunkSize: 7, concurrency: 2) }
    func models(_ days: UsageDays, _ provider: UsageProvider) -> [String: TokenCounters] {
        Dictionary(uniqueKeysWithValues: usageModels(days, provider: provider, lastDays: 1, today: today).map { ($0.model, $0.counters) })
    }
    var outcome = scan()
    var claude = models(outcome.days, .claude), codex = models(outcome.days, .codex)
    try expect(claude["claude-opus-5-5"] == TokenCounters(input: 30, cacheWrite: 100, cacheRead: 1000, output: 35)
               && claude["claude-sonnet-5-5"] == TokenCounters(input: 1, cacheWrite: 2, cacheRead: 3, output: 4)
               && claude.count == 2, 170)
    try expect(codex["unknown"] == TokenCounters(input: 1, cacheWrite: 0, cacheRead: 0, output: 1)
               && codex["gpt-5.5-codex"] == TokenCounters(input: 200, cacheWrite: 0, cacheRead: 800, output: 50)
               && codex["gpt-old"] == TokenCounters(input: 90, cacheWrite: 0, cacheRead: 140, output: 20) && codex.count == 3, 171)
    try expect(outcome.filesScanned == 4 && outcome.recordsAdded == 7, 172)
    let mode = (try? manager.attributesOfItem(atPath: cache.path))?[.posixPermissions] as? Int
    try expect(mode == 0o600 && manager.fileExists(atPath: seenURL(for: cache).path), 173)
    let cacheText = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
    try expect(!cacheText.contains("msg_") && !cacheText.contains("resp_") && !cacheText.contains(root.path)
               && !cacheText.contains("rollout"), 174)

    // Unchanged files are skipped; an appended line is read from the stored offset; a partial line waits.
    outcome = scan()
    try expect(outcome.filesScanned == 0 && outcome.bytesRead == 0, 175)
    let partial = assistant("msg_5", "req_5", "claude-opus-5-5", [1, 0, 0, 1])
    let handle = try FileHandle(forWritingTo: fileA)
    handle.seekToEndOfFile()
    handle.write(Data((assistant("msg_4", "req_4", "claude-sonnet-5-5", [100, 0, 0, 0]) + "\n" + partial.prefix(40)).utf8))
    outcome = scan()
    claude = models(outcome.days, .claude)
    try expect(outcome.filesScanned == 1 && outcome.recordsAdded == 1
               && claude["claude-sonnet-5-5"] == TokenCounters(input: 101, cacheWrite: 2, cacheRead: 3, output: 4), 176)
    handle.write(Data((partial.dropFirst(40) + "\n").utf8))
    try handle.close()
    outcome = scan()
    claude = models(outcome.days, .claude)
    try expect(outcome.recordsAdded == 1 && claude["claude-opus-5-5"]?.output == 36, 177)

    // A shrunk file is rescanned from zero; known records stay deduped, the model is re-derived.
    try ([turn("gpt-5.5-codex"), record("resp_1", input: 1000, cached: 800, output: 50), record("resp_9", input: 10, cached: 0, output: 2)]
        .joined(separator: "\n") + "\n").write(to: codexA, atomically: false, encoding: .utf8)
    outcome = scan()
    codex = models(outcome.days, .codex)
    try expect(outcome.filesRescanned == 1 && outcome.recordsAdded == 1
               && codex["gpt-5.5-codex"] == TokenCounters(input: 210, cacheWrite: 0, cacheRead: 800, output: 52), 178)

    // Without a cache the same files give the same totals.
    let clean = scanUsage(sources: sources, cacheURL: nil, now: now, chunkSize: 1 << 20, concurrency: 1)
    try expect(models(clean.days, .claude) == models(outcome.days, .claude)
               && models(clean.days, .codex)["gpt-5.5-codex"] == codex["gpt-5.5-codex"], 179)
}

// MARK: - Live check

private func checkLine(_ row: AccountRow) -> String {
    let session = row.usage?.primary.map { String(Int($0.remaining.rounded())) } ?? "unavailable"
    let weekly = row.usage?.secondary.map { String(Int($0.remaining.rounded())) } ?? "unavailable"
    let models = row.models.isEmpty ? "none" : row.models.map {
        "\($0.title) remaining=\(Int($0.quota.remaining.rounded()))"
    }.joined(separator: ", ")
    let payment = paymentLabel(anchor: row.billingAnchor, now: Date()) ?? "no billing date"
    return "\(row.name): session remaining=\(session); weekly remaining=\(weekly); models: \(models); \(payment)"
}

private func runCheck() -> Bool {
    let configuration = loadAccountsConfiguration()
    if let warning = configuration.warning { print("warning: \(warning)") }
    guard !configuration.accounts.isEmpty else {
        print("FAIL: no accounts (install Claude Code or the Codex CLI and log in, or list accounts in accounts.json).")
        return false
    }
    let billing = loadBillingOverrides()
    var failed = 0
    func report(_ account: AccountConfig, _ fetch: () throws -> (Usage, [ModelQuota], String?)) {
        do {
            let (usage, models, anchor) = try fetch()
            let row = rows(for: [account.slot], usages: [account.id: usage],
                           extras: [account.id: AccountExtras(models: models, billingAnchor: billing[account.id] ?? anchor)])[0]
            print(checkLine(row))
        } catch {
            failed += 1
            print("\(account.name): error: \(error)")
        }
        fflush(stdout)
    }
    for account in configuration.accounts {
        switch account.kind {
        case .codex:
            report(account) { (try fetchCodexUsage(account).usage, [], nil) }
        case .claude:
            report(account) {
                let reading = try fetchClaudeUsage(account)
                return (reading.usage, reading.models, claudeSubscriptionAnchor(account))
            }
        }
    }
    let total = configuration.accounts.count
    print(failed == 0 ? "PASS: \(total) account(s) fetched live; absent session quota remains unavailable."
                      : "FAIL: \(failed) of \(total) accounts could not be fetched.")
    return failed == 0
}

@main struct Launch {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--launch-at-login") {
            let command = CommandLine.arguments.dropFirst(index + 1).first ?? "status"
            let service = SMAppService.mainApp
            do {
                switch command {
                case "enable":
                    if service.status != .enabled { try service.register() }
                case "disable":
                    if service.status != .notRegistered { try service.unregister() }
                case "status": break
                default:
                    fputs("Usage: --launch-at-login enable|disable|status\n", stderr)
                    exit(2)
                }
                switch service.status {
                case .enabled: print("launch-at-login: enabled")
                case .requiresApproval: print("launch-at-login: requires-approval")
                case .notRegistered: print("launch-at-login: not-registered")
                case .notFound: print("launch-at-login: not-found")
                @unknown default: print("launch-at-login: unknown")
                }
                return
            } catch {
                fputs("Launch-at-login operation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            do {
                try runSelfTest()
                print("PASS: unavailable account is isolated; missing quota stays unknown; real zero remains zero; original timestamp preserves stale state; UI language choice, Russian plurals, en/ru captions.")
                print("PASS: Claude /usage parser handles escapes, glued words, missing minutes/Resets, year rollover; trust prompt and empty output are errors.")
                print("PASS: Codex windows classified by duration; model windows and payment anchors survive publishing; payment dates recur monthly.")
                print("PASS: accounts.json parsed (defaults, duplicate/bad ids, one codex, at most 4, bad paths, unparseable -> warning + detection); log roots derived; reset zones parsed for any IANA name; fetch failures map to fixed en/ru hints; login-shell misses expire after 5 min.")
                print("PASS: pace math, history sampling and pruning, price prefixes, compact numbers in English and Russian, Codex plan; usage days follow DST; log scanner dedupes, skips synthetic, joins chunk-split lines, resumes and rescans shrunk files.")
                print("PASS: pricing pages parsed by header names (<sup>, link in parentheses, two Haiku 5.5 tiers, later fast/batch tables ignored, 4-column OpenAI table); validation rejects; layers user > downloaded > built-in; prefix lookup; 1-hour cache write cost; 24 h refresh throttle.")
                return
            } catch let failure as SelfTestFailure {
                fputs("FAIL: self-test check \(failure.code).\n", stderr); exit(1)
            } catch {
                fputs("FAIL: self-test error: \(error)\n", stderr); exit(1)
            }
        }
        // CLI reports stay English whatever the UI language; the self-test above follows it on purpose.
        let reportFlags: Set = ["--prices", "--update-prices", "--analytics", "--accounts", "--check"]
        if CommandLine.arguments.contains(where: reportFlags.contains) { L10n.language = .en }
        if CommandLine.arguments.contains("--prices") {
            runPricesReport()
            return
        }
        if CommandLine.arguments.contains("--update-prices") {
            exit(runUpdatePrices() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--analytics") {
            runAnalyticsReport(useCache: !CommandLine.arguments.contains("--no-cache"))
            return
        }
        if CommandLine.arguments.contains("--accounts") {
            runAccountsReport()
            return
        }
        if CommandLine.arguments.contains("--check") {
            exit(runCheck() ? 0 : 1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
