import AppKit
import UsageCore

/// A right-hand Settings page. Panes are rebuilt only when selected; live updates call `update()`,
/// which refreshes labels and switches in place so typed text and focus survive.
@MainActor
class SettingsPane: NSObject {
    let id: SettingsPaneID
    weak var host: SettingsWindowController?
    let content = NSStackView()
    private(set) lazy var view: NSView = SettingsUI.scrollView(containing: content)

    init(id: SettingsPaneID, host: SettingsWindowController) {
        self.id = id
        self.host = host
        super.init()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = SettingsStyle.sectionSpacing
    }

    func update() {}

    var secureFields: [NSSecureTextField] { [] }

    /// Secrets never outlive the pane that received them.
    func clearSecrets() {
        for field in secureFields {
            field.abortEditing()
            field.stringValue = ""
        }
    }

    func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func addSection(_ title: String?, _ views: [NSView]) {
        add(SettingsUI.column((title.map { [SettingsUI.sectionHeader($0)] } ?? []) + views, spacing: 8))
    }
}

extension SettingsUI {
    static func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func iconButton(symbol: String, accessibility: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(image: SettingsUI.symbol(symbol, pointSize: 15, weight: .regular), target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(accessibility)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    static func dotTone(for state: ProviderState?) -> SettingsDotView.Tone {
        guard let state else { return .gray }
        if state.hasDisplayableUsage { return state.status == .stale ? .orange : .green }
        if state.status == .refreshing || ConnectionCatalog.isUntouched(state) { return .gray }
        return .orange
    }

    /// What one number shows for a provider: "Auto · lowest limit" or the chosen limit's title.
    static func showsText(for provider: ProviderID, settings: AppSettings, state: ProviderState?) -> String {
        guard let id = settings.limitSelection(for: provider) else {
            let snapshot = state?.snapshot
            if let snapshot, snapshot.remainingPercent == nil, snapshot.creditBalance != nil || snapshot.windows.contains(where: { $0.balance != nil }) {
                return "Auto · balance"
            }
            return "Auto · lowest limit"
        }
        if let title = state?.snapshot?.windows.first(where: { $0.id == id })?.title { return title }
        return "Chosen limit (not in the latest data)"
    }

    static func limitValue(_ window: UsageWindow) -> String? {
        if let remaining = window.remainingPercent { return "\(Int(remaining.rounded()))% left" }
        return window.compactBalanceText
    }
}

// MARK: - General

@MainActor
final class GeneralSettingsPane: SettingsPane {
    struct PinRow: Equatable {
        let provider: ProviderID
        let shows: String
        let value: String?
        let canRemove: Bool
    }

    let header = SettingsPaneHeaderView(icon: SettingsUI.symbol("gearshape", pointSize: 24, weight: .regular),
                                        title: "General", status: "Menu bar, glass and startup")
    let pinsGroup = SettingsGroupView()
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let glassControl = NSSegmentedControl()
    let launchSwitch = NSSwitch()
    let launchMessage = SettingsMessageView()
    let loginItemsButton: NSButton
    private var launchBar: NSView?
    private(set) var removeButtons: [ProviderID: NSButton] = [:]
    private(set) var pinModel: [PinRow] = []
    private(set) var addCandidates: [ProviderID] = []

    init(host: SettingsWindowController) {
        loginItemsButton = SettingsUI.button("Open Login Items", target: nil, action: #selector(openLoginItems))
        super.init(id: .general, host: host)
        loginItemsButton.target = self
        header.statusDot.tone = nil
        add(header)

        addButton.target = self
        addButton.action = #selector(addToMenuBar(_:))
        addButton.setAccessibilityLabel("Add a provider to the menu bar")
        addButton.menu?.autoenablesItems = false
        let pinsNote = SettingsUI.footnote("Up to \(AppSettings.maximumMenuBarItems) items, each showing one number.")
        addSection("Menu bar", [pinsGroup, SettingsUI.buttonBar(leading: [pinsNote], trailing: [addButton])])

        glassControl.segmentCount = 2
        glassControl.setLabel("Clear", forSegment: 0)
        glassControl.setLabel("Regular", forSegment: 1)
        glassControl.trackingMode = .selectOne
        glassControl.target = self
        glassControl.action = #selector(glassChanged)
        glassControl.setAccessibilityLabel("Usage panel glass")
        let glassRow = SettingsRowView(title: "Usage panels", subtitle: "Regular is frosted and easiest to read. Clear is more see-through.",
                                       accessories: [glassControl])
        addSection("Glass", [SettingsGroupView(rows: [glassRow])])

        launchSwitch.target = self
        launchSwitch.action = #selector(launchChanged)
        launchSwitch.setAccessibilityLabel("Launch UsageRail at login")
        let launchRow = SettingsRowView(title: "Launch at login", subtitle: "Start UsageRail quietly in the menu bar when you log in.",
                                        accessories: [launchSwitch])
        loginItemsButton.isHidden = true
        let launchBar = SettingsUI.buttonBar(leading: [launchMessage], trailing: [loginItemsButton])
        launchBar.isHidden = true
        self.launchBar = launchBar
        addSection("Startup", [SettingsGroupView(rows: [launchRow]), launchBar])

        let refreshRows = ConnectionCatalog.refreshSchedule.map { SettingsRowView(title: $0.title, subtitle: $0.detail) }
        addSection("Refresh", [SettingsGroupView(rows: refreshRows), SettingsUI.footnote(ConnectionCatalog.refreshFootnote)])

        let status = host.environment.launchAtLogin.status()
        launchSwitch.state = status == .enabled || status == .requiresApproval ? .on : .off
        if status == .requiresApproval { showApprovalHint() }
    }

    override func update() {
        guard let host else { return }
        let settings = host.settings
        let model = settings.menuBarProviders.map { provider in
            let state = host.state(for: provider)
            return PinRow(provider: provider,
                          shows: state?.hasDisplayableUsage == true
                            ? SettingsUI.showsText(for: provider, settings: settings, state: state) : "Not connected right now",
                          value: state.flatMap { ConnectionCatalog.compactValue(for: $0, settings: settings) },
                          canRemove: settings.menuBarProviders.count > 1)
        }
        if model != pinModel { rebuildPins(model) }

        let candidates = host.connectedProviders.filter { !settings.isPinnedToMenuBar($0) }
        if candidates != addCandidates || addButton.numberOfItems == 0 {
            addCandidates = candidates
            addButton.removeAllItems()
            addButton.addItem(withTitle: "Add to menu bar")
            for provider in candidates {
                let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
                item.image = SettingsUI.menuIcon(for: provider)
                item.representedObject = provider.rawValue
                addButton.menu?.addItem(item)
            }
        }
        let full = settings.menuBarProviders.count >= AppSettings.maximumMenuBarItems
        addButton.isEnabled = !full && !candidates.isEmpty
        addButton.toolTip = full ? "The menu bar holds up to \(AppSettings.maximumMenuBarItems) items. Remove one first."
            : (candidates.isEmpty ? "Connect another provider to add it here." : nil)
        glassControl.selectedSegment = settings.glassStyle == .clear ? 0 : 1
    }

    private func rebuildPins(_ model: [PinRow]) {
        pinModel = model
        removeButtons = [:]
        pinsGroup.removeAllRows()
        for row in model {
            let value = SettingsLabel.make(row.value ?? "", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                           color: .secondaryLabelColor, wraps: false)
            value.isHidden = row.value == nil
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            let remove = SettingsUI.iconButton(symbol: "minus.circle.fill", accessibility: "Remove \(row.provider.displayName) from the menu bar",
                                               target: self, action: #selector(removeFromMenuBar(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(row.provider.rawValue)
            remove.isEnabled = row.canRemove
            remove.toolTip = row.canRemove ? "Remove from the menu bar" : "The menu bar always keeps one item."
            removeButtons[row.provider] = remove
            pinsGroup.addRow(SettingsRowView(title: row.provider.displayName, subtitle: row.shows,
                                             icon: ProviderIconArtwork.image(for: row.provider), accessories: [value, remove]))
        }
    }

    @objc func addToMenuBar(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let provider = ProviderID(rawValue: raw) else { return }
        _ = host?.setMenuBar(provider, pinned: true)
    }

    @objc func removeFromMenuBar(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let provider = ProviderID(rawValue: raw) else { return }
        _ = host?.setMenuBar(provider, pinned: false)
    }

    @objc func glassChanged() {
        host?.setGlassStyle(glassControl.selectedSegment == 1 ? .regular : .clear)
    }

    @objc func launchChanged() {
        guard let host else { return }
        let wanted = launchSwitch.state == .on
        launchMessage.show(nil)
        loginItemsButton.isHidden = true
        if let problem = host.setLaunchAtLogin(wanted) {
            launchMessage.show(problem)
            if problem.tone == .error { launchSwitch.state = wanted ? .off : .on }
        }
        if host.environment.launchAtLogin.status() == .requiresApproval { showApprovalHint() }
        launchBar?.isHidden = launchMessage.isHidden && loginItemsButton.isHidden
    }

    private func showApprovalHint() {
        launchMessage.show(.warning("Allow UsageRail in System Settings › General › Login Items."))
        loginItemsButton.isHidden = false
        launchBar?.isHidden = false
    }

    @objc func openLoginItems() { host?.environment.launchAtLogin.openLoginItems() }
}

// MARK: - Menu bar section (provider and guide panes)

@MainActor
final class MenuBarSection: NSObject {
    let provider: ProviderID
    let isGuide: Bool
    weak var host: SettingsWindowController?
    let toggle = NSSwitch()
    let limitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let switchRow: SettingsRowView
    let limitRow: SettingsRowView
    let note = SettingsMessageView()
    let view: NSView
    private var limitSignature: [String] = []

    init(provider: ProviderID, host: SettingsWindowController, isGuide: Bool = false) {
        self.provider = provider
        self.isGuide = isGuide
        self.host = host
        switchRow = SettingsRowView(title: "Show in menu bar", accessories: [toggle])
        limitRow = SettingsRowView(title: "Number shown", accessories: [limitPopup])
        view = SettingsUI.column([SettingsGroupView(rows: [switchRow, limitRow]), note], spacing: 8)
        super.init()
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Show \(provider.displayName) in the menu bar")
        limitPopup.target = self
        limitPopup.action = #selector(limitChanged)
        limitPopup.menu?.autoenablesItems = false
        limitPopup.setAccessibilityLabel("Number shown for \(provider.displayName)")
    }

    func update() {
        guard let host else { return }
        let settings = host.settings
        let state = host.state(for: provider)
        let connected = state?.hasDisplayableUsage == true
        let pinned = settings.isPinnedToMenuBar(provider)
        let isLast = pinned && settings.menuBarProviders.count == 1
        let limits = connected ? (state?.snapshot?.windows.filter(\.hasDisplayableMetric) ?? []) : []
        let chosen = settings.limitSelection(for: provider)
        let showsLimitPicker = connected && (limits.count > 1 || chosen != nil)

        toggle.state = pinned ? .on : .off
        toggle.isEnabled = pinned ? !isLast : connected
        if isLast {
            toggle.toolTip = "The menu bar always keeps one item. Add another provider first."
            switchRow.subtitle = "The menu bar always keeps at least one item."
        } else if pinned {
            toggle.toolTip = nil
            switchRow.subtitle = showsLimitPicker ? nil : "Shows " + SettingsUI.showsText(for: provider, settings: settings, state: state)
        } else if !connected {
            toggle.toolTip = "Available once \(provider.shortName) reports real usage."
            switchRow.subtitle = isGuide ? "Only available when real usage is reported." : "Available once connected."
        } else if settings.menuBarProviders.count >= AppSettings.maximumMenuBarItems, let oldest = settings.menuBarProviders.first {
            toggle.toolTip = nil
            switchRow.subtitle = "The menu bar is full. Turning this on replaces \(oldest.shortName)."
        } else {
            toggle.toolTip = nil
            switchRow.subtitle = "Up to \(AppSettings.maximumMenuBarItems) items."
        }

        limitRow.isHidden = !showsLimitPicker
        guard showsLimitPicker else { return }
        let signature = [chosen ?? "auto"] + limits.map { "\($0.id)|\($0.title)|\(SettingsUI.limitValue($0) ?? "")" }
        guard signature != limitSignature else { return }
        limitSignature = signature
        let menu = NSMenu()
        menu.autoenablesItems = false
        let auto = NSMenuItem(title: "Auto · lowest limit", action: nil, keyEquivalent: "")
        menu.addItem(auto)
        var selected = auto
        for limit in limits {
            let title = [limit.title, SettingsUI.limitValue(limit)].compactMap { $0 }.joined(separator: " · ")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = limit.id
            menu.addItem(item)
            if limit.id == chosen { selected = item }
        }
        if let chosen, !limits.contains(where: { $0.id == chosen }) {
            let missing = NSMenuItem(title: "Chosen limit (not in the latest data)", action: nil, keyEquivalent: "")
            missing.representedObject = chosen
            menu.addItem(missing)
            selected = missing
        }
        limitPopup.menu = menu
        limitPopup.select(selected)
    }

    @objc func toggled() {
        guard let host else { return }
        switch host.setMenuBar(provider, pinned: toggle.state == .on) {
        case .pinned(let displaced?): note.show(.info("Replaced \(displaced.shortName) in the menu bar."))
        case .pinned(nil), .unpinned: note.show(nil)
        case .keptLastItem: note.show(.warning("The menu bar always keeps one item."))
        case .notConnected: note.show(.warning("Connect \(provider.shortName) first."))
        case .unchanged: break
        }
        update()
    }

    @objc func limitChanged() {
        host?.selectLimit(limitPopup.selectedItem?.representedObject as? String, for: provider)
    }
}

// MARK: - Provider pane

@MainActor
protocol ProviderSetupSection: AnyObject {
    var view: NSView { get }
    var secureFields: [NSSecureTextField] { get }
    /// A saved setup exists even if no check has run yet.
    var isConfigured: Bool { get }
    func update()
}

@MainActor
final class ProviderSettingsPane: SettingsPane {
    let entry: ConnectionCatalogEntry
    let provider: ProviderID
    let header: SettingsPaneHeaderView
    let checkButton: NSButton
    let menuBar: MenuBarSection
    private(set) var setup: ProviderSetupSection!
    let message = SettingsMessageView()

    init(host: SettingsWindowController, entry: ConnectionCatalogEntry, provider: ProviderID) {
        self.entry = entry
        self.provider = provider
        checkButton = SettingsUI.button("Check now", target: nil, action: #selector(checkNow),
                                        accessibility: "Check \(provider.displayName) now")
        header = SettingsPaneHeaderView(icon: ProviderIconArtwork.image(for: provider), title: entry.title, accessory: checkButton)
        menuBar = MenuBarSection(provider: provider, host: host)
        super.init(id: .provider(provider), host: host)
        checkButton.target = self
        add(header)
        addSection("Menu bar", [menuBar.view])

        switch entry.setup {
        case .chatGPTApp: setup = CodexSetupSection(host: host)
        case .claudeProfile: setup = ClaudeSetupSection(host: host)
        case .apiKey(let page): setup = APIKeySetupSection(provider: provider, keyPage: page, host: host)
        case .copilotToken: setup = CopilotSetupSection(host: host)
        case .custom: setup = CustomSetupSection(provider: provider, host: host)
        case .guide: setup = nil
        }
        var views: [NSView] = [SettingsLabel.make(entry.summary, font: SettingsStyle.detailFont, color: .secondaryLabelColor)]
        if let setup { views.append(setup.view) }
        views.append(message)
        if let location = entry.credentialLocation { views.append(SettingsUI.footnote(location)) }
        addSection(entry.setup == .custom ? "API" : "Setup", views)
    }

    override var secureFields: [NSSecureTextField] { setup?.secureFields ?? [] }

    override func update() {
        guard let host else { return }
        let state = host.state(for: provider)
        header.setStatus(ConnectionCatalog.statusLine(for: state, settings: host.settings, isConfigured: setup?.isConfigured ?? false),
                         tone: SettingsUI.dotTone(for: state))
        checkButton.isEnabled = !host.isChecking(provider)
        menuBar.update()
        setup?.update()
        message.show(host.message(for: provider))
    }

    @objc func checkNow() { host?.checkNow(provider) }
}

// MARK: - Setup sections

@MainActor
final class CodexSetupSection: NSObject, ProviderSetupSection {
    weak var host: SettingsWindowController?
    let openButton: NSButton
    let view: NSView
    var secureFields: [NSSecureTextField] { [] }
    var isConfigured: Bool { false }

    init(host: SettingsWindowController) {
        self.host = host
        openButton = SettingsUI.button("Open ChatGPT", target: nil, action: #selector(openChatGPT))
        let row = SettingsRowView(title: "ChatGPT app",
                                  subtitle: "Sign in to the ChatGPT app, or run codex login for the Codex CLI. UsageRail detects it automatically.",
                                  accessories: [openButton])
        view = SettingsUI.column([SettingsGroupView(rows: [row])])
        super.init()
        openButton.target = self
    }

    func update() {}

    @objc func openChatGPT() { host?.openChatGPT() }
}

@MainActor
final class ClaudeSetupSection: NSObject, ProviderSetupSection {
    weak var host: SettingsWindowController?
    let profileRow: SettingsRowView
    let loginRow: SettingsRowView
    let createButton: NSButton
    let chooseButton: NSButton
    let copyLoginButton: NSButton
    let copyBridgeButton: NSButton
    let more: SettingsDisclosureView
    let view: NSView
    private(set) var profile: URL?
    var secureFields: [NSSecureTextField] { [] }
    var isConfigured: Bool { profile != nil }

    init(host: SettingsWindowController) {
        self.host = host
        profile = host.environment.claudeProfile()
        createButton = SettingsUI.button("Create profile", target: nil, action: #selector(createProfile),
                                         accessibility: "Create a private Claude profile for UsageRail")
        chooseButton = SettingsUI.button("Choose profile…", target: nil, action: #selector(chooseProfile))
        copyLoginButton = SettingsUI.button("Copy login command", target: nil, action: #selector(copyLogin))
        copyBridgeButton = SettingsUI.button("Copy UsageBridge path", target: nil, action: #selector(copyBridge))
        profileRow = SettingsRowView(title: "Profile", accessories: [createButton, chooseButton])
        loginRow = SettingsRowView(title: "Sign in",
                                   subtitle: "Copy the command and run it yourself in Terminal. UsageRail never signs in or out for you.",
                                   accessories: [copyLoginButton])
        more = SettingsDisclosureView(content: [
            SettingsUI.footnote("Only for older status-line setups. When a profile is selected, its limits win over status-line events."),
            copyBridgeButton
        ])
        view = SettingsUI.column([SettingsGroupView(rows: [profileRow, loginRow]), more])
        super.init()
        for button in [createButton, chooseButton, copyLoginButton, copyBridgeButton] { button.target = self }
        update()
    }

    func update() {
        // A path stays on one line (truncated in the middle); the no-profile hint may wrap.
        profileRow.subtitleLabel.lineBreakMode = profile == nil ? .byWordWrapping : .byTruncatingMiddle
        profileRow.subtitle = profile.map { ($0.path as NSString).abbreviatingWithTildeInPath }
            ?? "None yet. Create one just for UsageRail."
        createButton.isHidden = profile != nil
        copyLoginButton.isEnabled = profile != nil
        copyLoginButton.toolTip = profile == nil ? "Create or choose a profile first, so login uses that same profile." : nil
    }

    func reloadProfile() {
        profile = host?.environment.claudeProfile()
        update()
    }

    @objc func createProfile() { host?.createClaudeProfile(for: self) }
    @objc func chooseProfile() { host?.chooseClaudeProfile(for: self) }
    @objc func copyLogin() { host?.copyClaudeLogin() }
    @objc func copyBridge() { host?.copyBridgePath() }
}

@MainActor
final class APIKeySetupSection: NSObject, ProviderSetupSection {
    let provider: ProviderID
    let keyPage: URL
    weak var host: SettingsWindowController?
    let keyField: NSSecureTextField
    let savedRow: SettingsRowView
    let keyRow: SettingsRowView
    let connectButton: NSButton
    let replaceButton: NSButton
    let saveReplacementButton: NSButton
    let cancelReplaceButton: NSButton
    let getKeyButton: NSButton
    let view: NSView
    private(set) var hasSavedKey: Bool
    private(set) var isReplacing = false
    var secureFields: [NSSecureTextField] { [keyField] }
    var isConfigured: Bool { hasSavedKey }

    init(provider: ProviderID, keyPage: URL, host: SettingsWindowController) {
        self.provider = provider
        self.keyPage = keyPage
        self.host = host
        hasSavedKey = host.hasSavedKey(provider)
        keyField = SettingsUI.secureField(placeholder: "Paste your \(provider.shortName) API key",
                                          accessibility: "\(provider.displayName) API key")
        connectButton = SettingsUI.button("Connect", target: nil, action: #selector(connect))
        replaceButton = SettingsUI.button("Replace key…", target: nil, action: #selector(beginReplacing))
        saveReplacementButton = SettingsUI.button("Save & reconnect", target: nil, action: #selector(saveReplacement))
        cancelReplaceButton = SettingsUI.button("Cancel", target: nil, action: #selector(cancelReplacing))
        getKeyButton = SettingsUI.button("Get API key", target: nil, action: #selector(openKeyPage),
                                         accessibility: "Open the \(provider.shortName) API key page")
        savedRow = SettingsRowView(title: "Key saved", icon: SettingsUI.symbol("lock.fill", pointSize: 13), accessories: [replaceButton])
        keyRow = SettingsUI.formRow("API key", control: keyField, width: 290)
        view = SettingsUI.column([SettingsGroupView(rows: [savedRow, keyRow]),
                                  SettingsUI.buttonBar(leading: [getKeyButton],
                                                       trailing: [cancelReplaceButton, saveReplacementButton, connectButton])])
        super.init()
        for button in [connectButton, replaceButton, saveReplacementButton, cancelReplaceButton, getKeyButton] { button.target = self }
        keyField.target = self
        keyField.action = #selector(submitFromField)
        applyMode()
    }

    func update() {}

    private func applyMode() {
        let replacing = hasSavedKey && isReplacing
        savedRow.isHidden = !hasSavedKey
        savedRow.subtitle = replacing ? "The saved key stays until the new one is saved." : "Stored privately. It's never shown again."
        replaceButton.isHidden = !hasSavedKey || replacing
        keyRow.isHidden = hasSavedKey && !replacing
        keyRow.title = hasSavedKey ? "New key" : "API key"
        connectButton.isHidden = hasSavedKey
        saveReplacementButton.isHidden = !replacing
        cancelReplaceButton.isHidden = !replacing
        connectButton.keyEquivalent = connectButton.isHidden ? "" : "\r"
        saveReplacementButton.keyEquivalent = saveReplacementButton.isHidden ? "" : "\r"
        if keyRow.isHidden {
            keyField.abortEditing()
            keyField.stringValue = ""
        }
    }

    @objc func connect() { save(replacing: false) }
    @objc func saveReplacement() { save(replacing: true) }
    @objc func submitFromField() {
        guard !keyField.stringValue.isEmpty else { return }
        save(replacing: hasSavedKey && isReplacing)
    }

    @objc func beginReplacing() {
        isReplacing = true
        applyMode()
        keyField.window?.makeFirstResponder(keyField)
    }

    @objc func cancelReplacing() {
        isReplacing = false
        keyField.abortEditing()
        keyField.stringValue = ""
        applyMode()
    }

    @objc func openKeyPage() { host?.openLink(keyPage, failure: "Couldn't open the \(provider.shortName) API key page.") }

    private func save(replacing: Bool) {
        guard let host else { return }
        if host.saveAPIKey(provider, key: keyField.stringValue, replaceExisting: replacing) {
            keyField.abortEditing()
            keyField.stringValue = ""
            isReplacing = false
        }
        // Metadata only: flips to "Key saved" when a key exists, even one written elsewhere.
        hasSavedKey = host.hasSavedKey(provider)
        applyMode()
    }
}

@MainActor
final class CopilotSetupSection: NSObject, ProviderSetupSection {
    weak var host: SettingsWindowController?
    let usernameField: NSTextField
    let allowanceField: NSTextField
    let tokenField: NSSecureTextField
    let saveButton: NSButton
    let createTokenButton: NSButton
    let view: NSView
    var secureFields: [NSSecureTextField] { [tokenField] }
    var isConfigured: Bool { !(host?.settings.githubUsername.isEmpty ?? true) }

    init(host: SettingsWindowController) {
        self.host = host
        usernameField = SettingsUI.textField(placeholder: "octocat", accessibility: "GitHub username")
        allowanceField = SettingsUI.textField(placeholder: "Optional, e.g. 300", accessibility: "Monthly premium request allowance")
        tokenField = SettingsUI.secureField(placeholder: "Fine-grained token · Plan: read", accessibility: "GitHub fine-grained token")
        saveButton = SettingsUI.button("Save & connect", target: nil, action: #selector(save))
        createTokenButton = SettingsUI.button("Create token", target: nil, action: #selector(createToken),
                                              accessibility: "Create a fine-grained token on GitHub")
        let settings = host.settings
        usernameField.stringValue = settings.githubUsername
        allowanceField.stringValue = settings.githubAllowance.map(Self.allowanceText) ?? ""
        view = SettingsUI.column([
            SettingsGroupView(rows: [SettingsUI.formRow("GitHub username", control: usernameField),
                                     SettingsUI.formRow("Monthly allowance", control: allowanceField),
                                     SettingsUI.formRow("Token", control: tokenField)]),
            SettingsUI.footnote("Leave the token blank to keep the saved one. Add your plan's monthly allowance to see what's left."),
            SettingsUI.buttonBar(leading: [createTokenButton], trailing: [saveButton])
        ])
        super.init()
        saveButton.target = self
        saveButton.keyEquivalent = "\r"
        createTokenButton.target = self
    }

    static func allowanceText(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : ConnectionCatalog.scaleText(value)
    }

    func update() {}

    @objc func save() {
        guard let host else { return }
        if host.saveCopilot(username: usernameField.stringValue, allowance: allowanceField.stringValue, token: tokenField.stringValue) {
            tokenField.abortEditing()
            tokenField.stringValue = ""
            // Show exactly what was saved, e.g. "@octocat" becomes "octocat".
            usernameField.stringValue = host.settings.githubUsername
            allowanceField.stringValue = host.settings.githubAllowance.map(Self.allowanceText) ?? ""
        }
    }

    @objc func createToken() {
        guard let url = URL(string: "https://github.com/settings/personal-access-tokens/new") else { return }
        host?.openLink(url, failure: "Couldn't open GitHub.")
    }
}

// MARK: - Guide pane

@MainActor
final class GuideSettingsPane: SettingsPane {
    let entry: ConnectionCatalogEntry
    let header: SettingsPaneHeaderView
    let menuBar: MenuBarSection?
    let more: SettingsDisclosureView?
    let docsButton: NSButton?
    let templateButton: NSButton?
    let message = SettingsMessageView()

    init(host: SettingsWindowController, entry: ConnectionCatalogEntry) {
        self.entry = entry
        let icon: NSImage
        switch entry.id {
        case .provider(let provider): icon = ProviderIconArtwork.image(for: provider)
        case .research(let name):
            icon = ConnectionResearch.entries.first { $0.name == name }.map(ProviderIconArtwork.image(for:))
                ?? SettingsUI.symbol("book", pointSize: 22)
        }
        header = SettingsPaneHeaderView(icon: icon, title: entry.title)
        menuBar = entry.provider.map { MenuBarSection(provider: $0, host: host, isGuide: true) }
        more = entry.details.map { SettingsDisclosureView(content: [SettingsLabel.make($0, font: SettingsStyle.detailFont, color: .secondaryLabelColor)]) }
        docsButton = entry.documentationURL == nil ? nil
            : SettingsUI.button("Open documentation", target: nil, action: #selector(openDocumentation))
        templateButton = entry.template == nil ? nil
            : SettingsUI.button("Set up as custom API…", target: nil, action: #selector(useTemplate))
        super.init(id: .entry(entry.id), host: host)
        docsButton?.target = self
        templateButton?.target = self
        add(header)
        if let menuBar { addSection("Menu bar", [menuBar.view]) }
        let summary = SettingsRowView(title: entry.summary, icon: SettingsUI.symbol("info.circle", pointSize: 13))
        var views: [NSView] = [SettingsGroupView(rows: [summary])]
        if let more { views.append(more) }
        let trailing = [templateButton, docsButton].compactMap { $0 }
        if !trailing.isEmpty { views.append(SettingsUI.buttonBar(leading: [], trailing: trailing)) }
        views.append(message)
        addSection("Guide", views)
    }

    override func update() {
        guard let host else { return }
        if let provider = entry.provider, let state = host.state(for: provider), state.hasDisplayableUsage {
            header.setStatus(ConnectionCatalog.statusLine(for: state, settings: host.settings), tone: SettingsUI.dotTone(for: state))
        } else {
            header.setStatus(entry.guideStatus ?? "Guide", tone: .gray)
        }
        menuBar?.update()
    }

    @objc func openDocumentation() {
        guard let url = entry.documentationURL, url.scheme == "https" else { return }
        if host?.environment.openURL(url) != true { message.show(.error("Couldn't open the documentation.")) }
    }

    @objc func useTemplate() {
        guard let template = entry.template else { return }
        host?.showAddCustom(template: template)
    }
}
