import AppKit
import ServiceManagement
import UsageCore

final class UsagePreferencesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "w": performClose(nil); return true
            case "m": performMiniaturize(nil); return true
            // A menu-bar app has no Edit menu, so route the standard editing keys (pasting a key!).
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            case "z": if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
struct LaunchAtLoginControl {
    var status: () -> SMAppService.Status
    var setEnabled: (Bool) throws -> Void
    var openLoginItems: () -> Void

    static let live = LaunchAtLoginControl(
        status: { SMAppService.mainApp.status },
        setEnabled: { enabled in
            let service = SMAppService.mainApp
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
        },
        openLoginItems: { SMAppService.openSystemSettingsLoginItems() })
}

/// Every side effect Settings can have, injectable so hidden QA never touches real
/// credentials, the Keychain, the pasteboard, login items or the user's defaults.
@MainActor
struct SettingsEnvironment {
    var customDefaults: UserDefaults
    /// Whether a Kie or Runpod key is saved, from Keychain metadata only.
    var hasAPIKey: (ProviderID) -> Bool
    var writeAPIKey: (String, ProviderID) throws -> Void
    var writeCopilotToken: (String) throws -> Void
    /// Used only to run a test request for an edit with a blank token. Never shown.
    var readCustomToken: (ProviderID) throws -> String?
    var writeCustomToken: (String, ProviderID) throws -> Void
    var deleteCustomToken: (ProviderID) throws -> Void
    var saveCustomEntries: ([CustomConnection]) throws -> Void
    var testCustom: @MainActor (CustomConnection, String) async throws -> UsageSnapshot
    var claudeProfile: () -> URL?
    var saveClaudeProfile: (URL) throws -> Void
    var createClaudeProfile: () throws -> URL
    /// Where Claude Code's launcher is installed, for the login command. Nothing is run.
    var claudeLauncher: () -> URL?
    var copyText: (String) -> Void
    var openURL: (URL) -> Bool
    var chatGPTAppURL: () -> URL?
    var launchAtLogin: LaunchAtLoginControl
    var confirmRemoval: (_ window: NSWindow?, _ title: String, _ message: String, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    var bridgePath: () -> String
    var now: () -> Date

    func loadCustomEntries() -> [CustomConnection] { CustomConnection.load(defaults: customDefaults) }

    static func live(keychain: KeychainStore) -> SettingsEnvironment {
        let defaults = UserDefaults.standard
        return SettingsEnvironment(
            customDefaults: defaults,
            hasAPIKey: { APIKeyStore.hasSavedKey($0, keychain: keychain) },
            writeAPIKey: { value, provider in
                guard let account = APIKeyStore.account(for: provider) else { throw ConnectorError.unavailable("No API key for this service.") }
                try keychain.write(value, account: account)
            },
            writeCopilotToken: { try keychain.write($0, account: "github-plan-read") },
            // Custom connectors read their token from the shared store, so they are written there too.
            readCustomToken: { try KeychainStore.shared.read(account: $0.rawValue, allowInteraction: false) },
            writeCustomToken: { try KeychainStore.shared.write($0, account: $1.rawValue) },
            deleteCustomToken: { try KeychainStore.shared.delete(account: $0.rawValue) },
            saveCustomEntries: { try CustomConnection.save($0, defaults: defaults) },
            testCustom: { try await CustomUsageConnector.test($0, token: $1) },
            claudeProfile: { try? ClaudeConnector.configuredProfile() },
            saveClaudeProfile: { try ClaudeConnector.saveProfile($0) },
            createClaudeProfile: { try ClaudeConnector.createDefaultProfile() },
            claudeLauncher: { ClaudeExecutable.installedLauncher() },
            copyText: { value in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            },
            openURL: { NSWorkspace.shared.open($0) },
            chatGPTAppURL: {
                let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            launchAtLogin: .live,
            confirmRemoval: { window, title, message, completion in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.addButton(withTitle: "Remove").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                if let window {
                    alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
                } else {
                    completion(alert.runModal() == .alertFirstButtonReturn)
                }
            },
            bridgePath: { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/UsageBridge").path },
            now: { Date() })
    }
}

@MainActor
final class SettingsDetailController: NSViewController {
    private(set) var paneView: NSView?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 540))
    }

    func display(_ pane: NSView) {
        loadViewIfNeeded()
        paneView?.removeFromSuperview()
        pane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.topAnchor.constraint(equalTo: view.topAnchor),
            pane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        paneView = pane
    }
}

/// One Settings window for everything: General, every connection, guides and custom APIs.
/// Changes apply immediately. Opening it runs no network request, subprocess or Keychain read.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSettingsChanged: ((AppSettings) -> Void)?
    var onRefreshConnections: (() -> Void)?
    var onRefreshProvider: ((ProviderID) -> Void)?
    var onClose: (() -> Void)?

    enum MenuBarChange: Equatable {
        case pinned(displaced: ProviderID?)
        case unpinned
        case keptLastItem
        case notConnected
        case unchanged
    }

    struct PendingCheck {
        let since: Date
        var started: Bool
        let baseline: ProviderState?
        let token: UUID
    }

    let settingsStore: SettingsStore
    let environment: SettingsEnvironment
    private(set) var settings: AppSettings
    private(set) var states: [ProviderState] = []
    private(set) var customConnections: [CustomConnection] = []
    private(set) var selectedPane: SettingsPaneID = .general
    private(set) var currentPane: SettingsPane?
    private(set) var setupMessages: [ProviderID: SettingsMessage] = [:]
    private(set) var pendingChecks: [ProviderID: PendingCheck] = [:]
    let sidebar = SettingsSidebarController()
    let detail = SettingsDetailController()
    let splitController = NSSplitViewController()
    private(set) var customTask: Task<Void, Never>?
    private var pendingTemplate: CustomConnectionTemplate?
    private var hasPresented = false
    private var needsFreshPane = false

    convenience init(settings: AppSettings, settingsStore: SettingsStore, keychain: KeychainStore = .shared) {
        self.init(settings: settings, settingsStore: settingsStore, environment: .live(keychain: keychain))
    }

    init(settings: AppSettings, settingsStore: SettingsStore, environment: SettingsEnvironment) {
        self.settings = settings
        self.settingsStore = settingsStore
        self.environment = environment
        let window = UsagePreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "UsageRail Settings"
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "UsageRailSettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.animationBehavior = .documentWindow
        super.init(window: window)
        window.delegate = self

        sidebar.onSelect = { [weak self] pane in self?.select(pane) }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 196
        sidebarItem.maximumThickness = 280
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 440
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)
        splitController.view.frame = NSRect(x: 0, y: 0, width: 760, height: 540)
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 760, height: 540))
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.initialFirstResponder = sidebar.tableView
        // Panes are swapped in and out, so let Tab follow whatever is on screen.
        window.autorecalculatesKeyViewLoop = true

        customConnections = environment.loadCustomEntries()
        rebuildSidebar()
        select(.general, rebuild: true)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Public interface

    func updateConnectionStates(_ states: [ProviderState]) {
        self.states = states
        let latest = environment.loadCustomEntries()
        if latest != customConnections { customConnections = latest }
        resolvePendingChecks()
        if !paneIsAvailable(selectedPane) { select(.general) }
        rebuildSidebar()
        currentPane?.update()
    }

    /// Pins or limits changed elsewhere (menu-bar panel). Already persisted by the caller.
    func applyExternalSettings(_ settings: AppSettings) {
        self.settings = settings
        rebuildSidebar()
        currentPane?.update()
    }

    func show(provider: ProviderID?) {
        let target = provider.map(SettingsPaneID.provider) ?? .general
        select(paneIsAvailable(target) ? target : .general, rebuild: needsFreshPane)
        needsFreshPane = false
        showWindow(nil)
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        if needsFreshPane {
            needsFreshPane = false
            select(selectedPane, rebuild: true)
        }
        if !hasPresented {
            window.center()
            hasPresented = true
        }
        super.showWindow(sender)
        if window.isMiniaturized { window.deminiaturize(sender) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        cancelCustomTask()
        currentPane?.clearSecrets()
        setupMessages = [:]
        pendingChecks = [:]
        needsFreshPane = true
        onClose?()
    }

    // MARK: Navigation

    func select(_ pane: SettingsPaneID, rebuild: Bool = false) {
        let target = paneIsAvailable(pane) ? pane : .general
        if target == selectedPane, currentPane != nil, !rebuild {
            sidebar.select(target)
            return
        }
        currentPane?.clearSecrets()
        cancelCustomTask()
        // Input errors and hints belong to what was typed there; check results stay.
        if let left = selectedPane.provider, let tone = setupMessages[left]?.tone, tone == .error || tone == .info {
            setupMessages[left] = nil
        }
        selectedPane = target
        let pane = makePane(target)
        currentPane = pane
        detail.display(pane.view)
        sidebar.select(target)
        pane.update()
    }

    func paneIsAvailable(_ pane: SettingsPaneID) -> Bool {
        switch pane {
        case .general, .addCustom: return true
        case .entry(.provider(let provider)):
            return !provider.isCustom || customConnections.contains { $0.provider == provider }
        case .entry(.research(let name)):
            return ConnectionResearch.entries.contains { $0.name == name }
        }
    }

    private func makePane(_ pane: SettingsPaneID) -> SettingsPane {
        switch pane {
        case .general:
            return GeneralSettingsPane(host: self)
        case .addCustom:
            let template = pendingTemplate
            pendingTemplate = nil
            return AddCustomAPIPane(host: self, template: template)
        case .entry(let id):
            guard let entry = ConnectionCatalog.entry(for: id) else { return GeneralSettingsPane(host: self) }
            if entry.isGuide || entry.provider == nil { return GuideSettingsPane(host: self, entry: entry) }
            return ProviderSettingsPane(host: self, entry: entry, provider: entry.provider!)
        }
    }

    func showAddCustom(template: CustomConnectionTemplate?) {
        pendingTemplate = template
        select(.addCustom, rebuild: true)
    }

    private enum SidebarSection { case connected, setUp, guides }

    func rebuildSidebar() {
        let sections = ConnectionCatalog.sections(states: states, customProviders: customConnections.map(\.provider))
        var rows: [SettingsSidebarController.Row] = [
            .item(SettingsSidebarItem(pane: .general, title: "General", icon: .symbol("gearshape"), accessory: .none,
                                      accessibilityLabel: "General"))
        ]
        func append(_ title: String, _ ids: [ConnectionCatalogEntry.ID], _ section: SidebarSection, always: Bool = false) {
            guard always || !ids.isEmpty else { return }
            rows.append(.header(title))
            rows += ids.compactMap { id in sidebarItem(for: id, in: section).map { .item($0) } }
        }
        append("Connected", sections.connected, .connected)
        // "Add custom API…" closes Set up, so it stays visible above the long Guides list.
        append("Set up", sections.setUp, .setUp, always: true)
        rows.append(.item(SettingsSidebarItem(pane: .addCustom, title: "Add custom API…", icon: .symbol("plus"),
                                              accessory: .none, accessibilityLabel: "Add custom API")))
        append("Guides", sections.guides, .guides)
        sidebar.setRows(rows, selected: selectedPane)
    }

    private func sidebarItem(for id: ConnectionCatalogEntry.ID, in section: SidebarSection) -> SettingsSidebarItem? {
        guard let entry = ConnectionCatalog.entry(for: id) else { return nil }
        let pane = SettingsPaneID.entry(id)
        guard case .provider(let provider) = id else {
            if case .research(let name) = id {
                return SettingsSidebarItem(pane: pane, title: entry.title, icon: .research(name), accessory: .tag("Guide"),
                                           accessibilityLabel: "\(entry.title), guide")
            }
            return nil
        }
        let state = state(for: provider)
        switch section {
        case .connected:
            let value = state.flatMap { ConnectionCatalog.compactValue(for: $0, settings: settings) }
            let accessory: SettingsSidebarItem.Accessory = value.map { .value($0, attention: state?.status == .stale) } ?? .dot(.green)
            return SettingsSidebarItem(pane: pane, title: entry.title, icon: .provider(provider), accessory: accessory,
                                       accessibilityLabel: "\(entry.title), connected" + (value.map { ", \($0)" } ?? ""))
        case .setUp:
            // Attention only for setups that did work or were configured and now fail.
            let failing = state.map { $0.status != .refreshing && ($0.snapshot != nil || (provider.isCustom && !ConnectionCatalog.isUntouched($0))) } ?? false
            return SettingsSidebarItem(pane: pane, title: entry.title, icon: .provider(provider),
                                       accessory: failing ? .dot(.orange) : .none,
                                       accessibilityLabel: "\(entry.title), " + (failing ? "needs attention" : "not set up"))
        case .guides:
            return SettingsSidebarItem(pane: pane, title: entry.title, icon: .provider(provider), accessory: .tag("Guide"),
                                       accessibilityLabel: "\(entry.title), guide")
        }
    }

    // MARK: State helpers for panes

    func state(for provider: ProviderID) -> ProviderState? { states.first { $0.provider == provider } }
    func message(for provider: ProviderID) -> SettingsMessage? { setupMessages[provider] }
    func isChecking(_ provider: ProviderID) -> Bool { pendingChecks[provider] != nil }
    func customConnection(for provider: ProviderID) -> CustomConnection? { customConnections.first { $0.provider == provider } }
    func hasSavedKey(_ provider: ProviderID) -> Bool { environment.hasAPIKey(provider) }

    /// Connected providers in sidebar order, for the "Add to menu bar" menu.
    var connectedProviders: [ProviderID] {
        ConnectionCatalog.sections(states: states, customProviders: customConnections.map(\.provider)).connected.compactMap {
            if case .provider(let provider) = $0 { return provider }
            return nil
        }
    }

    func post(_ message: SettingsMessage?, for provider: ProviderID) {
        setupMessages[provider] = message
        currentPane?.update()
    }

    // MARK: Settings (instant apply)

    /// Persists, then tells the app. Each change starts from the stored settings so a pin made
    /// from the menu-bar panel meanwhile is never overwritten.
    private func commit(_ updated: AppSettings) {
        settingsStore.save(updated)
        settings = updated
        onSettingsChanged?(updated)
        rebuildSidebar()
        currentPane?.update()
    }

    func setMenuBar(_ provider: ProviderID, pinned: Bool) -> MenuBarChange {
        var updated = settingsStore.load()
        if pinned {
            guard !updated.isPinnedToMenuBar(provider) else { return .unchanged }
            guard state(for: provider)?.hasDisplayableUsage == true else { return .notConnected }
            let displaced = updated.pinToMenuBar(provider)
            commit(updated)
            return .pinned(displaced: displaced)
        }
        guard updated.isPinnedToMenuBar(provider) else { return .unchanged }
        guard updated.unpinFromMenuBar(provider) else { return .keptLastItem }
        commit(updated)
        return .unpinned
    }

    func selectLimit(_ limitID: String?, for provider: ProviderID) {
        var updated = settingsStore.load()
        guard updated.limitSelection(for: provider) != limitID else { return }
        updated.selectLimit(limitID, for: provider)
        commit(updated)
    }

    func setGlassStyle(_ style: GlassStyle) {
        var updated = settingsStore.load()
        guard updated.glassStyle != style else { return }
        updated.glassStyle = style
        commit(updated)
    }

    /// Returns a problem to show inline, or nil when the login item changed as asked.
    func setLaunchAtLogin(_ enabled: Bool) -> SettingsMessage? {
        do {
            try environment.launchAtLogin.setEnabled(enabled)
        } catch {
            return .error("Couldn't change the login item: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: Checks

    func checkNow(_ provider: ProviderID) { beginCheck(provider) }

    /// Shows "Checking…" until a state newer than this request arrives.
    private func beginCheck(_ provider: ProviderID, message: String = "Checking…") {
        let token = UUID()
        pendingChecks[provider] = PendingCheck(since: environment.now(), started: false, baseline: state(for: provider), token: token)
        setupMessages[provider] = .progress(message)
        currentPane?.update()
        onRefreshProvider?(provider)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.expireCheck(provider, token: token)
        }
    }

    private func expireCheck(_ provider: ProviderID, token: UUID) {
        guard pendingChecks[provider]?.token == token else { return }
        pendingChecks[provider] = nil
        setupMessages[provider] = .warning("No answer yet. Try Check now in a moment.")
        currentPane?.update()
    }

    /// A fresh state newer than the request confirms the connection, including a zero balance.
    /// A failure counts once the check has visibly started (or the state changed).
    private func resolvePendingChecks() {
        for (provider, pending) in pendingChecks {
            guard let state = state(for: provider) else { continue }
            var check = pending
            if state.status == .refreshing { check.started = true }
            if state.status == .fresh, (state.snapshot?.updatedAt ?? .distantPast) >= check.since {
                setupMessages[provider] = state.hasDisplayableUsage ? .success("Connected · \(state.displayValue)")
                    : .warning(ConnectionCatalog.noValueMessage(for: provider))
                pendingChecks[provider] = nil
            } else if [.loginRequired, .stale, .unavailable].contains(state.status),
                      check.started || (check.baseline != nil && state != check.baseline) {
                setupMessages[provider] = .warning(ConnectionCatalog.settingsHint(for: state))
                pendingChecks[provider] = nil
            } else {
                pendingChecks[provider] = check
            }
        }
    }

    // MARK: Setup actions

    /// Kie and Runpod keys go to the Keychain; replacing a saved key needs the explicit action.
    func saveAPIKey(_ provider: ProviderID, key: String, replaceExisting: Bool) -> Bool {
        do {
            let value = try APIKeyStore.validated(key, for: provider)
            if !replaceExisting, environment.hasAPIKey(provider) {
                post(.error("A key is already saved. Use Replace key… to change it."), for: provider)
                return false
            }
            try environment.writeAPIKey(value, provider)
        } catch {
            post(.error((error as? LocalizedError)?.errorDescription ?? "The key couldn't be saved to your Keychain."), for: provider)
            return false
        }
        beginCheck(provider, message: replaceExisting ? "Key replaced. Checking…" : "Key saved. Checking…")
        return true
    }

    func saveCopilot(username: String, allowance: String, token: String) -> Bool {
        let allowanceText = allowance.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowanceValue = allowanceText.isEmpty ? nil : Double(allowanceText)
        if !allowanceText.isEmpty, !(allowanceValue.map { $0.isFinite && $0 > 0 } ?? false) {
            post(.error("Monthly allowance must be a positive number, like 300 — or leave it blank."), for: .copilot)
            return false
        }
        var user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.hasPrefix("@") { user.removeFirst() }
        guard user.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil else {
            post(.error("Enter your GitHub username (letters, numbers and hyphens)."), for: .copilot)
            return false
        }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil, secret.utf8.count <= 4096 else {
            post(.error("That token doesn't look right. Paste it again without spaces."), for: .copilot)
            return false
        }
        do {
            if !secret.isEmpty { try environment.writeCopilotToken(secret) }
        } catch {
            post(.error("Couldn't save the token to your Keychain: \(error.localizedDescription)"), for: .copilot)
            return false
        }
        var updated = settingsStore.load()
        updated.githubUsername = user
        updated.githubAllowance = allowanceValue
        commit(updated)
        beginCheck(.copilot, message: "Saved. Checking…")
        return true
    }

    func openChatGPT() {
        guard let url = environment.chatGPTAppURL(), environment.openURL(url) else {
            post(.warning("ChatGPT isn't in your Applications folder. Nothing was installed."), for: .codex)
            return
        }
        post(.info("Finish signing in to ChatGPT, then choose Check now."), for: .codex)
    }

    func openLink(_ url: URL, failure: String) {
        guard url.scheme == "https", environment.openURL(url) else {
            if let provider = selectedPane.provider { post(.error(failure), for: provider) }
            return
        }
    }

    func chooseClaudeProfile(for section: ClaudeSetupSection) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose a signed-in Claude Code profile"
        picker.message = "Pick an existing private profile folder. UsageRail saves only its path, never credentials."
        picker.prompt = "Choose"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        picker.canCreateDirectories = false
        picker.directoryURL = try? UsagePaths.applicationSupport()
        picker.beginSheetModal(for: window) { [weak self, weak section] response in
            guard response == .OK, let url = picker.url, let self else { return }
            do {
                try self.environment.saveClaudeProfile(url)
                section?.reloadProfile()
                self.beginCheck(.claude, message: "Profile saved. Checking…")
            } catch {
                self.post(.error((error as? LocalizedError)?.errorDescription ?? "That folder can't be used."), for: .claude)
            }
        }
    }

    /// Creates UsageRail's own private profile folder and selects it. Nothing signs in.
    func createClaudeProfile(for section: ClaudeSetupSection) {
        do {
            _ = try environment.createClaudeProfile()
        } catch {
            post(.error((error as? LocalizedError)?.errorDescription ?? "The profile folder couldn't be created."), for: .claude)
            return
        }
        section.reloadProfile()
        post(.success("Profile created. Copy the login command, run it in Terminal, then choose Check now."), for: .claude)
    }

    /// Copies the login command only. UsageRail never runs it or reads Claude credentials.
    func copyClaudeLogin() {
        guard let profile = environment.claudeProfile() else {
            post(.info("Create or choose the profile first so login uses that same profile."), for: .claude)
            return
        }
        guard let launcher = environment.claudeLauncher() else {
            post(.warning("Claude Code isn't installed. Install it first, then copy the login command."), for: .claude)
            return
        }
        environment.copyText(ClaudeConnector.loginCommand(profile: profile, launcher: launcher))
        post(.success("Login command copied. Run it yourself in Terminal — nothing was run."), for: .claude)
    }

    func copyBridgePath() {
        environment.copyText(environment.bridgePath())
        post(.success("UsageBridge path copied. Your Claude settings weren't changed."), for: .claude)
    }

    // MARK: Custom APIs

    func cancelCustomTask() {
        customTask?.cancel()
        customTask = nil
    }

    /// Test must pass before anything is saved; the token goes to the Keychain with rollback.
    func testAndAddCustom(from pane: AddCustomAPIPane) {
        guard customTask == nil else { return }
        let form = pane.form
        do {
            guard pane.approval.state == .on else {
                throw ConnectorError.unavailable("Check the endpoint and token permissions, then tick the confirmation.")
            }
            guard environment.loadCustomEntries().count < 20 else {
                throw ConnectorError.unavailable("You've reached the limit of 20 custom APIs.")
            }
            guard let provider = ProviderID.custom(name: form.nameField.stringValue) else {
                throw ConnectorError.unavailable("Enter a name of 1–40 characters.")
            }
            let configuration = try form.configuration(provider: provider)
            if configuration.endpoint.contains("YOUR_") {
                throw ConnectorError.unavailable("Replace the YOUR_… placeholder in the endpoint first.")
            }
            let secret = configuration.authentication == .none ? "" : form.typedToken
            if configuration.authentication != .none, secret.isEmpty {
                throw ConnectorError.unavailable("Paste the API token, or set Authentication to None.")
            }
            let test = environment.testCustom
            pane.setBusy(true)
            pane.message.show(.progress("Testing the usage value…"))
            customTask = Task { [weak self, weak pane] in
                let result: Result<UsageSnapshot, Error>
                do { result = .success(try await test(configuration, secret)) } catch { result = .failure(error) }
                // A cancelled test (pane switch, window close) changes nothing.
                guard !Task.isCancelled, let self else { return }
                self.customTask = nil
                pane?.setBusy(false)
                do {
                    let snapshot = try result.get()
                    try self.persistNewCustom(configuration, secret: secret)
                    pane?.form.clearSecrets()
                    // Prevent an accidental second click from adding a duplicate.
                    pane?.approval.state = .off
                    let value = ProviderState(provider: provider, status: .fresh, snapshot: snapshot).displayValue
                    self.customConnections = self.environment.loadCustomEntries()
                    self.setupMessages[provider] = .success("Added · \(value). Turn on Show in menu bar to pin it.")
                    self.rebuildSidebar()
                    self.select(.provider(provider))
                    self.onRefreshConnections?()
                } catch {
                    pane?.message.show(.error((error as? LocalizedError)?.errorDescription ?? "Test failed. Nothing was added."))
                }
            }
        } catch {
            pane.message.show(.error((error as? LocalizedError)?.errorDescription ?? "Check the connection fields."))
        }
    }

    /// Same order and rollback as before: token first, then the entry; a failed entry save removes the token.
    private func persistNewCustom(_ configuration: CustomConnection, secret: String) throws {
        if configuration.authentication != .none { try environment.writeCustomToken(secret, configuration.provider) }
        do {
            try environment.saveCustomEntries(environment.loadCustomEntries() + [configuration])
        } catch {
            if configuration.authentication != .none { try? environment.deleteCustomToken(configuration.provider) }
            throw error
        }
    }

    /// Keeps the ProviderID and list position. A blank token tests with the saved one (never shown)
    /// and leaves the Keychain untouched; a typed token is written only after the test passes.
    func testAndSaveCustomEdit(_ section: CustomSetupSection) {
        guard customTask == nil else { return }
        let provider = section.provider
        do {
            guard customConnection(for: provider) != nil else { throw ConnectorError.unavailable("This API was removed.") }
            let configuration = try section.form.configuration(provider: provider)
            let typed = section.form.typedToken
            let secret: String
            if configuration.authentication == .none {
                secret = ""
            } else if !typed.isEmpty {
                secret = typed
            } else {
                let saved: String?
                do { saved = try environment.readCustomToken(provider) } catch {
                    throw ConnectorError.loginRequired("The saved token couldn't be read without a prompt. Type it again to test.")
                }
                guard let saved, !saved.isEmpty else { throw ConnectorError.loginRequired("Enter a token for this API.") }
                secret = saved
            }
            let newToken = configuration.authentication == .none || typed.isEmpty ? nil : typed
            let test = environment.testCustom
            section.setBusy(true)
            post(.progress("Testing the usage value…"), for: provider)
            customTask = Task { [weak self, weak section] in
                let result: Result<UsageSnapshot, Error>
                do { result = .success(try await test(configuration, secret)) } catch { result = .failure(error) }
                guard !Task.isCancelled, let self else { return }
                self.customTask = nil
                section?.setBusy(false)
                do {
                    let snapshot = try result.get()
                    try self.persistEditedCustom(configuration, newToken: newToken)
                    self.customConnections = self.environment.loadCustomEntries()
                    section?.finishEditing()
                    let value = ProviderState(provider: provider, status: .fresh, snapshot: snapshot).displayValue
                    self.setupMessages[provider] = .success("Saved · \(value)")
                    self.rebuildSidebar()
                    self.currentPane?.update()
                    self.onRefreshConnections?()
                } catch {
                    self.post(.error((error as? LocalizedError)?.errorDescription ?? "Test failed. Nothing was changed."), for: provider)
                }
            }
        } catch {
            post(.error((error as? LocalizedError)?.errorDescription ?? "Check the connection fields."), for: provider)
        }
    }

    /// Entry first, then a typed token; a failed token write restores the previous entry list.
    private func persistEditedCustom(_ configuration: CustomConnection, newToken: String?) throws {
        let original = environment.loadCustomEntries()
        guard let index = original.firstIndex(where: { $0.provider == configuration.provider }) else {
            throw ConnectorError.unavailable("This API was removed.")
        }
        var updated = original
        updated[index] = configuration
        try environment.saveCustomEntries(updated)
        if let newToken {
            do { try environment.writeCustomToken(newToken, configuration.provider) } catch {
                try? environment.saveCustomEntries(original)
                throw error
            }
        }
    }

    func confirmRemoveCustom(_ provider: ProviderID) {
        environment.confirmRemoval(window, "Remove \(provider.displayName)?",
                                   "This removes the API and its saved token from UsageRail. Your account with the service isn't changed.") { [weak self] confirmed in
            guard confirmed else { return }
            self?.removeCustom(provider)
        }
    }

    func removeCustom(_ provider: ProviderID) {
        cancelCustomTask()
        do {
            try environment.deleteCustomToken(provider)
            try environment.saveCustomEntries(environment.loadCustomEntries().filter { $0.provider != provider })
        } catch {
            post(.error("Couldn't remove it: \((error as? LocalizedError)?.errorDescription ?? "unknown error")"), for: provider)
            return
        }
        customConnections = environment.loadCustomEntries()
        setupMessages[provider] = nil
        pendingChecks[provider] = nil
        var updated = settingsStore.load()
        if updated.menuBarProviders == [provider] { updated.setMenuBarProviders([.codex]) } else { updated.unpinFromMenuBar(provider) }
        updated.selectLimit(nil, for: provider)
        select(.general)
        commit(updated)
        onRefreshConnections?()
    }
}
