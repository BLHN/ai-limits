import AppKit
import SwiftUI
import Observation
import WidgetKit
import ServiceManagement

// The host app fetches quotas itself by launching the user's installed `codex` and
// `claude` CLIs (see Fetchers.swift). From the Claude profile state files it reads only
// oauthAccount.subscriptionCreatedAt, emailAddress and planDisplayName, plus an optional
// user-edited billing.json. Login emails stay in memory for the UI. It never reads
// credentials, changes accounts, or makes network/model requests of its own.
// Analytics.swift reads token counters from the local CLI logs; History.swift keeps a
// local history of remaining percentages.

private let codexInterval: TimeInterval = 60

/// At most this many Codex app-server checks run at the same time; the rest wait for a slot.
let maxConcurrentCodexChecks = 2

/// The due Codex accounts to start now, in list order: as many as the free slots allow.
func codexChecksToStart(due: [String], running: Int, limit: Int = maxConcurrentCodexChecks) -> [String] {
    Array(due.prefix(max(0, limit - running)))
}

/// How long after its last check a Claude account is due again. Claude checks run one at a
/// time and take about 15 s each, so with many accounts the cadence stretches to leave the
/// sequence a short idle gap: 2 minutes for up to 6 accounts, 2.5 minutes for 8.
func claudeCheckInterval(accountCount: Int) -> TimeInterval {
    max(120, Double(accountCount) * 15 + 30)
}

/// "hideEmails" user default: login emails are shown masked everywhere in the UI.
let hideEmailsKey = "hideEmails"

/// Publishes are serialized so an older result never overwrites a newer file.
private let publishQueue = DispatchQueue(label: "ai-limits.publish")

/// Writes the sanitized snapshot for the widget. Returns true when the file content changed.
func publish(_ rows: [AccountRow]) throws -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let published = try encoder.encode(PublishedSnapshot(rows: rows))
    let destination = hostSnapshotURL
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

/// Short remaining summary for the menu bar tooltip; a known login email follows the name.
func remainingSummary(_ accounts: [AccountRow], hideEmails: Bool = false) -> String {
    let lines = accounts.map { account -> String in
        let parts = [account.usage?.primary.map { L("session", "сеанс") + " \(Int($0.remaining.rounded()))%" },
                     account.usage?.secondary.map { L("week", "неделя") + " \(Int($0.remaining.rounded()))%" }].compactMap { $0 }
        let login = account.email.map { " (" + (hideEmails ? maskedEmail($0) : $0) + ")" } ?? ""
        return "\(account.name)\(login): \(parts.isEmpty ? L("no data", "нет данных") : parts.joined(separator: ", "))"
    }
    return ([L("AI Limits — remaining", "AI Limits — остаток")] + lines).joined(separator: "\n")
}

@MainActor @Observable final class QuotaStore {
    private(set) var usages: [String: Usage] = [:]
    private(set) var models: [String: [ModelQuota]] = [:]
    /// Payment anchor, login email and plan per Claude account (email and plan in memory only).
    private var claudeProfiles: [String: ClaudeProfile] = [:]
    /// Login email and plan per Codex account from account/read (in memory only).
    private var codexAccounts: [String: CodexAccountInfo] = [:]
    private var billing: [String: String] = [:]
    /// Category of the last failure per account; cleared by the next success. No CLI text is kept.
    private(set) var lastErrors: [String: FetchFailure] = [:]
    /// The app's own description of the last failure (FetchError text, never CLI output).
    private(set) var lastErrorDetails: [String: String] = [:]
    /// Accounts with a fetch running right now (the onboarding shows "Checking...").
    private(set) var inFlight: Set<String> = []
    /// Accounts asked to check now that have not started yet.
    private(set) var queued: Set<String> = []
    /// Window lengths and plan from each Codex response. Host-only, never published.
    private(set) var codexMeta: [String: CodexMeta] = [:]
    /// Login emails are shown masked ("hideEmails" user default).
    var hideEmails = appDefaults.bool(forKey: hideEmailsKey) {
        didSet { appDefaults.set(hideEmails, forKey: hideEmailsKey) }
    }
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
    /// Observed: the onboarding cards say "in line" while another Claude check runs.
    private var claudeChainRunning = false
    /// Codex checks running right now (at most maxConcurrentCodexChecks).
    @ObservationIgnored private var codexRunning: Set<String> = []
    @ObservationIgnored private var billingDate: Date?
    @ObservationIgnored private var accountsDate: Date?
    @ObservationIgnored private var configurationLoading = false
    /// A reload was asked for while one was running: run one more after it, so a save is never lost.
    @ObservationIgnored private var configurationReloadPending = false
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
            let claude = slot.kind == .claude ? claudeProfiles[slot.id] : nil
            let codex = slot.kind == .codex ? codexAccounts[slot.id] : nil
            result[slot.id] = AccountExtras(models: models[slot.id] ?? [],
                                            billingAnchor: billing[slot.id] ?? claude?.anchor,
                                            weeklyWindow: slot.kind == .codex ? codexMeta[slot.id]?.weeklyWindow : weekWindow,
                                            failure: lastErrors[slot.id],
                                            email: claude?.email ?? codex?.email,
                                            plan: slot.kind == .claude ? claude?.plan
                                                : codexPlanLabel(codexMeta[slot.id], account: codex),
                                            dedicated: configuration?.accounts.first(where: { $0.id == slot.id })?.directory != nil)
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
        let published = PublishedSnapshot.loadPublished(from: hostSnapshotURL)
        seedSlots = published?.map { AccountSlot(id: $0.id, kind: $0.kind, name: $0.name) } ?? placeholderSlots
        for row in published ?? [] {
            if let usage = row.usage { usages[row.id] = usage }
            models[row.id] = row.models
            if row.kind == .claude, let anchor = row.billingAnchor { claudeProfiles[row.id] = ClaudeProfile(anchor: anchor) }
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
        queued.formUnion(slots.map(\.id))
        for slot in slots {
            if nextDue[slot.id] == .distantFuture { rerunRequested.insert(slot.id) } else { nextDue[slot.id] = .distantPast }
        }
        tick()
    }

    /// Requests an immediate fetch of these accounts only.
    func refresh(ids: Set<String>) {
        let known = Set(slots.map(\.id))
        for id in ids where known.contains(id) {
            queued.insert(id)
            if nextDue[id] == .distantFuture { rerunRequested.insert(id) } else { nextDue[id] = .distantPast }
        }
        tick()
    }

    /// Re-reads accounts.json now (after the onboarding saved it) instead of on the next tick.
    func reloadConfigurationNow() {
        accountsDate = accountsModificationDate()
        reloadConfiguration()
    }

    /// Re-reads accounts.json (or re-detects the CLIs) off the main thread.
    private func reloadConfiguration() {
        guard !configurationLoading else { configurationReloadPending = true; return }
        configurationLoading = true
        configurationReloadPending = false
        Task {
            let loaded = await Task.detached(priority: .utility) { loadAccountsConfiguration() }.value
            configurationLoading = false
            configurationLoadedAt = Date()
            // A newer request arrived while this load ran: its result may predate the file, so load again.
            if configurationReloadPending {
                reloadConfiguration()
                return
            }
            apply(loaded)
        }
    }

    private func apply(_ loaded: AccountsConfiguration) {
        let previous = configuration
        guard loaded != previous else { return }
        configuration = loaded
        queued.formIntersection(loaded.ids)
        // An account whose type or folder changed is another login: drop its old numbers.
        for account in loaded.accounts {
            if let old = previous?.accounts.first(where: { $0.id == account.id }),
               old.kind != account.kind || old.directory != account.directory {
                usages[account.id] = nil
                models[account.id] = nil
                claudeProfiles[account.id] = nil
                codexAccounts[account.id] = nil
                codexMeta[account.id] = nil
                lastErrors[account.id] = nil
                lastErrorDetails[account.id] = nil
                if nextDue[account.id] == .distantFuture { rerunRequested.insert(account.id) } else { nextDue[account.id] = .distantPast }
            }
        }
        let claude = loaded.claudeAccounts
        Task {
            let profiles = await Task.detached(priority: .utility) { () -> [String: ClaudeProfile?] in
                var profiles: [String: ClaudeProfile?] = [:]
                for account in claude { profiles[account.id] = claudeProfile(account) }
                return profiles
            }.value
            // Only accounts that still have the same folder; an unreadable file keeps the last profile.
            for account in claude where isCurrent(account) {
                if let profile = profiles[account.id] {
                    claudeProfiles[account.id] = mergedClaudeProfile(previous: claudeProfiles[account.id], read: profile)
                }
            }
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
        startDueCodex()
        if !claudeChainRunning {
            let due = configuration.claudeAccounts.filter { (nextDue[$0.id] ?? .distantPast) <= now }
            if !due.isEmpty { runClaude(due) }
        }
        onTick?()
    }

    /// The account is still configured with the same id, type and folder. A result fetched for a
    /// folder that was removed or replaced meanwhile (ids are reused) belongs to another login.
    private func isCurrent(_ account: AccountConfig) -> Bool {
        configuration?.accounts.contains { $0.sameFolder(as: account) } ?? false
    }

    private func finish(_ id: String, interval: TimeInterval) {
        nextDue[id] = rerunRequested.remove(id) != nil ? .distantPast : Date().addingTimeInterval(interval)
    }

    /// Starts due Codex accounts in list order while a slot is free; the others stay due and
    /// start as running checks finish. nextDue = .distantFuture guards one in flight per account.
    private func startDueCodex() {
        guard let configuration else { return }
        let now = Date()
        let due = configuration.codexAccounts.filter { (nextDue[$0.id] ?? .distantPast) <= now && !codexRunning.contains($0.id) }
        let start = Set(codexChecksToStart(due: due.map(\.id), running: codexRunning.count))
        for codex in due where start.contains(codex.id) { runCodex(codex) }
    }

    private func runCodex(_ account: AccountConfig) {
        let id = account.id
        nextDue[id] = .distantFuture
        codexRunning.insert(id)
        inFlight.insert(id)
        queued.remove(id)
        Task {
            let result = await Task.detached(priority: .utility) { Result { try fetchCodexUsage(account) } }.value
            codexRunning.remove(id)
            // A slot is free: the next waiting account starts once this result is applied.
            defer { startDueCodex() }
            guard isCurrent(account) else {
                inFlight.remove(id)
                finish(id, interval: 0)
                return
            }
            switch result {
            case .success(let reading):
                usages[id] = reading.usage
                codexMeta[id] = reading.meta
                // A failed account/read keeps the last known login rather than blanking it.
                if let account = reading.account { codexAccounts[id] = account }
                lastErrors[id] = nil
                lastErrorDetails[id] = nil
                history.record(id: id, usage: reading.usage, models: [])
                publishCurrent()
            case .failure(let error):
                // Keep the previous measurement and its original timestamp.
                lastErrors[id] = fetchFailure(of: error)
                lastErrorDetails[id] = (error as? FetchError)?.description
            }
            inFlight.remove(id)
            finish(id, interval: codexInterval)
        }
    }

    /// Claude accounts run one after another, never in parallel. Only one chain runs at a time
    /// (claudeChainRunning); accounts that fall due meanwhile wait for the next chain, so every
    /// account is checked once per cycle in the configured order and none is starved.
    private func runClaude(_ accounts: [AccountConfig]) {
        claudeChainRunning = true
        let interval = claudeCheckInterval(accountCount: configuration?.claudeAccounts.count ?? accounts.count)
        Task {
            for account in accounts {
                // The account may have been removed while earlier ones ran.
                guard isCurrent(account) else { continue }
                nextDue[account.id] = .distantFuture
                inFlight.insert(account.id)
                queued.remove(account.id)
                let (result, profile) = await Task.detached(priority: .utility) {
                    (Result { try fetchClaudeUsage(account) }, claudeProfile(account))
                }.value
                // The folder was removed or replaced while the check ran: drop the stale result.
                guard isCurrent(account) else {
                    inFlight.remove(account.id)
                    finish(account.id, interval: 0)
                    continue
                }
                claudeProfiles[account.id] = mergedClaudeProfile(previous: claudeProfiles[account.id], read: profile)
                switch result {
                case .success(let reading):
                    usages[account.id] = reading.usage
                    models[account.id] = reading.models
                    lastErrors[account.id] = nil
                    lastErrorDetails[account.id] = nil
                    history.record(id: account.id, usage: reading.usage, models: reading.models)
                    publishCurrent()
                case .failure(let error):
                    lastErrors[account.id] = fetchFailure(of: error)
                    lastErrorDetails[account.id] = (error as? FetchError)?.description
                }
                inFlight.remove(account.id)
                finish(account.id, interval: interval)
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

/// Live status of one onboarding card from the real checks (Onboarding.swift).
extension QuotaStore {
    func checkState(_ draft: AccountDraft) -> AccountCheckState {
        guard let configuration, configuration.accounts.contains(where: draft.sameLogin) else {
            return AccountCheckState(saved: false)
        }
        let id = draft.id
        let failure = lastErrors[id]
        let usage = usages[id]
        // No result of any kind yet: the first check is due now.
        let checking = inFlight.contains(id) || queued.contains(id) || (failure == nil && usage == nil)
        // Claude checks run one at a time: a card not yet started waits for the running chain.
        // Codex checks run at most two at a time: a card not yet started waits for a free slot.
        let waiting = checking && !inFlight.contains(id)
            && (draft.kind == .claude ? claudeChainRunning : codexRunning.count >= maxConcurrentCodexChecks)
        let row = accounts.first { $0.id == id }
        return AccountCheckState(saved: true, checking: checking, waiting: waiting, failure: failure,
                                 detail: failure == nil ? nil : lastErrorDetails[id], summary: usage.map(connectedSummary),
                                 email: row?.email, plan: row?.plan)
    }
}

/// Tallest the popover or the floating panel may get: the visible height of the screen it is
/// on, minus a margin. Each has its own instance, refreshed when it opens or changes screen.
@MainActor @Observable final class ScreenLimits {
    var maxHeight: CGFloat = ScreenLimits.height(of: NSScreen.main)
    /// The screen this limit follows (the popover's menu bar, the panel's window).
    @ObservationIgnored var screen: () -> NSScreen? = { NSScreen.main }
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let height = ScreenLimits.height(of: screen() ?? NSScreen.main)
        if height != maxHeight { maxHeight = height }
    }

    static func height(of screen: NSScreen?) -> CGFloat {
        cappedHeight(visibleHeight: screen?.visibleFrame.height)
    }
}

/// Visible screen height minus a 60 pt margin, never below 320 pt (800 pt when unknown).
func cappedHeight(visibleHeight: CGFloat?) -> CGFloat {
    max(320, (visibleHeight ?? 800) - 60)
}

struct Dashboard: View {
    let store: QuotaStore
    let screen: ScreenLimits
    var onSetUp: (() -> Void)? = nil
    var onFix: ((String) -> Void)? = nil
    var body: some View {
        ScrollingPanel(maxHeight: screen.maxHeight - 28) {  // 28: the panel's title bar
            LimitsSummary(accounts: store.accounts, now: store.now,
                size: .panel, sourceError: store.allFetchersFailing, notice: store.configurationWarning,
                onSetUp: onSetUp, onFix: onFix, hideEmails: store.hideEmails)
                .padding(18)
        }
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
    let screen: ScreenLimits
    let onHeight: (CGFloat) -> Void
    var onSetUp: (() -> Void)? = nil
    var onFix: ((String) -> Void)? = nil
    var body: some View {
        GeometryReader { _ in content }
            .background(Palette.background)
    }
    private var content: some View {
        PopoverContent(accounts: store.accounts, now: store.now, sourceError: store.allFetchersFailing,
                       notice: store.configurationWarning,
                       usage: usage.days, prices: usage.priceBook.prices, pricesAsOf: usage.priceBook.asOf,
                       firstScanRunning: usage.scanning && usage.lastScan == nil, lastScan: usage.lastScan,
                       history: store.history.recent, codexPlan: nil, hideEmails: store.hideEmails,
                       maxHeight: screen.maxHeight, onHeight: onHeight,
                       onSetUp: onSetUp, onFix: onFix)
    }
}

/// "Plus" or "Plus · 120 credits" ("Plus · кредиты 120"); nil when the responses carried neither.
/// The plan from account/read wins over the one in the rate-limit response.
func codexPlanLabel(_ meta: CodexMeta?, account: CodexAccountInfo? = nil) -> String? {
    var parts: [String] = []
    if let plan = account?.plan ?? meta?.plan { parts.append(plan) }
    if let credits = meta?.credits {
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
    private let hideEmailsItem = NSMenuItem(title: L("Hide Emails", "Скрыть почты"),
                                            action: #selector(toggleHideEmails), keyEquivalent: "")
    /// Height caps: the popover follows the menu bar it opens from, the panel its own window.
    let popoverScreen = ScreenLimits()
    let panelScreen = ScreenLimits()
    private let popover = NSPopover()
    private lazy var onboarding = OnboardingWindowController { [unowned self] in self.onboardingServices() }
    private let popoverWidth: CGFloat = 380
    /// When the transient popover closed; a click on the icon right after it must not reopen it.
    private var popoverClosedAt = Date.distantPast

    private var panelPreferred: Bool {
        get { appDefaults.object(forKey: floatingPanelKey) as? Bool ?? true }
        set { appDefaults.set(newValue, forKey: floatingPanelKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: Dashboard(store: store, screen: panelScreen,
            onSetUp: { [weak self] in self?.openOnboarding() },
            onFix: { [weak self] id in self?.openOnboarding(focus: id) }))
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
        window.setFrameAutosaveName(panelFrameName)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(panelFrameName), let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: bounds.maxX - size.width - 22, y: bounds.maxY - size.height - 22))
        }
        window.setContentSize(size)
        panel = window
        panelScreen.screen = { [weak window] in window?.screen }
        panelScreen.refresh()
        if panelPreferred { window.orderFrontRegardless() }
        let menu = NSMenu()
        let root = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L("Quit AI Limits", "Закрыть AI Limits"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = applicationMenu
        menu.addItem(root)
        // Text fields in the setup window need the standard editing shortcuts.
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit", "Правка"))
        editMenu.addItem(withTitle: L("Undo", "Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo", "Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut", "Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy", "Скопировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste", "Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All", "Выбрать все"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editRoot.submenu = editMenu
        menu.addItem(editRoot)
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
        if CommandLine.arguments.contains("--onboarding") || shouldOfferOnboarding() {
            openOnboarding()
        }
    }

    // MARK: Onboarding

    @objc private func openAccounts() { openOnboarding(step: .accounts) }

    /// The setup window; from a failing account it opens on that account's card.
    func openOnboarding(step: OnboardingStep? = nil, focus id: String? = nil) {
        if popover.isShown { popover.performClose(nil) }
        onboarding.show(step: step, focus: id)
    }

    private func onboardingServices() -> OnboardingServices {
        OnboardingServices(
            configuration: { [unowned self] in store.configuration },
            state: { [unowned self] draft in store.checkState(draft) },
            recheck: { [unowned self] ids in store.refresh(ids: ids) },
            saved: { [unowned self] in store.reloadConfigurationNow() },
            launchAtLogin: {
                switch SMAppService.mainApp.status {
                case .enabled: return .on
                case .requiresApproval: return .needsApproval
                default: return .off
                }
            },
            setLaunchAtLogin: { [unowned self] on in setLaunchAtLogin(on) },
            panelVisible: { [unowned self] in panel?.isVisible == true },
            setPanelVisible: { [unowned self] on in
                guard let panel else { return }
                if on { showPanel() } else { panel.orderOut(nil) }
                panelPreferred = on
            },
            hideEmails: { [unowned self] in store.hideEmails },
            setHideEmails: { [unowned self] on in store.hideEmails = on; updateTooltip() },
            close: { [unowned self] in onboarding.close() })
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
        let accounts = NSMenuItem(title: L("Accounts…", "Аккаунты…"), action: #selector(openAccounts), keyEquivalent: "")
        accounts.target = self
        let updatePrices = NSMenuItem(title: L("Update Prices", "Обновить цены"), action: #selector(refreshPrices), keyEquivalent: "")
        updatePrices.target = self
        launchAtLoginItem.target = self
        floatingPanelItem.target = self
        hideEmailsItem.target = self
        let quit = NSMenuItem(title: L("Quit AI Limits", "Закрыть AI Limits"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        launchAtLoginItem.isHidden = appDataOverridden()
        statusMenu.items = [refresh, accounts, updatePrices, floatingPanelItem, hideEmailsItem, launchAtLoginItem, .separator(), quit]
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
        let root = PopoverRoot(store: store, usage: usage, screen: popoverScreen, onHeight: { [weak self] height in
            // Resizing from inside a SwiftUI layout pass is not allowed; the next turn is soon enough.
            DispatchQueue.main.async { self?.setPopoverHeight(height) }
        }, onSetUp: { [weak self] in self?.openOnboarding() },
           onFix: { [weak self] id in self?.openOnboarding(focus: id) })
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
        // Cap the height by the screen whose menu bar was clicked, not the main one.
        popoverScreen.screen = { [weak button] in button?.window?.screen }
        popoverScreen.refresh()
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

    @objc private func toggleHideEmails() {
        store.hideEmails.toggle()
        updateTooltip()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        floatingPanelItem.state = panel?.isVisible == true ? .on : .off
        hideEmailsItem.state = store.hideEmails ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled: launchAtLoginItem.state = .on
        case .requiresApproval: launchAtLoginItem.state = .mixed
        default: launchAtLoginItem.state = .off
        }
    }

    @objc private func refreshNow() { store.refreshNow() }
    @objc private func refreshPrices() { priceUpdater.refreshNow() }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    /// Registers or removes the login item; a pending approval opens System Settings instead.
    private func setLaunchAtLogin(_ on: Bool) {
        // A test run with AI_LIMITS_DATA_DIR never registers or removes the real login item.
        guard !appDataOverridden() else { return }
        let service = SMAppService.mainApp
        do {
            switch (service.status, on) {
            case (.requiresApproval, true): SMAppService.openSystemSettingsLoginItems()
            case (.enabled, false), (.requiresApproval, false): try service.unregister()
            case (.enabled, true): break
            case (_, true): try service.register()
            default: break
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change Launch at Login", "Не удалось изменить автозапуск")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateTooltip() {
        statusItem?.button?.toolTip = remainingSummary(store.accounts, hideEmails: store.hideEmails)
    }

    /// The panel was dragged to another display: cap it by that display's height.
    func windowDidChangeScreen(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { panelScreen.refresh() }
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
    // Login emails and plans reach the rows (host UI) but never the published file.
    let enriched = rows(for: legacySlots, usages: ["codex": codexWeekly, "claude-1": reading.usage],
                        extras: ["claude-1": AccountExtras(models: reading.models, billingAnchor: "2026-10-28T20:00:00.000000Z",
                                                           email: "someone@example.com", plan: "Claude Max"),
                                 "codex": AccountExtras(billingAnchor: "2026-08-13", email: "other@example.org", plan: "Pro")])
    try expect(enriched[1].email == "someone@example.com" && enriched[0].plan == "Pro" && enriched[2].email == nil, 68)
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
    try expect(!text.contains("@") && !text.contains("label") && !text.contains("limitId")
               && !text.contains("example") && !text.contains("Claude Max") && !text.contains("\"Pro\""), 63)
    let legacy = #"{"accounts":[{"id":"codex","name":"Codex","usage":null},{"id":"claude-1","name":"Claude 1","usage":null},{"id":"claude-2","name":"Claude 2","usage":null}]}"#
    let legacyRows = try JSONDecoder().decode(PublishedSnapshot.self, from: Data(legacy.utf8)).displayRows
    try expect(legacyRows.allSatisfy { $0.models.isEmpty && $0.billingAnchor == nil }
               && legacyRows.map(\.kind) == [.codex, .claude, .claude], 64)
    // Any 0-8 accounts with valid unique ids are a usable snapshot (older 4-account files too);
    // anything else falls back.
    func snapshot(_ ids: [String]) -> PublishedSnapshot {
        PublishedSnapshot(rows: rows(for: ids.map { AccountSlot(id: $0, kind: .claude, name: $0) }, usages: nil))
    }
    try expect(snapshot([]).isValid && snapshot(["work"]).isValid && snapshot(["a", "b", "c", "d"]).isValid
               && snapshot((1...8).map { "c\($0)" }).isValid
               && !snapshot((1...9).map { "c\($0)" }).isValid && !snapshot(["a", "a"]).isValid
               && !snapshot(["someone@example.com"]).isValid, 66)
    try expect(withLanguage(.ru) { remainingSummary(enriched) }.contains("Claude 1 (someone@example.com): сеанс 100%, неделя 1%")
               && withLanguage(.ru) { remainingSummary(enriched) }.contains("Claude 2: нет данных"), 65)
    try expect(withLanguage(.en) { remainingSummary(enriched) }.contains("Claude 1 (someone@example.com): session 100%, week 1%")
               && withLanguage(.en) { remainingSummary(enriched) }.contains("Claude 2: no data")
               && withLanguage(.en) { remainingSummary(enriched, hideEmails: true) }.contains("Claude 1 (s•••@example.com): session")
               && !withLanguage(.en) { remainingSummary(enriched, hideEmails: true) }.contains("someone"), 67)

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
    try withLanguage(.en) { try runIdentitySelfTest() }
    try runOnboardingSelfTest()
    try runAnalyticsSelfTest()
}

/// Login emails and plans (account/read, the Claude profile), masking, same-login detection,
/// eight accounts with several Codex homes, widget layouts, the data folder, the Claude cadence.
private func runIdentitySelfTest() throws {
    // Codex account/read: shape verified on codex-cli 0.164.
    let chatgpt = #"{"id":3,"result":{"account":{"type":"chatgpt","email":"Dev.Person@Example.com","planType":"pro"},"requiresOpenaiAuth":true,"extra":"x"}}"#
    try expect(codexAccount(fromResponse: Data(chatgpt.utf8)) == CodexAccountInfo(email: "Dev.Person@Example.com", plan: "Pro"), 400)
    for none in [#"{"id":3,"result":{"account":null,"requiresOpenaiAuth":true}}"#, #"{"id":3,"result":{}}"#,
                 #"{"id":3,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":false}}"#,
                 #"{"id":3,"error":{"code":-32601,"message":"unknown method"}}"#, "garbage",
                 #"{"id":3,"result":{"account":{"type":"chatgpt","email":"not an email","planType":"unknown"}}}"#] {
        try expect(codexAccount(fromResponse: Data(none.utf8)) == nil, 401)
    }
    try expect(codexAccount(fromResponse: Data(#"{"id":3,"result":{"account":{"type":"chatgpt","planType":"plus"}}}"#.utf8))
               == CodexAccountInfo(email: nil, plan: "Plus"), 402)
    try expect(["pro", "plus", "team", "business", "enterprise", "edu", "PRO", "free_workspace", "go"].map { codexPlanName($0) }
               == ["Pro", "Plus", "Team", "Business", "Enterprise", "Edu", "Pro", "Free Workspace", "Go"]
               && codexPlanName("unknown") == nil && codexPlanName("two words") == nil && codexPlanName("") == nil, 403)
    try expect(codexPlanLabel(CodexMeta(plan: "Plus"), account: CodexAccountInfo(email: nil, plan: "Pro")) == "Pro"
               && codexPlanLabel(CodexMeta(plan: "Plus"), account: nil) == "Plus"
               && codexPlanLabel(nil, account: CodexAccountInfo(email: "a@b.c", plan: nil)) == nil
               && codexPlanLabel(nil, account: CodexAccountInfo(email: nil, plan: "Team")) == "Team", 404)
    // Claude profile: only subscriptionCreatedAt, emailAddress and planDisplayName are taken.
    let profile = claudeProfile(fromStateData: Data(#"{"oauthAccount":{"emailAddress":"alex@example.com","planDisplayName":"Claude Max","subscriptionCreatedAt":"2026-10-28T20:00:00Z","accountUuid":"secret","organizationName":"Org"},"projects":{}}"#.utf8))
    try expect(profile == ClaudeProfile(anchor: "2026-10-28T20:00:00Z", email: "alex@example.com", plan: "Claude Max"), 405)
    try expect(claudeProfile(fromStateData: Data(#"{"oauthAccount":{"emailAddress":"line\nbreak@x.io","planDisplayName":"\#(String(repeating: "x", count: 50))","subscriptionCreatedAt":"bad"}}"#.utf8)) == ClaudeProfile()
               && claudeProfile(fromStateData: Data("{}".utf8)) == ClaudeProfile()
               && claudeProfile(fromStateData: Data("nope".utf8)) == nil
               && claudeProfile(fromStateData: Data(#"{"oauthAccou"#.utf8)) == nil, 406)
    // An unreadable state file keeps the last profile; a parsed signed-out one clears it.
    let known = ClaudeProfile(anchor: "2026-10-28T20:00:00Z", email: "alex@example.com", plan: "Claude Max")
    try expect(mergedClaudeProfile(previous: known, read: nil) == known
               && mergedClaudeProfile(previous: known, read: ClaudeProfile()) == ClaudeProfile()
               && mergedClaudeProfile(previous: nil, read: nil) == nil, 420)
    // Masking and the "plan · email" line.
    try expect(maskedEmail("alex@example.com") == "a•••@example.com" && maskedEmail("x@y.z") == "x•••@y.z"
               && maskedEmail("plain") == "p•••" && maskedEmail("@odd") == "@•••" && maskedEmail("") == "", 407)
    try expect(identityLine(plan: "Max", email: "alex@example.com", hideEmails: false) == "Max · alex@example.com"
               && identityLine(plan: "Max", email: "alex@example.com", hideEmails: true) == "Max · a•••@example.com"
               && identityLine(plan: nil, email: "a@b.co", hideEmails: false) == "a@b.co"
               && identityLine(plan: "Pro", email: nil, hideEmails: true) == "Pro"
               && identityLine(plan: nil, email: nil, hideEmails: false) == nil, 408)
    try expect(sanitizedEmail("  a@b.co ") == "a@b.co" && sanitizedEmail("a@") == nil && sanitizedEmail("@b") == nil
               && sanitizedEmail("a b@c.d") == nil && sanitizedEmail(42) == nil, 409)
    // Same login: same type and email (any case); another type with the same email is fine.
    // All dedicated folders: the first keeps the login, the later ones are asked to sign in again.
    let logins: [(id: String, kind: AccountKind, email: String?, dedicated: Bool)] = [
        ("claude-1", .claude, "Alex@Example.com", true), ("codex", .codex, "alex@example.com", true),
        ("claude-2", .claude, "alex@example.COM", true), ("claude-3", .claude, nil, true),
        ("claude-4", .claude, "sam@example.org", true), ("codex-2", .codex, "alex@example.com", true),
        ("claude-5", .claude, "alex@example.com", true)]
    try expect(sameLoginPairs(logins) == [SameLoginPair(earlier: "claude-1", later: "claude-2"),
                                          SameLoginPair(earlier: "codex", later: "codex-2"),
                                          SameLoginPair(earlier: "claude-1", later: "claude-5")]
               && sameLoginPairs([(id: "a", kind: .claude, email: nil, dedicated: true),
                                  (id: "b", kind: .claude, email: nil, dedicated: false)]).isEmpty, 410)
    // The default login (no dedicated folder) is never the one asked to sign in again, even listed later.
    try expect(sameLoginPairs([(id: "claude-1", kind: .claude, email: "alex@example.com", dedicated: true),
                               (id: "claude-2", kind: .claude, email: "Alex@example.com", dedicated: false),
                               (id: "claude-3", kind: .claude, email: "alex@example.com", dedicated: true),
                               (id: "codex-2", kind: .codex, email: "team@example.net", dedicated: true),
                               (id: "codex", kind: .codex, email: "team@example.net", dedicated: false)])
               == [SameLoginPair(earlier: "claude-2", later: "claude-1"),
                   SameLoginPair(earlier: "claude-2", later: "claude-3"),
                   SameLoginPair(earlier: "codex", later: "codex-2")]
               && sameLoginPairs([(id: "claude-1", kind: .claude, email: "alex@example.com", dedicated: false),
                                  (id: "claude-2", kind: .claude, email: "alex@example.com", dedicated: true)])
               == [SameLoginPair(earlier: "claude-1", later: "claude-2")], 428)
    // The panel skips a pair whose later account is failing (its card shows the failure instead).
    let sameRows = [AccountRow(id: "claude-1", name: "Claude 1", kind: .claude, usage: nil, email: "alex@example.com", dedicated: true),
                    AccountRow(id: "claude-2", name: "Claude 2", kind: .claude, usage: nil, failure: .failed, email: "alex@example.com", dedicated: true),
                    AccountRow(id: "claude-3", name: "Claude 3", kind: .claude, usage: nil, email: "ALEX@example.com", dedicated: true)]
    try expect(sameLoginPairs(sameRows) == [SameLoginPair(earlier: "claude-1", later: "claude-3")], 427)
    // A default-login row listed after a dedicated one keeps the login; the dedicated row gets the warning.
    let defaultLater = [AccountRow(id: "claude-2", name: "Claude 2", kind: .claude, usage: nil, email: "alex@example.com", dedicated: true),
                        AccountRow(id: "claude-1", name: "Claude 1", kind: .claude, usage: nil, email: "alex@example.com")]
    try expect(sameLoginPairs(defaultLater) == [SameLoginPair(earlier: "claude-1", later: "claude-2")]
               && rows(for: [AccountSlot(id: "claude-2", kind: .claude, name: "Claude 2")], usages: nil,
                       extras: ["claude-2": AccountExtras(email: "alex@example.com", dedicated: true)])[0].dedicated, 429)
    try expect(sameLoginTitle("Claude 1", "Claude 2") == "Claude 1 and Claude 2 are the same login"
               && withLanguage(.ru) { sameLoginTitle("Claude 1", "Claude 2") } == "Claude 1 и Claude 2 — один и тот же вход"
               && sameLoginHint("Claude 2", kind: .claude).contains("/login")
               && withLanguage(.ru) { sameLoginHint("Codex 2", kind: .codex) }.contains("codex login"), 411)

    // Eight accounts, two Codex logins with different homes; a second default-home Codex is refused.
    let home = URL(fileURLWithPath: "/Users/tester")
    func resolve(_ text: String) -> AccountsConfiguration {
        resolveAccounts(fileData: Data(text.utf8), home: home, isExecutable: { _ in false }) { _, _ in nil }
    }
    let eight = resolve(#"""
    {"accounts":[{"id":"codex","type":"codex"},{"id":"codex-2","type":"codex","home":"~/.codex-work"},
                 \#((1...6).map { #"{"id":"claude-\#($0)","type":"claude","configDir":"~/.claude-\#($0)"}"# }.joined(separator: ",")),
                 {"id":"codex-3","type":"codex"},{"id":"codex-4","type":"codex","home":"~/.codex-work/"},
                 {"id":"codex-5","type":"codex","home":"~/.codex"}]}
    """#)
    try expect(eight.ids == ["codex", "codex-2"] + (1...6).map { "claude-\($0)" }
               && eight.codexAccounts.map(\.directory) == [nil, "/Users/tester/.codex-work"]
               && eight.accounts.map(\.name).prefix(3) == ["Codex 1", "Codex 2", "Claude 1"]
               && eight.warning?.contains("entry 9: only one codex account can use the default home") == true
               && eight.warning?.contains("and 1 more") == true, 412)
    let homes = resolve(#"{"accounts":[{"id":"cx","type":"codex","home":"~/.codex-a"},{"id":"cy","type":"codex","home":"~/.codex-a"},{"id":"cz","type":"codex","home":"~/.codex"},{"id":"cw","type":"codex"}]}"#)
    try expect(homes.ids == ["cx", "cz"] && homes.warning?.contains("another codex account already uses this home") == true
               && homes.warning?.contains("default home") == true, 413)
    try expect(nextCodexID(existing: []) == "codex" && nextCodexID(existing: ["codex"]) == "codex-2"
               && nextCodexID(existing: ["codex", "codex-2", "codex-4"]) == "codex-3"
               && nextAccountID(kind: .claude, existing: ["claude-1"]) == "claude-2", 414)
    try expect(suggestedLoginFolder(kind: .codex, name: "Work", home: home, taken: [], exists: { _ in false }) == "~/.codex-work"
               && suggestedLoginFolder(kind: .codex, name: "", home: home, taken: ["/Users/tester/.codex-account"], exists: { _ in false }) == "~/.codex-account-2"
               && suggestedName(forFolder: "/Users/tester/.codex-work", kind: .codex) == "Codex Work"
               && suggestedName(forFolder: "/Users/tester/.codex2", kind: .codex) == "Codex 2", 415)

    // Widget layouts: blocks up to 4 accounts, a list above; medium columns up to 4, a 2-column grid above.
    try expect((0...4).allSatisfy { !largeWidgetUsesList(accountCount: $0) } && (5...8).allSatisfy { largeWidgetUsesList(accountCount: $0) }
               && (0...4).allSatisfy { !mediumWidgetUsesGrid(accountCount: $0) } && (5...8).allSatisfy { mediumWidgetUsesGrid(accountCount: $0) }, 416)

    // Data folder: AI_LIMITS_DATA_DIR (absolute or ~/) wins; empty means unset; anything else refuses to start.
    try expect(appDataDirectory(environment: [:], home: home)?.path == "/Users/tester/Library/Application Support/AILimits"
               && appDataDirectory(environment: ["AI_LIMITS_DATA_DIR": "/tmp/ai-limits-test"], home: home)?.path == "/tmp/ai-limits-test"
               && appDataDirectory(environment: ["AI_LIMITS_DATA_DIR": "~/test-data"], home: home)?.path == "/Users/tester/test-data"
               && appDataDirectory(environment: ["AI_LIMITS_DATA_DIR": "relative"], home: home) == nil
               && appDataDirectory(environment: ["AI_LIMITS_DATA_DIR": "tmp/ail"], home: home) == nil
               && appDataDirectory(environment: ["AI_LIMITS_DATA_DIR": ""], home: home)?.path.hasSuffix("Application Support/AILimits") == true, 417)
    // A test run gets its own preferences domain, stable per folder and different between folders.
    try expect(appDataOverridden(environment: ["AI_LIMITS_DATA_DIR": "/tmp/a"]) && !appDataOverridden(environment: [:])
               && !appDataOverridden(environment: ["AI_LIMITS_DATA_DIR": ""])
               && preferencesSuiteName(forDataFolder: URL(fileURLWithPath: "/tmp/a"))
                    == preferencesSuiteName(forDataFolder: URL(fileURLWithPath: "/tmp/a/"))
               && preferencesSuiteName(forDataFolder: URL(fileURLWithPath: "/tmp/a"))
                    != preferencesSuiteName(forDataFolder: URL(fileURLWithPath: "/tmp/b"))
               && preferencesSuiteName(forDataFolder: URL(fileURLWithPath: "/tmp/a")).hasPrefix("local.ai-limits.test-"), 421)
    // The running self-test resolves every file of the app inside that folder.
    for url in [accountsURL, billingURL, historyURL, pricesURL, onboardingScriptsFolder, hostSnapshotURL] {
        try expect(url.path.hasPrefix(appDataFolder.path + "/"), 418)
    }
    // A result is kept only while its id, type and folder still match (a renamed card keeps it; a reused id does not).
    let oldLogin = AccountConfig(id: "claude-2", kind: .claude, name: "Claude 2", directory: "/Users/tester/.claude-a")
    try expect(oldLogin.sameFolder(as: AccountConfig(id: "claude-2", kind: .claude, name: "Renamed", directory: "/Users/tester/.claude-a"))
               && !oldLogin.sameFolder(as: AccountConfig(id: "claude-2", kind: .claude, name: "Claude 2", directory: "/Users/tester/.claude-b"))
               && !oldLogin.sameFolder(as: AccountConfig(id: "claude-2", kind: .codex, name: "Claude 2", directory: "/Users/tester/.claude-a"))
               && !oldLogin.sameFolder(as: AccountConfig(id: "claude-3", kind: .claude, name: "Claude 2", directory: "/Users/tester/.claude-a")), 422)
    // A /usage read without limits is "not signed in" only after a timely repaint; else a plain failure.
    try expect(claudeMissingUsageReason(repaintBytes: 4_000, readSeconds: 5.2) == .notLoggedIn
               && claudeMissingUsageReason(repaintBytes: 0, readSeconds: 5) == .failed
               && claudeMissingUsageReason(repaintBytes: 4_000, readSeconds: 600) == .failed, 425)
    // Height cap per screen: a 900 pt laptop screen caps at 840 pt, a 1440 pt display at 1380 pt.
    try expect(cappedHeight(visibleHeight: 900) == 840 && cappedHeight(visibleHeight: 1440) == 1380
               && cappedHeight(visibleHeight: 300) == 320 && cappedHeight(visibleHeight: nil) == 740, 426)
    // Claude cadence: 2 minutes up to 6 accounts, stretched so 8 sequential ~15 s checks leave a gap.
    try expect(claudeCheckInterval(accountCount: 1) == 120 && claudeCheckInterval(accountCount: 6) == 120
               && claudeCheckInterval(accountCount: 7) == 135 && claudeCheckInterval(accountCount: 8) == 150
               && claudeCheckInterval(accountCount: 8) > 8 * 15, 419)
    // Codex checks: at most two at a time; the rest wait in list order for a free slot.
    try expect(codexChecksToStart(due: ["codex", "codex-2", "codex-3", "codex-4"], running: 0) == ["codex", "codex-2"]
               && codexChecksToStart(due: ["codex-3", "codex-4"], running: 1) == ["codex-3"]
               && codexChecksToStart(due: ["codex-3"], running: 2).isEmpty
               && codexChecksToStart(due: ["codex-3"], running: 3).isEmpty
               && codexChecksToStart(due: [], running: 0).isEmpty && maxConcurrentCodexChecks == 2, 430)
}

/// accounts.json writer, login discovery, Terminal scripts and names, on a temporary fake home.
/// The real Application Support folder and home folder are never touched.
private func runOnboardingSelfTest() throws {
    let manager = FileManager.default
    let temp = manager.temporaryDirectory.appendingPathComponent("ai-limits-selftest-\(UUID().uuidString)")
    try manager.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temp) }
    let home = temp.appendingPathComponent("home")

    // Writer: keeps "cli" and unknown keys (top level and per entry), ids, "~/" folders, 0600 / 0700.
    let existing = #"{"accounts":[{"id":"cx","type":"codex","note":"keep"},{"id":"claude-1","type":"claude","name":"Old","color":"red"},{"id":"gone","type":"claude"}],"cli":{"claude":"/opt/tools/claude"},"future":{"a":1}}"#
    let drafts = [AccountDraft(id: "cx", kind: .codex, name: "Codex", directory: nil),
                  AccountDraft(id: "claude-1", kind: .claude, name: "  Personal ", directory: nil),
                  AccountDraft(id: "claude-2", kind: .claude, name: "Work", directory: home.appendingPathComponent(".claude-work").path),
                  AccountDraft(id: "claude-3", kind: .claude, name: "", directory: "/Volumes/x/claude")]
    let written = try accountsFileData(drafts: drafts, existing: Data(existing.utf8), home: home)
    let object = try JSONSerialization.jsonObject(with: written) as? [String: Any] ?? [:]
    let entries = object["accounts"] as? [[String: Any]] ?? []
    try expect((object["cli"] as? [String: String]) == ["claude": "/opt/tools/claude"]
               && (object["future"] as? [String: Int]) == ["a": 1]
               && entries.map { $0["id"] as? String } == ["cx", "claude-1", "claude-2", "claude-3"]
               && entries[0]["note"] as? String == "keep" && entries[1]["color"] as? String == "red"
               && entries[1]["name"] as? String == "Personal" && entries[2]["configDir"] as? String == "~/.claude-work"
               && entries[3]["name"] == nil && entries[3]["configDir"] as? String == "/Volumes/x/claude"
               && entries[0]["home"] == nil && entries[0]["configDir"] == nil, 350)
    let reread = resolveAccounts(fileData: written, home: home, isExecutable: { $0 == "/opt/tools/claude" }) { _, _ in nil }
    try expect(reread.fromFile && reread.warning == nil && reread.ids == ["cx", "claude-1", "claude-2", "claude-3"]
               && reread.accounts.map(\.name) == ["Codex", "Personal", "Work", "Claude 3"]
               && reread.accounts.map(AccountDraft.init).enumerated().allSatisfy { index, draft in
                   draft.id == drafts[index].id && draft.directory == drafts[index].directory }, 351)
    let support = temp.appendingPathComponent("Support/AILimits")
    let file = support.appendingPathComponent("accounts.json")
    try writeAccountsFile(drafts: drafts, to: file, home: home)
    func mode(_ url: URL) -> Int { ((try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    try expect(mode(file) == 0o600 && mode(support) == 0o700
               && (try? Data(contentsOf: file)) == (try accountsFileData(drafts: drafts, existing: nil, home: home)), 352)
    try Data("not json".utf8).write(to: file)
    try writeAccountsFile(drafts: Array(drafts.prefix(1)), to: file, home: home)
    try expect((try? String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8)) == "not json"
               && mode(file.appendingPathExtension("bak")) == 0o600
               && resolveAccounts(fileData: try Data(contentsOf: file), home: home, isExecutable: { _ in false }) { _, _ in nil }.ids == ["cx"], 353)

    // Discovery: only folders named .claude* (not .claude) that hold a .claude.json; sorted; capped.
    func makeFolder(_ name: String, withState: Bool) throws {
        let folder = home.appendingPathComponent(name)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if withState { try Data("{}".utf8).write(to: folder.appendingPathComponent(".claude.json")) }
    }
    try makeFolder(".claude", withState: true)
    try makeFolder(".claude-work", withState: true)
    try makeFolder(".claude2", withState: true)
    try makeFolder(".claude-alt", withState: true)
    try makeFolder(".claude-empty", withState: false)
    try makeFolder("claude-nodot", withState: true)
    try makeFolder(".config", withState: true)
    try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
    try Data("{}".utf8).write(to: home.appendingPathComponent(".claudefile"))
    // Codex: .codex* folders (not .codex) with an auth.json; only its existence is checked.
    for (name, auth) in [(".codex", true), (".codex-work", true), (".codex-empty", false), (".codexalt", true)] {
        let folder = home.appendingPathComponent(name)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        if auth { try Data().write(to: folder.appendingPathComponent("auth.json")) }
    }
    try expect(discoverCodexLogins(home: home).map { ($0 as NSString).lastPathComponent } == [".codex-work", ".codexalt"], 365)
    let found = discoverClaudeLogins(home: home).map { ($0 as NSString).lastPathComponent }
    try expect(found == [".claude-alt", ".claude-work", ".claude2"]
               && discoverClaudeLogins(home: home, limit: 2).count == 2
               && discoverClaudeLogins(home: temp.appendingPathComponent("missing")).isEmpty, 354)

    // Scripts: every path single-quoted, a quote inside escaped, nothing piped, fixed lines.
    let cli = "/Users/x/My Tools/it's/claude"
    let probe = "/Users/x/Library/Application Support/AILimits/ClaudeProbe"
    let trust = withLanguage(.en) {
        terminalScript(task: .claudeTrust, cli: cli, directory: "/Users/x/.claude-o'brien", probeFolder: probe, home: home)
    }
    let lines = trust.split(separator: "\n").map(String.init)
    try expect(lines.first == "#!/bin/zsh"
               && lines.contains("export PATH='/Users/x/My Tools/it'\\''s':\"$PATH\"")
               && lines.contains("cd '/Users/x/Library/Application Support/AILimits/ClaudeProbe' || exit 1")
               && lines.contains("unset -m 'CLAUDE*' 'ANTHROPIC*'")
               && lines.contains("export CLAUDE_CONFIG_DIR='/Users/x/.claude-o'\\''brien'")
               && lines.last == "exec '/Users/x/My Tools/it'\\''s/claude'"
               && !trust.contains(" | ") && !trust.contains("<<") && lines.contains { $0.hasPrefix("printf '%s\\n' 'AI Limits: Claude Code will ask") }, 355)
    let login = terminalScript(task: .claudeLogin, cli: "/opt/c/claude", directory: nil, probeFolder: probe, home: home)
    let codex = terminalScript(task: .codexLogin, cli: "/opt/c/codex", directory: "/Users/x/codex home", probeFolder: probe, home: home,
                               defaultCodexHome: "/elsewhere")
    try expect(!login.contains("CLAUDE_CONFIG_DIR=") && login.hasSuffix("exec '/opt/c/claude'\n")
               && withLanguage(.ru) { terminalScript(task: .claudeLogin, cli: "/opt/c/claude", directory: nil, probeFolder: probe, home: home) }.contains("/login")
               && codex.contains("export CODEX_HOME='/Users/x/codex home'") && codex.hasSuffix("exec '/opt/c/codex' login\n")
               && !codex.contains("unset -m") && codex.contains("cd '\(home.path)' || exit 1"), 356)
    // The default Codex login never follows a CODEX_HOME from the user's shell profile; it gets
    // exactly what the app's own check inherits.
    let defaultCodex = terminalScript(task: .codexLogin, cli: "/opt/c/codex", directory: nil, probeFolder: probe, home: home,
                                      defaultCodexHome: nil)
    let inheritedCodex = terminalScript(task: .codexLogin, cli: "/opt/c/codex", directory: nil, probeFolder: probe, home: home,
                                        defaultCodexHome: "/Users/x/gui-codex")
    try expect(defaultCodex.contains("\nunset CODEX_HOME\n") && !defaultCodex.contains("export CODEX_HOME")
               && inheritedCodex.contains("export CODEX_HOME='/Users/x/gui-codex'") && !inheritedCodex.contains("unset CODEX_HOME")
               && inheritedCodexHome(environment: [:], home: home) == nil
               && inheritedCodexHome(environment: ["CODEX_HOME": "~/c"], home: URL(fileURLWithPath: "/Users/x")) == "/Users/x/c", 423)
    // The quoting survives a real shell: the shell prints back exactly the original text.
    for text in [cli, "a 'b' \"c\" $HOME `x` \\ ; & é", ""] {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf %s " + shellQuote(text)]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardInput = FileHandle.nullDevice
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        try expect(String(decoding: data, as: UTF8.self) == text, 357)
    }
    let script = try writeTerminalScript(trust, name: "claude-test", folder: temp.appendingPathComponent("Onboarding"))
    try expect(mode(script) == 0o700 && mode(temp.appendingPathComponent("Onboarding")) == 0o700
               && script.lastPathComponent == "claude-test.command", 358)
    // Copy commands: "~/" stays outside the quotes so the shell expands it.
    let fakeHome = URL(fileURLWithPath: "/Users/you")
    try expect(terminalCommand(task: .claudeTrust, directory: "/Users/you/.claude-work",
                               probeFolder: "/Users/you/Library/Application Support/AILimits/ClaudeProbe", home: fakeHome, defaultCodexHome: nil)
               == "cd ~/'Library/Application Support/AILimits/ClaudeProbe' && CLAUDE_CONFIG_DIR=~/'.claude-work' env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude"
               && terminalCommand(task: .claudeLogin, directory: nil, probeFolder: "/tmp/p q", home: fakeHome, defaultCodexHome: nil)
                  == "cd '/tmp/p q' && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CONFIG_DIR claude"
               && terminalCommand(task: .codexLogin, directory: nil, probeFolder: "/tmp", home: fakeHome, defaultCodexHome: nil) == "env -u CODEX_HOME codex login"
               && terminalCommand(task: .codexLogin, directory: nil, probeFolder: "/tmp", home: fakeHome, defaultCodexHome: "/Users/you/.codex")
                  == "CODEX_HOME=~/'.codex' codex login"
               && terminalCommand(task: .codexLogin, directory: "/Users/you/it's", probeFolder: "/tmp", home: fakeHome, defaultCodexHome: nil)
                  == "CODEX_HOME=~/'it'\\''s' codex login", 359)
    // The copied commands expand "~" in zsh (a prefix assignment, not an argument to env).
    for (command, expected) in [("CLAUDE_CONFIG_DIR=~/'.claude-work' env -u ANTHROPIC_API_KEY printenv CLAUDE_CONFIG_DIR", "/.claude-work"),
                                ("CLAUDE_CONFIG_DIR=x env -u CLAUDE_CONFIG_DIR printenv CLAUDE_CONFIG_DIR || echo unset", "unset")] {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", command]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardInput = FileHandle.nullDevice
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(text.hasSuffix(expected) && !text.hasPrefix("~"), 424)
    }

    // Names, slugs and ids.
    try expect(accountSlug("Work") == "work" && accountSlug("Claude Work 2") == "claude-work-2"
               && accountSlug("Работа") == "rabota" && accountSlug("  !!  ") == "" && accountSlug("Café_Team") == "cafe-team"
               && accountSlug(String(repeating: "ab ", count: 20)).count <= 24 && !accountSlug(String(repeating: "ab ", count: 20)).hasSuffix("-"), 360)
    try expect(nextClaudeID(existing: []) == "claude-1" && nextClaudeID(existing: ["claude-1", "claude-3", "codex"]) == "claude-2", 361)
    try expect(suggestedClaudeFolder(name: "Work", home: fakeHome, taken: ["/Users/you/.claude-work"], exists: { _ in false }) == "~/.claude-work-2"
               && suggestedClaudeFolder(name: "Work", home: fakeHome, taken: [], exists: { $0.hasSuffix(".claude-work") || $0.hasSuffix("-2") }) == "~/.claude-work-3"
               && suggestedClaudeFolder(name: "", home: fakeHome, taken: [], exists: { _ in false }) == "~/.claude-account", 362)
    try expect(suggestedName(forClaudeFolder: "/Users/you/.claude-work") == "Claude Work"
               && suggestedName(forClaudeFolder: "/Users/you/.claude2") == "Claude 2"
               && suggestedName(forClaudeFolder: "/Users/you/.claude-alt") == "Claude Alt"
               && displayPath("/Users/you/.claude-x", home: fakeHome) == "~/.claude-x" && displayPath("/Users/youth", home: fakeHome) == "/Users/youth", 363)
    // Status wording and which failures Terminal can fix.
    let usage = Usage(provider: "claude", updatedAt: nil, primary: Quota(usedPercent: 60, resetsAt: nil), secondary: Quota(usedPercent: 17, resetsAt: nil))
    try expect(withLanguage(.en) { connectedSummary(usage) } == "Week 83% left"
               && withLanguage(.ru) { connectedSummary(usage) } == "Неделя: осталось 83%"
               && withLanguage(.en) { connectedSummary(Usage(provider: "codex", updatedAt: nil, primary: Quota(usedPercent: 60, resetsAt: nil), secondary: nil)) } == "Session 40% left"
               && terminalTask(for: .probeNotTrusted, kind: .claude) == .claudeTrust && terminalTask(for: .notLoggedIn, kind: .claude) == .claudeLogin
               && terminalTask(for: .notLoggedIn, kind: .codex) == .codexLogin && terminalTask(for: .cliNotFound, kind: .claude) == nil
               && terminalTask(for: .failed, kind: .codex) == nil, 364)
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
               && valid.cli == ["claude": "/opt/tools/claude"] && valid.codexAccounts.map(\.id) == ["codex"], 300)

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
    try expect(twoCodex.ids == ["codex"] && twoCodex.warning?.contains("only one codex account can use the default home") == true, 305)
    let many = resolve(#"{"accounts":[\#((1...10).map { #"{"id":"c\#($0)","type":"claude"}"# }.joined(separator: ","))]}"#)
    try expect(many.ids == (1...8).map { "c\($0)" } && many.accounts.last?.name == "Claude 8"
               && many.warning?.contains("first 8") == true, 306)
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
    // Several Codex homes: one sessions root each, a shared folder counted once.
    let codexHomes = UsageSources(configuration: resolve(#"""
    {"accounts":[{"id":"codex","type":"codex"},{"id":"codex-2","type":"codex","home":"~/.codex-work"},
                 {"id":"codex-3","type":"codex","home":"~/.codex-team"}]}
    """#), home: home, environment: [:])
    try expect(codexHomes.codexRoots.map(\.path) == ["/Users/tester/.codex/sessions", "/Users/tester/.codex-work/sessions",
                                                      "/Users/tester/.codex-team/sessions"], 324)
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
        // A mistyped AI_LIMITS_DATA_DIR must not fall back to the real data folder.
        if appDataDirectory() == nil { fputs(dataDirectoryError, stderr); exit(64) }
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
                print("PASS: accounts.json parsed (defaults, duplicate/bad ids, several codex homes but one default, at most 8, bad paths, unparseable -> warning + detection); log roots derived per home; reset zones parsed for any IANA name; fetch failures map to fixed en/ru hints; login-shell misses expire after 5 min.")
                print("PASS: login emails and plans from account/read and the Claude profile (api-key and missing accounts ignored), plan names, masking, same-login pairs (never the default login), emails never published; widget layouts for 5-8 accounts; AI_LIMITS_DATA_DIR; Claude cadence for 8 accounts; at most two Codex checks at a time.")
                print("PASS: onboarding writes accounts.json keeping cli/unknown keys and ids (0600, folder 0700, broken file backed up); finds extra Claude logins by folder name and .claude.json presence only; Terminal scripts quote paths with spaces and quotes; slugs, ids and folder names.")
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
