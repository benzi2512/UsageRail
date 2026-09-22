import Foundation

public struct LocalSnapshotConnector: UsageConnector {
    public let provider: ProviderID
    private let eventURL: URL

    public init(provider: ProviderID, fileManager: FileManager = .default, eventURL: URL? = nil) throws {
        guard provider == .claude || provider == .antigravity else {
            throw ConnectorError.unavailable("Local snapshots only support status-line providers")
        }
        self.provider = provider
        self.eventURL = try eventURL ?? UsagePaths.bridgeEvent(for: provider, fileManager: fileManager)
    }

    public func refresh() async throws -> UsageSnapshot {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: eventURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= SnapshotCache.maximumBytes else {
            if provider == .claude {
                throw ConnectorError.unavailable("Waiting for Claude Code usage. Run /login with your Claude subscription, then send a message. Desktop login alone does not send quota to this bridge.")
            }
            throw ConnectorError.unavailable("No \(provider.shortName) status-line event yet")
        }
        let data = try Data(contentsOf: eventURL)
        let snapshot = try JSONDecoder.usageRail.decode(UsageSnapshot.self, from: data)
        guard snapshot.provider == provider else {
            throw ConnectorError.malformedResponse("Local snapshot provider does not match")
        }
        return snapshot
    }
}
