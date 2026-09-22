import Foundation
import CoreFoundation
import Darwin

/// User-configured HTTPS GET only. This never launches an MCP server, code, or a model request.
public struct CustomConnection: Codable, Equatable, Sendable {
    public enum Metric: String, Codable, CaseIterable, Sendable { case credits, usd, remainingPercent }
    public enum Authentication: String, Codable, CaseIterable, Sendable { case none, bearer, apiKey }
    public let provider: ProviderID
    public let endpoint: String
    public let pointer: String
    public let metric: Metric
    public let authentication: Authentication
    public let multiplier: Double

    public init(provider: ProviderID, endpoint: String, pointer: String, metric: Metric,
                authentication: Authentication, multiplier: Double = 1) throws {
        self.provider = provider; self.endpoint = endpoint; self.pointer = pointer
        self.metric = metric; self.authentication = authentication; self.multiplier = multiplier
        try validate()
    }

    public func validate() throws {
        guard provider.isCustom, let url = URLComponents(string: endpoint), url.scheme == "https",
              let host = url.host, host.contains("."), host.count < 254,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, endpoint.count <= 2048,
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".test"),
              !host.contains(":"), host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              host.split(separator: ".").contains(where: { $0.rangeOfCharacter(from: .letters) != nil }),
              pointer.isEmpty || pointer.hasPrefix("/"), pointer.count < 512,
              pointer.range(of: "~(?![01])", options: .regularExpression) == nil,
              multiplier.isFinite, multiplier != 0, abs(multiplier) <= 1_000_000 else {
            throw ConnectorError.unavailable("Use a public HTTPS endpoint (port 443, no query/token in URL), a JSON pointer such as /data/credits, and a valid scale.")
        }
    }

    public func snapshot(from data: Data) throws -> UsageSnapshot {
        guard data.count <= 256 * 1024 else { throw ConnectorError.outputTooLarge }
        var value: Any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if !pointer.isEmpty {
            for component in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
                let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                if let object = value as? [String: Any], let next = object[key] { value = next }
                else if let array = value as? [Any], let index = Int(key), index >= 0, String(index) == key, array.indices.contains(index) { value = array[index] }
                else { throw ConnectorError.malformedResponse("The usage field was not found. Check the JSON pointer against the provider documentation.") }
            }
        }
        let numeric: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { numeric = number.doubleValue }
        else if let string = value as? String { numeric = Double(string) }
        else { numeric = nil }
        guard let numeric, numeric.isFinite, (numeric * multiplier).isFinite else {
            throw ConnectorError.malformedResponse("The selected field must contain a finite number, not a login page, boolean or text.")
        }
        let amount = numeric * multiplier
        guard metric == .usd || amount >= 0, metric != .remainingPercent || amount <= 100 else {
            throw ConnectorError.malformedResponse("The value is outside the selected unit's range. Check the unit and scale.")
        }
        return UsageSnapshot(provider: provider,
                             windows: metric == .remainingPercent ? [UsageWindow(id: "custom-quota", title: "Remaining quota", usedPercent: nil, remainingPercentReported: amount)] : [],
                             source: .customAPI, creditBalance: metric == .remainingPercent ? nil : amount,
                             balanceUnit: metric == .usd ? .usd : .credits)
    }

    public static func load(defaults: UserDefaults = .standard) -> [Self] {
        guard let data = defaults.data(forKey: "customConnections"), data.count < 64 * 1024,
              let entries = try? JSONDecoder().decode([Self].self, from: data), entries.count <= 20 else { return [] }
        var seen = Set<ProviderID>()
        return entries.filter { (try? $0.validate()) != nil && seen.insert($0.provider).inserted }
    }
    public static func save(_ entries: [Self], defaults: UserDefaults = .standard) throws {
        guard entries.count <= 20, Set(entries.map(\.provider)).count == entries.count else {
            throw ConnectorError.unavailable("Up to 20 distinct custom connections are supported.")
        }
        for entry in entries { try entry.validate() }
        defaults.set(try JSONEncoder().encode(entries), forKey: "customConnections")
    }
}

public struct CustomUsageConnector: UsageConnector {
    public let configuration: CustomConnection
    public var provider: ProviderID { configuration.provider }
    public init(configuration: CustomConnection) { self.configuration = configuration }
    public func refresh() async throws -> UsageSnapshot {
        let token: String
        do { token = configuration.authentication == .none ? "" : try KeychainStore.shared.read(account: provider.rawValue, allowInteraction: false) ?? "" }
        catch { throw ConnectorError.loginRequired("This app's saved token is unavailable or locked. No background permission dialog was opened.") }
        return try await Self.test(configuration, token: token)
    }
    public static func test(_ configuration: CustomConnection, token: String) async throws -> UsageSnapshot {
        try configuration.validate()
        guard configuration.authentication == .none || (!token.isEmpty && token.utf8.count <= 4096
              && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) else {
            throw ConnectorError.loginRequired("Enter a dedicated read-only token in Add connection.")
        }
        guard let url = URL(string: configuration.endpoint), let host = url.host else { throw ConnectorError.malformedResponse("Invalid endpoint") }
        // Reject hosts resolving to local/private addresses before sending any authorization.
        try await Task.detached { try validatePublicDNS(host) }.value
        let delegate = NoCustomRedirects()
        let options = URLSessionConfiguration.ephemeral
        options.httpCookieStorage = nil; options.httpShouldSetCookies = false
        options.urlCache = nil; options.urlCredentialStorage = nil
        options.timeoutIntervalForRequest = 15; options.timeoutIntervalForResource = 20
        let session = URLSession(configuration: options, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.authentication {
        case .none: break
        case .bearer: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey: request.setValue(token, forHTTPHeaderField: "X-API-Key")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectorError.malformedResponse("Invalid HTTPS response") }
            if http.statusCode == 401 || http.statusCode == 403 { throw ConnectorError.loginRequired("The service rejected this token or its read permission.") }
            guard http.statusCode == 200 else { throw ConnectorError.unavailable("Service returned HTTP \(http.statusCode). Redirects are not followed.") }
            guard response.expectedContentLength <= 256 * 1024 else { throw ConnectorError.outputTooLarge }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().split(separator: ";").first ?? ""
            guard type == "application/json" || type.hasSuffix("+json") else { throw ConnectorError.malformedResponse("The endpoint must return JSON, not an HTML login page.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { throw ConnectorError.outputTooLarge }
                data.append(byte)
            }
            return try configuration.snapshot(from: data)
        } catch let error as ConnectorError { throw error }
        catch { throw ConnectorError.unavailable("Could not read the service. Check connectivity and the documented endpoint. No response body is logged.") }
    }
}

private final class NoCustomRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

private func validatePublicDNS(_ host: String) throws {
    var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
    var results: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else { throw ConnectorError.unavailable("Endpoint DNS lookup failed.") }
    defer { freeaddrinfo(first) }
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let item = current {
        let info = item.pointee
        guard info.ai_family == AF_INET || info.ai_family == AF_INET6, let address = info.ai_addr else {
            throw ConnectorError.unavailable("Unsupported endpoint address.")
        }
        var output = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, info.ai_addrlen, &output, socklen_t(output.count), nil, 0, NI_NUMERICHOST) == 0 else {
            throw ConnectorError.unavailable("Could not verify endpoint address.")
        }
        let ip = String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard CustomAddressPolicy.isPublic(ip) else { throw ConnectorError.unavailable("Custom connections cannot access private, loopback or reserved network addresses.") }
        current = info.ai_next
    }
}

public enum CustomAddressPolicy {
    public static func isPublic(_ ip: String) -> Bool {
        if ip.contains(":") {
            // Only global unicast; reject mapped IPv4, ULA, link-local and tunneling ranges.
            let lower = ip.lowercased()
            return (lower.hasPrefix("2") || lower.hasPrefix("3")) && !lower.hasPrefix("2001:") && !lower.hasPrefix("2002:") && !lower.contains("%")
        }
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b))
                 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                 || (a == 192 && (b == 168 || b == 0 || b == 2)) || (a == 198 && (b == 18 || b == 19 || b == 51)) || (a == 203 && b == 0))
    }
}
