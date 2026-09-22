import AppKit
import CoreServices
import Network
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private let keychain = KeychainStore.shared
    private var usageStore: UsageStore?
    private var cache: SnapshotCache?
    private var coordinator: RefreshCoordinator?
    private var menuBarController: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var bridgeMonitor: BridgeEventMonitor?
    private var backgroundRefreshTimer: Timer?
    private var backgroundTask: Task<Void, Never>?
    private var scheduleRevision = 0
    private var suspension = RefreshSuspension()
    private var pendingBridgeProviders: Set<ProviderID> = []
    private var bridgeDeliveryTask: Task<Void, Never>?
    private var hoverRefreshTask: Task<Void, Never>?
    private var pendingHoverProviders: [ProviderID] = []
    private let networkMonitor = NWPathMonitor()
    private var isDemo = false
    private var demoSettings: AppSettings?
    private let observationEnabled = ProcessInfo.processInfo.arguments.contains("--observe-refresh")
    private var observedUpdates: [ProviderID: Date] = [:]
    private var observedHoverCalls = 0
    private var observationStartedAt: Date?

    override init() {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--demo") }),
           let defaults = UserDefaults(suiteName: "com.usagerail.qa") {
            settingsStore = SettingsStore(defaults: defaults)
        } else {
            settingsStore = SettingsStore()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        isDemo = arguments.contains { $0.hasPrefix("--demo") }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchKind = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let isBackgroundLaunch = arguments.contains("--background")
            || launchKind == keyAELaunchedAsLogInItem || launchKind == keyAELaunchedAsServiceItem
        do {
            let store = UsageStore()
            let snapshotCache = try SnapshotCache()
            var connectors: [any UsageConnector] = [
                CodexConnector(),
                ClaudeConnector(),
                CopilotConnector(settings: { [settingsStore] in settingsStore.load() }, keychain: keychain),
                try LocalSnapshotConnector(provider: .antigravity),
                KieConnector(keychain: keychain),
                RunpodConnector(keychain: keychain)
            ]
            if !isDemo { connectors += CustomConnection.load().map { CustomUsageConnector(configuration: $0) } }
            let refreshCoordinator = RefreshCoordinator(connectors: connectors, store: store, cache: snapshotCache)
            let settings: AppSettings
            if isDemo {
                // Fixture data only; `--demo-pins=claude,codex` chooses the menu-bar items.
                let pins = arguments.first { $0.hasPrefix("--demo-pins=") }
                    .map { $0.dropFirst(12).split(separator: ",").compactMap { ProviderID(rawValue: String($0)) } } ?? []
                settings = AppSettings(
                    providerOrder: ProviderID.allCases,
                    selectedProvider: arguments.contains("--demo-runpod") ? .runpod : (arguments.contains("--demo-kie") ? .kie : .codex),
                    menuBarProviders: pins,
                    glassStyle: arguments.contains("--demo-regular-glass") ? .regular : .clear
                )
                demoSettings = settings
            } else {
                settings = settingsStore.load()
            }
            let menuBar = MenuBarController(settings: settings, autosavesPositions: !isDemo)

            usageStore = store
            cache = snapshotCache
            coordinator = refreshCoordinator
            menuBarController = menuBar

            menuBar.onRefresh = { [weak self] provider in self?.refresh(provider) }
            menuBar.onOpenSettings = { [weak self] provider in self?.openSettings(provider: provider) }
            menuBar.onHoverRefresh = { [weak self] providers in self?.refreshOnHover(providers) }
            menuBar.onSettingsChange = { [weak self] updated in
                guard let self else { return }
                if self.isDemo { self.demoSettings = updated } else { self.settingsStore.save(updated) }
                // An open Settings window must show (and never save back) the previous pins.
                self.settingsWindow?.applyExternalSettings(updated)
                self.scheduleBackgroundRefresh()
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(usageDidUpdate),
                name: .usageRailDidUpdate,
                object: nil
            )

            if arguments.contains("--demo-settings") || (!isDemo && !isBackgroundLaunch) {
                openSettings(provider: nil)
            }

            Task { [weak self] in
                guard let self else { return }
                if self.isDemo {
                    for snapshot in Self.demoSnapshots() { await store.apply(snapshot) }
                    await self.render()
                    if !arguments.contains("--demo-settings") {
                        try? await Task.sleep(for: .milliseconds(300))
                        self.applyDemoPresentation(arguments: arguments)
                    }
                } else {
                    await store.restore(await snapshotCache.load())
                    await self.render()
                    // Warm only the menu-bar items, one at a time. Everything else keeps cached
                    // values until it is looked at, avoiding a startup subprocess burst.
                    for provider in settings.menuBarProviders { await refreshCoordinator.refresh(provider) }
                    self.scheduleBackgroundRefresh()
                    if arguments.contains("--show-runpod") {
                        await self.render()
                        self.menuBarController?.showDetails(for: .runpod)
                    } else if arguments.contains("--show-codex") {
                        await self.render()
                        self.menuBarController?.showDetails(for: .codex)
                    }
                }
            }

            if !isDemo {
                let notifications = NSWorkspace.shared.notificationCenter
                for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                             NSWorkspace.sessionDidResignActiveNotification] {
                    notifications.addObserver(self, selector: #selector(refreshLifecycleChanged(_:)), name: name, object: nil)
                }
                for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                             NSWorkspace.sessionDidBecomeActiveNotification] {
                    notifications.addObserver(self, selector: #selector(refreshLifecycleChanged(_:)), name: name, object: nil)
                }
                NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged),
                                                       name: .NSProcessInfoPowerStateDidChange, object: nil)
                networkMonitor.pathUpdateHandler = { [weak self] path in
                    let online = path.status == .satisfied
                    Task { @MainActor in
                        guard let self else { return }
                        self.suspension.set(.offline, paused: !online)
                        await self.coordinator?.setNetworkPaused(!online)
                        self.scheduleBackgroundRefresh()
                    }
                }
                networkMonitor.start(queue: DispatchQueue(label: "com.usagerail.network", qos: .utility))
                bridgeMonitor = try? BridgeEventMonitor { [weak self] providers in
                    DispatchQueue.main.async {
                        self?.receiveBridgeEvents(providers)
                    }
                }
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "UsageRail could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundRefreshTimer?.invalidate()
        backgroundTask?.cancel()
        networkMonitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isDemo, let cache else { return .terminateNow }
        backgroundRefreshTimer?.invalidate()
        backgroundTask?.cancel()
        Task {
            await coordinator?.setAutomaticPaused(true)
            await cache.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func scheduleBackgroundRefresh() {
        scheduleRevision += 1
        let revision = scheduleRevision
        backgroundRefreshTimer?.invalidate()
        backgroundRefreshTimer = nil
        guard !isDemo, suspension.allowsNetwork, backgroundTask == nil, let coordinator else { return }
        let pinned = settingsStore.load().menuBarProviders
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task { [weak self] in
            let deadline = await coordinator.nextAutomaticRefresh(pinned: pinned, lowPower: lowPower)
            guard let self, self.scheduleRevision == revision, self.suspension.allowsNetwork,
                  self.backgroundTask == nil, let deadline else { return }
            let timer = Timer(fire: max(deadline, Date().addingTimeInterval(0.25)), interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refreshBackground() }
            }
            // These are quota/balance reads, not realtime telemetry. Let macOS coalesce the
            // wakeup with other work instead of forcing a precise timer firing.
            timer.tolerance = lowPower ? 60 : 15
            RunLoop.main.add(timer, forMode: .common)
            self.backgroundRefreshTimer = timer
        }
    }

    @objc private func refreshLifecycleChanged(_ notification: Notification) {
        guard !isDemo else { return }
        switch notification.name {
        case NSWorkspace.willSleepNotification: suspension.set(.systemSleep, paused: true)
        case NSWorkspace.didWakeNotification: suspension.set(.systemSleep, paused: false)
        case NSWorkspace.screensDidSleepNotification: suspension.set(.displaySleep, paused: true)
        case NSWorkspace.screensDidWakeNotification: suspension.set(.displaySleep, paused: false)
        case NSWorkspace.sessionDidResignActiveNotification: suspension.set(.sessionInactive, paused: true)
        case NSWorkspace.sessionDidBecomeActiveNotification: suspension.set(.sessionInactive, paused: false)
        default: return
        }
        if !suspension.allowsLocalEvents {
            backgroundTask?.cancel()
            menuBarController?.closeSurface()
        }
        scheduleBackgroundRefresh()
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator?.setAutomaticPaused(!self.suspension.allowsLocalEvents)
            if self.suspension.allowsLocalEvents {
                self.receiveBridgeEvents([])
                await self.render()
            }
            self.scheduleBackgroundRefresh()
        }
    }

    @objc private func powerStateChanged() { scheduleBackgroundRefresh() }

    private func refreshBackground() {
        backgroundRefreshTimer = nil
        guard !isDemo, suspension.allowsNetwork, backgroundTask == nil, let coordinator else { return }
        let pinned = settingsStore.load().menuBarProviders
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        backgroundTask = Task { [weak self] in
            await coordinator.refreshDue(pinned: pinned, lowPower: lowPower)
            guard let self else { return }
            self.backgroundTask = nil
            self.scheduleBackgroundRefresh()
        }
    }

    private func receiveBridgeEvents(_ providers: [ProviderID]) {
        pendingBridgeProviders.formUnion(providers)
        guard suspension.allowsLocalEvents, bridgeDeliveryTask == nil,
              !pendingBridgeProviders.isEmpty, let coordinator else { return }
        bridgeDeliveryTask = Task { [weak self] in
            guard let self else { return }
            // Events received during an in-flight read are drained again, never lost to deduplication.
            while self.suspension.allowsLocalEvents, !self.pendingBridgeProviders.isEmpty {
                let provider = self.pendingBridgeProviders.sorted { $0.rawValue < $1.rawValue }[0]
                self.pendingBridgeProviders.remove(provider)
                // Legacy events carry no account/profile identity. Never let a different
                // Claude session overwrite the quota of the explicitly selected profile.
                if provider == .claude && ClaudeConnector.hasProfileConfiguration { continue }
                if let connector = try? LocalSnapshotConnector(provider: provider),
                   let snapshot = try? await connector.refresh() {
                    await coordinator.applyLocalEvent(snapshot)
                }
            }
            self.bridgeDeliveryTask = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(provider: nil)
        return false
    }

    @objc private func usageDidUpdate() {
        Task { [weak self] in
            await self?.render()
            self?.scheduleBackgroundRefresh()
        }
    }

    private func render() async {
        guard isDemo || suspension.allowsLocalEvents else { return }
        guard let store = usageStore else { return }
        let settings = demoSettings ?? settingsStore.load()
        let states = await store.rows(for: settings.providerOrder)
        menuBarController?.update(states: states, settings: settings)
        settingsWindow?.updateConnectionStates(states)
        observeRefreshForQA(states)
    }

    /// Opt-in, two-minute local diagnostic. No credential/account IDs or persistent telemetry.
    private func observeRefreshForQA(_ states: [ProviderState]) {
        guard observationEnabled else { return }
        if observationStartedAt == nil { observationStartedAt = Date() }
        guard Date().timeIntervalSince(observationStartedAt!) < 150 else { return }
        for state in states where state.status == .fresh {
            guard let snapshot = state.snapshot, observedUpdates[state.provider] != snapshot.updatedAt else { continue }
            observedUpdates[state.provider] = snapshot.updatedAt
            let record: [String: Any] = [
                "provider": state.provider.rawValue,
                "updatedAt": ISO8601DateFormatter().string(from: snapshot.updatedAt),
                "value": state.displayValue,
                "iconRenders": menuBarController?.iconRenderCountForQA ?? 0,
                "hoverCallbacks": observedHoverCalls,
                "visiblePopover": menuBarController?.hasVisibleSurfaceForQA ?? false,
                "applicationActive": NSApp.isActive
            ]
            if var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        }
    }

    private func refresh(_ provider: ProviderID) {
        guard !isDemo, let coordinator else { return }
        Task { await coordinator.refresh(provider) }
    }

    /// Looking at the hover bar or a detail refreshes connected providers whose data is older
    /// than the hover freshness window — sequentially, so a hover never starts a burst of
    /// helper processes. Providers that are not connected refresh only from Settings or Refresh.
    private func refreshOnHover(_ providers: [ProviderID]) {
        guard !isDemo, let coordinator, let usageStore else { return }
        if observationEnabled { observedHoverCalls += providers.count }
        pendingHoverProviders.append(contentsOf: providers.filter { !pendingHoverProviders.contains($0) })
        guard hoverRefreshTask == nil else { return }
        hoverRefreshTask = Task { [weak self] in
            while let self, !self.pendingHoverProviders.isEmpty {
                let provider = self.pendingHoverProviders.removeFirst()
                let state = await usageStore.state(for: provider)
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard state.hasDisplayableUsage else { continue }
                if let updatedAt = state.snapshot?.updatedAt, state.status == .fresh,
                   Date().timeIntervalSince(updatedAt) < RefreshPolicy.hoverFreshness(lowPower: lowPower) { continue }
                guard self.suspension.allowsLocalEvents,
                      self.suspension.allowsNetwork || !RefreshPolicy.isNetwork(provider) else { continue }
                await coordinator.refresh(provider, isBackground: true)
            }
            self?.hoverRefreshTask = nil
        }
    }

    private func openSettings(provider: ProviderID?) {
        menuBarController?.closeSurface()
        if let settingsWindow {
            settingsWindow.show(provider: provider)
            return
        }
        let controller = SettingsWindowController(
            settings: demoSettings ?? settingsStore.load(),
            settingsStore: settingsStore,
            keychain: keychain
        )
        controller.onSettingsChanged = { [weak self] newSettings in
            guard let self else { return }
            if self.isDemo { self.demoSettings = newSettings }
            Task {
                await self.render()
                self.scheduleBackgroundRefresh()
            }
        }
        controller.onRefreshProvider = { [weak self] provider in self?.refresh(provider) }
        controller.onRefreshConnections = { [weak self] in
            guard let self, !self.isDemo, let coordinator = self.coordinator else { return }
            Task {
                let custom = CustomConnection.load()
                await coordinator.registerCustom(custom)
                await self.render()
                // Only custom APIs changed; built-in providers keep their own schedule.
                for configuration in custom { await coordinator.refresh(configuration.provider) }
            }
        }
        controller.onClose = { [weak self, weak controller] in
            // Release after AppKit finishes closing; a reopen in between keeps the window.
            Task { @MainActor in
                guard let self, let controller, self.settingsWindow === controller,
                      controller.window?.isVisible != true else { return }
                self.settingsWindow = nil
            }
        }
        settingsWindow = controller
        Task { [weak self, weak controller] in
            guard let self, let store = self.usageStore else { return }
            controller?.updateConnectionStates(await store.rows(for: (self.demoSettings ?? self.settingsStore.load()).providerOrder))
        }
        controller.show(provider: provider)
    }

    /// Fixture-only visual check. Shows real UI, so it is never part of the hidden QA gate.
    private func applyDemoPresentation(arguments: [String]) {
        guard let menuBarController else { return }
        if let value = arguments.first(where: { $0.hasPrefix("--demo-detail=") }),
           let provider = ProviderID(rawValue: String(value.dropFirst(14))) {
            menuBarController.showDetails(for: provider)
        } else if arguments.contains("--demo-pinned") {
            menuBarController.showDetails(for: menuBarController.settings.selectedProvider)
        }
    }

    private static func demoSnapshots(now: Date = Date()) -> [UsageSnapshot] {
        [
            UsageSnapshot(
                provider: .codex,
                windows: [
                    UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 8, resetAt: now.addingTimeInterval(8_200), kind: .shortTerm),
                    UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 28, resetAt: now.addingTimeInterval(220_000), kind: .weekly),
                    UsageWindow(id: "review", title: "Code review", usedPercent: 64, resetAt: now.addingTimeInterval(220_000), kind: .model),
                    UsageWindow(id: "monthly", title: "Monthly requests", usedPercent: 44, used: 440, limit: 1_000, resetAt: now.addingTimeInterval(1_000_000), kind: .monthly),
                    UsageWindow(id: "credits", title: "Extra credits", usedPercent: 24, used: 24, limit: 100, kind: .credits, detail: "$24 / $100")
                ],
                updatedAt: now,
                source: .codexAppServer,
                availableResetCount: 1
            ),
            UsageSnapshot(
                provider: .claude,
                windows: [
                    UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 16, resetAt: now.addingTimeInterval(6_000)),
                    UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 41, resetAt: now.addingTimeInterval(310_000))
                ],
                modelName: "Claude",
                updatedAt: now,
                source: .officialStatusLine
            ),
            UsageSnapshot(
                provider: .copilot,
                windows: [UsageWindow(
                    id: "current-month",
                    title: "Current month",
                    usedPercent: 3,
                    used: 9,
                    limit: 300,
                    resetAt: now.addingTimeInterval(1_000_000),
                    isEstimated: true
                )],
                updatedAt: now,
                source: .githubREST
            ),
            UsageSnapshot(
                provider: .antigravity,
                windows: [
                    UsageWindow(id: "daily", title: "Daily agent quota", usedPercent: 34, resetAt: now.addingTimeInterval(31_000), kind: .shortTerm),
                    UsageWindow(id: "monthly", title: "Monthly quota", usedPercent: 11, resetAt: now.addingTimeInterval(900_000), kind: .monthly)
                ],
                modelName: "Gemini 3.5 Pro",
                updatedAt: now,
                source: .manual
            ),
            UsageSnapshot(
                provider: .gemini,
                windows: [
                    UsageWindow(id: "daily", title: "Daily model quota", usedPercent: 47, resetAt: now.addingTimeInterval(42_000), kind: .model)
                ],
                modelName: "Gemini",
                updatedAt: now,
                source: .manual
            ),
            UsageSnapshot(
                provider: .kie,
                windows: [UsageWindow(id: "account-credit", title: "Account credits", usedPercent: nil, kind: .credits)],
                updatedAt: now,
                source: .kieAPI,
                creditBalance: 12345.67
            ),
            UsageSnapshot(
                provider: .runpod,
                windows: [UsageWindow(id: "account-balance", title: "Account balance (USD)", usedPercent: nil, kind: .credits)],
                updatedAt: now,
                source: .runpodAPI,
                creditBalance: 23.4567891234,
                balanceUnit: .usd
            )
        ]
    }
}
