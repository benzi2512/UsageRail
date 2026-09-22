import Foundation

public extension AppSettings {
    /// Menu-bar pins first, then the remaining providers in their saved order.
    var hoverOrder: [ProviderID] {
        menuBarProviders + providerOrder.filter { !menuBarProviders.contains($0) }
    }

    /// Connected providers for the hover bar, each projected to its display limit.
    func hoverStates(from states: [ProviderState]) -> [ProviderState] {
        hoverOrder.compactMap { provider in states.first { $0.provider == provider } }
            .filter(\.hasDisplayableUsage).map { displayState(from: $0) }
    }

    /// One state per menu-bar item, in pin order. A provider without data shows its hint.
    func menuBarStates(from states: [ProviderState]) -> [ProviderState] {
        menuBarProviders.map { provider in
            displayState(from: states.first { $0.provider == provider }
                ?? ProviderState(provider: provider, status: .unavailable, snapshot: nil, message: "No data yet"))
        }
    }

    /// Projects the one number that represents a provider in the menu bar and hover bar.
    /// Full detail and the cache always keep every limit.
    func displayState(from state: ProviderState) -> ProviderState {
        guard state.hasDisplayableUsage else {
            return ProviderState(provider: state.provider, status: state.status, snapshot: nil, message: state.connectionHint)
        }
        guard let limitID = limitSelection(for: state.provider) else { return state }
        guard let snapshot = state.snapshot,
              let limit = snapshot.windows.first(where: { $0.id == limitID }),
              limit.hasDisplayableMetric else {
            // Never silently fall back to a different limit than the one the user chose.
            return ProviderState(provider: state.provider, status: state.status == .loginRequired ? .loginRequired : .unavailable,
                                 snapshot: nil, message: "Pinned limit unavailable; choose another limit in details")
        }
        return ProviderState(provider: state.provider, status: state.status,
                             snapshot: UsageSnapshot(provider: state.provider, windows: [limit], updatedAt: snapshot.updatedAt,
                                                     source: snapshot.source, creditBalance: limit.balance,
                                                     balanceUnit: limit.balanceUnit), message: state.message)
    }

    /// The limit the menu bar currently shows for a provider: the chosen one, or the lowest.
    func displayedLimit(in state: ProviderState) -> UsageWindow? {
        guard let snapshot = state.snapshot else { return nil }
        if let limitID = limitSelection(for: state.provider) {
            return snapshot.windows.first { $0.id == limitID }
        }
        return snapshot.limitingWindow ?? snapshot.windows.first { $0.balance != nil }
    }
}
