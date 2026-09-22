import Foundation
import CoreFoundation

public enum CodexResponseParser {
    public static func parseRateLimitsResponse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= SnapshotCache.maximumBytes else { throw ConnectorError.outputTooLarge }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.malformedResponse("Codex response is not a JSON object")
        }
        if let error = response["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Codex app-server returned an error"
            if message.localizedCaseInsensitiveContains("login") || message.localizedCaseInsensitiveContains("auth") {
                throw ConnectorError.loginRequired(message)
            }
            throw ConnectorError.malformedResponse(message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw ConnectorError.malformedResponse("Codex response is missing result")
        }

        let buckets: [(String, [String: Any])]
        if let byID = result["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            buckets = byID.keys.sorted().compactMap { key in
                (byID[key] as? [String: Any]).map { (key, $0) }
            }
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            buckets = [("codex", legacy)]
        } else {
            throw ConnectorError.unavailable("Codex did not return a rate-limit bucket")
        }

        var windows: [UsageWindow] = []
        for (bucketKey, bucket) in buckets {
            let label: String
            if let limitName = bucket["limitName"] as? String, !limitName.isEmpty {
                label = limitName
            } else {
                let rawLabel = (bucket["limitId"] as? String) ?? bucketKey
                label = rawLabel.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let prefixTitles = buckets.count > 1 || label.localizedCaseInsensitiveCompare("codex") != .orderedSame

            if let primary = bucket["primary"] as? [String: Any],
               let window = makeRateWindow(primary, id: "\(bucketKey)-primary", fallbackTitle: "Primary window", bucketLabel: prefixTitles ? label : nil) {
                windows.append(window)
            }
            if let secondary = bucket["secondary"] as? [String: Any],
               let window = makeRateWindow(secondary, id: "\(bucketKey)-secondary", fallbackTitle: "Secondary window", bucketLabel: prefixTitles ? label : nil) {
                windows.append(window)
            }
            if let individual = bucket["individualLimit"] as? [String: Any],
               let remaining = number(individual["remainingPercent"]) {
                let usedText = individual["used"] as? String
                let limitText = individual["limit"] as? String
                let detail = [usedText.map { "Used \($0)" }, limitText.map { "Limit \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                windows.append(UsageWindow(
                    id: "\(bucketKey)-individual",
                    title: "\(label) spend control",
                    usedPercent: nil,
                    remainingPercentReported: remaining,
                    resetAt: epochDate(individual["resetsAt"]),
                    kind: .critical,
                    detail: detail.isEmpty ? nil : detail
                ))
            }
            if let credits = bucket["credits"] as? [String: Any] {
                let unlimited = credits["unlimited"] as? Bool ?? false
                let hasCredits = credits["hasCredits"] as? Bool ?? false
                let balanceValue = creditBalance(credits["balance"])
                if unlimited || hasCredits || credits["balance"] != nil {
                    let detail = unlimited ? "Unlimited" : (balanceValue == nil ? "Credits available" : nil)
                    windows.append(UsageWindow(
                        id: "\(bucketKey)-credits",
                        title: "\(label) credits",
                        usedPercent: nil,
                        kind: .credits,
                        detail: detail,
                        balance: balanceValue,
                        balanceUnit: .credits
                    ))
                }
            }
        }

        guard !windows.isEmpty else {
            throw ConnectorError.unavailable("Codex rate-limit windows are unavailable for this account")
        }
        return UsageSnapshot(provider: .codex, windows: windows, updatedAt: now,
                             source: .codexAppServer, availableResetCount: availableResets(in: result))
    }

    private static func availableResets(in result: [String: Any]) -> Int? {
        // The count is authoritative; detail rows may be omitted/capped. Keep no credit IDs.
        guard let resetCredits = result["rateLimitResetCredits"] as? [String: Any],
              let count = resetCredits["availableCount"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID() else { return nil }
        let value = count.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int.max),
              value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }

    private static func makeRateWindow(
        _ object: [String: Any],
        id: String,
        fallbackTitle: String,
        bucketLabel: String?
    ) -> UsageWindow? {
        guard let used = number(object["usedPercent"]) else { return nil }
        let duration = number(object["windowDurationMins"]).map(Int.init)
        let baseTitle: String
        let kind: UsageLimitKind
        switch duration {
        case 300: baseTitle = "5-hour"; kind = .shortTerm
        case 1_440: baseTitle = "24-hour"; kind = .shortTerm
        case 10_080: baseTitle = "Weekly"; kind = .weekly
        case let minutes? where minutes >= 40_000:
            baseTitle = "\(minutes / 1_440)-day"; kind = .monthly
        case let minutes? where minutes >= 60 && minutes.isMultiple(of: 60):
            baseTitle = "\(minutes / 60)-hour"; kind = .shortTerm
        case let minutes?: baseTitle = "\(minutes)-minute"; kind = .shortTerm
        case nil: baseTitle = fallbackTitle; kind = .auxiliary
        }
        let title = bucketLabel.map { "\($0) · \(baseTitle)" } ?? baseTitle
        return UsageWindow(id: id, title: title, usedPercent: used, resetAt: epochDate(object["resetsAt"]), kind: kind)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            let kept = string.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(kept)
        }
        return nil
    }

    /// Credit balances are exposed as strings by Codex. Parse only a plain,
    /// nonnegative decimal value; never echo arbitrary provider text into the UI.
    private static func creditBalance(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let result = number.doubleValue
            return result.isFinite && result >= 0 ? result : nil
        }
        guard var text = value as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        if text.first == "$" { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }),
              text.filter({ $0 == "." }).count <= 1,
              let result = Double(text), result.isFinite, result >= 0 else { return nil }
        return result
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
