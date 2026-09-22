import Foundation

/// Reads the Kie credit balance with the key saved in the Keychain. Exactly one credit GET per
/// refresh to Kie's fixed host; nothing is generated and no redirect is followed.
public struct KieConnector: UsageConnector, Sendable {
    public let provider: ProviderID = .kie
    static let endpoint = URL(string: "https://api.kie.ai/api/v1/chat/credit")!
    private let savedKey: @Sendable () throws -> String?
    private let session: URLSession?

    public init(keychain: KeychainStore = .shared, session: URLSession? = nil) {
        self.init(session: session) { try APIKeyStore.read(.kie, keychain: keychain) }
    }

    /// Tests supply the key directly instead of touching the Keychain.
    init(session: URLSession?, savedKey: @escaping @Sendable () throws -> String?) {
        self.savedKey = savedKey
        self.session = session
    }

    public func refresh() async throws -> UsageSnapshot {
        guard let key = try savedKey() else {
            throw ConnectorError.loginRequired("Add your Kie API key in Settings.")
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await BalanceRequest.send(request, session: session, service: "Kie")
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ConnectorError.loginRequired("Kie rejected the API key. Replace it in Settings.")
        }
        guard response.statusCode == 200 else { throw ConnectorError.server(status: response.statusCode) }
        return try KieCreditParser.parse(data)
    }
}

public enum KieCreditParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= 64 * 1024 else { throw ConnectorError.outputTooLarge }
        struct Response: Decodable { let code: Int; let msg: String?; let data: Double? }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch {
            throw ConnectorError.malformedResponse("Kie did not return a valid credit balance")
        }
        if response.code == 401 || response.code == 403 {
            throw ConnectorError.loginRequired("Kie rejected the API key. Replace it in Settings.")
        }
        guard response.code == 200 else { throw ConnectorError.server(status: response.code) }
        guard response.msg == "success" else { throw ConnectorError.malformedResponse("Kie credit response was not successful") }
        guard let balance = response.data, balance.isFinite, balance >= 0 else {
            throw ConnectorError.malformedResponse("Kie did not return a nonnegative numeric credit balance")
        }
        return UsageSnapshot(
            provider: .kie,
            windows: [UsageWindow(id: "account-credit", title: "Account credits", usedPercent: nil,
                                  kind: .credits, balance: balance, balanceUnit: .credits)],
            updatedAt: now,
            source: .kieAPI,
            creditBalance: balance
        )
    }
}
