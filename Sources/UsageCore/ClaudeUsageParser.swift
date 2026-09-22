import CoreFoundation
import Foundation

/// Claude Code's control-protocol usage reply (shape checked against 2.1.233), not scraped
/// terminal text. get_usage is experimental: unknown envelopes and absent quotas fail closed.
public enum ClaudeUsageParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard data.count <= SnapshotCache.maximumBytes else { throw ConnectorError.outputTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "control_response",
              let response = root["response"] as? [String: Any],
              response["request_id"] as? String == "usage-rail-read",
              response["subtype"] as? String == "success",
              let body = response["response"] as? [String: Any],
              let session = body["session"] as? [String: Any],
              number(session["total_cost_usd"]) == 0 else {
            throw ConnectorError.malformedResponse("Claude Code returned a usage reply UsageRail doesn't understand. Update UsageRail or Claude Code.")
        }
        guard body["rate_limits_available"] as? Bool == true else {
            throw ConnectorError.loginRequired("Sign in to the configured Claude Code profile with a supported Claude subscription.")
        }
        guard let limits = body["rate_limits"] as? [String: Any] else {
            throw ConnectorError.unavailable("Claude quota lookup failed. The login may still be valid; use Refresh to try again.")
        }

        var windows: [UsageWindow] = []
        let fixed: [(String, String, UsageLimitKind)] = [
            ("five_hour", "5-hour session", .shortTerm),
            ("seven_day", "Weekly · all models", .weekly)
        ]
        for (key, title, kind) in fixed {
            guard let value = limits[key] as? [String: Any], let percent = percent(value["utilization"]) else { continue }
            windows.append(UsageWindow(id: key.replacingOccurrences(of: "_", with: "-"), title: title,
                                       usedPercent: percent, resetAt: date(value["resets_at"]), kind: kind,
                                       breakdown: key == "seven_day" ? breakdown(limits["seven_day_breakdown"]) : nil))
        }

        // Only vendor-labelled model and product scopes, never internal bucket names such as nimbus_quill.
        var scopedNames: Set<String> = []
        func appendScoped(id: String, name: String, used: Double, resetsAt: Any?) {
            guard scopedNames.insert(name).inserted else { return }
            windows.append(UsageWindow(id: id, title: "Weekly · \(name)", usedPercent: used,
                                       resetAt: date(resetsAt), kind: .model))
        }
        if let scoped = limits["limits"] as? [[String: Any]] {
            for value in scoped {
                guard value["kind"] as? String == "weekly_scoped",
                      let scope = value["scope"] as? [String: Any],
                      let used = percent(value["percent"]) else { continue }
                if let model = scope["model"] as? [String: Any], let name = name(model["display_name"]) {
                    appendScoped(id: "model-\(name)", name: name, used: used, resetsAt: value["resets_at"])
                } else if let surface = scope["surface"] as? [String: Any], let name = name(surface["display_name"]) {
                    appendScoped(id: "surface-\(name)", name: name, used: used, resetsAt: value["resets_at"])
                }
            }
        }
        if let scoped = limits["model_scoped"] as? [[String: Any]] {
            for value in scoped {
                guard let name = name(value["display_name"]), let used = percent(value["utilization"]) else { continue }
                appendScoped(id: "model-\(name)", name: name, used: used, resetsAt: value["resets_at"])
            }
        }
        for (key, id, label) in [("seven_day_opus", "model-Opus", "Opus"), ("seven_day_sonnet", "model-Sonnet", "Sonnet"),
                                 ("seven_day_cowork", "surface-Cowork", "Cowork")] {
            guard let value = limits[key] as? [String: Any], let used = percent(value["utilization"]) else { continue }
            appendScoped(id: id, name: label, used: used, resetsAt: value["resets_at"])
        }
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = percent(extra["utilization"]) {
            windows.append(UsageWindow(id: "extra-usage", title: "Extra usage", usedPercent: used, kind: .credits))
        }
        guard !windows.isEmpty else {
            throw ConnectorError.malformedResponse("Claude did not return a supported numeric usage window.")
        }
        return UsageSnapshot(provider: .claude, windows: windows, updatedAt: now, source: .claudeCode)
    }

    /// This week's usage by product (Claude Code, Chats, Cowork…). Shares of what was used,
    /// not limits; an all-zero breakdown (a fresh week) is omitted.
    private static func breakdown(_ value: Any?) -> [UsageShare]? {
        guard let object = value as? [String: Any], let rows = object["rows"] as? [[String: Any]] else { return nil }
        var seen: Set<String> = []
        var shares: [UsageShare] = []
        for row in rows.prefix(12) {
            guard let title = name(row["display_name"]), let share = percent(row["percent"]),
                  seen.insert(title).inserted else { continue }
            let key = (row["key"] as? String).flatMap { key in
                key.count <= 40 && key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) ? key : nil
            }
            shares.append(UsageShare(id: key ?? title, title: title, percent: share))
        }
        return shares.contains { $0.percent > 0 } ? shares : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let value = number(value), (0...100).contains(value) else { return nil }
        return value
    }

    private static func name(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 100,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
