import Foundation
import Testing
@testable import UsageCore

private func fixture(pointer: String = "/data/credits", metric: CustomConnection.Metric = .credits, multiplier: Double = 1) throws -> CustomConnection {
    try CustomConnection(provider: #require(ProviderID.custom(name: "Fixture App")), endpoint: "https://api.example.com/balance",
                         pointer: pointer, metric: metric, authentication: .bearer, multiplier: multiplier)
}

@Test func customIdentityPreservesBuiltinEncodingAndUniqueNames() throws {
    #expect(String(data: try JSONEncoder().encode(ProviderID.codex), encoding: .utf8) == "\"codex\"")
    #expect(try JSONDecoder().decode(ProviderID.self, from: Data("\"claude\"".utf8)) == .claude)
    let first = try #require(ProviderID.custom(name: "Demo"))
    let second = try #require(ProviderID.custom(name: "Demo"))
    #expect(first != second)
    #expect(first.displayName == "Demo")
    #expect(try JSONDecoder().decode(ProviderID.self, from: JSONEncoder().encode(first)) == first)
    #expect(ProviderID.custom(name: "") == nil)
    #expect(ProviderID.custom(name: "bad\nname") == nil)
    #expect(ProviderID(rawValue: "custom:bad:RGVtbw==") == nil)
    #expect(ProviderID(rawValue: "unknown") == nil)
}

@Test func customJSONMappingHandlesZeroDecimalsArraysAndEscapes() throws {
    #expect(try fixture().snapshot(from: Data(#"{"data":{"credits":0}}"#.utf8)).creditBalance == 0)
    #expect(try fixture(pointer: "/total/val", metric: .usd, multiplier: 0.01)
        .snapshot(from: Data(#"{"total":{"val":"-1000"}}"#.utf8)).creditBalance == -10)
    #expect(try fixture(pointer: "/items/0/a~1b~0c", metric: .remainingPercent)
        .snapshot(from: Data(#"{"items":[{"a/b~c":42.5}]}"#.utf8)).remainingPercent == 42.5)
}

@Test func customMappingRejectsInvalidAndOutOfRangeValues() throws {
    for json in [#"{"data":{"credits":true}}"#, #"{"data":{"credits":null}}"#, #"{"data":{"credits":"NaN"}}"#,
                 #"{"data":{"credits":-1}}"#, #"{"data":{"credits":{}}}"#, "<html>login</html>", "{}"] {
        #expect(throws: (any Error).self) { try fixture().snapshot(from: Data(json.utf8)) }
    }
    #expect(throws: (any Error).self) { try fixture(metric: .remainingPercent).snapshot(from: Data(#"{"data":{"credits":101}}"#.utf8)) }
    #expect(throws: (any Error).self) { try fixture().snapshot(from: Data(repeating: 32, count: 256 * 1024 + 1)) }
    #expect(throws: (any Error).self) { try fixture(pointer: "/bad~2") }
}

@Test func customEndpointValidationRejectsUnsafeDestinationsAndSecretsInURL() throws {
    let provider = try #require(ProviderID.custom(name: "Test"))
    for endpoint in ["http://api.example.com/balance", "https://localhost/balance", "https://127.0.0.1/balance",
                     "https://[::1]/balance", "https://example.local/balance", "https://api.example.com:8080/balance",
                     "https://user:password@api.example.com/balance", "https://api.example.com/balance?token=secret",
                     "file:///etc/passwd", "https://api.example.com/balance#token"] {
        #expect(throws: (any Error).self) { try CustomConnection(provider: provider, endpoint: endpoint, pointer: "/value", metric: .usd, authentication: .none) }
    }
    for ip in ["127.0.0.1", "10.0.0.1", "169.254.169.254", "192.168.1.1", "172.16.0.1", "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "::ffff:127.0.0.1", "fe80::1", "fc00::1", "2001:db8::1", "2002::1"] {
        #expect(!CustomAddressPolicy.isPublic(ip))
    }
    #expect(CustomAddressPolicy.isPublic("8.8.8.8"))
    #expect(CustomAddressPolicy.isPublic("2606:4700:4700::1111"))
}

@Test func customConnectionsPersistAndAppearInSettingsWithoutKeys() throws {
    let suite = "com.usagerail.customtests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = try fixture(), second = try fixture()
    try CustomConnection.save([first, second], defaults: defaults)
    #expect(CustomConnection.load(defaults: defaults) == [first, second])
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    #expect(settings.providerOrder.contains(first.provider))
    #expect(settings.providerOrder.contains(second.provider))
    settings.pinToMenuBar(second.provider); store.save(settings)
    #expect(store.load().menuBarProviders.contains(second.provider))
    #expect(!String(data: try #require(defaults.data(forKey: "customConnections")), encoding: .utf8)!.contains("token"))
    #expect(throws: (any Error).self) { try CustomConnection.save([first, first], defaults: defaults) }
}

@Test func customSnapshotIsCachedAndPollingIsConservative() async throws {
    let config = try fixture()
    let snapshot = try config.snapshot(from: Data(#"{"data":{"credits":12}}"#.utf8))
    let store = UsageStore()
    await store.apply(snapshot)
    #expect(await store.allSnapshots().contains(snapshot))
    #expect(await store.state(for: config.provider).hasDisplayableUsage)
    #expect(RefreshPolicy.interval(for: config.provider, selected: config.provider, lowPower: false) == 900)
    #expect(RefreshPolicy.interval(for: config.provider, selected: config.provider, lowPower: true) == 1_800)
    #expect(RefreshPolicy.interval(for: config.provider, selected: .codex, lowPower: false) == nil)
}
