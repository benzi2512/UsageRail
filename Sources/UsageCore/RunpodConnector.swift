import Foundation

/// Reads the Runpod USD balance with the key saved in the Keychain. Exactly one fixed GraphQL
/// balance query per refresh to Runpod's host; no pods are started and no redirect is followed.
public struct RunpodConnector: UsageConnector, Sendable {
    public let provider: ProviderID = .runpod
    static let endpoint = URL(string: "https://api.runpod.io/graphql")!
    static let query = "query UsageRailBalance { myself { clientBalance } }"
    private let savedKey: @Sendable () throws -> String?
    private let session: URLSession?

    public init(keychain: KeychainStore = .shared, session: URLSession? = nil) {
        self.init(session: session) { try APIKeyStore.read(.runpod, keychain: keychain) }
    }

    /// Tests supply the key directly instead of touching the Keychain.
    init(session: URLSession?, savedKey: @escaping @Sendable () throws -> String?) {
        self.savedKey = savedKey
        self.session = session
    }

    public func refresh() async throws -> UsageSnapshot {
        guard let key = try savedKey() else {
            throw ConnectorError.loginRequired("Add your Runpod API key in Settings.")
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": Self.query])
        let (data, response) = try await BalanceRequest.send(request, session: session, service: "Runpod")
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ConnectorError.loginRequired("Runpod rejected the API key. Replace it in Settings.")
        }
        guard response.statusCode == 200 else { throw ConnectorError.server(status: response.statusCode) }
        return try RunpodBalanceParser.parse(data)
    }
}

public enum RunpodBalanceParser {
    /// Parses Runpod's GraphQL reply `{"data":{"myself":{"clientBalance":…}}}`. Any GraphQL
    /// error, missing field or non-number fails closed instead of showing a made-up balance.
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 64 * 1024 else { throw ConnectorError.outputTooLarge }
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Account: Decodable { let clientBalance: Double }
                let myself: Account?
            }
            struct GraphQLError: Decodable {}
            let data: Payload?
            let errors: [GraphQLError]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.errors?.isEmpty ?? true,
              let balance = response.data?.myself?.clientBalance, balance.isFinite else {
            throw ConnectorError.malformedResponse("Runpod did not return a verified USD account balance")
        }
        return UsageSnapshot(
            provider: .runpod,
            windows: [UsageWindow(id: "account-balance", title: "Account balance (USD)", usedPercent: nil,
                                  kind: .credits, balance: balance, balanceUnit: .usd)],
            updatedAt: now,
            source: .runpodAPI,
            creditBalance: balance,
            balanceUnit: .usd
        )
    }
}
