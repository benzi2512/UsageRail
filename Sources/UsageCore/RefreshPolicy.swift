import Foundation

/// One scheduler owns polling and retries. Local bridge events still bypass polling.
public enum RefreshPolicy {
    public static let networkProviders: [ProviderID] = [.codex, .claude, .copilot, .kie, .runpod]
    public static func isNetwork(_ provider: ProviderID) -> Bool { provider.isCustom || networkProviders.contains(provider) }

    /// Only providers pinned to the menu bar are polled automatically. Everything else
    /// refreshes on explicit interaction (hover, Refresh, or connection setup).
    public static func interval(for provider: ProviderID, selected: ProviderID, lowPower: Bool) -> TimeInterval? {
        interval(for: provider, pinned: [selected], lowPower: lowPower)
    }

    public static func interval(for provider: ProviderID, pinned: Set<ProviderID>, lowPower: Bool) -> TimeInterval? {
        guard pinned.contains(provider) else { return nil }
        if provider.isCustom { return lowPower ? 1_800 : 900 }
        switch provider {
        case .codex:
            return lowPower ? 900 : 300
        case .claude, .copilot, .kie, .runpod:
            return lowPower ? 1_800 : 900
        default:
            return nil
        }
    }

    /// Quiet periods stretch polling: 1×, 1.5×, then at most 2× the interval while consecutive
    /// readings stay identical. Any change returns to the regular interval.
    public static func quietMultiplier(unchangedReadings: Int) -> Double {
        1 + 0.5 * Double(min(max(0, unchangedReadings), 2))
    }

    /// Hover should feel current without turning pointer movement into a polling loop.
    public static func hoverFreshness(lowPower: Bool) -> TimeInterval {
        lowPower ? 900 : 300
    }

    public static func retryDelay(failures: Int) -> TimeInterval {
        let delays: [TimeInterval] = [120, 300, 900, 1800]
        return delays[min(max(0, failures - 1), delays.count - 1)]
    }

    public static func nextDate(
        state: ProviderState, selected: ProviderID, lowPower: Bool,
        lastAttempt: Date?, retryAfter: Date?, blocked: Bool, inFlight: Bool
    ) -> Date? {
        nextDate(state: state, pinned: [selected], lowPower: lowPower, lastAttempt: lastAttempt,
                 retryAfter: retryAfter, blocked: blocked, inFlight: inFlight)
    }

    public static func nextDate(
        state: ProviderState, pinned: Set<ProviderID>, lowPower: Bool,
        lastAttempt: Date?, retryAfter: Date?, blocked: Bool, inFlight: Bool, unchangedReadings: Int = 0
    ) -> Date? {
        if state.provider == .claude, state.snapshot?.source == .officialStatusLine { return nil }
        guard isNetwork(state.provider), !blocked, !inFlight,
              state.status != .loginRequired,
              state.snapshot != nil || retryAfter != nil,
              let interval = interval(for: state.provider, pinned: pinned, lowPower: lowPower) else { return nil }
        let anchor = lastAttempt ?? state.snapshot?.updatedAt ?? .distantPast
        let regular = anchor.addingTimeInterval(interval * quietMultiplier(unchangedReadings: unchangedReadings))
        return max(regular, retryAfter ?? .distantPast)
    }
}

/// Independent reasons prevent a display-wake notification from undoing a locked session.
public struct RefreshSuspension: Sendable {
    public enum Reason: Hashable, Sendable { case systemSleep, displaySleep, sessionInactive, offline }
    private var reasons: Set<Reason> = []
    public init() {}
    public mutating func set(_ reason: Reason, paused: Bool) {
        if paused { reasons.insert(reason) } else { reasons.remove(reason) }
    }
    public var allowsNetwork: Bool { reasons.isEmpty }
    public var allowsLocalEvents: Bool { reasons.subtracting([.offline]).isEmpty }
}
