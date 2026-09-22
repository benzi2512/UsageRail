import Foundation

public actor UsageStore {
    private var states: [ProviderID: ProviderState]

    public init() {
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderState(provider: $0, status: .unavailable, snapshot: nil, message: "No data yet"))
        })
    }

    public func restore(_ snapshots: [UsageSnapshot]) {
        for snapshot in snapshots {
            states[snapshot.provider] = ProviderState(
                provider: snapshot.provider,
                status: .cached,
                snapshot: snapshot,
                message: nil
            )
        }
    }

    public func markRefreshing(_ provider: ProviderID) {
        let existing = states[provider]
        states[provider] = ProviderState(
            provider: provider,
            status: .refreshing,
            snapshot: existing?.snapshot,
            message: nil
        )
    }

    public func apply(_ snapshot: UsageSnapshot) {
        states[snapshot.provider] = ProviderState(
            provider: snapshot.provider,
            status: .fresh,
            snapshot: snapshot,
            message: nil
        )
    }

    public func fail(_ provider: ProviderID, error: Error) {
        let existing = states[provider]
        let status: ProviderStatus
        if case ConnectorError.loginRequired = error {
            status = .loginRequired
        } else if existing?.snapshot != nil {
            status = .stale
        } else {
            status = .unavailable
        }
        states[provider] = ProviderState(
            provider: provider,
            status: status,
            snapshot: existing?.snapshot,
            message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        )
    }

    public func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? ProviderState(provider: provider, status: .unavailable, snapshot: nil)
    }
    public func removeCustom(_ provider: ProviderID) { if provider.isCustom { states.removeValue(forKey: provider) } }

    public func rows(for providers: [ProviderID]) -> [ProviderState] {
        providers.map { states[$0] ?? ProviderState(provider: $0, status: .unavailable, snapshot: nil) }
    }

    public func allSnapshots() -> [UsageSnapshot] {
        states.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { states[$0]?.snapshot }
    }
}
