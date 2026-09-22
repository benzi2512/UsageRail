import AppKit
import Darwin
import UsageCore

/// Records every side effect the hidden QA environment would have had.
/// Nothing here touches the real Keychain, pasteboard, login items, browser or user defaults.
@MainActor
final class SettingsQAProbe {
    var tokens: [String: String] = [:]
    var tokenReads = 0
    var tokenWrites = 0
    var copilotWrites: [String] = []
    var apiKeys: [ProviderID: String] = [:]
    var apiKeyWrites = 0
    var profile: URL?
    var createdProfiles = 0
    var launcher: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
    var copied: [String] = []
    var opened: [URL] = []
    var savedProfiles: [URL] = []
    var launchEnabled = false
    var tests: [(configuration: CustomConnection, token: String)] = []
    var testResult: (CustomConnection) throws -> UsageSnapshot = { try $0.snapshot(from: Data(#"{"credits":42}"#.utf8)) }
    var confirmRemoval = true
    var failNextEntrySave = false
    var now = Date()
}

extension SettingsWindowController {
    static let qaSuiteName = "com.usagerail.qa"

    static func qaEnvironment(defaults: UserDefaults, probe: SettingsQAProbe, profile: URL?) -> SettingsEnvironment {
        probe.profile = profile
        return SettingsEnvironment(
            customDefaults: defaults,
            hasAPIKey: { probe.apiKeys[$0] != nil },
            writeAPIKey: { value, provider in probe.apiKeyWrites += 1; probe.apiKeys[provider] = value },
            writeCopilotToken: { probe.copilotWrites.append($0); probe.tokens["github-plan-read"] = $0 },
            readCustomToken: { probe.tokenReads += 1; return probe.tokens[$0.rawValue] },
            writeCustomToken: { probe.tokenWrites += 1; probe.tokens[$1.rawValue] = $0 },
            deleteCustomToken: { probe.tokens[$0.rawValue] = nil },
            saveCustomEntries: { entries in
                if probe.failNextEntrySave {
                    probe.failNextEntrySave = false
                    throw ConnectorError.unavailable("Synthetic save failure")
                }
                try CustomConnection.save(entries, defaults: defaults)
            },
            testCustom: { configuration, token in
                probe.tests.append((configuration, token))
                return try probe.testResult(configuration)
            },
            claudeProfile: { probe.profile },
            saveClaudeProfile: { probe.savedProfiles.append($0) },
            createClaudeProfile: {
                probe.createdProfiles += 1
                let created = URL(fileURLWithPath: "/Users/qa/Library/Application Support/UsageRail/\(ClaudeConnector.defaultProfileName)", isDirectory: true)
                probe.profile = created
                return created
            },
            claudeLauncher: { probe.launcher },
            copyText: { probe.copied.append($0) },
            openURL: { probe.opened.append($0); return false },
            chatGPTAppURL: { nil },
            launchAtLogin: LaunchAtLoginControl(status: { probe.launchEnabled ? .enabled : .notRegistered },
                                                setEnabled: { probe.launchEnabled = $0 }, openLoginItems: {}),
            confirmRemoval: { _, _, _, completion in completion(probe.confirmRemoval) },
            bridgePath: { "/Applications/UsageRail.app/Contents/MacOS/UsageBridge" },
            now: { probe.now })
    }

    /// Runs `work` against the QA defaults suite and restores the suite exactly afterwards.
    static func withQADefaults<T>(_ work: (UserDefaults) throws -> T) rethrows -> T? {
        guard let defaults = UserDefaults(suiteName: qaSuiteName) else { return nil }
        let original = defaults.persistentDomain(forName: qaSuiteName)
        defaults.removePersistentDomain(forName: qaSuiteName)
        defer { restoreQADefaults(defaults, to: original) }
        return try work(defaults)
    }

    /// QA modes exit right after reporting, so wait for the restore to reach the defaults database.
    static func restoreQADefaults(_ defaults: UserDefaults, to original: [String: Any]?) {
        if let original { defaults.setPersistentDomain(original, forName: qaSuiteName) }
        else { defaults.removePersistentDomain(forName: qaSuiteName) }
        defaults.synchronize()
    }

    static func qaStates(now: Date, custom: ProviderID?) -> [ProviderState] {
        func quota(_ provider: ProviderID, _ windows: [UsageWindow], source: UsageSource) -> ProviderState {
            ProviderState(provider: provider, status: .fresh, snapshot: UsageSnapshot(provider: provider, windows: windows, updatedAt: now, source: source))
        }
        var states = [
            quota(.codex, [UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 12, kind: .shortTerm),
                           UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 28, kind: .weekly)], source: .codexAppServer),
            quota(.claude, [UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 9, kind: .shortTerm),
                            UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 51, kind: .weekly)], source: .claudeCode),
            ProviderState(provider: .copilot, status: .unavailable, snapshot: nil, message: "No data yet"),
            ProviderState(provider: .antigravity, status: .unavailable, snapshot: nil, message: "No data yet"),
            ProviderState(provider: .gemini, status: .unavailable, snapshot: nil, message: "No data yet"),
            ProviderState(provider: .kie, status: .fresh, snapshot: UsageSnapshot(provider: .kie, windows: [], updatedAt: now,
                                                                                 source: .kieAPI, creditBalance: 12_345.67)),
            ProviderState(provider: .runpod, status: .fresh, snapshot: UsageSnapshot(provider: .runpod, windows: [], updatedAt: now,
                                                                                    source: .runpodAPI, creditBalance: 23.46, balanceUnit: .usd))
        ]
        if let custom {
            states.append(ProviderState(provider: custom, status: .fresh, snapshot: UsageSnapshot(
                provider: custom, windows: [], updatedAt: now, source: .customAPI, creditBalance: 42)))
        }
        return states
    }

    // MARK: Helpers for driving real controls without showing anything

    static func toggle(_ control: NSSwitch, to state: NSControl.StateValue) {
        control.state = state
        control.sendAction(control.action, to: control.target)
    }

    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    static func visibleText(in view: NSView) -> String {
        allSubviews(of: view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ")
    }

    static func buttonTitles(in view: NSView) -> [String] {
        allSubviews(of: view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? NSButton }.map(\.title)
    }

    var sidebarPanes: [SettingsPaneID] { sidebar.items.map(\.pane) }

    // MARK: - Background QA

    /// Hidden QA: never shows or focuses a window, uses the QA defaults suite and an in-memory
    /// credential store. `--qa-output=<dir>` also writes renders.
    static func runBackgroundQA() -> [String: Bool] {
        let result: [String: Bool]? = withQADefaults { defaults in
            do { return try backgroundChecks(defaults: defaults) } catch { return ["backgroundQACompleted": false] }
        }
        var checks = result ?? ["qaDefaultsSuiteAvailable": false]
        if let output = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-output=") })
            .map({ URL(fileURLWithPath: String($0.dropFirst(12)), isDirectory: true) }) {
            let rendered: [String: Bool]? = withQADefaults { defaults in
                (try? renderPanesForQA(defaults: defaults, to: output)) ?? ["settingsRendersWritten": false]
            }
            checks.merge(rendered ?? ["settingsRendersWritten": false]) { _, new in new }
        }
        checks["settingsQANeverShowsAWindow"] = !NSApp.windows.contains { $0.isVisible }
        return checks
    }

    private static func backgroundChecks(defaults: UserDefaults) throws -> [String: Bool] {
        let probe = SettingsQAProbe()
        let store = SettingsStore(defaults: defaults)
        let custom = try requireQAValue(ProviderID.custom(name: "QA Web"))
        try CustomConnection.save([CustomConnection(provider: custom, endpoint: "https://api.example.com/balance", pointer: "/credits",
                                                    metric: .credits, authentication: .bearer)], defaults: defaults)
        var initial = store.load()
        initial.setMenuBarProviders([.codex])
        store.save(initial)
        let profile = URL(fileURLWithPath: "/Users/qa/Library/Application Support/UsageRail/Claude's usage profile", isDirectory: true)
        let controller = SettingsWindowController(settings: store.load(), settingsStore: store,
                                                  environment: qaEnvironment(defaults: defaults, probe: probe, profile: profile))
        var checks: [String: Bool] = [:]
        var settingsChanges = 0, connectionRefreshes = 0, closes = 0
        var refreshes: [ProviderID] = []
        controller.onSettingsChanged = { _ in settingsChanges += 1 }
        controller.onRefreshProvider = { refreshes.append($0) }
        controller.onRefreshConnections = { connectionRefreshes += 1 }
        controller.onClose = { closes += 1 }
        guard let window = controller.window else { return ["settingsWindowExists": false] }

        // Window
        checks["settingsTitle"] = window.title == "UsageRail Settings"
        checks["settingsHasCloseButton"] = window.styleMask.contains(.closable) && window.standardWindowButton(.closeButton)?.isEnabled == true
        checks["settingsHasMinimizeButton"] = window.styleMask.contains(.miniaturizable)
            && window.standardWindowButton(.miniaturizeButton)?.isEnabled == true
        checks["settingsIsResizableFullSizeContent"] = window.styleMask.contains(.resizable) && window.styleMask.contains(.fullSizeContentView)
        checks["settingsUsesNormalWindowLevel"] = window.level == .normal
        checks["settingsDoesNotFollowEverySpace"] = !window.collectionBehavior.contains(.canJoinAllSpaces)
        checks["settingsIsNotReleasedWhenClosed"] = !window.isReleasedWhenClosed
        let size = window.contentRect(forFrameRect: window.frame).size
        checks["settingsDefaultSize760x540"] = abs(size.width - 760) < 1 && abs(size.height - 540) < 1
        checks["settingsMinimumSize680x460"] = window.contentMinSize == NSSize(width: 680, height: 460)
        checks["settingsUsesNativeSidebarSplit"] = controller.splitController.splitViewItems.first?.behavior == .sidebar
            && controller.splitController.splitViewItems.first?.canCollapse == false && window.contentViewController === controller.splitController
        checks["settingsHasUnifiedToolbar"] = window.toolbar != nil && window.toolbarStyle == .unified
        checks["settingsOpensOnGeneral"] = controller.selectedPane == .general && controller.currentPane is GeneralSettingsPane

        // Sidebar
        let panes = controller.sidebarPanes
        checks["sidebarListsEveryProvider"] = ProviderID.allCases.allSatisfy { panes.contains(.provider($0)) }
        checks["sidebarListsEveryResearchGuide"] = ConnectionResearch.entries.allSatisfy { panes.contains(.entry(.research($0.name))) }
        checks["sidebarListsCustomConnections"] = panes.contains(.provider(custom))
        let rowsAboveGuides = controller.sidebar.rows.prefix { $0 != .header("Guides") }
        var addCustomEndsSetUp = false
        if case .item(let item) = rowsAboveGuides.last { addCustomEndsSetUp = item.pane == .addCustom }
        checks["sidebarStartsWithGeneralAddCustomAboveGuides"] = panes.first == .general && addCustomEndsSetUp
        checks["sidebarShowsEachPaneOnce"] = Set(panes).count == panes.count
        func headers() -> [String] { controller.sidebar.rows.compactMap { if case .header(let title) = $0 { return title } else { return nil } } }
        checks["sidebarBeforeDataHasSetUpAndGuides"] = headers() == ["Set up", "Guides"]

        // Visiting every pane performs no credential, network or subprocess work.
        for pane in panes { controller.select(pane) }
        checks["openingPanesReadsNoCredential"] = probe.tokenReads == 0 && probe.copilotWrites.isEmpty && probe.tokenWrites == 0
            && probe.apiKeyWrites == 0 && probe.createdProfiles == 0
        checks["openingPanesRunsNoCheckOrRequest"] = refreshes.isEmpty && connectionRefreshes == 0 && probe.tests.isEmpty
            && probe.opened.isEmpty && probe.copied.isEmpty && settingsChanges == 0

        // Guides never ask for keys and stay truthful.
        var guidesHaveNoFields = true, guidesTruthful = true, guideLinksHTTPS = true
        for entry in ConnectionCatalog.research + ConnectionCatalog.builtIn.filter(\.isGuide) {
            controller.select(.entry(entry.id))
            guard let pane = controller.currentPane as? GuideSettingsPane else { guidesTruthful = false; continue }
            let fields = allSubviews(of: pane.view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            if !fields.isEmpty || allSubviews(of: pane.view).contains(where: { $0 is NSSecureTextField }) { guidesHaveNoFields = false }
            if pane.header.statusLabel.stringValue != entry.guideStatus { guidesTruthful = false }
            checks["guideTruthful-\(entry.title)"] = pane.header.statusLabel.stringValue == entry.guideStatus
                && !allSubviews(of: pane.view).contains { $0 is NSSecureTextField }
                && (entry.details == nil || pane.more?.isExpanded == false)
            if (pane.docsButton != nil) != (entry.documentationURL != nil) { guideLinksHTTPS = false }
            if let url = entry.documentationURL, url.scheme != "https" { guideLinksHTTPS = false }
            if entry.provider != nil, pane.menuBar?.toggle.isEnabled != false { guidesTruthful = false }
        }
        checks["guidesExposeNoKeyField"] = guidesHaveNoFields
        checks["guidesShowTruthfulStatusAndNoPinWithoutData"] = guidesTruthful
        checks["guideDocumentationIsHTTPSOnly"] = guideLinksHTTPS

        // Live data
        controller.updateConnectionStates(qaStates(now: probe.now, custom: custom))
        checks["sidebarGroupsConnectedSetUpGuides"] = headers() == ["Connected", "Set up", "Guides"]
        let values = Dictionary(controller.sidebar.items.map { ($0.pane, $0.accessory) }, uniquingKeysWith: { first, _ in first })
        checks["sidebarShowsCompactValues"] = values[.provider(.claude)] == .value("49%", attention: false)
            && values[.provider(.runpod)] == .value("$23.46", attention: false) && values[.provider(.kie)] == .value("12.3K cr", attention: false)
        checks["sidebarLabelsGuides"] = values[.provider(.gemini)] == .tag("Guide")
            && values[.entry(.research("Cursor"))] == .tag("Guide")

        // Codex
        controller.select(.provider(.codex))
        if let pane = controller.currentPane as? ProviderSettingsPane, let codex = pane.setup as? CodexSetupSection {
            checks["codexHasOpenChatGPTAndCheckNow"] = buttonTitles(in: pane.view).contains("Open ChatGPT") && pane.checkButton.title == "Check now"
                && visibleText(in: pane.view).contains("UsageRail detects it automatically")
            checks["providerHeaderShowsLiveStatus"] = pane.header.statusLabel.stringValue.hasPrefix("Connected · 72% left · Updated ")
            codex.openButton.performClick(nil)
            checks["codexMissingAppIsReportedInline"] = probe.opened.isEmpty
                && controller.message(for: .codex)?.text.contains("isn't in your Applications folder") == true
            pane.checkButton.performClick(nil)
            checks["checkNowRefreshesThatProvider"] = refreshes == [.codex] && controller.message(for: .codex)?.text == "Checking…"
        } else { checks["codexHasOpenChatGPTAndCheckNow"] = false }

        // Claude
        controller.select(.provider(.claude))
        if let pane = controller.currentPane as? ProviderSettingsPane, let claude = pane.setup as? ClaudeSetupSection {
            checks["claudeShowsConfiguredProfile"] = claude.profileRow.subtitle == (profile.path as NSString).abbreviatingWithTildeInPath
            checks["claudeHasProfileLoginAndCheckActions"] = buttonTitles(in: pane.view).contains("Choose profile…")
                && buttonTitles(in: pane.view).contains("Copy login command") && !buttonTitles(in: pane.view).contains("Copy UsageBridge path")
            claude.copyLoginButton.performClick(nil)
            checks["claudeCopiesExactLoginCommandOnly"] = probe.copied == [
                "CLAUDE_CONFIG_DIR='/Users/qa/Library/Application Support/UsageRail/Claude'\\''s usage profile' /opt/homebrew/bin/claude auth login"
            ]
            checks["claudeHidesCreateWhenConfigured"] = claude.createButton.isHidden
            probe.launcher = nil
            claude.copyLoginButton.performClick(nil)
            checks["claudeMissingCLIIsReportedInline"] = probe.copied.count == 1
                && controller.message(for: .claude)?.text.hasPrefix("Claude Code isn't installed") == true
            probe.launcher = URL(fileURLWithPath: "/Users/qa/.local/bin/claude")
            probe.profile = nil
            claude.reloadProfile()
            checks["claudeOffersCreateWithoutProfile"] = !claude.createButton.isHidden && !claude.copyLoginButton.isEnabled
                && buttonTitles(in: pane.view).contains("Create profile")
            claude.createButton.performClick(nil)
            checks["claudeCreateSelectsNewProfileWithoutSigningIn"] = probe.createdProfiles == 1 && claude.createButton.isHidden
                && claude.profileRow.subtitle == "/Users/qa/Library/Application Support/UsageRail/Claude usage profile"
                && claude.copyLoginButton.isEnabled && refreshes == [.codex]
                && controller.message(for: .claude)?.text.hasPrefix("Profile created") == true
            claude.copyLoginButton.performClick(nil)
            checks["claudeLoginUsesInstalledLauncher"] = probe.copied.last
                == "CLAUDE_CONFIG_DIR='/Users/qa/Library/Application Support/UsageRail/Claude usage profile' /Users/qa/.local/bin/claude auth login"
            probe.profile = profile
            claude.reloadProfile()
            claude.more.toggle.performClick(nil)
            claude.copyBridgeButton.performClick(nil)
            checks["claudeBridgePathLivesUnderMore"] = claude.more.isExpanded
                && probe.copied.last == "/Applications/UsageRail.app/Contents/MacOS/UsageBridge"
        } else { checks["claudeShowsConfiguredProfile"] = false }

        // Kie / Runpod key setup against the probe's stand-in Keychain
        controller.select(.provider(.runpod))
        if let pane = controller.currentPane as? ProviderSettingsPane, let keys = pane.setup as? APIKeySetupSection {
            checks["keyPaneStartsWithConnect"] = !keys.hasSavedKey && !keys.keyRow.isHidden && !keys.connectButton.isHidden
                && keys.savedRow.isHidden && keys.getKeyButton.title == "Get API key"
            refreshes = []
            keys.keyField.stringValue = "synthetic_ui_fixture_123456789"
            keys.connectButton.performClick(nil)
            checks["keyFirstSaveGoesOnlyToItsKeychainItem"] = probe.apiKeys == [.runpod: "synthetic_ui_fixture_123456789"]
                && probe.apiKeyWrites == 1
            checks["keySaveClearsFieldAndChecksOnce"] = keys.keyField.stringValue.isEmpty && refreshes == [.runpod]
            checks["savedKeyIsNotClaimedConnected"] = controller.message(for: .runpod)?.tone == .progress
                && controller.message(for: .runpod)?.text.contains("Checking") == true
            checks["savedKeyFlipsPaneToReplaceKey"] = keys.hasSavedKey && !keys.savedRow.isHidden && !keys.replaceButton.isHidden
                && keys.keyRow.isHidden && keys.connectButton.isHidden
            let old = UsageSnapshot(provider: .runpod, windows: [], updatedAt: .distantPast, source: .runpodAPI, creditBalance: 99, balanceUnit: .usd)
            controller.updateConnectionStates([ProviderState(provider: .runpod, status: .fresh, snapshot: old)])
            checks["newKeyDoesNotClaimOldBalanceAsSuccess"] = controller.message(for: .runpod)?.text.hasPrefix("Connected") == false
            controller.updateConnectionStates([ProviderState(provider: .runpod, status: .refreshing, snapshot: old)])
            controller.updateConnectionStates([ProviderState(provider: .runpod, status: .loginRequired, snapshot: old, message: "401")])
            checks["failedConnectionShowsNextAction"] = controller.message(for: .runpod)?.text == "Credential missing or rejected. Check it below, then try again."
            keys.replaceButton.performClick(nil)
            checks["replaceKeyRevealsSecureField"] = !keys.keyRow.isHidden && !keys.saveReplacementButton.isHidden && keys.keyRow.title == "New key"
            keys.keyField.stringValue = "synthetic_ui_replacement_123456789"
            probe.now = Date()
            keys.saveReplacementButton.performClick(nil)
            checks["explicitReplaceChangesKey"] = probe.apiKeys[.runpod] == "synthetic_ui_replacement_123456789"
                && keys.keyField.stringValue.isEmpty && refreshes == [.runpod, .runpod] && keys.keyRow.isHidden
            let zero = UsageSnapshot(provider: .runpod, windows: [], updatedAt: probe.now.addingTimeInterval(1), source: .runpodAPI,
                                     creditBalance: 0, balanceUnit: .usd)
            controller.updateConnectionStates([ProviderState(provider: .runpod, status: .fresh, snapshot: zero)])
            checks["newBalanceConfirmsConnectionIncludingZero"] = controller.message(for: .runpod) == .success("Connected · $0.00")
        } else { checks["keyPaneStartsWithConnect"] = false }

        controller.select(.provider(.kie))
        if let pane = controller.currentPane as? ProviderSettingsPane, let keys = pane.setup as? APIKeySetupSection {
            // Another writer saves a key while this pane still offers Connect.
            probe.apiKeys[.kie] = "synthetic_original_kie_123456"
            refreshes = []
            keys.keyField.stringValue = "synthetic_second_kie_1234567"
            keys.connectButton.performClick(nil)
            checks["secondSaveWithoutReplaceKeepsOriginal"] = probe.apiKeys[.kie] == "synthetic_original_kie_123456"
                && refreshes.isEmpty && controller.message(for: .kie)?.text == "A key is already saved. Use Replace key… to change it."
            checks["existingKeyFlipsPaneToReplaceKey"] = keys.hasSavedKey && !keys.replaceButton.isHidden && keys.keyRow.isHidden
                && keys.keyField.stringValue.isEmpty
            keys.replaceButton.performClick(nil)
            keys.keyField.stringValue = "discard_on_switch_123456789"
            let field = keys.keyField
            controller.select(.general)
            checks["switchingPanesDiscardsKeyInput"] = field.stringValue.isEmpty
            checks["switchingPanesDropsInputErrors"] = controller.message(for: .kie) == nil
                && controller.message(for: .runpod) == .success("Connected · $0.00")
        } else { checks["secondSaveWithoutReplaceKeepsOriginal"] = false }

        // Menu-bar pins: at most 3, at least 1, persisted immediately.
        controller.updateConnectionStates(qaStates(now: probe.now, custom: custom))
        settingsChanges = 0
        controller.select(.provider(.codex))
        if let pane = controller.currentPane as? ProviderSettingsPane {
            checks["lastMenuBarItemCannotBeRemoved"] = pane.menuBar.toggle.state == .on && !pane.menuBar.toggle.isEnabled
                && pane.menuBar.toggle.toolTip?.contains("always keeps one item") == true
            toggle(pane.menuBar.toggle, to: .off)
            checks["lastMenuBarItemSurvivesToggleAttempt"] = store.load().menuBarProviders == [.codex] && pane.menuBar.toggle.state == .on
                && settingsChanges == 0
        }
        for provider in [ProviderID.claude, .kie] {
            controller.select(.provider(provider))
            if let pane = controller.currentPane as? ProviderSettingsPane { toggle(pane.menuBar.toggle, to: .on) }
        }
        checks["menuBarSwitchPinsAndPersists"] = store.load().menuBarProviders == [.codex, .claude, .kie] && settingsChanges == 2
        controller.select(.provider(.runpod))
        if let pane = controller.currentPane as? ProviderSettingsPane {
            let warned = pane.menuBar.switchRow.subtitle?.contains("replaces ChatGPT") == true
            toggle(pane.menuBar.toggle, to: .on)
            checks["menuBarSwitchReplacesOldestAtThree"] = warned && store.load().menuBarProviders == [.claude, .kie, .runpod]
                && pane.menuBar.note.message?.text == "Replaced ChatGPT in the menu bar."
            toggle(pane.menuBar.toggle, to: .off)
        }
        controller.select(.provider(.kie))
        if let pane = controller.currentPane as? ProviderSettingsPane { toggle(pane.menuBar.toggle, to: .off) }
        controller.select(.provider(.claude))
        if let pane = controller.currentPane as? ProviderSettingsPane {
            checks["menuBarSwitchUnpinsDownToOne"] = store.load().menuBarProviders == [.claude] && !pane.menuBar.toggle.isEnabled
            // Limit choice: Claude has two limits, so "Number shown" is offered.
            checks["limitPickerOfferedForSeveralLimits"] = !pane.menuBar.limitRow.isHidden && pane.menuBar.limitPopup.numberOfItems == 3
            if let week = pane.menuBar.limitPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == "seven-day" }) {
                pane.menuBar.limitPopup.selectItem(at: week)
                pane.menuBar.limitPopup.sendAction(pane.menuBar.limitPopup.action, to: pane.menuBar.limitPopup.target)
            }
            checks["limitPickerPersistsChoice"] = store.load().limitSelection(for: .claude) == "seven-day"
                && pane.header.statusLabel.stringValue.hasPrefix("Connected · 49% left")
        }
        controller.select(.provider(.gemini))
        checks["menuBarSwitchNeedsConnection"] = (controller.currentPane as? GuideSettingsPane)?.menuBar?.toggle.isEnabled == false

        // General pane
        controller.select(.general)
        if let general = controller.currentPane as? GeneralSettingsPane {
            checks["generalListsWhatEachItemShows"] = general.pinModel == [
                GeneralSettingsPane.PinRow(provider: .claude, shows: "Rolling 7 days", value: "49%", canRemove: false)
            ]
            checks["generalRemoveDisabledForLastItem"] = general.removeButtons[.claude]?.isEnabled == false
            checks["generalAddOffersConnectedUnpinned"] = general.addButton.isEnabled
                && general.addCandidates == [.codex, .kie, .runpod, custom]
            for provider in [ProviderID.codex, .kie] {
                if let index = general.addButton.itemArray.firstIndex(where: { ($0.representedObject as? String) == provider.rawValue }) {
                    general.addButton.selectItem(at: index)
                    general.addButton.sendAction(general.addButton.action, to: general.addButton.target)
                }
            }
            checks["generalAddPinsFromMenu"] = store.load().menuBarProviders == [.claude, .codex, .kie]
            checks["generalAddDisabledWhenFull"] = !general.addButton.isEnabled && general.addButton.toolTip?.contains("up to 3") == true
            general.removeButtons[.kie]?.performClick(nil)
            checks["generalRemoveUnpins"] = store.load().menuBarProviders == [.claude, .codex] && general.addButton.isEnabled
            // Regular is the default, so choose Clear first and then return to Regular.
            let startsRegular = general.glassControl.selectedSegment == 1
            general.glassControl.selectedSegment = 0
            general.glassControl.sendAction(general.glassControl.action, to: general.glassControl.target)
            let clear = store.load().glassStyle == .clear
            general.glassControl.selectedSegment = 1
            general.glassControl.sendAction(general.glassControl.action, to: general.glassControl.target)
            checks["glassStylePersists"] = startsRegular && clear && store.load().glassStyle == .regular
            toggle(general.launchSwitch, to: .on)
            checks["launchAtLoginUsesService"] = probe.launchEnabled && general.launchMessage.isHidden
            toggle(general.launchSwitch, to: .off)
            let refreshText = visibleText(in: general.view)
            checks["refreshCopyMatchesPolicy"] = refreshText.contains("ChatGPT every 5 min, others every 15 min.")
                && refreshText.contains("ChatGPT every 15 min, others every 30 min.") && refreshText.contains("at most every 5 min")
                && !refreshText.contains("30 sec") && refreshText.contains("sleeps")
        } else { checks["generalListsWhatEachItemShows"] = false }
        checks["everySettingsChangeWasReported"] = settingsChanges == 11

        // Copilot
        controller.select(.provider(.copilot))
        if let pane = controller.currentPane as? ProviderSettingsPane, let copilot = pane.setup as? CopilotSetupSection {
            refreshes = []
            copilot.usernameField.stringValue = "octo-cat"
            copilot.allowanceField.stringValue = "-5"
            copilot.tokenField.stringValue = "synthetic_copilot_token_1234"
            copilot.saveButton.performClick(nil)
            checks["copilotRejectsInvalidAllowanceInline"] = probe.copilotWrites.isEmpty && store.load().githubUsername.isEmpty
                && controller.message(for: .copilot)?.tone == .error && refreshes.isEmpty
                && pane.message.message?.tone == .error
            copilot.allowanceField.stringValue = "300"
            copilot.saveButton.performClick(nil)
            checks["copilotTokenGoesOnlyToItsKeychainAccount"] = probe.copilotWrites == ["synthetic_copilot_token_1234"]
                && probe.tokens.keys.sorted() == ["github-plan-read"] && copilot.tokenField.stringValue.isEmpty
            let saved = store.load()
            checks["copilotSavePersistsAndChecks"] = saved.githubUsername == "octo-cat" && saved.githubAllowance == 300 && refreshes == [.copilot]
            copilot.saveButton.performClick(nil)
            checks["copilotBlankTokenKeepsSavedToken"] = probe.copilotWrites.count == 1 && refreshes == [.copilot, .copilot]
            // GitHub answered, but without an allowance there is no number: say so instead of "Connected".
            let noNumber = UsageSnapshot(provider: .copilot, windows: [UsageWindow(id: "current-month", title: "Current month",
                                                                                   usedPercent: nil, used: 12)],
                                         updatedAt: probe.now.addingTimeInterval(1), source: .githubREST)
            var withCopilot = qaStates(now: probe.now, custom: custom)
            withCopilot.removeAll { $0.provider == .copilot }
            withCopilot.append(ProviderState(provider: .copilot, status: .fresh, snapshot: noNumber))
            controller.updateConnectionStates(withCopilot)
            checks["copilotWithoutAllowanceExplainsMissingNumber"] = controller.message(for: .copilot)?.tone == .warning
                && controller.message(for: .copilot)?.text.contains("monthly allowance") == true
                && pane.header.statusLabel.stringValue == "Connected · add your monthly allowance to see what's left"

            // Live updates must not lose the selection or what the user is typing.
            copilot.usernameField.stringValue = "still-typing"
            let field = copilot.usernameField
            var moved = qaStates(now: probe.now, custom: custom)
            moved.removeAll { $0.provider == .kie }
            moved.append(ProviderState(provider: .kie, status: .loginRequired, snapshot: nil, message: "rejected"))
            controller.updateConnectionStates(moved)
            let current = (controller.currentPane as? ProviderSettingsPane)?.setup as? CopilotSetupSection
            checks["statusUpdatesKeepSelection"] = controller.selectedPane == .provider(.copilot)
                && controller.sidebar.selectedPane == .provider(.copilot)
                && controller.sidebar.rows.contains(.header("Set up"))
            checks["statusUpdatesKeepTypedText"] = current === copilot && field.stringValue == "still-typing"
        } else { checks["copilotRejectsInvalidAllowanceInline"] = false }

        // Esc closes; closing discards any typed secret.
        controller.select(.provider(.kie))
        if let pane = controller.currentPane as? ProviderSettingsPane, let keys = pane.setup as? APIKeySetupSection {
            keys.replaceButton.performClick(nil)
            keys.keyField.stringValue = "not-a-real-token-qa"
            window.cancelOperation(nil)
            checks["settingsEscapeCloses"] = closes == 1
            checks["settingsCloseDiscardsPendingKey"] = keys.keyField.stringValue.isEmpty
        } else { checks["settingsEscapeCloses"] = false }
        checks["qaNeverReadsAKeyBack"] = probe.tokenReads == 0 && probe.tests.isEmpty
        checks["settingsWindowStayedHidden"] = !window.isVisible && !window.isKeyWindow
        return checks
    }

    // MARK: - Custom API QA

    static func runCustomConnectionQA() async throws -> [String: Bool] {
        guard let defaults = UserDefaults(suiteName: qaSuiteName) else { return ["qaDefaultsSuiteAvailable": false] }
        let original = defaults.persistentDomain(forName: qaSuiteName)
        defaults.removePersistentDomain(forName: qaSuiteName)
        defer { restoreQADefaults(defaults, to: original) }
        let probe = SettingsQAProbe()
        let store = SettingsStore(defaults: defaults)
        let controller = SettingsWindowController(settings: store.load(), settingsStore: store,
                                                  environment: qaEnvironment(defaults: defaults, probe: probe, profile: nil))
        var connectionRefreshes = 0, settingsChanges = 0
        controller.onRefreshConnections = { connectionRefreshes += 1 }
        controller.onSettingsChanged = { _ in settingsChanges += 1 }
        func settle() async { if let task = controller.customTask { await task.value } }
        func entries() -> [CustomConnection] { CustomConnection.load(defaults: defaults) }
        var checks: [String: Bool] = [:]

        // Add
        controller.select(.addCustom)
        guard let add = controller.currentPane as? AddCustomAPIPane else { return ["customAddPaneExists": false] }
        add.form.nameField.stringValue = "QA Web"
        add.form.endpointField.stringValue = "https://api.example.com/balance"
        add.form.pointerField.stringValue = "/credits"
        add.form.tokenField.stringValue = "synthetic_qa_token"
        add.testButton.performClick(nil)
        await settle()
        checks["customRequiresExplicitEndpointApproval"] = probe.tests.isEmpty && entries().isEmpty
            && add.message.message?.tone == .error
        checks["customWindowRemainsHidden"] = controller.window?.isVisible == false
        checks["customHasNativeClose"] = controller.window?.standardWindowButton(.closeButton)?.isEnabled == true
        add.approval.state = .on
        add.testButton.performClick(nil)
        await settle()
        guard let added = entries().first else { return checks.merging(["customTestAndAddCallsOnce": false]) { _, new in new } }
        checks["customTestAndAddCallsOnce"] = probe.tests.count == 1 && entries().count == 1 && connectionRefreshes == 1
        checks["customTestUsesTypedToken"] = probe.tests.first?.token == "synthetic_qa_token"
        checks["customTokenStoredOnlyInKeychain"] = probe.tokens == [added.provider.rawValue: "synthetic_qa_token"]
            && !(String(data: defaults.data(forKey: "customConnections") ?? Data(), encoding: .utf8) ?? "").contains("synthetic_qa_token")
        checks["customSuccessClearsSecret"] = add.form.tokenField.stringValue.isEmpty && add.approval.state == .off
        checks["customSuccessSelectsNewProvider"] = controller.selectedPane == .provider(added.provider)
            && controller.sidebarPanes.contains(.provider(added.provider))
        checks["customSuccessReportsRealNumber"] = controller.message(for: added.provider)?.text.contains("42 cr") == true

        // A failed test saves nothing; a failed entry save rolls the token back.
        controller.select(.addCustom)
        guard let retry = controller.currentPane as? AddCustomAPIPane else { return checks }
        retry.form.nameField.stringValue = "QA Two"
        retry.form.endpointField.stringValue = "https://api.example.org/usage"
        retry.form.pointerField.stringValue = "/credits"
        retry.form.tokenField.stringValue = "synthetic_second_token"
        retry.approval.state = .on
        probe.testResult = { _ in throw ConnectorError.loginRequired("Synthetic rejection") }
        retry.testButton.performClick(nil)
        await settle()
        checks["customFailedTestDoesNotSave"] = entries().count == 1 && connectionRefreshes == 1 && probe.tokens.count == 1
            && retry.message.message?.text == "Synthetic rejection" && controller.selectedPane == .addCustom
        probe.testResult = { try $0.snapshot(from: Data(#"{"credits":7}"#.utf8)) }
        probe.failNextEntrySave = true
        retry.testButton.performClick(nil)
        await settle()
        checks["customFailedSaveRollsBackToken"] = entries().count == 1 && probe.tokens.count == 1 && connectionRefreshes == 1
        let testsBeforeBlank = probe.tests.count
        retry.form.tokenField.stringValue = ""
        retry.testButton.performClick(nil)
        await settle()
        checks["customBlankTokenIsCaughtBeforeTesting"] = probe.tests.count == testsBeforeBlank
            && retry.message.message?.text == "Paste the API token, or set Authentication to None."
        retry.form.tokenField.stringValue = "synthetic_second_token"
        retry.explainMCP()
        checks["customMCPDoesNotPretendSupport"] = retry.message.message?.text.contains("isn't enabled") == true
        let full = try (0..<20).map { index in
            try CustomConnection(provider: requireQAValue(ProviderID.custom(name: "Filler \(index)")), endpoint: "https://api.example.com/\(index)",
                                 pointer: "/v", metric: .credits, authentication: .none)
        }
        let beforeFull = entries()
        try CustomConnection.save(full, defaults: defaults)
        let testsBeforeLimit = probe.tests.count
        retry.testButton.performClick(nil)
        await settle()
        checks["customLimitOfTwenty"] = probe.tests.count == testsBeforeLimit && retry.message.message?.text.contains("20") == true
        try CustomConnection.save(beforeFull, defaults: defaults)
        retry.form.tokenField.stringValue = "discard"
        controller.window?.performClose(nil)
        checks["customCloseClearsSecret"] = retry.form.tokenField.stringValue.isEmpty

        // Edit: same ProviderID and position; blank token tests with the saved one.
        let second = try CustomConnection(provider: requireQAValue(ProviderID.custom(name: "QA Second")), endpoint: "https://api.example.net/b",
                                          pointer: "/b", metric: .usd, authentication: .none)
        try CustomConnection.save([added, second], defaults: defaults)
        controller.updateConnectionStates([])
        controller.select(.provider(added.provider))
        guard let pane = controller.currentPane as? ProviderSettingsPane, let section = pane.setup as? CustomSetupSection else {
            return checks.merging(["customEditPaneExists": false]) { _, new in new }
        }
        checks["customSummaryShowsConfiguration"] = section.endpointRow.subtitle == "GET https://api.example.com/balance"
            && section.valueRow.subtitle == "/credits · Credits · scale 1" && section.authRow.subtitle?.hasPrefix("Bearer token") == true
        section.editButton.performClick(nil)
        checks["customEditPrefillsForm"] = section.isEditing && section.form.endpointField.stringValue == added.endpoint
            && section.form.pointerField.stringValue == "/credits" && section.form.scaleField.stringValue == "1"
            && section.form.authentication == .bearer && section.form.metric == .credits && section.form.tokenField.stringValue.isEmpty
        checks["customEditNameIsReadOnly"] = section.form.nameField.superview == nil
            && !allSubviews(of: pane.view).contains { ($0 as? NSTextField)?.isEditable == true && ($0 as? NSTextField)?.stringValue == "QA Web" }
        section.form.pointerField.stringValue = "/data/credits"
        section.form.scaleField.stringValue = "0.5"
        probe.testResult = { try $0.snapshot(from: Data(#"{"data":{"credits":84}}"#.utf8)) }
        let writesBefore = probe.tokenWrites
        section.saveButton.performClick(nil)
        await settle()
        let edited = entries()
        checks["customEditBlankTokenTestsWithSavedToken"] = probe.tests.last?.token == "synthetic_qa_token" && probe.tokenReads == 1
        checks["customEditKeepsProviderIDAndPosition"] = edited.map(\.provider) == [added.provider, second.provider]
            && edited.first?.pointer == "/data/credits" && edited.first?.multiplier == 0.5 && edited.last == second
        checks["customEditBlankTokenLeavesKeychain"] = probe.tokenWrites == writesBefore && probe.tokens[added.provider.rawValue] == "synthetic_qa_token"
        checks["customEditRefreshesAndReturnsToSummary"] = connectionRefreshes == 2 && !section.isEditing
            && section.valueRow.subtitle == "/data/credits · Credits · scale 0.5"
            && controller.message(for: added.provider)?.text == "Saved · 42 cr"
        section.editButton.performClick(nil)
        section.form.tokenField.stringValue = "synthetic_new_token"
        section.saveButton.performClick(nil)
        await settle()
        checks["customEditWritesTypedTokenAfterTest"] = probe.tests.last?.token == "synthetic_new_token"
            && probe.tokens[added.provider.rawValue] == "synthetic_new_token" && probe.tokenWrites == writesBefore + 1
            && section.form.tokenField.stringValue.isEmpty
        section.editButton.performClick(nil)
        section.form.pointerField.stringValue = "/missing"
        probe.testResult = { _ in throw ConnectorError.malformedResponse("The usage field was not found.") }
        section.saveButton.performClick(nil)
        await settle()
        checks["customFailedEditChangesNothing"] = entries().first?.pointer == "/data/credits" && section.isEditing
            && controller.message(for: added.provider)?.tone == .error
        section.cancelButton.performClick(nil)

        // Remove: token and entry go, the pin falls back to ChatGPT when it was the only one.
        var pinned = store.load()
        pinned.setMenuBarProviders([added.provider])
        pinned.selectLimit("custom-quota", for: added.provider)
        store.save(pinned)
        controller.applyExternalSettings(pinned)
        probe.confirmRemoval = false
        section.removeButton.performClick(nil)
        checks["customRemoveCanBeCancelled"] = entries().count == 2 && probe.tokens[added.provider.rawValue] != nil
        probe.confirmRemoval = true
        let changesBefore = settingsChanges
        section.removeButton.performClick(nil)
        let after = store.load()
        checks["customRemoveDeletesTokenAndEntry"] = entries() == [second] && probe.tokens[added.provider.rawValue] == nil
        checks["customRemoveUnpinsFallingBackToChatGPT"] = after.menuBarProviders == [.codex] && after.limitSelection(for: added.provider) == nil
            && settingsChanges == changesBefore + 1
        checks["customRemoveRefreshesAndReturnsToGeneral"] = connectionRefreshes == 4 && controller.selectedPane == .general
            && !controller.sidebarPanes.contains(.provider(added.provider))
        checks["customQANeverShowsAWindow"] = controller.window?.isVisible == false && !NSApp.windows.contains { $0.isVisible }
        return checks
    }

    // MARK: - Renders

    /// Offscreen light/dark renders of the main panes. Glass is not captured; layout is.
    static func renderPanesForQA(defaults: UserDefaults, to directory: URL) throws -> [String: Bool] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = SettingsQAProbe()
        let store = SettingsStore(defaults: defaults)
        let custom = try requireQAValue(ProviderID.custom(name: "Acme AI"))
        try CustomConnection.save([CustomConnection(provider: custom, endpoint: "https://api.acme.example.com/v1/account/balance",
                                                    pointer: "/data/credits", metric: .credits, authentication: .bearer)], defaults: defaults)
        var settings = store.load()
        settings.setMenuBarProviders([.codex, .claude])
        settings.selectLimit("seven-day", for: .claude)
        store.save(settings)
        probe.apiKeys[.runpod] = "synthetic_render_fixture_123456"
        let profile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UsageRail/claude-usage")
        let controller = SettingsWindowController(settings: store.load(), settingsStore: store,
                                                  environment: qaEnvironment(defaults: defaults, probe: probe, profile: profile))
        controller.updateConnectionStates(qaStates(now: probe.now, custom: custom))
        var written = 0
        let panes: [(SettingsPaneID, String)] = [(.general, "general"), (.provider(.claude), "claude"), (.provider(.kie), "kie"),
                                                 (.provider(.runpod), "runpod-saved-key"), (.provider(.copilot), "copilot"),
                                                 (.provider(.codex), "codex"), (.provider(custom), "custom-existing"),
                                                 (.addCustom, "custom-add"), (.entry(.research("Grok · xAI API")), "guide")]
        let variants: [(SettingsPaneID, String, () -> Void)] = [
            (.provider(.runpod), "runpod-replacing", {
                ((controller.currentPane as? ProviderSettingsPane)?.setup as? APIKeySetupSection)?.replaceButton.performClick(nil)
            }),
            (.provider(.copilot), "copilot-error", {
                guard let copilot = (controller.currentPane as? ProviderSettingsPane)?.setup as? CopilotSetupSection else { return }
                copilot.usernameField.stringValue = "octocat"
                copilot.allowanceField.stringValue = "lots"
                copilot.saveButton.performClick(nil)
            }),
            (.provider(.claude), "claude-more", {
                ((controller.currentPane as? ProviderSettingsPane)?.setup as? ClaudeSetupSection)?.more.setExpanded(true)
            }),
            (.provider(.claude), "claude-new", {
                probe.profile = nil
                ((controller.currentPane as? ProviderSettingsPane)?.setup as? ClaudeSetupSection)?.reloadProfile()
            }),
            (.entry(.research("Grok · xAI API")), "custom-template", {
                (controller.currentPane as? GuideSettingsPane)?.templateButton?.performClick(nil)
            })
        ]
        for (pane, name, prepare) in variants {
            controller.select(pane, rebuild: true)
            prepare()
            for dark in [false, true] {
                if try render(controller, to: directory.appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"), dark: dark) {
                    written += 1
                }
            }
        }
        probe.profile = profile
        for (pane, name) in panes {
            controller.select(pane, rebuild: true)
            for dark in [false, true] {
                if try render(controller, to: directory.appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"), dark: dark) {
                    written += 1
                }
            }
        }
        // Smallest allowed window: nothing may clip or overlap.
        controller.window?.setContentSize(NSSize(width: 680, height: 460))
        let compact: [(SettingsPaneID, String)] = [(.general, "general-min"), (.addCustom, "custom-add-min"), (.provider(.copilot), "copilot-min")]
        for (pane, name) in compact {
            controller.select(pane, rebuild: true)
            if try render(controller, to: directory.appendingPathComponent("settings-\(name)-light.png"), dark: false) { written += 1 }
        }
        controller.window?.setContentSize(NSSize(width: 760, height: 540))
        controller.window?.appearance = nil
        return ["settingsRendersWritten": written == (panes.count + variants.count) * 2 + compact.count]
    }

    /// Offscreen capture cannot draw macOS 26 glass or scroll-edge views, so the render is composed
    /// from what it can draw: the sidebar rows and the pane, at their real window positions.
    private static func render(_ controller: SettingsWindowController, to url: URL, dark: Bool) throws -> Bool {
        guard let window = controller.window, let content = window.contentView,
              let appearance = NSAppearance(named: dark ? .darkAqua : .aqua),
              let scroll = controller.currentPane?.view as? NSScrollView, let document = scroll.documentView else { return false }
        window.appearance = appearance
        content.layoutSubtreeIfNeeded()
        document.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        func snapshot(_ view: NSView, _ rect: NSRect) -> NSImage? {
            guard !rect.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: rect, to: rep) }
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            return image
        }
        func write(size: NSSize, to destination: URL, draw: () -> Void) throws -> Bool {
            guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
            // Size first: the context must draw in points, not pixels.
            output.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: output) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance(draw)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = output.representation(using: .png, properties: [:]) else { return false }
            try data.write(to: destination)
            return true
        }
        let table = controller.sidebar.tableView
        let tableVisible = table.visibleRect
        let documentVisible = document.visibleRect
        let wroteWindow = try write(size: bounds.size, to: url) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            // Stand-in for the floating glass sidebar and toolbar controls.
            let sidebar = controller.sidebar.view.convert(controller.sidebar.view.bounds, to: content)
            NSColor(white: dark ? 1 : 1, alpha: dark ? 0.08 : 0.55).setFill()
            NSBezierPath(roundedRect: sidebar, xRadius: 18, yRadius: 18).fill()
            NSColor(white: dark ? 1 : 0, alpha: 0.08).setStroke()
            NSBezierPath(roundedRect: sidebar.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18).stroke()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: sidebar.minX + 12 + CGFloat(index) * 23, y: bounds.maxY - 34, width: 14, height: 14)).fill()
            }
            snapshot(table, tableVisible)?.draw(in: table.convert(tableVisible, to: content))
            snapshot(document, documentVisible)?.draw(in: document.convert(documentVisible, to: content))
        }
        // Full-length pane, for reviewing everything below the fold.
        let wroteFull = try write(size: document.bounds.size, to: url.deletingPathExtension().appendingPathExtension("full.png")) {
            NSColor.windowBackgroundColor.setFill()
            document.bounds.fill()
            snapshot(document, document.bounds)?.draw(in: NSRect(origin: .zero, size: document.bounds.size))
        }
        return wroteWindow && wroteFull
    }
}

private struct QARequirementFailed: Error {}

/// `#require`-style unwrap for QA code outside the test target.
private func requireQAValue<T>(_ value: T?) throws -> T {
    guard let value else { throw QARequirementFailed() }
    return value
}
