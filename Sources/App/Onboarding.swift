import AppKit
import SwiftUI
import Observation

// The "Set up AI Limits" window: welcome, connect accounts, finish. The account cards show the
// real QuotaStore checks; every fix is something the user does in Terminal themselves (the app
// writes a fixed .command script that starts their own CLI and never types into it). Saving
// writes accounts.json; nothing here reads credentials or the CLIs' own files.

let onboardingCompletedKey = "onboardingCompleted"
let claudeInstallGuideURL = URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
let codexInstallGuideURL = URL(string: "https://github.com/openai/codex")!
let widgetSigningGuideURL = URL(string: "https://github.com/BLHN/ai-limits#signing-and-the-widget")!

/// First launch of a fresh install: no accounts.json, never finished the setup, no history yet
/// (people upgrading from an older version already have a history and are not asked).
func shouldOfferOnboarding(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> Bool {
    !defaults.bool(forKey: onboardingCompletedKey)
        && !fileManager.fileExists(atPath: accountsURL.path)
        && !fileManager.fileExists(atPath: historyURL.path)
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, accounts, finish
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: return L("Welcome", "Начало")
        case .accounts: return L("Accounts", "Аккаунты")
        case .finish: return L("Finish", "Завершение")
        }
    }
}

/// What a card knows about its account's latest check.
struct AccountCheckState: Equatable {
    /// The running app has this account in its configuration (it was saved).
    var saved = true
    /// A check is running or queued.
    var checking = false
    var failure: FetchFailure?
    /// App-authored description of the failure (never CLI output).
    var detail: String?
    /// "Week 83% left" after a successful check.
    var summary: String?
}

enum LaunchAtLoginState: Equatable { case off, on, needsApproval }

/// "Week 83% left" ("Неделя: осталось 83%"), else the session.
func connectedSummary(_ usage: Usage) -> String {
    if let week = usage.secondary {
        let value = Int(week.remaining.rounded())
        return L("Week \(value)% left", "Неделя: осталось \(value)%")
    }
    if let session = usage.primary {
        let value = Int(session.remaining.rounded())
        return L("Session \(value)% left", "Сеанс: осталось \(value)%")
    }
    return L("No limits reported", "Сервис не передал лимиты")
}

/// The Terminal session that fixes a failure, if one does.
func terminalTask(for failure: FetchFailure, kind: AccountKind) -> TerminalTask? {
    switch (failure, kind) {
    case (.probeNotTrusted, .claude): return .claudeTrust
    case (.notLoggedIn, .claude): return .claudeLogin
    case (.notLoggedIn, .codex): return .codexLogin
    default: return nil
    }
}

/// What the window needs from the running app; the preview tool passes fixtures.
struct OnboardingServices {
    var configuration: @MainActor () -> AccountsConfiguration?
    var state: @MainActor (AccountDraft) -> AccountCheckState
    var recheck: @MainActor (Set<String>) -> Void
    /// accounts.json was written.
    var saved: @MainActor () -> Void
    var launchAtLogin: @MainActor () -> LaunchAtLoginState
    var setLaunchAtLogin: @MainActor (Bool) -> Void
    var panelVisible: @MainActor () -> Bool
    var setPanelVisible: @MainActor (Bool) -> Void
    var close: @MainActor () -> Void
}

struct AddClaudeForm: Equatable {
    var name = ""
    var folder = ""
    /// The user typed a folder: the name no longer rewrites it.
    var folderEdited = false
    var error: String?
}

// MARK: - Model

@MainActor @Observable final class OnboardingModel {
    var step: OnboardingStep
    var drafts: [AccountDraft] = []
    /// Extra Claude login folders found in the home folder and not in the list.
    var suggestions: [String] = []
    var addForm: AddClaudeForm?
    /// Card to point at (opened from a failing account in the panel).
    var highlighted: String?
    var expandedDetails: Set<String> = []
    /// Accounts whose fix opened Terminal: re-checked automatically until this moment.
    var watching: [String: Date] = [:]
    /// Key of the command just copied, for a short "Copied" confirmation.
    var copiedKey: String?
    var launchAtLogin: LaunchAtLoginState = .off
    var panelVisible = true
    /// A save or Terminal problem, shown as one amber line.
    var notice: String?

    @ObservationIgnored let services: OnboardingServices
    /// Fixture render: no timers, files, Terminal or text fields.
    @ObservationIgnored let isStatic: Bool
    @ObservationIgnored let home: URL
    @ObservationIgnored let probeFolder: String
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastRecheck: [String: Date] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var edited = false

    /// How long a card keeps re-checking after its fix opened Terminal.
    static let watchDuration: TimeInterval = 180

    init(services: OnboardingServices, step: OnboardingStep = .welcome, isStatic: Bool = false,
         home: URL = realHome, probeFolder: String = claudeProbeFolderURL.path) {
        self.services = services
        self.step = step
        self.isStatic = isStatic
        self.home = home
        self.probeFolder = probeFolder
    }

    func start() {
        launchAtLogin = services.launchAtLogin()
        panelVisible = services.panelVisible()
        if let configuration = services.configuration() {
            load(configuration)
        } else {
            Task {
                let loaded = await Task.detached(priority: .userInitiated) { loadAccountsConfiguration() }.value
                if !edited { load(loaded) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchTick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if saveTask != nil { saveTask?.cancel(); saveTask = nil; save() }
    }

    func load(_ configuration: AccountsConfiguration) {
        drafts = configuration.accounts.map(AccountDraft.init)
        refreshSuggestions()
    }

    func refreshSuggestions() {
        guard !isStatic else { return }
        let used = Set(drafts.compactMap { $0.directory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
        suggestions = discoverClaudeLogins(home: home).filter { !used.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }
    }

    func state(of draft: AccountDraft) -> AccountCheckState { services.state(draft) }

    var canAdd: Bool { drafts.count < maxAccounts }
    var hasCodex: Bool { drafts.contains { $0.kind == .codex } }
    var hasDefaultClaude: Bool { drafts.contains { $0.kind == .claude && $0.directory == nil } }

    func folderCaption(_ draft: AccountDraft) -> String {
        switch draft.kind {
        case .claude:
            return draft.directory.map { displayPath($0, home: home) } ?? L("Default login · ~/.claude", "Основной вход · ~/.claude")
        case .codex:
            return draft.directory.map { displayPath($0, home: home) } ?? L("Default login · ~/.codex", "Основной вход · ~/.codex")
        }
    }

    // MARK: Steps

    func goForward() {
        switch step {
        case .welcome: setStep(.accounts)
        case .accounts:
            saveTask?.cancel(); saveTask = nil
            if !drafts.isEmpty { save() }
            addForm = nil
            launchAtLogin = services.launchAtLogin()
            panelVisible = services.panelVisible()
            setStep(.finish)
        case .finish:
            UserDefaults.standard.set(true, forKey: onboardingCompletedKey)
            services.close()
        }
    }

    func goBack() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { setStep(previous) }
    }

    func setStep(_ value: OnboardingStep) {
        step = value
    }

    /// Opened from a failing account: the Accounts step, pointing at its card.
    func focus(_ id: String) {
        step = .accounts
        highlighted = id
        guard !isStatic else { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if highlighted == id { highlighted = nil }
        }
    }

    // MARK: Editing

    func rename(_ id: String, to name: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].name = String(name.prefix(32))
        edited = true
        scheduleSave()
    }

    func remove(_ id: String) {
        drafts.removeAll { $0.id == id }
        watching[id] = nil
        edited = true
        refreshSuggestions()
        save()
    }

    func addSuggestion(_ path: String) {
        guard canAdd else { return }
        drafts.append(AccountDraft(id: nextClaudeID(existing: drafts.map(\.id)), kind: .claude,
                                   name: suggestedName(forClaudeFolder: path), directory: path))
        suggestions.removeAll { $0 == path }
        edited = true
        save()
    }

    func addCodex() {
        guard canAdd, !hasCodex else { return }
        var id = "codex"
        var number = 2
        while drafts.contains(where: { $0.id == id }) { id = "codex-\(number)"; number += 1 }
        drafts.append(AccountDraft(id: id, kind: .codex, name: "Codex", directory: nil))
        edited = true
        save()
    }

    /// The default login first; after that every Claude account needs its own folder.
    func beginAddClaude() {
        guard canAdd else { return }
        if !hasDefaultClaude {
            drafts.append(AccountDraft(id: nextClaudeID(existing: drafts.map(\.id)), kind: .claude, name: "Claude", directory: nil))
            edited = true
            save()
            return
        }
        addForm = AddClaudeForm(folder: proposedFolder(for: ""))
    }

    private func proposedFolder(for name: String) -> String {
        suggestedClaudeFolder(name: name, home: home, taken: drafts.compactMap(\.directory),
                              exists: isStatic ? { _ in false } : { FileManager.default.fileExists(atPath: $0) })
    }

    func setFormName(_ name: String) {
        guard var form = addForm else { return }
        form.name = String(name.prefix(32))
        if !form.folderEdited { form.folder = proposedFolder(for: form.name) }
        form.error = nil
        addForm = form
    }

    func setFormFolder(_ folder: String) {
        guard var form = addForm else { return }
        form.folder = folder
        form.folderEdited = true
        form.error = nil
        addForm = form
    }

    func commitAddForm() {
        guard var form = addForm, canAdd else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            form.error = L("Give this login a short name, for example Work.", "Дайте входу короткое имя, например «Работа».")
            addForm = form; return
        }
        guard let path = expandedPath(form.folder, home: home) else {
            form.error = L("The folder must start with ~/ or /.", "Папка должна начинаться с ~/ или /.")
            addForm = form; return
        }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        if standard == home.appendingPathComponent(".claude").path || standard == home.path {
            form.error = L("That is the default login. Pick a separate folder, such as ~/.claude-work.",
                           "Это основной вход. Выберите отдельную папку, например ~/.claude-work.")
            addForm = form; return
        }
        // Claude writes its whole state into this folder, so keep it a dedicated folder in the home folder.
        guard standard.hasPrefix(home.path + "/"), URL(fileURLWithPath: standard).lastPathComponent.hasPrefix(".") else {
            form.error = L("Use a hidden folder in your home folder, such as ~/.claude-work.",
                           "Нужна скрытая папка в домашней папке, например ~/.claude-work.")
            addForm = form; return
        }
        if drafts.contains(where: { $0.directory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == standard }) {
            form.error = L("Another account already uses this folder.", "Эта папка уже занята другим аккаунтом.")
            addForm = form; return
        }
        if !isStatic {
            do {
                try FileManager.default.createDirectory(atPath: standard, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                form.error = L("Could not create the folder.", "Не удалось создать папку.")
                addForm = form; return
            }
        }
        drafts.append(AccountDraft(id: nextClaudeID(existing: drafts.map(\.id)), kind: .claude, name: name, directory: standard))
        suggestions.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == standard }
        addForm = nil
        edited = true
        save()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard !isStatic else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            saveTask = nil
            save()
        }
    }

    /// Writes accounts.json and lets the running app pick it up at once. An empty list is not
    /// written: the app would fall back to detection and bring the accounts back.
    func save() {
        guard !isStatic, !drafts.isEmpty else { return }
        do {
            try writeAccountsFile(drafts: drafts, home: home)
            notice = nil
            services.saved()
        } catch {
            notice = L("Could not save accounts.json.", "Не удалось сохранить accounts.json.")
        }
    }

    // MARK: Fixes

    func checkAgain(_ draft: AccountDraft) {
        CLILocator.shared.forgetMisses()
        lastRecheck[draft.id] = Date()
        services.recheck([draft.id])
    }

    func openInstallGuide(_ kind: AccountKind) {
        guard !isStatic else { return }
        NSWorkspace.shared.open(kind == .claude ? claudeInstallGuideURL : codexInstallGuideURL)
    }

    func openSigningGuide() {
        guard !isStatic else { return }
        NSWorkspace.shared.open(widgetSigningGuideURL)
    }

    func command(_ task: TerminalTask, for draft: AccountDraft) -> String {
        terminalCommand(task: task, directory: draft.directory, probeFolder: probeFolder, home: home)
    }

    func copyCommand(_ task: TerminalTask, for draft: AccountDraft) {
        let key = draft.id
        if !isStatic {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command(task, for: draft), forType: .string)
        }
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copiedKey == key { copiedKey = nil }
        }
    }

    /// Writes the fixed script for this account and opens it (Terminal is the default app for
    /// .command files), then keeps re-checking the card for a few minutes.
    func openTerminal(_ task: TerminalTask, for draft: AccountDraft) {
        guard !isStatic else { return }
        let kind = draft.kind
        let directory = draft.directory
        let home = home
        let name = kind == .codex ? "codex" : "claude-\(draft.id)"
        Task {
            let script = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let cli = CLILocator.shared.locate(kind.rawValue) else { return nil }
                let probe = (try? claudeProbeDirectory())?.path ?? claudeProbeFolderURL.path
                let content = terminalScript(task: task, cli: cli, directory: directory, probeFolder: probe, home: home)
                return try? writeTerminalScript(content, name: name)
            }.value
            guard let script else {
                notice = L("Could not prepare the Terminal script. Use Copy command instead.",
                           "Не удалось подготовить скрипт для Терминала. Скопируйте команду.")
                return
            }
            if NSWorkspace.shared.open(script) {
                notice = nil
                watching[draft.id] = Date().addingTimeInterval(Self.watchDuration)
                lastRecheck[draft.id] = Date()
            } else {
                notice = L("Terminal did not open. Use Copy command instead.", "Терминал не открылся. Скопируйте команду.")
            }
        }
    }

    /// Re-checks watched cards every few seconds until they connect or the watch runs out.
    private func watchTick() {
        let now = Date()
        for (id, until) in watching {
            guard until > now, let draft = drafts.first(where: { $0.id == id }) else { watching[id] = nil; continue }
            let state = services.state(draft)
            if state.failure == nil, state.summary != nil, !state.checking { watching[id] = nil; continue }
            if !state.checking, now.timeIntervalSince(lastRecheck[id] ?? .distantPast) >= 5 {
                lastRecheck[id] = now
                services.recheck([id])
            }
        }
    }

    // MARK: Finish step

    func setLaunchAtLogin(_ on: Bool) {
        if !isStatic { services.setLaunchAtLogin(on) }
        launchAtLogin = isStatic ? (on ? .on : .off) : services.launchAtLogin()
    }

    func setPanelVisible(_ on: Bool) {
        if !isStatic { services.setPanelVisible(on) }
        panelVisible = isStatic ? on : services.panelVisible()
    }
}

// MARK: - Window

final class OnboardingWindow: NSWindow {
    /// Handles Esc first (true = handled), e.g. to cancel the open add form.
    var onCancel: (() -> Bool)?
    /// Esc closes the window at any step, unless the add form is open: then it closes the form.
    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        performClose(sender)
    }
}

@MainActor final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 560
    private var window: OnboardingWindow?
    private var model: OnboardingModel?
    private let makeServices: () -> OnboardingServices

    init(services: @escaping () -> OnboardingServices) {
        makeServices = services
    }

    /// Opens the window, or brings the open one to the front.
    func show(step: OnboardingStep? = nil, focus id: String? = nil) {
        if let window, let model {
            if let id { model.focus(id) } else if let step { model.setStep(step) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = OnboardingModel(services: makeServices(), step: step ?? .welcome)
        let root = OnboardingRoot(model: model) { [weak self] height in
            // Resizing from inside a SwiftUI layout pass is not allowed; the next turn is soon enough.
            DispatchQueue.main.async { self?.setContentHeight(height) }
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = OnboardingWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 520),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.title = L("Set up AI Limits", "Настройка AI Limits")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 20/255, green: 20/255, blue: 21/255, alpha: 1)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: Self.width, height: 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak model] in
            guard let model, model.addForm != nil else { return false }
            model.addForm = nil
            return true
        }
        window.center()
        self.window = window
        self.model = model
        model.start()
        if let id { model.focus(id) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Keeps the top edge in place while the content grows or shrinks.
    private func setContentHeight(_ height: CGFloat) {
        guard let window, height > 0 else { return }
        let content = NSRect(x: 0, y: 0, width: Self.width, height: height.rounded(.up))
        var frame = window.frameRect(forContentRect: content)
        guard abs(frame.height - window.frame.height) >= 1 else { return }
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Seen once is enough: the window does not reopen by itself on later launches.
        // It stays one click away under Accounts... in the menu.
        UserDefaults.standard.set(true, forKey: onboardingCompletedKey)
        model?.stop()
        model = nil
        window = nil
    }
}

// MARK: - Views

/// Window root: the content reports its own height so the window can follow it.
struct OnboardingRoot: View {
    let model: OnboardingModel
    let onHeight: (CGFloat) -> Void
    var body: some View {
        GeometryReader { _ in
            OnboardingView(model: model)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: OnboardingHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(OnboardingHeightKey.self) { height in
                    if height > 0 { onHeight(height) }
                }
        }
        // The content runs under the transparent title bar; the step indicator sits in that band.
        .ignoresSafeArea()
        .background(Palette.background)
    }
}

private struct OnboardingHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private var hairline: Color { Palette.text.opacity(0.08) }

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Tallest the step body gets before it scrolls (the window stays under ~640 pt).
    private let maxBodyHeight: CGFloat = 470
    @State private var bodyHeight: CGFloat = 360
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(step: model.step)
                .frame(maxWidth: .infinity)
                .padding(.top, model.isStatic ? 16 : 6)
                .padding(.bottom, 14)
            Rectangle().fill(hairline).frame(height: 1)
            if model.isStatic {
                stepBody
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        stepBody.background(GeometryReader { geometry in
                            Color.clear.preference(key: BodyHeightKey.self, value: geometry.size.height)
                        })
                    }
                    .scrollIndicators(bodyHeight > maxBodyHeight ? .automatic : .never)
                    .frame(height: min(bodyHeight, maxBodyHeight))
                    .onPreferenceChange(BodyHeightKey.self) { height in
                        if height > 0 { bodyHeight = height }
                    }
                    .onChange(of: model.highlighted) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : switchSpring) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = model.highlighted { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Rectangle().fill(hairline).frame(height: 1)
            footer
        }
        .frame(width: OnboardingWindowController.width)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var stepBody: some View {
        Group {
            switch model.step {
            case .welcome: WelcomeStep()
            case .accounts: AccountsStep(model: model)
            case .finish: FinishStep(model: model)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .id(model.step)
        .transition(.opacity)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return L("Connect accounts", "Подключить аккаунты")
        case .accounts: return L("Continue", "Продолжить")
        case .finish: return L("Done", "Готово")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step != .welcome {
                Button(L("Back", "Назад")) { move { model.goBack() } }
                    .buttonStyle(OutlineButtonStyle(height: 28))
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Palette.amber.opacity(0.9))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.step == .accounts {
                Text(accountsCaption).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Button(primaryTitle) { move { model.goForward() } }
                .buttonStyle(FilledButtonStyle(height: 28))
                .keyboardShortcut(model.addForm == nil ? .defaultAction : nil)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private var accountsCaption: String {
        let count = model.drafts.count
        return L("\(count) of \(maxAccounts) accounts", "\(count) из \(maxAccounts) \(ruPlural(maxAccounts, "аккаунта", "аккаунтов", "аккаунтов"))")
    }

    private func move(_ change: () -> Void) {
        if reduceMotion || model.isStatic { change() } else { withAnimation(.easeOut(duration: 0.18)) { change() } }
    }
}

/// "1 Welcome — 2 Accounts — 3 Finish"; done steps carry a check mark.
struct StepIndicator: View {
    let step: OnboardingStep
    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases) { item in
                let current = item == step
                let done = item.rawValue < step.rawValue
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(current ? Palette.text : Palette.text.opacity(done ? 0.18 : 0.08))
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.text)
                        } else {
                            Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(current ? Palette.background : Palette.muted)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(item.title).font(.system(size: 11, weight: current ? .semibold : .regular))
                        .foregroundStyle(current || done ? Palette.text : Palette.muted)
                        .lineLimit(1)
                }
                if item != OnboardingStep.allCases.last {
                    Rectangle().fill(Palette.text.opacity(0.12)).frame(width: 22, height: 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Step \(step.rawValue + 1) of 3: \(step.title)", "Шаг \(step.rawValue + 1) из 3: \(step.title)"))
    }
}

// MARK: Step 1

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.text)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.text.opacity(0.08)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Limits").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(L("Claude Code and Codex limits in your menu bar", "Лимиты Claude Code и Codex в строке меню"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            Text(L("See how much of each subscription's session and weekly limit is left, when it resets and whether you are on pace. Connecting your accounts takes about a minute.",
                   "Сколько осталось от лимитов сеанса и недели в каждой подписке, когда они сбросятся и укладываетесь ли вы в темп. Подключение аккаунтов займёт около минуты."))
                .font(.system(size: 13)).foregroundStyle(Palette.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Private by design", "Приватность")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                bullet("terminal", L("Reads limits only from your own claude and codex command line tools.",
                                     "Берёт лимиты только из ваших собственных CLI claude и codex."))
                bullet("lock", L("Never reads tokens, passwords or the keychain.",
                                 "Никогда не читает токены, пароли и связку ключей."))
                bullet("network", L("Nothing leaves your Mac except an anonymous price-list download.",
                                    "С вашего Mac ничего не уходит, кроме анонимной загрузки прайс-листа."))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.text.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.text.opacity(0.08), lineWidth: 1))
            .padding(.top, 20)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                .frame(width: 16).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Step 2

struct AccountsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Connect your accounts", "Подключите аккаунты")).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(L("Each card checks its account live. Fix anything amber, add the logins that are missing, then continue.",
                   "Каждая карточка проверяет аккаунт вживую. Исправьте всё жёлтое, добавьте недостающие входы и продолжайте."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                if model.drafts.isEmpty {
                    emptyNote
                }
                ForEach(model.drafts) { draft in
                    AccountCard(model: model, draft: draft)
                        .id(draft.id)
                }
                ForEach(model.suggestions, id: \.self) { path in
                    SuggestionRow(model: model, path: path)
                }
                if let form = model.addForm {
                    AddClaudeCard(model: model, form: form)
                } else {
                    addButtons
                }
            }
            .padding(.top, 16)
        }
    }

    private var emptyNote: some View {
        Text(L("No Claude Code or Codex account here yet. Add the ones you use; each card shows how to install and sign in.",
               "Здесь пока нет аккаунтов Claude Code или Codex. Добавьте те, которыми пользуетесь: карточка подскажет, как установить и войти."))
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.text.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var addButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.beginAddClaude() } label: {
                    Label(L("Add Claude account", "Добавить Claude"), systemImage: "plus")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(!model.canAdd)
                if !model.hasCodex {
                    Button { model.addCodex() } label: {
                        Label(L("Add Codex", "Добавить Codex"), systemImage: "plus")
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(!model.canAdd)
                }
                Spacer(minLength: 0)
            }
            Text(model.canAdd
                 ? (model.hasDefaultClaude
                    ? L("Each extra Claude subscription needs its own login folder; you sign in there once.",
                        "Для каждой дополнительной подписки Claude нужна своя папка входа; войти в неё нужно один раз.")
                    : L("Codex has one login; Claude can have several, each in its own login folder.",
                        "У Codex один вход; у Claude их может быть несколько, у каждого своя папка входа."))
                 : L("AI\u{00A0}Limits shows up to \(maxAccounts) accounts. Remove one to add another.",
                     "AI\u{00A0}Limits показывает до \(maxAccounts) аккаунтов. Удалите один, чтобы добавить другой."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// Small provider badge, the same "CL"/"CX" codes the panel uses.
struct ProviderMark: View {
    let kind: AccountKind
    var body: some View {
        Text(kind == .codex ? "CX" : "CL")
            .font(.system(size: 10, weight: .semibold)).monospaced()
            .foregroundStyle(Palette.text)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.text.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.text.opacity(0.10), lineWidth: 1))
            .accessibilityLabel(kind == .codex ? "Codex" : "Claude")
    }
}

/// Rotating arc; a still arc with Reduce Motion and in fixture renders.
struct Spinner: View {
    var size: CGFloat = 10
    var animated = true
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let moving = animated && !reduceMotion
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Palette.muted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(moving ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: turning)
            .onAppear { if moving { turning = true } }
            .accessibilityHidden(true)
    }
}

/// Single-line field in the panel's ink; plain text in fixture renders, where AppKit fields do not draw.
struct InlineField: View {
    let placeholder: String
    @Binding var text: String
    var isStatic = false
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var monospaced = false
    var framed = true
    var onSubmit: () -> Void = {}
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isStatic {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Palette.muted.opacity(0.7) : Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.text)
                    .focused($focused)
                    .onSubmit(onSubmit)
            }
        }
        .font(monospaced ? .system(size: size, weight: weight).monospaced() : .system(size: size, weight: weight))
        .padding(.horizontal, framed ? 8 : 5)
        .frame(height: framed ? 26 : 24)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Palette.text.opacity(framed ? (focused ? 0.08 : 0.05) : (focused ? 0.08 : hovering ? 0.05 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Palette.text.opacity(framed ? (focused ? 0.24 : 0.10) : (focused ? 0.18 : 0)), lineWidth: 1))
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

struct AccountCard: View {
    @Bindable var model: OnboardingModel
    let draft: AccountDraft

    var body: some View {
        let state = model.state(of: draft)
        let highlighted = model.highlighted == draft.id
        HStack(alignment: .top, spacing: 12) {
            ProviderMark(kind: draft.kind).padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    InlineField(placeholder: draft.kind == .codex ? "Codex" : "Claude",
                                text: Binding(get: { draft.name }, set: { model.rename(draft.id, to: $0) }),
                                isStatic: model.isStatic, size: 13, weight: .semibold, framed: false)
                        .padding(.leading, -5)
                        .accessibilityLabel(L("Account name", "Имя аккаунта"))
                    Button { model.remove(draft.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(LinkButtonStyle())
                    .help(L("Remove from AI\u{00A0}Limits (the login itself stays)", "Убрать из AI\u{00A0}Limits (сам вход останется)"))
                    .accessibilityLabel(L("Remove \(draft.name)", "Убрать \(draft.name)"))
                }
                Text(model.folderCaption(draft)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
                StatusLine(state: state, kind: draft.kind, isStatic: model.isStatic)
                    .padding(.top, 8)
                if let failure = state.failure {
                    FixBlock(model: model, draft: draft, failure: failure, detail: state.detail)
                        .padding(.top, 10)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.text.opacity(highlighted ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Palette.text.opacity(highlighted ? 0.36 : 0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: highlighted)
        .accessibilityElement(children: .contain)
    }
}

struct StatusLine: View {
    let state: AccountCheckState
    let kind: AccountKind
    var isStatic = false

    var body: some View {
        HStack(spacing: 7) {
            if !state.saved {
                Image(systemName: "circle.dotted").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(L("Saving, the check starts in a moment", "Сохраняю, проверка начнётся через мгновение"))
                    .foregroundStyle(Palette.muted)
            } else if state.checking {
                Spinner(animated: !isStatic).frame(width: 12)
                Text(state.failure == nil
                     ? (kind == .claude ? L("Checking, about 15 seconds", "Проверяю, около 15 секунд") : L("Checking", "Проверяю"))
                     : L("Checking again", "Проверяю снова"))
                    .foregroundStyle(Palette.muted)
            } else if let failure = state.failure {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.amber)
                Text(failureTitle(failure, kind: kind)).fontWeight(.medium).foregroundStyle(Palette.amber)
            } else if let summary = state.summary {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.text)
                (Text(L("Connected", "Подключено")).fontWeight(.medium) + Text("  ·  ") + Text(summary).foregroundColor(Palette.muted))
                    .foregroundStyle(Palette.text)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}

func failureTitle(_ failure: FetchFailure, kind: AccountKind) -> String {
    switch failure {
    case .cliNotFound:
        return kind == .claude ? L("Claude Code is not installed", "Claude Code не установлен")
                               : L("Codex CLI is not installed", "Codex CLI не установлен")
    case .probeNotTrusted: return L("Claude needs your OK once", "Claude ждёт вашего разрешения")
    case .notLoggedIn: return L("Not signed in", "Вход не выполнен")
    case .failed: return L("Check failed", "Проверка не удалась")
    }
}

func failureExplanation(_ failure: FetchFailure, kind: AccountKind) -> String {
    switch failure {
    case .cliNotFound:
        return kind == .claude
            ? L("Install Claude Code and sign in, then check again. AI\u{00A0}Limits looks in the usual install folders and your shell's PATH.",
                "Установите Claude Code и войдите, затем проверьте снова. AI\u{00A0}Limits ищет его в обычных папках установки и в PATH оболочки.")
            : L("Install the Codex CLI and sign in, then check again. AI\u{00A0}Limits looks in the usual install folders and your shell's PATH.",
                "Установите Codex CLI и войдите, затем проверьте снова. AI\u{00A0}Limits ищет его в обычных папках установки и в PATH оболочки.")
    case .probeNotTrusted:
        return L("Claude Code asks once whether to trust the folder AI\u{00A0}Limits checks from. AI\u{00A0}Limits never answers for you: open Terminal, choose \"Yes\", then close it.",
                 "Claude Code один раз спрашивает, доверять ли папке, из которой проверяет AI\u{00A0}Limits. Сам AI\u{00A0}Limits не отвечает: откройте Терминал, выберите «Yes» и закройте его.")
    case .notLoggedIn:
        return kind == .claude
            ? L("Open Terminal and type /login to sign in. Already signed in? Then this plan has no usage limits to show.",
                "Откройте Терминал и введите /login, чтобы войти. Вход уже выполнен? Значит, у этого тарифа нет лимитов, которые можно показать.")
            : L("Open Terminal to sign in with your ChatGPT account. An API-key login has no plan limits to show.",
                "Откройте Терминал и войдите через аккаунт ChatGPT. При входе по API-ключу лимитов тарифа нет.")
    case .failed:
        return L("The check did not finish. It often helps to check again; Details says where it stopped.",
                 "Проверка не завершилась. Часто помогает проверить ещё раз; в подробностях видно, где она остановилась.")
    }
}

struct FixBlock: View {
    @Bindable var model: OnboardingModel
    let draft: AccountDraft
    let failure: FetchFailure
    let detail: String?

    var body: some View {
        let task = terminalTask(for: failure, kind: draft.kind)
        let watching = model.watching[draft.id] != nil
        VStack(alignment: .leading, spacing: 9) {
            Text(failureExplanation(failure, kind: draft.kind))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch failure {
                case .cliNotFound:
                    Button(L("Install guide", "Как установить")) { model.openInstallGuide(draft.kind) }
                        .buttonStyle(FilledButtonStyle())
                    Button(L("I installed it, check again", "Установил, проверить")) { model.checkAgain(draft) }
                        .buttonStyle(OutlineButtonStyle())
                case .probeNotTrusted, .notLoggedIn:
                    if let task {
                        Button { model.openTerminal(task, for: draft) } label: {
                            Label(L("Open Terminal", "Открыть Терминал"), systemImage: "terminal")
                        }
                        .buttonStyle(FilledButtonStyle())
                    }
                    Button(L("Check again", "Проверить снова")) { model.checkAgain(draft) }
                        .buttonStyle(OutlineButtonStyle())
                case .failed:
                    Button(L("Check again", "Проверить снова")) { model.checkAgain(draft) }
                        .buttonStyle(FilledButtonStyle())
                    if detail != nil {
                        Button {
                            if model.expandedDetails.contains(draft.id) { model.expandedDetails.remove(draft.id) }
                            else { model.expandedDetails.insert(draft.id) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                    .rotationEffect(.degrees(model.expandedDetails.contains(draft.id) ? 90 : 0))
                                Text(L("Details", "Подробности"))
                            }
                        }
                        .buttonStyle(LinkButtonStyle())
                        .padding(.leading, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            if failure == .failed, let detail, model.expandedDetails.contains(draft.id) {
                Text(detail).font(.system(size: 11).monospaced()).foregroundStyle(Palette.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.text.opacity(0.05)))
            }
            if let task {
                CommandRow(command: model.command(task, for: draft), copied: model.copiedKey == draft.id) {
                    model.copyCommand(task, for: draft)
                }
            }
            if watching {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text(task == .codexLogin
                         ? L("Waiting for you in Terminal. This card updates by itself once you are signed in.",
                             "Ждём вас в Терминале. Карточка обновится сама, когда вход завершится.")
                         : L("Waiting for you in Terminal. This card updates by itself; close Terminal when Claude is done.",
                             "Ждём вас в Терминале. Карточка обновится сама; закройте Терминал, когда закончите с Claude."))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The Terminal command in monospace with a Copy button, for people who use another terminal.
struct CommandRow: View {
    let command: String
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(.system(size: 10.5).monospaced()).foregroundStyle(Palette.text.opacity(0.8))
                .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(command)
                .textSelection(.enabled)
            Button(action: onCopy) {
                Text(copied ? L("Copied", "Скопировано") : L("Copy command", "Скопировать"))
            }
            .buttonStyle(LinkButtonStyle(size: 11))
            .accessibilityLabel(L("Copy the Terminal command", "Скопировать команду для терминала"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.text.opacity(0.05)))
    }
}

struct SuggestionRow: View {
    @Bindable var model: OnboardingModel
    let path: String

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(kind: .claude).opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Found another Claude login", "Найден ещё один вход Claude"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                Text(displayPath(path, home: model.home)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(L("Add", "Добавить")) { model.addSuggestion(path) }
                .buttonStyle(OutlineButtonStyle())
                .disabled(!model.canAdd)
                .help(model.canAdd ? "" : L("AI\u{00A0}Limits shows up to \(maxAccounts) accounts", "AI\u{00A0}Limits показывает до \(maxAccounts) аккаунтов"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10)
            .stroke(Palette.text.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

struct AddClaudeCard: View {
    @Bindable var model: OnboardingModel
    let form: AddClaudeForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProviderMark(kind: .claude)
                Text(L("New Claude login", "Новый вход Claude")).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
            row(L("Name", "Имя")) {
                InlineField(placeholder: L("Work", "Работа"),
                            text: Binding(get: { form.name }, set: { model.setFormName($0) }),
                            isStatic: model.isStatic, onSubmit: { model.commitAddForm() })
            }
            row(L("Folder", "Папка")) {
                InlineField(placeholder: "~/.claude-work",
                            text: Binding(get: { form.folder }, set: { model.setFormFolder($0) }),
                            isStatic: model.isStatic, size: 11.5, monospaced: true, onSubmit: { model.commitAddForm() })
            }
            Text(L("Each extra Claude subscription needs its own login folder. AI\u{00A0}Limits creates it; next you sign in there once from Terminal.",
                   "Каждой дополнительной подписке Claude нужна своя папка входа. AI\u{00A0}Limits её создаст, а потом вы один раз войдёте в неё из Терминала."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 64)
            if let error = form.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 64)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L("Cancel", "Отмена")) { model.addForm = nil }
                    .buttonStyle(OutlineButtonStyle())
                Button(L("Add", "Добавить")) { model.commitAddForm() }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.text.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.text.opacity(0.14), lineWidth: 1))
        // Esc while typing in the form cancels the form, not the whole window.
        .onExitCommand { model.addForm = nil }
    }

    private func row<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .frame(width: 52, alignment: .trailing)
            field()
        }
    }
}

// MARK: Step 3

/// Switch drawn in the panel's ink (also renders in fixture images, unlike the AppKit one).
struct PillToggle: View {
    let isOn: Bool
    let label: String
    let action: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { action(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(Palette.text.opacity(isOn ? 0.88 : 0.14))
                Circle().fill(isOn ? Palette.background : Palette.text.opacity(0.9))
                    .padding(2)
            }
            .frame(width: 32, height: 18)
            .animation(reduceMotion ? nil : switchSpring, value: isOn)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? L("On", "Вкл") : L("Off", "Выкл"))
        .accessibilityAddTraits(.isButton)
    }
}

struct FinishStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        let connected = model.drafts.filter { model.state(of: $0).summary != nil && model.state(of: $0).failure == nil }.count
        VStack(alignment: .leading, spacing: 0) {
            let allConnected = !model.drafts.isEmpty && connected == model.drafts.count
            Text(model.drafts.isEmpty ? L("No accounts yet", "Аккаунтов пока нет")
                 : allConnected ? L("You are set", "Всё готово") : L("Accounts saved", "Аккаунты сохранены"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.text)
            Text(model.drafts.isEmpty
                 ? L("You can add them any time from the menu bar icon. A few optional extras:",
                     "Их можно добавить в любой момент из значка в строке меню. Несколько необязательных настроек:")
                 : allConnected
                    ? L("\(connected) of \(model.drafts.count) accounts connected. A few optional extras:",
                        "Подключено \(connected) из \(model.drafts.count). Несколько необязательных настроек:")
                    : L("\(connected) of \(model.drafts.count) connected; the rest can be fixed later from Accounts. A few optional extras:",
                        "Подключено \(connected) из \(model.drafts.count); остальные можно исправить позже в «Аккаунтах». Несколько необязательных настроек:"))
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 0) {
                toggleRow(symbol: "power", title: L("Launch at login", "Запускать при входе"),
                          body: model.launchAtLogin == .needsApproval
                            ? L("Waiting for approval in System Settings > General > Login Items.",
                                "Ждёт разрешения в Системных настройках > Основные > Объекты входа.")
                            : L("Start AI\u{00A0}Limits when you log in to your Mac.", "Открывать AI\u{00A0}Limits при входе в систему."),
                          isOn: model.launchAtLogin != .off) { model.setLaunchAtLogin($0) }
                Rectangle().fill(hairline).frame(height: 1)
                toggleRow(symbol: "macwindow.on.rectangle", title: L("Floating panel", "Плавающая панель"),
                          body: L("A small always-on-top window with the same limits.", "Небольшое окно поверх остальных с теми же лимитами."),
                          isOn: model.panelVisible) { model.setPanelVisible($0) }
                Rectangle().fill(hairline).frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    icon("square.grid.2x2")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Add the widget", "Добавьте виджет")).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                        Text(L("Right-click the desktop and choose Edit Widgets.\nSearch for \"AI\u{00A0}Limits\" and add it in the medium or large size.",
                               "Нажмите правой кнопкой на рабочий стол и выберите «Изменить виджеты».\nНайдите «AI\u{00A0}Limits» и добавьте средний или большой размер."))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("Not in the list? The widget may need the app signed with a development certificate.",
                               "Нет в списке? Виджету может понадобиться подпись приложения сертификатом разработчика."))
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        Button(L("How to sign the app", "Как подписать приложение")) { model.openSigningGuide() }
                            .buttonStyle(LinkButtonStyle())
                            .help(widgetSigningGuideURL.absoluteString)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.text.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.text.opacity(0.08), lineWidth: 1))
            .padding(.top, 16)

            Text(L("Accounts can be changed later: right-click the menu bar icon and choose Accounts.",
                   "Аккаунты можно изменить позже: правый клик по значку в строке меню, пункт «Аккаунты»."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.text.opacity(0.06)))
            .accessibilityHidden(true)
    }

    private func toggleRow(symbol: String, title: String, body: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.text)
                Text(body).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PillToggle(isOn: isOn, label: title, action: action)
        }
        .padding(.vertical, 12)
    }
}
