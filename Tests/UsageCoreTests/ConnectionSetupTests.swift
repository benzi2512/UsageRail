import Foundation
import Testing
@testable import UsageCore

@Test func pinAddsMenuBarItemWithoutTouchingAccountsOrOrder() {
    var settings = AppSettings(githubUsername: "fixture-user", githubAllowance: 300, selectedProvider: .codex)
    settings.pinToMenuBar(.claude)
    #expect(settings.menuBarProviders == [.codex, .claude])
    #expect(settings.enabledProviders == [.codex, .claude])
    #expect(settings.visibleProviders == [.codex, .claude])
    #expect(settings.hoverOrder.prefix(2) == [.codex, .claude])
    #expect(Set(settings.providerOrder).count == ProviderID.allCases.count)
    #expect(settings.githubUsername == "fixture-user")
    #expect(settings.githubAllowance == 300)
    settings.pinToMenuBar(.claude)
    #expect(settings.menuBarProviders == [.codex, .claude])
    #expect(settings.providerOrder.count == ProviderID.allCases.count)
}

@Test func menuBarPinPersistsAcrossSettingsReload() throws {
    let suite = "com.usagerail.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(defaults: defaults)
    var settings = store.load()
    settings.setMenuBarProviders([.runpod])
    store.save(settings)
    #expect(store.load().selectedProvider == .runpod)
    #expect(store.load().hoverOrder.first == .runpod)
    settings.pinToMenuBar(.kie)
    store.save(settings)
    #expect(store.load().menuBarProviders == [.runpod, .kie])
}

@Test func apiKeysAreTrimmedAndShapeChecked() throws {
    #expect(try APIKeyStore.validated("  synthetic_fixture_123456789\n", for: .runpod) == "synthetic_fixture_123456789")
    #expect(try APIKeyStore.validated("rpa_ABC.def-123456", for: .kie) == "rpa_ABC.def-123456")
    for key in ["", "short", "has space inside 123456", "semi;colon_123456789", "line\nbreak_123456789",
                String(repeating: "a", count: 513)] {
        #expect(throws: APIKeyStore.SetupError.self) { try APIKeyStore.validated(key, for: .kie) }
    }
}

@Test func onlyKieAndRunpodUseAPIKeyItems() {
    #expect(APIKeyStore.account(for: .kie) == "kie-api-key")
    #expect(APIKeyStore.account(for: .runpod) == "runpod-api-key")
    for provider in ProviderID.allCases where provider != .kie && provider != .runpod {
        #expect(APIKeyStore.account(for: provider) == nil)
        #expect(!APIKeyStore.hasSavedKey(provider))
    }
    #expect(throws: APIKeyStore.SetupError.self) { try APIKeyStore.validated("synthetic_fixture_123456789", for: .claude) }
}

@Test func researchEntriesAreNotConnectedProviderIDs() {
    #expect(ConnectionResearch.entries.count == 5)
    #expect(ConnectionResearch.entries.allSatisfy { URL(string: $0.source)?.scheme == "https" })
    #expect(!ProviderID.allCases.map(\.rawValue).contains("arcads"))
    #expect(ConnectionResearch.entries.first(where: { $0.name == "Arcads" })?.status.hasPrefix("Blocked") == true)
}

@Test func earlierVersionsKeyFilesParseLikeTheirHelper() {
    let text = """
    # Kie.ai connector credentials
    #
    KIE_API_KEY = "synthetic_quoted_key_123456"
    OTHER=ignored
    """
    #expect(LegacyKeyFile.value(named: "KIE_API_KEY", in: text) == "synthetic_quoted_key_123456")
    #expect(LegacyKeyFile.value(named: "RUNPOD_API_KEY", in: "RUNPOD_API_KEY=synthetic_fixture_123456789\n") == "synthetic_fixture_123456789")
    #expect(LegacyKeyFile.value(named: "KIE_API_KEY", in: "KIE_API_KEY='a'\r\nKIE_API_KEY=last_one_wins_123456\r\n") == "last_one_wins_123456")
    #expect(LegacyKeyFile.value(named: "KIE_API_KEY", in: "# KIE_API_KEY=commented_out_123456\n") == nil)
    #expect(LegacyKeyFile.value(named: "KIE_API_KEY", in: "XKIE_API_KEY=wrong_name_123456789\n") == nil)
}

@Test func earlierVersionsKeyFileIsReadOnlyWhenPrivate() throws {
    let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("usagerail-legacy-key-\(UUID().uuidString)")
    let folder = home.appendingPathComponent(".codex/connectors/runpod")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: home) }
    let file = folder.appendingPathComponent(".env")
    #expect(!LegacyKeyFile.exists(for: .runpod, home: home))
    #expect(LegacyKeyFile.read(for: .runpod, home: home) == nil)

    try Data("RUNPOD_API_KEY=synthetic_fixture_123456789\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(!LegacyKeyFile.exists(for: .runpod, home: home))
    #expect(LegacyKeyFile.read(for: .runpod, home: home) == nil)

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(LegacyKeyFile.exists(for: .runpod, home: home))
    #expect(LegacyKeyFile.read(for: .runpod, home: home) == "synthetic_fixture_123456789")
    #expect(LegacyKeyFile.read(for: .kie, home: home) == nil)
    #expect(LegacyKeyFile.path(for: .copilot, home: home) == nil)

    // A symlink to a private file is refused.
    let kieFolder = home.appendingPathComponent(".codex/connectors/kie")
    try FileManager.default.createDirectory(at: kieFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: kieFolder.appendingPathComponent(".env"), withDestinationURL: file)
    #expect(!LegacyKeyFile.exists(for: .kie, home: home))
    #expect(LegacyKeyFile.read(for: .kie, home: home) == nil)
}
