import Foundation

public extension UsageSnapshot {
    /// A new observation time alone is not a usage change and need not rewrite the cache.
    func hasSameContent(as other: UsageSnapshot) -> Bool {
        provider == other.provider && windows == other.windows
            && sessionTokens == other.sessionTokens && modelName == other.modelName
            && source == other.source && creditBalance == other.creditBalance
            && balanceUnit == other.balanceUnit && availableResetCount == other.availableResetCount
    }
}

public extension UsageSnapshot {
    /// Same numbers as `other`, for deciding whether polling can slow down. Reset times are
    /// compared to the minute: Claude re-stamps them with sub-second noise on every read.
    func hasSameReading(as other: UsageSnapshot) -> Bool {
        guard provider == other.provider, creditBalance == other.creditBalance,
              availableResetCount == other.availableResetCount, windows.count == other.windows.count else { return false }
        return zip(windows, other.windows).allSatisfy { lhs, rhs in
            lhs.id == rhs.id && lhs.usedPercent == rhs.usedPercent && lhs.used == rhs.used
                && lhs.remainingPercentReported == rhs.remainingPercentReported && lhs.balance == rhs.balance
                && lhs.breakdown == rhs.breakdown && Self.sameMinute(lhs.resetAt, rhs.resetAt)
        }
    }

    private static func sameMinute(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < 60
        default: false
        }
    }
}

public extension ProviderState {
    func hasSameContent(as other: ProviderState) -> Bool {
        guard provider == other.provider, status == other.status, message == other.message else { return false }
        switch (snapshot, other.snapshot) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.hasSameContent(as: rhs)
        default: return false
        }
    }
}

/// Only fields that can change menu-bar pixels; detail data stays full precision.
public struct MenuBarPresentation: Equatable, Sendable {
    public let provider: ProviderID
    public let text: String
    public let percent: Double?
    public let isBalance: Bool
    public let isCached: Bool
    public let isUnavailable: Bool

    public init(_ state: ProviderState) {
        provider = state.provider
        text = state.displayValue
        isUnavailable = !state.hasDisplayableUsage
        isBalance = !isUnavailable && state.snapshot?.creditBalance != nil
        percent = !isUnavailable && !isBalance ? state.snapshot?.remainingPercent.flatMap { $0.isFinite ? $0.rounded() : nil } : nil
        isCached = state.status == .cached || state.status == .stale
    }
}
