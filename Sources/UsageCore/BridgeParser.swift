import Foundation

public enum BridgeParser {
    public static let maximumBytes = 512 * 1024

    public static func parse(_ data: Data, provider: ProviderID, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= maximumBytes else { throw ConnectorError.outputTooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.malformedResponse("Status-line payload is not a JSON object")
        }

        switch provider {
        case .claude:
            return try parseClaude(root, now: now)
        case .antigravity:
            return try parseAntigravity(root, now: now)
        default:
            throw ConnectorError.malformedResponse("UsageBridge only accepts local status-line providers")
        }
    }

    private static func parseClaude(_ root: [String: Any], now: Date) throws -> UsageSnapshot {
        guard let rateLimits = root["rate_limits"] as? [String: Any] else {
            throw ConnectorError.unavailable("Claude rate limits appear after the first API response")
        }
        var windows: [UsageWindow] = []
        let preferredOrder = ["five_hour", "seven_day"]
        let keys = preferredOrder.filter(rateLimits.keys.contains)
            + rateLimits.keys.filter { !preferredOrder.contains($0) }.sorted()
        for key in keys {
            guard let item = rateLimits[key] as? [String: Any],
                  let used = number(item["used_percentage"]) else { continue }
            let title: String
            let kind: UsageLimitKind
            switch key {
            case "five_hour": title = "5-hour session"; kind = .shortTerm
            case "seven_day": title = "Weekly · all models"; kind = .weekly
            default:
                title = (item["title"] as? String)
                    ?? key.replacingOccurrences(of: "_", with: " ").capitalized
                kind = key.localizedCaseInsensitiveContains("model") ? .model : .auxiliary
            }
            windows.append(UsageWindow(
                id: key.replacingOccurrences(of: "_", with: "-"),
                title: title,
                usedPercent: used,
                resetAt: epochDate(item["resets_at"]),
                kind: kind
            ))
        }
        guard !windows.isEmpty else {
            throw ConnectorError.unavailable("Claude did not provide a machine-readable usage window")
        }
        let model = (root["model"] as? [String: Any])?["display_name"] as? String
        return UsageSnapshot(
            provider: .claude,
            windows: windows,
            modelName: model,
            updatedAt: now,
            source: .officialStatusLine
        )
    }

    private static func parseAntigravity(_ root: [String: Any], now: Date) throws -> UsageSnapshot {
        let modelObject = root["model"] as? [String: Any]
        let model = (modelObject?["display_name"] as? String)
            ?? (modelObject?["name"] as? String)
            ?? (root["model_name"] as? String)

        let tokenObject = (root["token_usage"] as? [String: Any])
            ?? (root["tokens"] as? [String: Any])
        let tokens = integer(tokenObject?["total_tokens"])
            ?? integer(tokenObject?["total"])
            ?? integer(root["session_tokens"])

        var windows: [UsageWindow] = []
        if let quota = root["quota"] as? [String: Any],
           let used = number(quota["used_percentage"]) {
            windows.append(UsageWindow(
                id: "quota",
                title: (quota["title"] as? String) ?? "Quota",
                usedPercent: used,
                resetAt: epochDate(quota["resets_at"])
            ))
        }
        if let rateLimits = root["rate_limits"] as? [String: Any] {
            for key in rateLimits.keys.sorted() {
                guard let item = rateLimits[key] as? [String: Any],
                      let used = number(item["used_percentage"]) else { continue }
                windows.append(UsageWindow(
                    id: key,
                    title: (item["title"] as? String) ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                    usedPercent: used,
                    resetAt: epochDate(item["resets_at"])
                ))
            }
        }
        guard !windows.isEmpty || model != nil || tokens != nil else {
            throw ConnectorError.unavailable("Antigravity payload has no verified machine-readable usage fields")
        }
        return UsageSnapshot(
            provider: .antigravity,
            windows: windows,
            sessionTokens: tokens,
            modelName: model,
            updatedAt: now,
            source: .officialStatusLine
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 0, number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
