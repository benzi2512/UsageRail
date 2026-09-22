import Darwin
import Foundation
import UsageCore

final class BridgeEventMonitor: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let source: DispatchSourceFileSystemObject
    private let directory: URL
    private let queue = DispatchQueue(label: "com.usagerail.bridge-monitor", qos: .utility)
    private let lock = NSLock()
    private var modificationDates: [ProviderID: Date] = [:]
    private var pendingDelivery: DispatchWorkItem?
    private let handler: @Sendable ([ProviderID]) -> Void

    init(directoryURL: URL? = nil, handler: @escaping @Sendable ([ProviderID]) -> Void) throws {
        self.handler = handler
        directory = try directoryURL ?? UsagePaths.applicationSupport()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileDescriptor = open(directory.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw ConnectorError.unavailable("Unable to monitor local usage events")
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: queue
        )
        for provider in [ProviderID.claude, .antigravity] {
            if let date = modificationDate(for: provider) { modificationDates[provider] = date }
        }
        source.setEventHandler { [weak self] in self?.scheduleDelivery() }
        source.setCancelHandler { [fileDescriptor] in close(fileDescriptor) }
        source.resume()
    }

    deinit {
        lock.withLock { pendingDelivery?.cancel() }
        source.cancel()
    }

    private func scheduleDelivery() {
        lock.withLock {
            guard pendingDelivery == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.directoryChanged() }
            pendingDelivery = work
            // Coalesce atomic-file replacement events without a repeating poll or starvation.
            queue.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func directoryChanged() {
        var changed: [ProviderID] = []
        lock.withLock {
            pendingDelivery = nil
            for provider in [ProviderID.claude, .antigravity] {
                guard let newDate = modificationDate(for: provider) else { continue }
                if modificationDates[provider] != newDate {
                    modificationDates[provider] = newDate
                    changed.append(provider)
                }
            }
        }
        if !changed.isEmpty { handler(changed) }
    }

    private func modificationDate(for provider: ProviderID) -> Date? {
        let url = directory.appendingPathComponent("\(provider.rawValue)-event.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }
}
