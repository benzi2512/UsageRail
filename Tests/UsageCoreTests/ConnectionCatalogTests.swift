import Foundation
import Testing
@testable import UsageCore

private func quota(_ provider: ProviderID, used: Double, status: ProviderStatus = .fresh, at date: Date = Date()) -> ProviderState {
    ProviderState(provider: provider, status: status, snapshot: UsageSnapshot(
        provider: provider, windows: [UsageWindow(id: "week", title: "Rolling 7 days", usedPercent: used)],
        updatedAt: date, source: .manual))
}

private func balance(_ provider: ProviderID, _ amount: Double, unit: BalanceUnit? = nil) -> ProviderState {
    ProviderState(provider: provider, status: .fresh, snapshot: UsageSnapshot(
        provider: provider, windows: [], source: .manual, creditBalance: amount, balanceUnit: unit))
}

@Test func everyBuiltInProviderHasACatalogEntry() {
    for provider in ProviderID.allCases {
        let entry = ConnectionCatalog.entry(for: provider)
        #expect(entry.provider == provider)
        #expect(entry.title == provider.displayName)
        #expect(!entry.summary.isEmpty)
        #expect(ConnectionCatalog.builtIn.contains(entry), "\(provider.rawValue) must be described in the catalog")
    }
    #expect(Set(ConnectionCatalog.builtIn.map(\.id)).count == ConnectionCatalog.builtIn.count)
}

@Test func catalogSetupKindsMatchTheRealConnectors() throws {
    #expect(ConnectionCatalog.entry(for: .codex).setup == .chatGPTApp)
    #expect(ConnectionCatalog.entry(for: .claude).setup == .claudeProfile)
    #expect(ConnectionCatalog.entry(for: .copilot).setup == .copilotToken)
    #expect(ConnectionCatalog.entry(for: .kie).setup == .apiKey(keyPageURL: URL(string: "https://kie.ai/api-key")!))
    #expect(ConnectionCatalog.entry(for: .runpod).setup == .apiKey(keyPageURL: URL(string: "https://console.runpod.io/user/settings")!))
    #expect(ConnectionCatalog.entry(for: .gemini).isGuide)
    #expect(ConnectionCatalog.entry(for: .antigravity).isGuide)
    let custom = try #require(ProviderID.custom(name: "Fixture"))
    #expect(ConnectionCatalog.entry(for: custom).setup == .custom)
    #expect(ConnectionCatalog.entry(for: custom).title == "Fixture")
    // Every API-key setup has a key item and says the key stays in the Keychain.
    for provider in [ProviderID.kie, .runpod] {
        guard case .apiKey(let page) = ConnectionCatalog.entry(for: provider).setup else { Issue.record("not an API key setup"); continue }
        #expect(page.scheme == "https")
        #expect(APIKeyStore.account(for: provider) != nil)
        #expect(ConnectionCatalog.entry(for: provider).credentialLocation == "The key stays in your macOS Keychain.")
    }
}

@Test func guidesAreTruthfulAndNeverAskForKeys() {
    let guides = ConnectionCatalog.research + ConnectionCatalog.builtIn.filter(\.isGuide)
    #expect(ConnectionCatalog.research.count == ConnectionResearch.entries.count)
    for guide in guides {
        #expect(guide.isGuide)
        #expect(guide.guideStatus?.isEmpty == false)
        if case .apiKey = guide.setup { Issue.record("\(guide.title) must not offer a key field") }
        if let url = guide.documentationURL { #expect(url.scheme == "https") }
    }
    for research in ConnectionResearch.entries {
        let entry = ConnectionCatalog.entry(for: research)
        #expect(entry.guideStatus == research.status)
        #expect(entry.documentationURL?.absoluteString == research.source)
        #expect(entry.details?.contains("+ Add web app") == false)
        #expect(ConnectionCatalog.entry(for: .research(research.name)) == entry)
    }
}

@Test func sidebarSectionsGroupEveryProviderExactlyOnce() throws {
    let working = try #require(ProviderID.custom(name: "Working API"))
    let failing = try #require(ProviderID.custom(name: "Failing API"))
    let states = [quota(.claude, used: 51), balance(.runpod, 0, unit: .usd), balance(working, 42),
                  ProviderState(provider: .kie, status: .loginRequired, snapshot: nil, message: "rejected"),
                  ProviderState(provider: failing, status: .unavailable, snapshot: nil, message: "HTTP 500"),
                  quota(.antigravity, used: 10)]
    let sections = ConnectionCatalog.sections(states: states, customProviders: [working, failing, working])
    #expect(sections.connected == [.provider(.claude), .provider(.antigravity), .provider(.runpod), .provider(working)])
    #expect(sections.setUp == [.provider(.codex), .provider(.copilot), .provider(.kie), .provider(failing)])
    #expect(sections.guides == [.provider(.gemini)] + ConnectionResearch.entries.map { .research($0.name) })
    #expect(Set(sections.all).count == sections.all.count)
    #expect(sections.all.count == ProviderID.allCases.count + 2 + ConnectionResearch.entries.count)
}

@Test func statusLineIsTruthfulForEachState() {
    let now = Date()
    let settings = AppSettings()
    #expect(ConnectionCatalog.statusLine(for: nil) == "Not set up")
    #expect(ConnectionCatalog.statusLine(for: ProviderState(provider: .kie, status: .unavailable, snapshot: nil, message: "No data yet")) == "Not set up")
    #expect(ConnectionCatalog.statusLine(for: ProviderState(provider: .kie, status: .unavailable, snapshot: nil, message: "No data yet"),
                                         isConfigured: true) == "Not checked yet")
    let connected = ConnectionCatalog.statusLine(for: quota(.claude, used: 51, at: now), settings: settings, now: now)
    #expect(connected.hasPrefix("Connected · 49% left · Updated "))
    #expect(ConnectionCatalog.statusLine(for: balance(.runpod, 0, unit: .usd), now: now).hasPrefix("Connected · $0.00 · Updated"))
    #expect(ConnectionCatalog.statusLine(for: balance(.kie, 12_345.67), now: now).hasPrefix("Connected · 12.3K cr"))
    #expect(ConnectionCatalog.statusLine(for: ProviderState(provider: .kie, status: .refreshing, snapshot: nil)) == "Checking…")
    let stale = ProviderState(provider: .claude, status: .stale, snapshot: quota(.claude, used: 51).snapshot, message: "HTTP 500")
    #expect(ConnectionCatalog.statusLine(for: stale).contains("Latest check failed"))
    let rejected = ProviderState(provider: .runpod, status: .loginRequired, snapshot: nil, message: "401")
    #expect(ConnectionCatalog.statusLine(for: rejected) == "Credential missing or rejected. Check it below, then try again.")
}

@Test func aCheckWithoutANumberIsNotCalledConnectedUsage() {
    let noAllowance = ProviderState(provider: .copilot, status: .fresh, snapshot: UsageSnapshot(provider: .copilot, windows: [
        UsageWindow(id: "current-month", title: "Current month", usedPercent: nil, used: 12)], source: .githubREST))
    #expect(!noAllowance.hasDisplayableUsage)
    #expect(ConnectionCatalog.isConnectedWithoutValue(noAllowance))
    #expect(ConnectionCatalog.statusLine(for: noAllowance) == "Connected · add your monthly allowance to see what's left")
    #expect(ConnectionCatalog.noValueMessage(for: .copilot).contains("monthly allowance"))
    #expect(!ConnectionCatalog.sections(states: [noAllowance], customProviders: []).connected.contains(.provider(.copilot)))
    let expired = ProviderState(provider: .copilot, status: .loginRequired, snapshot: noAllowance.snapshot, message: "401")
    #expect(!ConnectionCatalog.isConnectedWithoutValue(expired))
}

@Test func statusAndSidebarValueFollowTheChosenLimit() {
    let state = ProviderState(provider: .claude, status: .fresh, snapshot: UsageSnapshot(provider: .claude, windows: [
        UsageWindow(id: "five", title: "Rolling 5 hours", usedPercent: 10),
        UsageWindow(id: "week", title: "Rolling 7 days", usedPercent: 51),
        UsageWindow(id: "model", title: "Fable · Rolling 7 days", usedPercent: 60)], source: .claudeCode))
    var settings = AppSettings(selectedProvider: .claude)
    #expect(ConnectionCatalog.compactValue(for: state, settings: settings) == "40%")
    settings.selectLimit("week", for: .claude)
    #expect(ConnectionCatalog.compactValue(for: state, settings: settings) == "49%")
    #expect(ConnectionCatalog.valueText(for: state, settings: settings) == "49% left")
    // A missing chosen limit still reports the provider truthfully instead of "—".
    settings.selectLimit("gone", for: .claude)
    #expect(ConnectionCatalog.compactValue(for: state, settings: settings) == "40%")
    #expect(ConnectionCatalog.compactValue(for: ProviderState(provider: .claude, status: .loginRequired, snapshot: state.snapshot), settings: settings) == nil)
}

@Test func settingsHintsNeverPointAtTheRemovedConnectionsWindow() {
    let states = [ProviderState(provider: .kie, status: .unavailable, snapshot: nil, message: "Something failed"),
                  ProviderState(provider: .claude, status: .loginRequired, snapshot: nil, message: "expired"),
                  ProviderState(provider: .copilot, status: .loginRequired, snapshot: nil, message: "401"),
                  ProviderState(provider: .claude, status: .unavailable, snapshot: nil, message: "Choose a profile first"),
                  ProviderState(provider: .runpod, status: .unavailable, snapshot: nil, message: "secret_token_example /private/x")]
    for state in states {
        let hint = ConnectionCatalog.settingsHint(for: state)
        #expect(!hint.contains("Connections"), "\(hint)")
        #expect(!hint.contains("secret_token"))
        #expect(!hint.contains("/private"))
    }
}

@Test func refreshCopyMatchesTheRealPolicy() {
    let lines = ConnectionCatalog.refreshSchedule
    #expect(lines.count == 4)
    #expect(lines[3].detail == "Menu-bar checks space out to at most 2× apart until usage moves again.")
    #expect(lines[0].detail == "ChatGPT every 5 min, others every 15 min.")
    #expect(lines[1].detail == "ChatGPT every 15 min, others every 30 min.")
    #expect(lines[2].detail.contains("at most every 5 min (15 min in Low Power Mode)"))
    #expect(RefreshPolicy.interval(for: .codex, pinned: [.codex], lowPower: false) == 300)
    #expect(RefreshPolicy.interval(for: .kie, pinned: [.kie], lowPower: true) == 1_800)
    #expect(!lines.map(\.detail).joined().contains("30 sec"))
    #expect(ConnectionCatalog.refreshFootnote.contains("sleeps"))
}

@Test func customLabelsAndTemplatesProduceValidConnections() throws {
    #expect(CustomConnection.Authentication.allCases.map(ConnectionCatalog.title(for:)) == ["None", "Bearer token", "X-API-Key header"])
    #expect(CustomConnection.Metric.allCases.map(ConnectionCatalog.title(for:)) == ["Credits", "USD", "Percent remaining"])
    #expect(ConnectionCatalog.scaleText(1) == "1")
    #expect(ConnectionCatalog.scaleText(0.01) == "0.01")
    #expect(Double(ConnectionCatalog.scaleText(0.000125)) == 0.000125)
    let template = try #require(ConnectionCatalog.research.compactMap(\.template).first)
    let configuration = try CustomConnection(provider: #require(ProviderID.custom(name: template.name)), endpoint: template.endpoint,
                                             pointer: template.pointer, metric: template.metric,
                                             authentication: template.authentication, multiplier: template.multiplier)
    #expect(try configuration.snapshot(from: Data(#"{"total":{"val":"-1000"}}"#.utf8)).creditBalance == -10)
    #expect(template.note.contains("YOUR_TEAM_ID"))
}

@Test func onlyProvidersWithResetsShowTheResetsRow() {
    #expect(ConnectionCatalog.entry(for: .claude).offersResets)
    #expect(ConnectionCatalog.entry(for: .codex).offersResets)
    for provider in ProviderID.allCases where provider != .claude && provider != .codex {
        #expect(!ConnectionCatalog.entry(for: provider).offersResets)
    }
    #expect(ConnectionCatalog.research.allSatisfy { !$0.offersResets })
}
