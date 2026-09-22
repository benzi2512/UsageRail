import Foundation
import Testing
@testable import UsageCore

@Test func limitingWindowUsesLowestRemainingQuota() {
    let snapshot = UsageSnapshot(
        provider: .codex,
        windows: [
            UsageWindow(id: "a", title: "A", usedPercent: 20),
            UsageWindow(id: "b", title: "B", usedPercent: 85)
        ],
        source: .codexAppServer
    )
    #expect(snapshot.remainingPercent == 15)
    #expect(snapshot.limitingWindow?.id == "b")
}

@Test func clampsPercentagesWithoutInventingMissingValues() {
    #expect(UsageWindow(id: "low", title: "Low", usedPercent: -20).usedPercent == 0)
    #expect(UsageWindow(id: "high", title: "High", usedPercent: 140).usedPercent == 100)
    #expect(UsageWindow(id: "missing", title: "Missing", usedPercent: nil).remainingPercent == nil)
}

@Test func parsesClaudeOfficialStatusLine() throws {
    let payload = Data(#"""
    {
      "model":{"display_name":"Opus"},
      "rate_limits":{
        "five_hour":{"used_percentage":23.5,"resets_at":1738425600},
        "seven_day":{"used_percentage":41.2,"resets_at":1738857600}
      },
      "unknown_future_field":{"safe":true}
    }
    """#.utf8)
    let snapshot = try BridgeParser.parse(payload, provider: .claude, now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows[0].usedPercent == 23.5)
    #expect(snapshot.windows[1].remainingPercent == 58.8)
    #expect(snapshot.modelName == "Opus")
}

@Test func claudeMissingRateLimitsFailsClosed() {
    let payload = Data(#"{"model":{"display_name":"Opus"}}"#.utf8)
    do {
        _ = try BridgeParser.parse(payload, provider: .claude)
        Issue.record("Expected missing rate limits to fail")
    } catch let error as ConnectorError {
        #expect(error == .unavailable("Claude rate limits appear after the first API response"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func malformedBridgeJSONDoesNotCrash() {
    do {
        _ = try BridgeParser.parse(Data("not-json".utf8), provider: .claude)
        Issue.record("Expected malformed JSON to fail")
    } catch {
        #expect(error is DecodingError || error is ConnectorError || error is CocoaError)
    }
}

@Test func parsesCodexMultiBucketResponse() throws {
    let response = Data(#"""
    {
      "id":2,
      "result":{
        "rateLimits":{},
        "rateLimitsByLimitId":{
          "codex":{
            "limitId":"codex",
            "primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},
            "secondary":{"usedPercent":67,"windowDurationMins":10080,"resetsAt":1800600000}
          }
        }
      }
    }
    """#.utf8)
    let snapshot = try CodexResponseParser.parseRateLimitsResponse(response)
    #expect(snapshot.provider == .codex)
    #expect(snapshot.windows.map(\.title) == ["5-hour", "Weekly"])
    #expect(snapshot.remainingPercent == 33)
}

@Test func codexMissingWindowsFailsClosed() {
    let response = Data(#"{"id":2,"result":{"rateLimits":{}}}"#.utf8)
    do {
        _ = try CodexResponseParser.parseRateLimitsResponse(response)
        Issue.record("Expected a missing window error")
    } catch let error as ConnectorError {
        #expect(error == .unavailable("Codex rate-limit windows are unavailable for this account"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func parsesCopilotUsageWithUserAllowance() throws {
    let response = Data(#"""
    {
      "usageItems":[
        {"product":"Copilot","grossQuantity":40},
        {"product":"Copilot","grossQuantity":20}
      ]
    }
    """#.utf8)
    let snapshot = try CopilotResponseParser.parse(
        response,
        allowance: 300,
        now: Date(timeIntervalSince1970: 1_788_000_000)
    )
    #expect(snapshot.windows[0].used == 60)
    #expect(snapshot.windows[0].usedPercent == 20)
    #expect(snapshot.windows[0].remainingPercent == 80)
    #expect(snapshot.windows[0].isEstimated)
}

@Test func copilotWithoutAllowanceKeepsPercentageUnknown() throws {
    let response = Data(#"{"usageItems":[{"grossQuantity":40}]}"#.utf8)
    let snapshot = try CopilotResponseParser.parse(response, allowance: nil)
    #expect(snapshot.windows[0].used == 40)
    #expect(snapshot.windows[0].remainingPercent == nil)
}

@Test func cacheRoundTripsAndCorruptionFallsBackToEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshots.json")
    let cache = try SnapshotCache(cacheURL: url)
    let snapshot = UsageSnapshot(
        provider: .codex,
        windows: [UsageWindow(id: "a", title: "A", usedPercent: 10)],
        source: .codexAppServer
    )
    try await cache.save([snapshot])
    let restored = await cache.load()
    #expect(restored.count == 1)
    #expect(restored.first?.provider == .codex)
    #expect(restored.first?.windows == snapshot.windows)
    try Data("broken".utf8).write(to: url, options: .atomic)
    #expect(await cache.load().isEmpty)
}

@Test func usageStorePreservesLastGoodSnapshotOnFailure() async {
    let store = UsageStore()
    let snapshot = UsageSnapshot(
        provider: .codex,
        windows: [UsageWindow(id: "a", title: "A", usedPercent: 10)],
        source: .codexAppServer
    )
    await store.apply(snapshot)
    await store.fail(.codex, error: ConnectorError.timedOut)
    let state = await store.state(for: .codex)
    #expect(state.status == .stale)
    #expect(state.snapshot == snapshot)
}

@Test func appSettingsSelectsExactlyOneMenuBarProvider() {
    let settings = AppSettings(
        enabledProviders: Set(ProviderID.allCases),
        railPlacement: .top,
        positionFraction: 1.4,
        selectedProvider: .gemini
    )
    #expect(settings.visibleProviders == [.gemini])
    #expect(settings.enabledProviders == [.gemini])
    #expect(settings.selectedProvider == .gemini)
    #expect(settings.railPlacement == .top)
    #expect(settings.positionFraction == 1)
}

@Test func settingsStorePersistsMenuBarProvider() throws {
    let suiteName = "com.usagerail.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults)
    store.save(AppSettings(selectedProvider: .claude))

    let restored = store.load()
    #expect(restored.selectedProvider == .claude)
    #expect(restored.visibleProviders == [.claude])
}

@Test func parsesEveryClaudeRateLimitKey() throws {
    let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":2},"seven_day":{"used_percentage":3},"opus_model":{"used_percentage":91,"title":"Opus weekly"}}}"#.utf8)
    let snapshot = try BridgeParser.parse(payload, provider: .claude)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.limitingWindow?.title == "Opus weekly")
}

@Test func parsesAllCodexBucketsSpendControlAndCredits() throws {
    let payload = Data(#"""
    {"result":{"rateLimits":{},"rateLimitsByLimitId":{
      "codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"}},
      "special":{"limitId":"special","limitName":"Special","secondary":{"usedPercent":75,"windowDurationMins":10080},"individualLimit":{"used":"$2","limit":"$10","remainingPercent":80,"resetsAt":1800000000}}
    }}}
    """#.utf8)
    let snapshot = try CodexResponseParser.parseRateLimitsResponse(payload)
    #expect(snapshot.windows.count == 4)
    let credits = try #require(snapshot.windows.first { $0.kind == .credits })
    #expect(credits.balance == 12.5)
    #expect(credits.balanceUnit == .credits)
    #expect(credits.compactBalanceText == "12.5 cr")
    #expect(credits.prominentBalanceText == "12.5 credits")
    #expect(snapshot.creditBalance == nil)
    #expect(snapshot.windows.contains { $0.kind == .critical && $0.remainingPercent == 80 })
    #expect(snapshot.limitingWindow?.remainingPercent == 25)
}

@Test func codexCreditBalanceRejectsProviderTextInsteadOfEchoingIt() throws {
    let payload = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":10},"credits":{"hasCredits":true,"balance":"secret_token_example"}}}}"#.utf8)
    let snapshot = try CodexResponseParser.parseRateLimitsResponse(payload)
    let credits = try #require(snapshot.windows.first { $0.kind == .credits })
    #expect(credits.balance == nil)
    #expect(credits.detail == "Credits available")
    #expect(!String(data: try JSONEncoder.usageRail.encode(snapshot), encoding: .utf8)!.contains("secret_token_example"))
}

@Test func copilotKeepsExposedPerModelRows() throws {
    let payload = Data(#"{"usageItems":[{"model":"gpt-5","grossQuantity":7},{"sku":"premium","netQuantity":3}]}"#.utf8)
    let snapshot = try CopilotResponseParser.parse(payload, allowance: 100)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows[1].title == "gpt-5")
    #expect(snapshot.windows[2].used == 3)
}

@Test func oldCacheWithoutNewLimitFieldsStillDecodes() throws {
    let old = Data(#"{"provider":"codex","windows":[{"id":"old","title":"Old quota","usedPercent":25,"isEstimated":false}],"updatedAt":"1970-01-01T00:00:00Z","source":"codexAppServer"}"#.utf8)
    let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: old)
    #expect(snapshot.windows.first?.kind == nil)
    #expect(snapshot.remainingPercent == 75)
}

@Test func fullDetailOrdersCriticalThenWindowType() {
    let snapshot = UsageSnapshot(
        provider: .codex,
        windows: [
            UsageWindow(id: "credits", title: "Credits", usedPercent: nil, kind: .credits),
            UsageWindow(id: "weekly", title: "Week", usedPercent: 20, kind: .weekly),
            UsageWindow(id: "short", title: "5h", usedPercent: 10, kind: .shortTerm),
            UsageWindow(id: "critical", title: "Critical", usedPercent: 96, kind: .monthly)
        ],
        source: .codexAppServer
    )
    #expect(snapshot.limitsForDisplay.map(\.id) == ["critical", "short", "weekly", "credits"])
}
