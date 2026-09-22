import AppKit
import UsageCore

/// Explicit, hidden QA: fixtures in a private temporary directory; no credentials or provider requests.
@MainActor
enum RefreshRuntimeCheck {
    static func run() async throws -> [String: Any] {
        let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let settings = AppSettings(selectedProvider: .codex)
        let controller = MenuBarController(settings: settings, presentsStatusItems: false)
        var hoverCalls = 0
        controller.onHoverRefresh = { _ in hoverCalls += 1 }
        var checks: [String: Bool] = [:]
        let date = Date()
        func state(_ provider: ProviderID = .codex, used: Double, at: Date? = nil,
                   status: ProviderStatus = .fresh) -> ProviderState {
            ProviderState(provider: provider, status: status, snapshot: UsageSnapshot(
                provider: provider, windows: [UsageWindow(id: "fixture", title: "Fixture", usedPercent: used)],
                updatedAt: at ?? date, source: .officialStatusLine))
        }
        controller.update(states: [state(used: 20)], settings: settings)
        let renders = controller.iconRenderCountForQA
        controller.update(states: [state(used: 20, at: date.addingTimeInterval(30))], settings: settings)
        checks["timestampOnlyDoesNotRedrawIcon"] = controller.iconRenderCountForQA == renders
        controller.update(states: [state(used: 20), state(.kie, used: 5)], settings: settings)
        checks["anotherProviderDoesNotRedrawMainIcon"] = controller.iconRenderCountForQA == renders
        controller.update(states: [state(used: 30)], settings: settings)
        checks["mainValueChangesWithoutHover"] = controller.statusValueForQA.trimmingCharacters(in: .whitespaces) == "70%"
            && controller.iconRenderCountForQA == renders + 1
        controller.update(states: [state(used: 30, status: .cached)], settings: settings)
        checks["cachedStyleStillRedraws"] = controller.iconRenderCountForQA == renders + 2
        controller.update(states: [state(used: 30)], settings: settings)
        checks["freshStyleStillRedraws"] = controller.iconRenderCountForQA == renders + 3
        checks["updatesDoNotOpenAnySurface"] = !controller.hasVisibleSurfaceForQA

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagerail-refresh-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventURL = directory.appendingPathComponent("claude-event.json")
        let store = UsageStore()
        let cache = try SnapshotCache(cacheURL: directory.appendingPathComponent("snapshots.json"))
        let connector = try LocalSnapshotConnector(provider: .claude, eventURL: eventURL)
        let coordinator = RefreshCoordinator(connectors: [connector], store: store, cache: cache)
        let probe = BridgeRefreshProbe(controller: controller, store: store, coordinator: coordinator, connector: connector)
        let monitor = try BridgeEventMonitor(directoryURL: directory) { providers in
            Task { @MainActor in await probe.receive(providers) }
        }
        probe.startedAt = Date()
        for used in 20...31 {
            let snapshot = state(.claude, used: Double(used)).snapshot!
            try JSONEncoder.usageRail.encode(snapshot).write(to: eventURL, options: .atomic)
        }
        try await Task.sleep(for: .milliseconds(600))
        checks["bridgeBurstIsCoalesced"] = probe.deliveries == 1
        checks["bridgeFileReachesIconWithoutHover"] = controller.statusValueForQA.trimmingCharacters(in: .whitespaces) == "69%"
        checks["bridgeDeliveryUnderHalfSecond"] = (probe.deliveryMilliseconds ?? .infinity) < 500
        checks["noHoverCallbackWasNeeded"] = hoverCalls == 0
        // AppKit keeps the hidden item's offscreen NSStatusBarWindow marked visible internally.
        // Exclude only that exact backing window, while separately asserting the item is hidden.
        checks["bridgeRefreshDoesNotOpenWindows"] = !controller.hasVisibleSurfaceForQA && !controller.statusItemVisibleForQA
            && !NSApp.windows.contains { $0.isVisible && $0 !== controller.statusWindowForQA }
        checks["foregroundApplicationUnchanged"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundBefore
            && !NSApp.isActive
        await cache.flush()
        withExtendedLifetime(monitor) {}
        let visibleWindows = NSApp.windows.filter(\.isVisible).map {
            ["class": String(describing: type(of: $0)), "level": String($0.level.rawValue),
             "frame": NSStringFromRect($0.frame)]
        }
        return ["checks": checks, "visibleWindows": visibleWindows, "bridgeDeliveryMilliseconds": probe.deliveryMilliseconds ?? -1,
                "bridgeEvents": probe.deliveries, "pass": checks.values.allSatisfy { $0 }]
    }
}

@MainActor
private final class BridgeRefreshProbe {
    let controller: MenuBarController
    let store: UsageStore
    let coordinator: RefreshCoordinator
    let connector: LocalSnapshotConnector
    var startedAt = Date()
    var deliveries = 0
    var deliveryMilliseconds: Double?
    init(controller: MenuBarController, store: UsageStore, coordinator: RefreshCoordinator, connector: LocalSnapshotConnector) {
        self.controller = controller
        self.store = store
        self.coordinator = coordinator
        self.connector = connector
    }
    func receive(_ providers: [ProviderID]) async {
        guard providers.contains(.claude) else { return }
        deliveries += 1
        if let snapshot = try? await connector.refresh() { await coordinator.applyLocalEvent(snapshot) }
        controller.update(states: await store.rows(for: [.claude]), settings: AppSettings(selectedProvider: .claude))
        deliveryMilliseconds = Date().timeIntervalSince(startedAt) * 1000
    }
}
