import Foundation

public struct CacheEnvelope: Codable, Sendable {
    public let version: Int
    public let snapshots: [UsageSnapshot]

    public init(version: Int = 1, snapshots: [UsageSnapshot]) {
        self.version = version
        self.snapshots = snapshots
    }
}

public enum UsagePaths {
    public static func applicationSupport(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("UsageRail", isDirectory: true)
    }

    public static func bridgeEvent(for provider: ProviderID, fileManager: FileManager = .default) throws -> URL {
        try applicationSupport(fileManager: fileManager)
            .appendingPathComponent("\(provider.rawValue)-event.json")
    }
}

public actor SnapshotCache {
    public static let maximumBytes = 512 * 1024

    private let fileManager: FileManager
    private let cacheURL: URL
    private var lastSaved: [UsageSnapshot] = []
    private var lastWriteAt: Date?
    private var pending: [UsageSnapshot]?
    private var pendingWrite: Task<Void, Never>?
    private(set) var writeCount = 0

    public init(fileManager: FileManager = .default, cacheURL: URL? = nil) throws {
        self.fileManager = fileManager
        let directory = try cacheURL?.deletingLastPathComponent() ?? UsagePaths.applicationSupport(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.cacheURL = cacheURL ?? directory.appendingPathComponent("snapshots.json")
    }

    public func load() -> [UsageSnapshot] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: cacheURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumBytes,
              let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder.usageRail.decode(CacheEnvelope.self, from: data),
              envelope.version == 1,
              envelope.snapshots.allSatisfy({ $0.creditBalance == nil || $0.isValidBalance }) else {
            return []
        }
        lastSaved = envelope.snapshots
        lastWriteAt = Date()
        return envelope.snapshots
    }

    public func save(_ snapshots: [UsageSnapshot]) throws {
        let data = try JSONEncoder.usageRail.encode(CacheEnvelope(snapshots: snapshots))
        guard data.count <= Self.maximumBytes else { throw ConnectorError.outputTooLarge }
        try data.write(to: cacheURL, options: [.atomic])
        lastSaved = snapshots
        lastWriteAt = Date()
        writeCount += 1
    }

    /// At most one write for a burst; unchanged observations checkpoint only every five minutes.
    public func enqueueSave(_ snapshots: [UsageSnapshot], now: Date = Date()) {
        let unchanged = snapshots.count == lastSaved.count
            && zip(snapshots, lastSaved).allSatisfy { $0.hasSameContent(as: $1) }
        if unchanged, let lastWriteAt, now.timeIntervalSince(lastWriteAt) < 300 {
            pending = nil
            pendingWrite?.cancel()
            pendingWrite = nil
            return
        }
        pending = snapshots
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let snapshots = pending else { return }
        pending = nil
        try? save(snapshots)
    }
}

public extension JSONEncoder {
    static var usageRail: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var usageRail: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
