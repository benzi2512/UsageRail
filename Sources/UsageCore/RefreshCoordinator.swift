import Foundation

public extension Notification.Name {
    static let usageRailDidUpdate = Notification.Name("UsageRailDidUpdate")
}

public actor RefreshCoordinator {
    private var connectors: [ProviderID: any UsageConnector]
    private let store: UsageStore
    private let cache: SnapshotCache
    private var inFlight: [ProviderID: Task<RefreshOutcome, Never>] = [:]
    private var failureCounts: [ProviderID: Int] = [:]
    private var lastAttempts: [ProviderID: Date] = [:]
    private var retryAfter: [ProviderID: Date] = [:]
    private var blockedAutomatic: Set<ProviderID> = []
    /// Consecutive successful reads that matched the previous one, per provider.
    private var unchangedReadings: [ProviderID: Int] = [:]
    private var automaticPaused = false
    private var networkPaused = false
    private let now: @Sendable () -> Date

    public init(connectors: [any UsageConnector], store: UsageStore, cache: SnapshotCache,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.connectors = Dictionary(uniqueKeysWithValues: connectors.map { ($0.provider, $0) })
        self.store = store
        self.cache = cache
        self.now = now
    }

    public func setAutomaticPaused(_ paused: Bool) { automaticPaused = paused }
    public func setNetworkPaused(_ paused: Bool) { networkPaused = paused }
    public func registerCustom(_ configurations: [CustomConnection]) async {
        let retained = Set(configurations.map(\.provider))
        for provider in Array(connectors.keys) where provider.isCustom && !retained.contains(provider) {
            if let task = inFlight[provider] { task.cancel(); _ = await task.value }
            connectors.removeValue(forKey: provider)
            inFlight.removeValue(forKey: provider); lastAttempts.removeValue(forKey: provider)
            retryAfter.removeValue(forKey: provider); failureCounts.removeValue(forKey: provider); blockedAutomatic.remove(provider)
            unchangedReadings.removeValue(forKey: provider)
            await store.removeCustom(provider)
        }
        await cache.enqueueSave(await store.allSnapshots())
        for configuration in configurations where connectors[configuration.provider] == nil {
            connectors[configuration.provider] = CustomUsageConnector(configuration: configuration)
        }
    }
    private var networkProviders: [ProviderID] { connectors.keys.filter { RefreshPolicy.isNetwork($0) }.sorted { $0.rawValue < $1.rawValue } }

    /// A local event never launches the CLI or a network read, even while offline/backing off.
    public func applyLocalEvent(_ snapshot: UsageSnapshot) async {
        guard !automaticPaused, snapshot.provider == .claude || snapshot.provider == .antigravity,
              snapshot.source == .officialStatusLine else { return }
        let previous = await store.state(for: snapshot.provider).snapshot
        guard snapshot.updatedAt > (previous?.updatedAt ?? .distantPast) else { return }
        await store.apply(snapshot)
        await cache.enqueueSave(await store.allSnapshots())
        await postUpdate()
    }

    public func nextAutomaticRefresh(selected: ProviderID, lowPower: Bool) async -> Date? {
        await nextAutomaticRefresh(pinned: [selected], lowPower: lowPower)
    }

    public func nextAutomaticRefresh(pinned: [ProviderID], lowPower: Bool) async -> Date? {
        guard !automaticPaused, !networkPaused else { return nil }
        var next: Date?
        let pinnedSet = Set(pinned)
        for provider in networkProviders {
            let state = await store.state(for: provider)
            if let date = RefreshPolicy.nextDate(state: state, pinned: pinnedSet, lowPower: lowPower,
                                                lastAttempt: lastAttempts[provider], retryAfter: retryAfter[provider],
                                                blocked: blockedAutomatic.contains(provider), inFlight: inFlight[provider] != nil,
                                                unchangedReadings: unchangedReadings[provider, default: 0]) {
                next = min(next ?? date, date)
            }
        }
        return next
    }

    public func refreshDue(selected: ProviderID, lowPower: Bool) async {
        await refreshDue(pinned: [selected], lowPower: lowPower)
    }

    /// Menu-bar pins are due-checked first, in pin order.
    public func refreshDue(pinned: [ProviderID], lowPower: Bool) async {
        let ordered = pinned + networkProviders.filter { !pinned.contains($0) }
        let pinnedSet = Set(pinned)
        for provider in ordered where RefreshPolicy.isNetwork(provider) {
            guard !automaticPaused, !networkPaused, !Task.isCancelled else { return }
            let state = await store.state(for: provider)
            guard let date = RefreshPolicy.nextDate(state: state, pinned: pinnedSet, lowPower: lowPower,
                                                   lastAttempt: lastAttempts[provider], retryAfter: retryAfter[provider],
                                                   blocked: blockedAutomatic.contains(provider), inFlight: inFlight[provider] != nil,
                                                   unchangedReadings: unchangedReadings[provider, default: 0]),
                  date <= now() else { continue }
            await refresh(provider, isBackground: true)
        }
    }

    public func refresh(_ provider: ProviderID, scheduleRetry: Bool = true, isBackground: Bool = false) async {
        if provider.isCustom && networkPaused { return }
        if isBackground {
            guard !automaticPaused, !Task.isCancelled else { return }
            if RefreshPolicy.isNetwork(provider) {
                guard !networkPaused, !blockedAutomatic.contains(provider),
                      (retryAfter[provider] ?? .distantPast) <= now() else { return }
            }
        }
        if let task = inFlight[provider] {
            _ = await task.value
            return
        }
        guard let connector = connectors[provider] else { return }

        let task = Task { [store, cache] in
            // Background reads retain the last known value/color instead of flashing Refreshing.
            if !isBackground {
                await store.markRefreshing(provider)
                await postUpdate()
            }
            do {
                let previous = await store.state(for: provider).snapshot
                let snapshot = try await connector.refresh()
                await store.apply(snapshot)
                let snapshots = await store.allSnapshots()
                await cache.enqueueSave(snapshots)
                return RefreshOutcome.success(unchanged: previous.map { snapshot.hasSameReading(as: $0) } ?? false)
            } catch {
                await store.fail(provider, error: error)
                return Self.retryable(error, provider: provider) ? .retry : .stop
            }
        }
        inFlight[provider] = task
        let outcome = await task.value
        inFlight.removeValue(forKey: provider)
        lastAttempts[provider] = now()

        if case .success(let unchanged) = outcome {
            failureCounts[provider] = 0
            retryAfter.removeValue(forKey: provider)
            blockedAutomatic.remove(provider)
            unchangedReadings[provider] = unchanged ? min(unchangedReadings[provider, default: 0] + 1, 2) : 0
        } else if outcome == .retry && scheduleRetry {
            let failures = min(failureCounts[provider, default: 0] + 1, 4)
            failureCounts[provider] = failures
            retryAfter[provider] = now().addingTimeInterval(RefreshPolicy.retryDelay(failures: failures))
        } else if RefreshPolicy.isNetwork(provider) {
            blockedAutomatic.insert(provider)
            retryAfter.removeValue(forKey: provider)
        }
        // Notify only after bookkeeping, so the single scheduler sees the final deadline.
        await postUpdate()
    }

    public func refresh(_ providers: [ProviderID]) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await self.refresh(provider) }
            }
        }
    }

    private static func retryable(_ error: Error, provider: ProviderID) -> Bool {
        guard let connectorError = error as? ConnectorError else { return true }
        switch connectorError {
        case .timedOut, .server:
            return true
        case .malformedResponse:
            return provider == .codex || provider == .copilot
        case .unavailable(let message):
            return message.localizedCaseInsensitiveContains("lookup failed")
                || (provider == .copilot && (message.localizedCaseInsensitiveContains("offline")
                    || message.localizedCaseInsensitiveContains("unreachable")))
        case .loginRequired, .outputTooLarge:
            return false
        }
    }
}

private enum RefreshOutcome: Equatable, Sendable {
    case success(unchanged: Bool)
    case retry
    case stop
}

private func postUpdate() async {
    await MainActor.run {
        NotificationCenter.default.post(name: .usageRailDidUpdate, object: nil)
    }
}
