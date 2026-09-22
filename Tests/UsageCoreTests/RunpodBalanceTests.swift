import Foundation
import Testing
@testable import UsageCore

@Test func runpodBalancePreservesPrecisionAndShowsUSD() throws {
    let snapshot = try RunpodBalanceParser.parse(Data(#"{"data":{"myself":{"clientBalance":23.4567891234}}}"#.utf8))
    let state = ProviderState(provider: .runpod, status: .fresh, snapshot: snapshot)
    #expect(snapshot.provider == .runpod)
    #expect(snapshot.source == .runpodAPI)
    #expect(snapshot.creditBalance == 23.4567891234)
    #expect(snapshot.balanceUnit == .usd)
    #expect(snapshot.windows.first?.balance == 23.4567891234)
    #expect(snapshot.windows.first?.balanceUnit == .usd)
    #expect(snapshot.remainingPercent == nil)
    #expect(state.hasDisplayableUsage)
    #expect(state.displayValue == "$23.46")
    #expect(state.usageAccessibilityValue.contains("USD"))
}

@Test func runpodZeroAndNegativeBalancesAreRealBalances() throws {
    for (balance, displayed) in [(0.0, "$0.00"), (-0.25, "-$0.25")] {
        let data = Data("{\"data\":{\"myself\":{\"clientBalance\":\(balance)}}}".utf8)
        let snapshot = try RunpodBalanceParser.parse(data)
        let state = ProviderState(provider: .runpod, status: .fresh, snapshot: snapshot)
        #expect(state.hasDisplayableUsage)
        #expect(state.displayValue == displayed)
        #expect(snapshot.remainingPercent == nil)
    }
}

@Test func runpodMissingMalformedAndUnsuccessfulResponsesFailClosed() {
    for text in [
        #"{"data":{"myself":null}}"#,
        #"{"data":{"myself":{}}}"#,
        #"{"data":{"myself":{"clientBalance":null}}}"#,
        #"{"data":{"myself":{"clientBalance":"20"}}}"#,
        #"{"data":{"myself":{"clientBalance":true}}}"#,
        #"{"data":{"myself":{"clientBalance":1e999}}}"#,
        #"{"data":{"myself":{"clientBalance":20}},"errors":[{"message":"Unauthorized"}]}"#,
        #"{"errors":[{"message":"Unauthorized"}]}"#,
        #"{"data":null}"#,
        "{}", "not-json"
    ] {
        #expect(throws: (any Error).self) { try RunpodBalanceParser.parse(Data(text.utf8)) }
    }
}

@Test func runpodOutputIsBounded() {
    #expect(throws: ConnectorError.outputTooLarge) {
        try RunpodBalanceParser.parse(Data(repeating: 0x20, count: 65537))
    }
}

@Test func runpodAuthFailureHidesCachedBalance() throws {
    let snapshot = try RunpodBalanceParser.parse(Data(#"{"data":{"myself":{"clientBalance":2}}}"#.utf8))
    for status in [ProviderStatus.loginRequired, .unavailable] {
        #expect(!ProviderState(provider: .runpod, status: status, snapshot: snapshot).hasDisplayableUsage)
    }
    for status in [ProviderStatus.fresh, .stale, .cached, .refreshing] {
        #expect(ProviderState(provider: .runpod, status: status, snapshot: snapshot).hasDisplayableUsage)
    }
}

@Test func runpodCacheKeepsCurrencyAndExactAmount() throws {
    let snapshot = try RunpodBalanceParser.parse(Data(#"{"data":{"myself":{"clientBalance":23.4567891234}}}"#.utf8),
                                                 now: Date(timeIntervalSince1970: 1_788_581_000))
    let restored = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: JSONEncoder.usageRail.encode(snapshot))
    #expect(restored == snapshot)
    #expect(restored.formattedUSD == "$23.46")
}

@Test func legacyKieBalanceRemainsCredits() throws {
    let data = Data(#"{"provider":"kie","windows":[],"creditBalance":5000,"updatedAt":"2026-09-04T00:00:00Z","source":"kieAPI"}"#.utf8)
    let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: data)
    #expect(snapshot.balanceUnit == nil)
    #expect(snapshot.formattedUSD == nil)
    #expect(ProviderState(provider: .kie, status: .fresh, snapshot: snapshot).displayValue.hasSuffix(" cr"))
}

@Test func runpodAppearsInExistingProviderOrderWithoutChangingSelection() {
    let settings = AppSettings(providerOrder: [.codex, .kie], selectedProvider: .codex)
    #expect(settings.providerOrder.contains(.runpod))
    #expect(settings.selectedProvider == .codex)
}

@Test func runpodEmptyErrorListStillCountsAsSuccess() throws {
    let snapshot = try RunpodBalanceParser.parse(Data(#"{"data":{"myself":{"clientBalance":5}},"errors":[]}"#.utf8))
    #expect(snapshot.creditBalance == 5)
}
