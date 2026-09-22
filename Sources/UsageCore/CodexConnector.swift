import Foundation

public struct CodexConnector: UsageConnector, Sendable {
    public let provider: ProviderID = .codex
    private let executableURL: URL?
    private let timeout: TimeInterval

    /// `executableURL` names one launcher to use instead of searching (tests, troubleshooting).
    public init(executableURL: URL? = nil, timeout: TimeInterval = 12) {
        self.executableURL = executableURL
        self.timeout = max(2, timeout)
    }

    public func refresh() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try refreshBlocking()
        }.value
    }

    private func refreshBlocking() throws -> UsageSnapshot {
        let codex = CodexExecutable.standard
        let executable = try executableURL.map { try codex.verified($0) } ?? codex.verifiedURL()

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        let accumulator = NDJSONAccumulator(maximumBytes: SnapshotCache.maximumBytes)
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            accumulator.ingest(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            throw ConnectorError.unavailable("Unable to start Codex app-server")
        }

        defer {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try writeJSON([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "usage-rail",
                    "title": "UsageRail",
                    "version": "0.1.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: standardInput.fileHandleForWriting)

        // A freshly installed or updated codex can take a few seconds to start the first time
        // while macOS assesses it; a normal start answers in about a second.
        let initializeBudget = min(6, timeout / 2)
        guard accumulator.wait(for: 1, timeout: initializeBudget) else {
            if accumulator.exceededLimit { throw ConnectorError.outputTooLarge }
            throw ConnectorError.timedOut
        }
        if let response = accumulator.response(for: 1), responseContainsError(response) {
            throw try decodeServerError(response)
        }

        try writeJSON(["method": "initialized"], to: standardInput.fileHandleForWriting)
        try writeJSON([
            "id": 2,
            "method": "account/rateLimits/read"
        ], to: standardInput.fileHandleForWriting)

        guard accumulator.wait(for: 2, timeout: max(1, timeout - initializeBudget)) else {
            if accumulator.exceededLimit { throw ConnectorError.outputTooLarge }
            throw ConnectorError.timedOut
        }
        guard let response = accumulator.response(for: 2) else {
            throw ConnectorError.malformedResponse("Codex returned no rate-limit response")
        }
        return try CodexResponseParser.parseRateLimitsResponse(response)
    }

    private func writeJSON(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func responseContainsError(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["error"] != nil
    }

    private func decodeServerError(_ data: Data) throws -> ConnectorError {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return .malformedResponse("Codex initialization failed")
        }
        let message = (error["message"] as? String) ?? "Codex initialization failed"
        if message.localizedCaseInsensitiveContains("auth") || message.localizedCaseInsensitiveContains("login") {
            return .loginRequired(message)
        }
        return .malformedResponse(message)
    }
}

private final class NDJSONAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var buffer = Data()
    private var responses: [Int: Data] = [:]
    private var signals: [Int: DispatchSemaphore] = [:]
    private var totalBytes = 0
    private var didExceedLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            totalBytes += data.count
            if totalBytes > maximumBytes {
                didExceedLimit = true
                signals.values.forEach { $0.signal() }
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue else { continue }
                responses[id] = line
                signals[id]?.signal()
            }
        }
    }

    func wait(for id: Int, timeout: TimeInterval) -> Bool {
        let semaphore = lock.withLock { () -> DispatchSemaphore in
            if responses[id] != nil {
                let ready = DispatchSemaphore(value: 1)
                return ready
            }
            if let existing = signals[id] { return existing }
            let created = DispatchSemaphore(value: 0)
            signals[id] = created
            return created
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    func response(for id: Int) -> Data? {
        lock.withLock { responses[id] }
    }
}
