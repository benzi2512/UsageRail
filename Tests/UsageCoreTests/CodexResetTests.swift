import Foundation
import Testing
@testable import UsageCore

private func resetFixture(_ resetJSON: String?) -> Data {
    let extra = resetJSON.map { ",\"rateLimitResetCredits\":\($0)" } ?? ""
    return Data("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":63,\"windowDurationMins\":10080}}\(extra)}}".utf8)
}

@Test func resetAvailabilityUsesTheReportedCount() throws {
    for count in [0, 1, 3] {
        let snapshot = try CodexResponseParser.parseRateLimitsResponse(resetFixture("{\"availableCount\":\(count)}"))
        #expect(snapshot.availableResetCount == count)
        #expect(snapshot.remainingPercent == 37)
        #expect(ProviderState(provider: .codex, status: .fresh, snapshot: snapshot).displayableResetCount == (count > 0 ? count : nil))
    }
}

@Test func resetDetailsDoNotOverrideTheAuthoritativeCount() throws {
    for details in ["null", "[]", #"[{"status":"available","title":"Not an instruction"}]"#] {
        let snapshot = try CodexResponseParser.parseRateLimitsResponse(resetFixture("{\"availableCount\":3,\"credits\":\(details)}"))
        #expect(snapshot.availableResetCount == 3)
    }
}

@Test func malformedOrMissingResetCountsDoNotBreakUsageOrInventAvailability() throws {
    let values: [String?] = [nil, "null", "{}", #"{"credits":[{"status":"available"}]}"#,
        #"{"availableCount":null}"#, #"{"availableCount":true}"#, #"{"availableCount":false}"#,
        #"{"availableCount":"1"}"#, #"{"availableCount":-1}"#, #"{"availableCount":1.5}"#,
        #"{"availableCount":1e30}"#, #"{"availableCount":{}}"#]
    for value in values {
        let snapshot = try CodexResponseParser.parseRateLimitsResponse(resetFixture(value))
        #expect(snapshot.availableResetCount == nil)
        #expect(snapshot.remainingPercent == 37)
    }
}

@Test func resetPresentationRequiresCurrentCodexData() {
    let snapshot = UsageSnapshot(provider: .codex, windows: [], source: .codexAppServer, availableResetCount: 1)
    for status in [ProviderStatus.cached, .stale, .unavailable, .loginRequired] {
        #expect(ProviderState(provider: .codex, status: status, snapshot: snapshot).displayableResetCount == nil)
    }
    for status in [ProviderStatus.fresh, .refreshing] {
        #expect(ProviderState(provider: .codex, status: status, snapshot: snapshot).displayableResetCount == 1)
    }
}

@Test func anyProviderReportingResetsShowsTheControlEvenAtZero() {
    for provider in [ProviderID.codex, .claude, .kie] {
        let none = UsageSnapshot(provider: provider, windows: [], source: .manual, availableResetCount: 0)
        let state = ProviderState(provider: provider, status: .fresh, snapshot: none)
        #expect(state.reportedResetCount == 0)
        #expect(state.displayableResetCount == nil)
        let silent = UsageSnapshot(provider: provider, windows: [], source: .manual)
        #expect(ProviderState(provider: provider, status: .fresh, snapshot: silent).reportedResetCount == nil)
    }
}

@Test func resetCountSurvivesCacheWithoutStoringCreditIDs() throws {
    let snapshot = try CodexResponseParser.parseRateLimitsResponse(resetFixture(#"{"availableCount":1,"credits":[{"id":"fixture-only-id"}]}"#), now: Date(timeIntervalSince1970: 1_788_000_000))
    let data = try JSONEncoder.usageRail.encode(snapshot)
    #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only-id"))
    #expect(try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: data) == snapshot)
}

@Test func oldCachedSnapshotsHaveNoResetButton() throws {
    let data = Data(#"{"provider":"codex","windows":[],"updatedAt":"2026-09-04T00:00:00Z","source":"codexAppServer"}"#.utf8)
    let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: data)
    #expect(snapshot.availableResetCount == nil)
    #expect(ProviderState(provider: .codex, status: .fresh, snapshot: snapshot).displayableResetCount == nil)
}

@Test func negativeConstructedResetCountIsDiscarded() {
    let snapshot = UsageSnapshot(provider: .codex, windows: [], source: .codexAppServer, availableResetCount: -1)
    #expect(snapshot.availableResetCount == nil)
}
