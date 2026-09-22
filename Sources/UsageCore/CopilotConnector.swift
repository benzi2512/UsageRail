import Foundation

public final class CopilotConnector: UsageConnector, @unchecked Sendable {
    public let provider: ProviderID = .copilot

    private let settings: @Sendable () -> AppSettings
    private let keychain: KeychainStore
    private let injectedSession: URLSession?

    public init(
        settings: @escaping @Sendable () -> AppSettings,
        keychain: KeychainStore = .shared,
        session: URLSession? = nil
    ) {
        self.settings = settings
        self.keychain = keychain
        self.injectedSession = session
    }

    public func refresh() async throws -> UsageSnapshot {
        let current = settings()
        guard !current.githubUsername.isEmpty else {
            throw ConnectorError.loginRequired("Add your GitHub username in UsageRail Settings")
        }
        guard let token = try keychain.read(account: "github-plan-read"), !token.isEmpty else {
            throw ConnectorError.loginRequired("Add a fine-grained GitHub token with Plan: read")
        }
        guard let encodedUsername = current.githubUsername.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/users/\(encodedUsername)/settings/billing/premium_request/usage") else {
            throw ConnectorError.malformedResponse("GitHub username is invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("UsageRail/0.1", forHTTPHeaderField: "User-Agent")

        let session = injectedSession ?? Self.makeEphemeralSession()
        defer {
            if injectedSession == nil { session.finishTasksAndInvalidate() }
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ConnectorError.unavailable("GitHub is offline or unreachable")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.malformedResponse("GitHub returned a non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ConnectorError.loginRequired("GitHub token is invalid or lacks Plan: read")
        }
        guard http.statusCode == 200 else { throw ConnectorError.server(status: http.statusCode) }
        return try CopilotResponseParser.parse(data, allowance: current.githubAllowance)
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
