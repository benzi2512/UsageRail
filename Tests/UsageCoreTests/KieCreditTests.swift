import Foundation
import Testing
@testable import UsageCore

@Test func kieOfficialCreditFixtureDoesNotInventPercentage() throws {
    // https://docs.kie.ai/common-api/get-account-credits
    let snapshot = try KieCreditParser.parse(Data(#"{"code":200,"msg":"success","data":100}"#.utf8))
    #expect(snapshot.provider == .kie)
    #expect(snapshot.source == .kieAPI)
    #expect(snapshot.creditBalance == 100)
    #expect(snapshot.remainingPercent == nil)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].kind == .credits)
    #expect(snapshot.windows[0].balance == 100)
    #expect(snapshot.windows[0].balanceUnit == .credits)
}

@Test func kieFractionalBalanceAndTimestampArePreserved() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try KieCreditParser.parse(Data(#"{"code":200,"msg":"success","data":5000.125}"#.utf8), now: now)
    #expect(snapshot.creditBalance == 5000.125)
    #expect(snapshot.updatedAt == now)
    let state = ProviderState(provider: .kie, status: .fresh, snapshot: snapshot)
    #expect(state.hasDisplayableUsage)
    #expect(state.displayValue.hasSuffix(" cr"))
    #expect(!state.displayValue.contains("%"))
    #expect(state.usageAccessibilityValue.contains("credits remaining"))
}

@Test func kieZeroCreditsIsConnectedNotMissing() throws {
    let snapshot = try KieCreditParser.parse(Data(#"{"code":200,"msg":"success","data":0}"#.utf8))
    let state = ProviderState(provider: .kie, status: .fresh, snapshot: snapshot)
    #expect(state.hasDisplayableUsage)
    #expect(state.displayValue == "0 cr")
    #expect(snapshot.remainingPercent == nil)
}

@Test func kieMissingInvalidOrErrorCreditsFailClosed() {
    for payload in [
        #"{"code":200,"msg":"success"}"#,
        #"{"code":200,"msg":"success","data":null}"#,
        #"{"code":200,"msg":"success","data":"100"}"#,
        #"{"code":200,"msg":"success","data":true}"#,
        #"{"code":200,"msg":"success","data":-5}"#,
        #"{"code":200,"msg":"success","data":1e999}"#,
        #"{"code":200,"msg":"failure","data":100}"#,
        #"{"code":500,"msg":"failed","data":100}"#,
        "not-json"
    ] {
        #expect(throws: (any Error).self) { try KieCreditParser.parse(Data(payload.utf8)) }
    }
}

@Test func kieRejectsOversizedOutput() {
    #expect(throws: ConnectorError.outputTooLarge) {
        try KieCreditParser.parse(Data(repeating: 0x20, count: 64 * 1024 + 1))
    }
}

@Test func kieAuthenticationFailureIsNotAZeroBalance() {
    do {
        _ = try KieCreditParser.parse(Data(#"{"code":401,"msg":"You do not have access permissions"}"#.utf8))
        Issue.record("Expected login-required")
    } catch let error as ConnectorError {
        if case .loginRequired = error {} else { Issue.record("Wrong error class") }
    } catch { Issue.record("Unexpected error") }
}

@Test func kieUnavailableHidesButCachedBalanceRemainsAvailable() throws {
    let snapshot = try KieCreditParser.parse(Data(#"{"code":200,"msg":"success","data":20}"#.utf8))
    for status in [ProviderStatus.fresh, .cached, .stale, .refreshing] {
        #expect(ProviderState(provider: .kie, status: status, snapshot: snapshot).hasDisplayableUsage)
    }
    for status in [ProviderStatus.unavailable, .loginRequired] {
        #expect(!ProviderState(provider: .kie, status: status, snapshot: snapshot).hasDisplayableUsage)
    }
    #expect(!ProviderState(provider: .kie, status: .fresh, snapshot: nil).hasDisplayableUsage)
}

@Test func oldSnapshotWithoutCreditBalanceStillDecodes() throws {
    let payload = Data(#"{"provider":"codex","windows":[],"updatedAt":"2026-09-04T00:00:00Z","source":"codexAppServer"}"#.utf8)
    let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: payload)
    #expect(snapshot.creditBalance == nil)
}

@Test func kieCacheRoundTripsWithoutConvertingBalanceToUsedQuota() throws {
    let snapshot = try KieCreditParser.parse(Data(#"{"code":200,"msg":"success","data":100.125}"#.utf8))
    let payload = try JSONEncoder.usageRail.encode(snapshot)
    let restored = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: payload)
    #expect(restored.creditBalance == 100.125)
    #expect(restored.remainingPercent == nil)
    #expect(restored.windows.first?.used == nil)
    #expect(restored.windows.first?.limit == nil)
}

@Test func invalidConstructedCreditBalanceIsNotDisplayed() {
    for value in [-1.0, Double.nan, Double.infinity] {
        let snapshot = UsageSnapshot(provider: .kie, windows: [], source: .kieAPI, creditBalance: value)
        #expect(snapshot.creditBalance == nil)
        #expect(!ProviderState(provider: .kie, status: .fresh, snapshot: snapshot).hasDisplayableUsage)
    }
}
