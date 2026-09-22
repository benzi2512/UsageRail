import Foundation
import Testing
@testable import UsageCore

/// Serves canned replies and records requests, so connector tests never reach the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply(status: 200, body: "{}")
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func serve(_ status: Int, _ body: String) {
        lock.withLock { reply = Reply(status: status, body: body); recorded = [] }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = body
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.recorded.append(captured)
            return Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct BalanceConnectorTests {
    @Test func kieSendsOneCreditGETWithTheSavedKey() async throws {
        StubURLProtocol.serve(200, #"{"code":200,"msg":"success","data":5000.5}"#)
        let connector = KieConnector(session: StubURLProtocol.session()) { "synthetic_kie_key_123456" }
        let snapshot = try await connector.refresh()
        #expect(snapshot.creditBalance == 5000.5)
        let requests = StubURLProtocol.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.kie.ai/api/v1/chat/credit")
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic_kie_key_123456")
    }

    @Test func runpodSendsOneFixedBalanceQuery() async throws {
        StubURLProtocol.serve(200, #"{"data":{"myself":{"clientBalance":23.4568}}}"#)
        let connector = RunpodConnector(session: StubURLProtocol.session()) { "synthetic_runpod_key_123456" }
        let snapshot = try await connector.refresh()
        #expect(snapshot.creditBalance == 23.4568)
        #expect(snapshot.balanceUnit == .usd)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.runpod.io/graphql")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic_runpod_key_123456")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["query": "query UsageRailBalance { myself { clientBalance } }"])
    }

    @Test func missingKeyAsksForSetupWithoutAnyRequest() async {
        StubURLProtocol.serve(200, "{}")
        for connector in [KieConnector(session: StubURLProtocol.session()) { nil } as any UsageConnector,
                          RunpodConnector(session: StubURLProtocol.session()) { nil }] {
            await #expect(throws: ConnectorError.loginRequired(connector.provider == .kie
                ? "Add your Kie API key in Settings." : "Add your Runpod API key in Settings.")) {
                try await connector.refresh()
            }
        }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func rejectedKeysNeedSignInAndServerErrorsDoNotLookLikeZero() async {
        StubURLProtocol.serve(401, #"{"error":"unauthorized"}"#)
        await #expect(throws: ConnectorError.loginRequired("Runpod rejected the API key. Replace it in Settings.")) {
            try await RunpodConnector(session: StubURLProtocol.session()) { "synthetic_runpod_key_123456" }.refresh()
        }
        StubURLProtocol.serve(503, "{}")
        await #expect(throws: ConnectorError.server(status: 503)) {
            try await KieConnector(session: StubURLProtocol.session()) { "synthetic_kie_key_123456" }.refresh()
        }
    }

    @Test func oversizedRepliesAreRefused() async {
        StubURLProtocol.serve(200, String(repeating: " ", count: 64 * 1024 + 1))
        await #expect(throws: ConnectorError.outputTooLarge) {
            try await KieConnector(session: StubURLProtocol.session()) { "synthetic_kie_key_123456" }.refresh()
        }
    }
}

@Test func claudeIsLookedUpWhereItsInstallersPutIt() {
    let paths = ClaudeExecutable.candidatePaths(home: "/Users/example")
    #expect(paths.first == "/opt/homebrew/bin/claude")
    #expect(paths.contains("/usr/local/bin/claude"))
    #expect(paths.contains("/Users/example/.local/bin/claude"))
    #expect(paths.allSatisfy { $0.hasPrefix("/") && !$0.contains("..") })
}

@Test func onlyAnthropicSignedClaudeCodeIsTrusted() throws {
    #expect(ClaudeExecutable.requirement.contains("certificate leaf[subject.OU] = \"Q6L2SF6YDW\""))
    #expect(ClaudeExecutable.requirement.contains("identifier \"com.anthropic.claude-code\""))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usagerail-claude-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let impostor = folder.appendingPathComponent("claude")
    try Data("#!/bin/sh\necho usage\n".utf8).write(to: impostor)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)
    #expect(!ClaudeExecutable.isTrusted(impostor))
    // Ad-hoc or foreign-signed binaries fail the Anthropic requirement too.
    #expect(!ClaudeExecutable.isTrusted(URL(fileURLWithPath: "/bin/ls")))
    #expect(!ClaudeExecutable.isTrusted(folder.appendingPathComponent("missing")))
}

@Test func loginCommandQuotesOnlyWhatNeedsQuoting() {
    let profile = URL(fileURLWithPath: "/Users/example/Library/Application Support/UsageRail/Claude usage profile", isDirectory: true)
    #expect(ClaudeConnector.loginCommand(profile: profile, launcher: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        == "CLAUDE_CONFIG_DIR='/Users/example/Library/Application Support/UsageRail/Claude usage profile' /opt/homebrew/bin/claude auth login")
    #expect(ClaudeConnector.shellQuoted("it's here") == #"'it'\''s here'"#)
    #expect(ClaudeConnector.shellQuoted("") == "''")
}
