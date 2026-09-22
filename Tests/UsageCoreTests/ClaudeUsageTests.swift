import Foundation
import Testing
@testable import UsageCore

private func claudeReply(_ limits: String, available: Bool = true, cost: String = "0") -> Data {
    Data("""
    {"type":"control_response","response":{"subtype":"success","request_id":"usage-rail-read","response":{
    "rate_limits_available":\(available),"session":{"total_cost_usd":\(cost)},"rate_limits":\(limits)}}}
    """.replacingOccurrences(of: "\n", with: "").utf8)
}

@Test func claudeParsesLiveResponseShapeWithoutInternalOrDuplicateBuckets() throws {
    let data = claudeReply(#"""
    {"five_hour":{"utilization":11,"resets_at":"2026-09-05T05:59:59.813330+00:00"},
     "seven_day":{"utilization":8,"resets_at":"2026-09-06T18:59:59.813348+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"nimbus_quill":{"utilization":0},
     "extra_usage":{"is_enabled":false,"utilization":null},
     "limits":[{"kind":"session","percent":11}, {"kind":"weekly_all","percent":8},
       {"kind":"weekly_scoped","percent":15,"resets_at":"2026-09-06T18:59:59.813512+00:00", "scope":{"model":{"display_name":"Fable"}}}]}
    """#)
    let snapshot = try ClaudeUsageParser.parse(data)
    #expect(snapshot.source == .claudeCode)
    #expect(snapshot.windows.map(\.usedPercent) == [11, 8, 15])
    #expect(snapshot.windows.map(\.title) == ["5-hour session", "Weekly · all models", "Weekly · Fable"])
    #expect(snapshot.windows.allSatisfy { $0.resetAt != nil })
    #expect(snapshot.remainingPercent == 85)
    #expect(snapshot.creditBalance == nil)
}

@Test func claudeShowsThisWeeksUsageByProduct() throws {
    // Shape of a 2.1.233 get_usage reply (synthetic numbers), including the per-product week breakdown.
    let data = claudeReply(#"""
    {"five_hour":{"utilization":30,"resets_at":"2026-01-15T21:00:00Z"},
     "seven_day":{"utilization":55,"resets_at":"2026-01-20T18:00:00Z"},
     "seven_day_cowork":null,"seven_day_omelette":null,"nimbus_quill":{"utilization":0},
     "limits":[{"kind":"weekly_scoped","percent":45,"resets_at":"2026-01-20T17:59:59Z",
                "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],
     "seven_day_breakdown":{"as_of":"2026-01-15T18:00:00Z","rows":[
       {"key":"claude_code","display_name":"Claude Code","percent":30},{"key":"chat","display_name":"Chats","percent":6},
       {"key":"cowork","display_name":"Cowork","percent":64},{"key":"other","display_name":"Other","percent":0}]}}
    """#)
    let snapshot = try ClaudeUsageParser.parse(data)
    #expect(snapshot.windows.map(\.id) == ["five-hour", "seven-day", "model-Fable"])
    let week = try #require(snapshot.windows.first { $0.id == "seven-day" })
    #expect(week.breakdown?.map(\.title) == ["Claude Code", "Chats", "Cowork", "Other"])
    #expect(week.breakdown?.map(\.percent) == [30, 6, 64, 0])
    #expect(week.breakdown?.first?.id == "claude_code")
    #expect(snapshot.windows.first { $0.id == "five-hour" }?.breakdown == nil)
    // The breakdown is information, not a limit: the lowest limit stays the weekly 45%.
    #expect(snapshot.remainingPercent == 45)
}

@Test func claudeProductLimitsAppearOnceAndInternalBucketsNever() throws {
    let data = claudeReply(#"""
    {"seven_day":{"utilization":40},"seven_day_cowork":{"utilization":70,"resets_at":"2026-09-27T19:00:00Z"},
     "tangelo":{"utilization":90},"iguana_necktie":{"utilization":90},
     "limits":[{"kind":"weekly_scoped","percent":70,"scope":{"model":null,"surface":{"display_name":"Cowork"}}},
               {"kind":"weekly_scoped","percent":20,"scope":{"surface":{"display_name":"Claude Code"}}},
               {"kind":"weekly_scoped","percent":55,"scope":{"bucket":"nimbus_quill"}}],
     "seven_day_breakdown":{"rows":[{"key":"cowork","display_name":"Cowork","percent":0}]}}
    """#)
    let snapshot = try ClaudeUsageParser.parse(data)
    #expect(snapshot.windows.map(\.title) == ["Weekly · all models", "Weekly · Cowork", "Weekly · Claude Code"])
    #expect(snapshot.windows.map(\.id) == ["seven-day", "surface-Cowork", "surface-Claude Code"])
    // An all-zero breakdown is a fresh week, not information worth a row.
    #expect(snapshot.windows.first?.breakdown == nil)
}

@Test func cachedSnapshotsWithoutBreakdownStillDecode() throws {
    let data = Data(#"{"provider":"claude","windows":[{"id":"seven-day","title":"Rolling 7 days","usedPercent":51,"isEstimated":false}],"updatedAt":"2026-09-22T00:00:00Z","source":"claudeCode"}"#.utf8)
    let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: data)
    #expect(snapshot.windows.first?.breakdown == nil)
    #expect(snapshot.remainingPercent == 49)
}

@Test func claudeNeverTurnsMissingQuotaIntoZeroPercentUsed() {
    for limits in ["null", "{}", #"{"five_hour":{"utilization":null}}"#,
                   #"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":"12"}}"#,
                   #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{"utilization":101}}"#] {
        #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(claudeReply(limits)) }
    }
}

@Test func claudeAcceptsRealZeroAndFullUsage() throws {
    let data = claudeReply(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":100}}"#)
    #expect(try ClaudeUsageParser.parse(data).windows.map(\.remainingPercent) == [100, 0])
}

@Test func claudeRejectsUnexpectedProtocolAndNonzeroSessionCost() {
    let limits = #"{"five_hour":{"utilization":20}}"#
    #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(claudeReply(limits, cost: "0.01")) }
    #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(claudeReply(limits, cost: "false")) }
    #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(claudeReply(limits, available: false)) }
    let wrongID = String(data: claudeReply(limits), encoding: .utf8)!.replacingOccurrences(of: "usage-rail-read", with: "other")
    #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(Data(wrongID.utf8)) }
    #expect(throws: ConnectorError.self) { try ClaudeUsageParser.parse(Data(repeating: 32, count: 600_000)) }
}

@Test func claudeUsesKnownFallbackWindowsAndEnabledExtraUsage() throws {
    let data = claudeReply(#"""
    {"seven_day_opus":{"utilization":9,"resets_at":"2026-09-06T18:59:59Z"},
     "model_scoped":[{"display_name":"Sonnet","utilization":25},{"display_name":"Sonnet","utilization":25}],
     "seven_day_sonnet":{"utilization":25},"extra_usage":{"is_enabled":true,"utilization":40}}
    """#)
    let snapshot = try ClaudeUsageParser.parse(data)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows.first(where: { $0.id == "model-Opus" })?.resetAt != nil)
    #expect(snapshot.windows.last?.title == "Extra usage")
}

@Test func claudeControlStreamHandlesChunksAndIgnoresNonControlMessages() throws {
    let replies = ClaudeControlReplies()
    replies.ingest(Data("{\"type\":\"system\"}\n".utf8))
    var data = claudeReply(#"{"five_hour":{"utilization":11}}"#)
    data.append(0x0A)
    replies.ingest(Data(data.prefix(30)))
    replies.ingest(Data(data.dropFirst(30)))
    let response = try replies.wait(for: "usage-rail-read", seconds: 0.01)
    #expect(try ClaudeUsageParser.parse(response).remainingPercent == 89)
}

@Test func claudeControlStreamIsBoundedAndTerminatesOnEOF() {
    let large = ClaudeControlReplies()
    large.ingest(Data(repeating: 65, count: 600_000))
    #expect(throws: ConnectorError.outputTooLarge) { try large.wait(for: "usage-rail-read", seconds: 0.01) }
    let ended = ClaudeControlReplies()
    ended.finish()
    #expect(throws: ConnectorError.self) { try ended.wait(for: "usage-rail-read", seconds: 0.01) }
    let silent = ClaudeControlReplies()
    #expect(throws: ConnectorError.timedOut) { try silent.wait(for: "usage-rail-read", seconds: 0.01) }
}

@Test func claudeQuotaProcessHasNoPromptAndOnlyExplicitEnvironment() {
    let environment = ClaudeConnector.environment(profile: URL(fileURLWithPath: "/fixture/claude"))
    #expect(environment["DISABLE_TELEMETRY"] == "1")
    #expect(environment["DISABLE_ERROR_REPORTING"] == "1")
    #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
    #expect(environment["ANTHROPIC_API_KEY"] == nil)
    #expect(environment["NODE_OPTIONS"] == nil)
    #expect(environment["NODE_TLS_REJECT_UNAUTHORIZED"] == nil)
    let arguments = ClaudeConnector.arguments
    #expect(arguments.contains("--safe-mode"))
    #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
    #expect(arguments[arguments.firstIndex(of: "--max-turns")! + 1] == "0")
    #expect(arguments[arguments.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(arguments.last == "-p")
}
