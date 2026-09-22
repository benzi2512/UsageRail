import Foundation
import Testing
@testable import UsageCore

private let refreshEpoch = Date(timeIntervalSince1970: 1_788_000_000)

private func refreshSnapshot(_ provider: ProviderID = .codex, used: Double = 20,
                             date: Date = refreshEpoch, resets: Int? = nil) -> UsageSnapshot {
    UsageSnapshot(provider: provider,
                  windows: [UsageWindow(id: "quota", title: "Quota", usedPercent: used)],
                  updatedAt: date, source: provider == .claude ? .claudeCode : .codexAppServer,
                  availableResetCount: resets)
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = refreshEpoch
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor FixtureRefreshConnector: UsageConnector {
    let provider: ProviderID
    let clock: FixtureClock
    var failure: ConnectorError?
    var calls = 0
    /// Returns the same reading on every call, like a provider nobody is using.
    var constant = false
    var held: Bool
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(provider: ProviderID = .codex, clock: FixtureClock, failure: ConnectorError? = nil, held: Bool = false) {
        self.provider = provider
        self.clock = clock
        self.failure = failure
        self.held = held
    }

    func refresh() async throws -> UsageSnapshot {
        calls += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if held { await withCheckedContinuation { releaseWaiters.append($0) } }
        if let failure { throw failure }
        return refreshSnapshot(provider, used: constant ? 20 : Double(20 + calls), date: clock.now())
    }

    func waitUntilStarted() async {
        if calls == 0 { await withCheckedContinuation { startWaiters.append($0) } }
    }

    func release() {
        held = false
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func setFailure(_ error: ConnectorError?) { failure = error }
    func setConstant(_ value: Bool) { constant = value }
}

private struct RefreshHarness {
    let directory: URL
    let clock: FixtureClock
    let store: UsageStore
    let cache: SnapshotCache
    let connector: FixtureRefreshConnector
    let coordinator: RefreshCoordinator

    init(provider: ProviderID = .codex, failure: ConnectorError? = nil, held: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("usagerail-test-\(UUID().uuidString)")
        clock = FixtureClock()
        store = UsageStore()
        cache = try SnapshotCache(cacheURL: directory.appendingPathComponent("snapshots.json"))
        connector = FixtureRefreshConnector(provider: provider, clock: clock, failure: failure, held: held)
        coordinator = RefreshCoordinator(connectors: [connector], store: store, cache: cache, now: clock.now)
    }

    func finish() async {
        await cache.flush()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func automaticCadencePollsOnlyThePinnedProviderConservatively() {
    for provider in RefreshPolicy.networkProviders {
        let normal: TimeInterval = provider == .codex ? 300 : 900
        let lowPower: TimeInterval = provider == .codex ? 900 : 1_800
        #expect(RefreshPolicy.interval(for: provider, selected: provider, lowPower: false) == normal)
        #expect(RefreshPolicy.interval(for: provider, selected: .gemini, lowPower: false) == nil)
        #expect(RefreshPolicy.interval(for: provider, selected: provider, lowPower: true) == lowPower)
        #expect(RefreshPolicy.interval(for: provider, selected: .gemini, lowPower: true) == nil)
    }
    #expect(RefreshPolicy.hoverFreshness(lowPower: false) == 300)
    #expect(RefreshPolicy.hoverFreshness(lowPower: true) == 900)
}

@Test func onlyConnectedNetworkSourcesHaveAutomaticDeadlines() {
    for provider in ProviderID.allCases {
        let state = ProviderState(provider: provider, status: .fresh, snapshot: refreshSnapshot(provider))
        let date = RefreshPolicy.nextDate(state: state, selected: provider, lowPower: false,
                                         lastAttempt: nil, retryAfter: nil, blocked: false, inFlight: false)
        let interval = RefreshPolicy.interval(for: provider, selected: provider, lowPower: false)
        #expect(date == interval.map { refreshEpoch.addingTimeInterval($0) })
    }
    let missing = ProviderState(provider: .codex, status: .unavailable, snapshot: nil)
    #expect(RefreshPolicy.nextDate(state: missing, selected: .codex, lowPower: false,
                                  lastAttempt: nil, retryAfter: nil, blocked: false, inFlight: false) == nil)
}

@Test func retryAndSecurityGatesOverrideFastCadence() {
    let fresh = ProviderState(provider: .codex, status: .fresh, snapshot: refreshSnapshot())
    let retry = refreshEpoch.addingTimeInterval(300)
    #expect(RefreshPolicy.nextDate(state: fresh, selected: .codex, lowPower: false,
                                  lastAttempt: refreshEpoch, retryAfter: retry, blocked: false, inFlight: false) == retry)
    for (blocked, inFlight) in [(true, false), (false, true)] {
        #expect(RefreshPolicy.nextDate(state: fresh, selected: .codex, lowPower: false,
                                      lastAttempt: nil, retryAfter: nil, blocked: blocked, inFlight: inFlight) == nil)
    }
    let login = ProviderState(provider: .codex, status: .loginRequired, snapshot: refreshSnapshot())
    #expect(RefreshPolicy.nextDate(state: login, selected: .codex, lowPower: false,
                                  lastAttempt: nil, retryAfter: retry, blocked: false, inFlight: false) == nil)
    #expect((1...6).map(RefreshPolicy.retryDelay(failures:)) == [120, 300, 900, 1800, 1800, 1800])
}

@Test func wakingDisplayDoesNotUnpauseALockedSession() {
    var suspension = RefreshSuspension()
    suspension.set(.sessionInactive, paused: true)
    suspension.set(.displaySleep, paused: true)
    suspension.set(.displaySleep, paused: false)
    #expect(!suspension.allowsNetwork)
    #expect(!suspension.allowsLocalEvents)
    suspension.set(.offline, paused: true)
    suspension.set(.sessionInactive, paused: false)
    #expect(!suspension.allowsNetwork)
    #expect(suspension.allowsLocalEvents)
    suspension.set(.systemSleep, paused: true)
    suspension.set(.offline, paused: false)
    #expect(!suspension.allowsLocalEvents)
    suspension.set(.systemSleep, paused: false)
    #expect(suspension.allowsNetwork)
}

@Test func backgroundFetchHappensAtFiveMinutesWithoutAnyHoverCall() async throws {
    let h = try RefreshHarness()
    await h.store.apply(refreshSnapshot())
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == refreshEpoch.addingTimeInterval(300))
    h.clock.advance(299)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 0)
    h.clock.advance(1)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 1)
    #expect(await h.store.state(for: .codex).snapshot?.remainingPercent == 79)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == h.clock.now().addingTimeInterval(300))
    await h.finish()
}

@Test func lowPowerModeExtendsTheNextReadWithoutLosingConnection() async throws {
    let h = try RefreshHarness()
    await h.store.apply(refreshSnapshot())
    h.clock.advance(300)
    await h.coordinator.refreshDue(selected: .codex, lowPower: true)
    #expect(await h.connector.calls == 0)
    h.clock.advance(600)
    await h.coordinator.refreshDue(selected: .codex, lowPower: true)
    #expect(await h.connector.calls == 1)
    await h.finish()
}

@Test func pausedAndOfflineSchedulersDoNotStartRequests() async throws {
    let h = try RefreshHarness()
    await h.store.apply(refreshSnapshot())
    h.clock.advance(300)
    await h.coordinator.setAutomaticPaused(true)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == nil)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    await h.coordinator.setNetworkPaused(true)
    await h.coordinator.setAutomaticPaused(false)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 0)
    await h.coordinator.setNetworkPaused(false)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 1)
    await h.finish()
}

@Test func offlineModeStillAcceptsLocalBridgeEvents() async throws {
    let h = try RefreshHarness(provider: .claude)
    await h.coordinator.setNetworkPaused(true)
    await h.coordinator.applyLocalEvent(UsageSnapshot(provider: .claude,
        windows: [UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 20)],
        updatedAt: refreshEpoch, source: .officialStatusLine))
    #expect(await h.connector.calls == 0)
    #expect(await h.store.state(for: .claude).hasDisplayableUsage)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .claude, lowPower: false) == nil)
    await h.finish()
}

@Test func claudeBackgroundReadUsesTheHeavyConnectorCadence() async throws {
    let h = try RefreshHarness(provider: .claude)
    await h.store.apply(refreshSnapshot(.claude))
    h.clock.advance(899)
    await h.coordinator.refreshDue(selected: .claude, lowPower: false)
    #expect(await h.connector.calls == 0)
    h.clock.advance(1)
    await h.coordinator.refreshDue(selected: .claude, lowPower: false)
    #expect(await h.connector.calls == 1)
    #expect(await h.store.state(for: .claude).hasDisplayableUsage)
    await h.finish()
}

@Test func legacyClaudeStatusLineDoesNotStartAPollingTimer() {
    let snapshot = UsageSnapshot(provider: .claude,
        windows: [UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 20)],
        source: .officialStatusLine)
    let state = ProviderState(provider: .claude, status: .fresh, snapshot: snapshot)
    #expect(RefreshPolicy.nextDate(state: state, selected: .claude, lowPower: false,
        lastAttempt: nil, retryAfter: nil, blocked: false, inFlight: false) == nil)
}

@Test func localEventsRespectSleepAndDoNotReplaceNewerSnapshots() async throws {
    let h = try RefreshHarness(provider: .claude)
    let newer = refreshSnapshot(.claude, date: refreshEpoch.addingTimeInterval(60))
    await h.store.apply(newer)
    let older = UsageSnapshot(provider: .claude, windows: newer.windows,
                              updatedAt: refreshEpoch, source: .officialStatusLine)
    await h.coordinator.applyLocalEvent(older)
    #expect(await h.store.state(for: .claude).snapshot == newer)
    await h.coordinator.setAutomaticPaused(true)
    let next = UsageSnapshot(provider: .claude, windows: newer.windows,
                             updatedAt: refreshEpoch.addingTimeInterval(90), source: .officialStatusLine)
    await h.coordinator.applyLocalEvent(next)
    #expect(await h.store.state(for: .claude).snapshot == newer)
    #expect(await h.connector.calls == 0)
    await h.finish()
}

@Test func transientFailuresUseOneBackoffDeadlineInsteadOfRetryStorms() async throws {
    let h = try RefreshHarness(failure: .timedOut)
    await h.coordinator.refresh(.codex)
    // Retry backoff cannot shorten the battery-saving five-minute polling floor.
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == h.clock.now().addingTimeInterval(300))
    h.clock.advance(299)
    for _ in 0..<10 { await h.coordinator.refreshDue(selected: .codex, lowPower: false) }
    #expect(await h.connector.calls == 1)
    h.clock.advance(1)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 2)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == h.clock.now().addingTimeInterval(300))
    await h.connector.setFailure(nil)
    h.clock.advance(300)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.connector.calls == 3)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == h.clock.now().addingTimeInterval(300))
    await h.finish()
}

@Test func authOrSecurityFailureRequiresExplicitRefreshToResume() async throws {
    for failure in [ConnectorError.loginRequired("Fixture login required"), .unavailable("Helper integrity mismatch")] {
        let h = try RefreshHarness(failure: failure)
        await h.store.apply(refreshSnapshot())
        await h.coordinator.refresh(.codex)
        await h.connector.setFailure(nil)
        h.clock.advance(10_000)
        await h.coordinator.refreshDue(selected: .codex, lowPower: false)
        #expect(await h.connector.calls == 1)
        #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == nil)
        await h.coordinator.refresh(.codex)
        #expect(await h.connector.calls == 2)
        #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) != nil)
        await h.finish()
    }
}

@Test func inFlightBackgroundReadKeepsTheIconStateAndDeduplicatesRequests() async throws {
    let h = try RefreshHarness(held: true)
    await h.store.apply(refreshSnapshot())
    h.clock.advance(300)
    let background = Task { await h.coordinator.refreshDue(selected: .codex, lowPower: false) }
    await h.connector.waitUntilStarted()
    #expect(await h.store.state(for: .codex).status == .fresh)
    #expect(await h.store.state(for: .codex).snapshot?.remainingPercent == 80)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == nil)
    let manual = Task { await h.coordinator.refresh(.codex) }
    // Keep the first request held while the second task enters the coordinator.
    try await Task.sleep(for: .milliseconds(20))
    #expect(await h.connector.calls == 1)
    await h.connector.release()
    await background.value
    await manual.value
    #expect(await h.connector.calls == 1)
    #expect(await h.store.state(for: .codex).snapshot?.remainingPercent == 79)
    await h.finish()
}

@Test func menuBarPresentationIgnoresObservationTimeAndSubPixelChanges() {
    let state = ProviderState(provider: .codex, status: .fresh, snapshot: refreshSnapshot(used: 20.1))
    let later = ProviderState(provider: .codex, status: .fresh,
                              snapshot: refreshSnapshot(used: 20.2, date: refreshEpoch.addingTimeInterval(30), resets: 2))
    #expect(MenuBarPresentation(state) == MenuBarPresentation(later))
    let changed = ProviderState(provider: .codex, status: .fresh, snapshot: refreshSnapshot(used: 21))
    #expect(MenuBarPresentation(state) != MenuBarPresentation(changed))
    let cached = ProviderState(provider: .codex, status: .cached, snapshot: state.snapshot)
    #expect(MenuBarPresentation(state) != MenuBarPresentation(cached))
}

@Test func cacheContentComparisonIncludesResetAvailabilityButNotObservationTime() {
    let first = refreshSnapshot(resets: 1)
    #expect(first.hasSameContent(as: refreshSnapshot(date: refreshEpoch.addingTimeInterval(30), resets: 1)))
    #expect(!first.hasSameContent(as: refreshSnapshot(resets: 2)))
}

@Test func burstUpdatesProduceOneCacheWriteWithTheLatestData() async throws {
    let h = try RefreshHarness()
    for used in 0..<20 { await h.cache.enqueueSave([refreshSnapshot(used: Double(used))]) }
    #expect(await h.cache.writeCount == 0)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(await h.cache.writeCount == 1)
    #expect(await h.cache.load().first?.remainingPercent == 81)
    await h.finish()
}

@Test func timestampOnlyUpdatesAvoidDiskWritesUntilCheckpoint() async throws {
    let h = try RefreshHarness()
    try await h.cache.save([refreshSnapshot()])
    for seconds in 1...10 {
        await h.cache.enqueueSave([refreshSnapshot(date: refreshEpoch.addingTimeInterval(Double(seconds)))])
    }
    await h.cache.flush()
    #expect(await h.cache.writeCount == 1)
    await h.cache.enqueueSave([refreshSnapshot(date: refreshEpoch.addingTimeInterval(301))], now: Date().addingTimeInterval(301))
    await h.cache.flush()
    #expect(await h.cache.writeCount == 2)
    await h.finish()
}

@Test func revertingABurstToSavedContentCancelsTheUnneededWrite() async throws {
    let h = try RefreshHarness()
    try await h.cache.save([refreshSnapshot()])
    await h.cache.enqueueSave([refreshSnapshot(used: 90)])
    await h.cache.enqueueSave([refreshSnapshot(date: refreshEpoch.addingTimeInterval(30))])
    await h.cache.flush()
    #expect(await h.cache.writeCount == 1)
    await h.finish()
}

@Test func identicalReadingsSpaceOutPollingUntilUsageMoves() async throws {
    let h = try RefreshHarness()
    await h.connector.setConstant(true)
    await h.store.apply(refreshSnapshot())
    var expected: [TimeInterval] = []
    for wait in [300.0, 450, 600] {
        h.clock.advance(wait)
        await h.coordinator.refreshDue(selected: .codex, lowPower: false)
        let next = await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false)
        expected.append(next.map { $0.timeIntervalSince(h.clock.now()) } ?? -1)
    }
    #expect(await h.connector.calls == 3)
    // 5 min → 7.5 min → capped at 10 min while nothing changes.
    #expect(expected == [450, 600, 600])
    await h.connector.setConstant(false)
    h.clock.advance(600)
    await h.coordinator.refreshDue(selected: .codex, lowPower: false)
    #expect(await h.coordinator.nextAutomaticRefresh(selected: .codex, lowPower: false) == h.clock.now().addingTimeInterval(300))
    await h.finish()
}

@Test func readingComparisonIgnoresResetTimeNoiseButNotUsage() {
    let reset = refreshEpoch.addingTimeInterval(3_600)
    func claude(_ used: Double, reset: Date, at date: Date) -> UsageSnapshot {
        UsageSnapshot(provider: .claude, windows: [UsageWindow(id: "five-hour", title: "5-hour session", usedPercent: used, resetAt: reset)],
                      updatedAt: date, source: .claudeCode)
    }
    let first = claude(59, reset: reset, at: refreshEpoch)
    #expect(first.hasSameReading(as: claude(59, reset: reset.addingTimeInterval(0.52), at: refreshEpoch.addingTimeInterval(900))))
    #expect(!first.hasSameReading(as: claude(60, reset: reset, at: refreshEpoch)))
    #expect(!first.hasSameReading(as: claude(59, reset: reset.addingTimeInterval(3_600), at: refreshEpoch)))
    #expect([0, 1, 2, 9].map { RefreshPolicy.quietMultiplier(unchangedReadings: $0) } == [1, 1.5, 2, 2])
}
