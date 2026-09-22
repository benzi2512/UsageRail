import Foundation
import UsageCore

private func readBoundedStdin() throws -> Data {
    var result = Data()
    while true {
        let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty { break }
        result.append(chunk)
        guard result.count <= BridgeParser.maximumBytes else { throw ConnectorError.outputTooLarge }
    }
    return result
}

private func statusLine(for snapshot: UsageSnapshot) -> String {
    let windows = snapshot.windows.prefix(2).compactMap { window -> String? in
        guard let remaining = window.remainingPercent else { return nil }
        let label = window.id == "five-hour" ? "5h" : (window.id == "seven-day" ? "7d" : window.title)
        return "\(label) \(Int(remaining.rounded()))% left"
    }
    if !windows.isEmpty { return "\(snapshot.provider.shortName) · \(windows.joined(separator: " · "))" }
    if let tokens = snapshot.sessionTokens { return "\(snapshot.provider.shortName) · \(tokens) tokens" }
    return snapshot.provider.shortName
}

do {
    let argument = CommandLine.arguments.dropFirst().first ?? "claude"
    guard let provider = ProviderID(rawValue: argument), provider == .claude || provider == .antigravity else {
        throw ConnectorError.unavailable("Usage: UsageBridge claude|antigravity")
    }
    let data = try readBoundedStdin()
    let snapshot = try BridgeParser.parse(data, provider: provider)
    let destination = try UsagePaths.bridgeEvent(for: provider)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoded = try JSONEncoder.usageRail.encode(snapshot)
    try encoded.write(to: destination, options: [.atomic])
    print(statusLine(for: snapshot))
} catch {
    print("UsageRail · waiting for usage")
}
