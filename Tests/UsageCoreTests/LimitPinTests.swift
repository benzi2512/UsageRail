import Foundation
import Testing
@testable import UsageCore

// Mirrors the live Claude payload: weekly has more left than the Fable model limit.
private let pinWindows = [UsageWindow(id: "five-hour", title: "Rolling 5 hours", usedPercent: 9, kind: .shortTerm),
                          UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 51, kind: .weekly),
                          UsageWindow(id: "model-Fable", title: "Fable · Rolling 7 days", usedPercent: 60, kind: .model)]
private func pinState(_ windows: [UsageWindow], provider: ProviderID = .claude) -> ProviderState {
    ProviderState(provider: provider, status: .fresh, snapshot: UsageSnapshot(provider: provider, windows: windows, source: .claudeCode))
}

@Test func expiredConnectionCannotPresentFreshQuota() {
    let original = pinState(pinWindows)
    let expired = ProviderState(provider: .claude, status: .loginRequired, snapshot: original.snapshot)
    let settings = AppSettings(selectedProvider: .claude)
    #expect(expired.displayValue == "—")
    #expect(MenuBarPresentation(expired) != MenuBarPresentation(original))
    #expect(MenuBarPresentation(expired).percent == nil)
    #expect(settings.hoverStates(from: [expired]).isEmpty)
    #expect(settings.displayState(from: expired).snapshot == nil)
}

@Test func automaticShowsTheLowestLimit() {
    let settings = AppSettings(selectedProvider: .claude)
    #expect(settings.menuBarStates(from: [pinState(pinWindows)]).first?.displayValue == "40%")
    #expect(settings.displayedLimit(in: pinState(pinWindows))?.id == "model-Fable")
}

/// Regression for build 23: pinning Claude's weekly row changed only the hover bar,
/// while the top bar kept showing the lower Fable limit.
@Test func pinnedWeeklyLimitDrivesTopBarAndHoverBar() {
    var settings = AppSettings(selectedProvider: .claude)
    settings.pinLimit("seven-day", of: .claude)
    let states = [pinState(pinWindows)]
    #expect(settings.menuBarStates(from: states).map(\.displayValue) == ["49%"])
    #expect(settings.hoverStates(from: states).first?.displayValue == "49%")
    #expect(settings.displayedLimit(in: states[0])?.id == "seven-day")
    #expect(settings.menuBarProviders == [.claude])
    // Detail keeps every limit.
    #expect(states[0].snapshot?.windows.count == 3)
}

@Test func pinnedLimitFollowsUpdatesAndReturnsToAutomatic() {
    var settings = AppSettings(selectedProvider: .claude)
    settings.pinLimit("seven-day", of: .claude)
    var windows = pinWindows
    windows[1] = UsageWindow(id: "seven-day", title: "Rolling 7 days", usedPercent: 52, kind: .weekly)
    #expect(settings.menuBarStates(from: [pinState(windows)]).first?.displayValue == "48%")
    settings.selectLimit(nil, for: .claude)
    #expect(settings.limitSelections.isEmpty)
    #expect(settings.menuBarStates(from: [pinState(windows)]).first?.displayValue == "40%")
}

@Test func pinnedLimitMissingNeverFallsBackToAnotherLimit() {
    var settings = AppSettings(selectedProvider: .claude)
    settings.selectLimit("seven-day", for: .claude)
    #expect(settings.displayState(from: pinState([pinWindows[0]])).displayValue == "—")
    #expect(settings.displayState(from: pinState([pinWindows[0]])).connectionHint.contains("choose Auto"))
    #expect(settings.limitSelection(for: .claude) == "seven-day")
    #expect(settings.displayState(from: pinState([UsageWindow(id: "seven-day", title: "Renamed", usedPercent: 30)])).displayValue == "70%")
}

@Test func pinningALimitOfAnotherProviderAddsASecondMenuBarItem() {
    var settings = AppSettings(selectedProvider: .claude)
    settings.pinLimit("seven-day", of: .claude)
    let displaced = settings.pinLimit("codex-primary", of: .codex)
    #expect(displaced == nil)
    #expect(settings.menuBarProviders == [.claude, .codex])
    let codex = pinState([UsageWindow(id: "codex-primary", title: "Rolling 7 days", usedPercent: 25)], provider: .codex)
    #expect(settings.menuBarStates(from: [pinState(pinWindows), codex]).map(\.displayValue) == ["49%", "75%"])
    // Pins lead the hover bar, in pin order.
    #expect(settings.hoverStates(from: [codex, pinState(pinWindows)]).map(\.provider) == [.claude, .codex])
}

@Test func menuBarHoldsAtMostThreeAndNeverZeroItems() {
    var settings = AppSettings(selectedProvider: .claude)
    let displaced = [settings.pinToMenuBar(.codex), settings.pinToMenuBar(.kie),
                     settings.pinToMenuBar(.claude), settings.pinToMenuBar(.runpod)]
    #expect(displaced == [nil, nil, nil, .claude])
    #expect(settings.menuBarProviders == [.codex, .kie, .runpod])
    let removed = [settings.unpinFromMenuBar(.kie), settings.unpinFromMenuBar(.codex), settings.unpinFromMenuBar(.runpod)]
    #expect(removed == [true, true, false])
    #expect(settings.menuBarProviders == [.runpod])
    #expect(settings.selectedProvider == .runpod)
}

@Test func codexCreditBalanceCanBePinnedAsTheDisplayedLimit() {
    let credits = UsageWindow(id: "credits", title: "Codex credits", usedPercent: nil,
                              kind: .credits, balance: 5_000, balanceUnit: .credits)
    let snapshot = UsageSnapshot(provider: .codex, windows: [pinWindows[0], credits], source: .codexAppServer)
    let state = ProviderState(provider: .codex, status: .fresh, snapshot: snapshot)
    var settings = AppSettings(selectedProvider: .codex)
    #expect(settings.displayState(from: state).displayValue == "91%")
    settings.pinLimit("credits", of: .codex)
    let menuBar = settings.displayState(from: state)
    #expect(menuBar.displayValue == "5,000 cr")
    #expect(menuBar.snapshot?.creditBalance == 5_000)
    #expect(MenuBarPresentation(menuBar).percent == nil)
    #expect(state.snapshot?.creditBalance == nil)
    #expect(state.snapshot?.windows.count == 2)
}

@Test func pinsAndLimitsPersistAndStayRollbackReadable() throws {
    let suite = "com.usagerail.pin.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    settings.setMenuBarProviders([.claude])
    settings.pinLimit("seven-day", of: .claude)
    settings.pinToMenuBar(.codex)
    settings.glassStyle = .regular
    store.save(settings)
    let restored = store.load()
    #expect(restored.menuBarProviders == [.claude, .codex])
    #expect(restored.limitSelection(for: .claude) == "seven-day")
    #expect(restored.glassStyle == .regular)
    // Build 23 reads these keys: same primary provider and the same limit on its top bar.
    #expect(defaults.string(forKey: "selectedProvider") == "claude")
    #expect(defaults.string(forKey: "selectedLimitID") == "seven-day")
    #expect((defaults.dictionary(forKey: "stripLimitIDs") as? [String: String]) == ["claude": "seven-day"])
}

@Test func build23HoverPinMigratesToTheMenuBarLimit() throws {
    let suite = "com.usagerail.migrate.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Exactly the live build 23 state: top bar automatic, weekly pinned only for hover.
    defaults.set("claude", forKey: "selectedProvider")
    defaults.set(["claude"], forKey: "enabledProviders")
    defaults.set(["claude": "seven-day"], forKey: "stripLimitIDs")
    let settings = SettingsStore(defaults: defaults).load()
    #expect(settings.menuBarProviders == [.claude])
    #expect(settings.menuBarStates(from: [pinState(pinWindows)]).first?.displayValue == "49%")
}

@Test func build23TopBarLimitWinsOverItsHoverChoice() throws {
    let suite = "com.usagerail.migrate-top.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("claude", forKey: "selectedProvider")
    defaults.set("five-hour", forKey: "selectedLimitID")
    defaults.set(["claude": "seven-day", "codex": "credits"], forKey: "stripLimitIDs")
    let settings = SettingsStore(defaults: defaults).load()
    #expect(settings.limitSelection(for: .claude) == "five-hour")
    #expect(settings.limitSelection(for: .codex) == "credits")
}

@Test func connectionCopyDoesNotEchoSensitiveProviderOutput() {
    let state = ProviderState(provider: .claude, status: .stale, snapshot: nil, message: "Unexpected failure secret_token_example /private/profile")
    #expect(!state.connectionHint.contains("secret_token"))
    #expect(!state.connectionHint.contains("/private"))
    let changed = ProviderState(provider: .claude, status: .unavailable, snapshot: nil, message: "Executable changed; revalidate")
    #expect(changed.connectionHint.contains("signing in again will not fix"))
}

@Test func multiplePinsAreAllPolledAutomatically() {
    let pinned: Set<ProviderID> = [.claude, .codex]
    #expect(RefreshPolicy.interval(for: .claude, pinned: pinned, lowPower: false) == 900)
    #expect(RefreshPolicy.interval(for: .codex, pinned: pinned, lowPower: false) == 300)
    #expect(RefreshPolicy.interval(for: .kie, pinned: pinned, lowPower: false) == nil)
}

@Test func build24ClearDefaultMovesToRegularButAChosenClearStays() throws {
    let suite = "com.usagerail.glass.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    #expect(store.load().glassStyle == .regular)
    // Build 24 wrote its Clear default on every save, without a revision.
    defaults.set("clear", forKey: "glassStyle")
    #expect(store.load().glassStyle == .regular)
    var settings = store.load()
    settings.glassStyle = .clear
    store.save(settings)
    #expect(store.load().glassStyle == .clear)
}
