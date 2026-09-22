import Foundation

public enum CopilotResponseParser {
    public static func parse(
        _ data: Data,
        allowance: Double?,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> UsageSnapshot {
        guard data.count <= SnapshotCache.maximumBytes else { throw ConnectorError.outputTooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["usageItems"] as? [[String: Any]] else {
            throw ConnectorError.malformedResponse("GitHub response is missing usageItems")
        }
        let used = items.reduce(0.0) { sum, item in
            sum + ((item["grossQuantity"] as? NSNumber)?.doubleValue
                ?? (item["netQuantity"] as? NSNumber)?.doubleValue
                ?? (item["quantity"] as? NSNumber)?.doubleValue
                ?? 0)
        }
        let usedPercent = allowance.flatMap { $0 > 0 ? min(100, max(0, (used / $0) * 100)) : nil }

        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = utcCalendar.dateComponents([.year, .month], from: now)
        let monthStart = utcCalendar.date(from: components)
        let resetAt = monthStart.flatMap { utcCalendar.date(byAdding: .month, value: 1, to: $0) }

        var windows = [UsageWindow(
            id: "current-month",
            title: "Current month",
            usedPercent: usedPercent,
            used: used,
            limit: allowance,
            resetAt: resetAt,
            isEstimated: allowance != nil,
            kind: .monthly
        )]
        for (index, item) in items.enumerated() {
            let quantity = (item["grossQuantity"] as? NSNumber)?.doubleValue
                ?? (item["netQuantity"] as? NSNumber)?.doubleValue
                ?? (item["quantity"] as? NSNumber)?.doubleValue
            guard let quantity else { continue }
            let model = (item["model"] as? String)
                ?? (item["sku"] as? String)
                ?? (item["product"] as? String)
            guard let model, !model.isEmpty else { continue }
            windows.append(UsageWindow(
                id: "item-\(index)-\(model)",
                title: model,
                usedPercent: nil,
                used: quantity,
                kind: .model,
                detail: "Usage exposed by GitHub; no per-model allowance exposed"
            ))
        }

        return UsageSnapshot(
            provider: .copilot,
            windows: windows,
            updatedAt: now,
            source: .githubREST
        )
    }
}
