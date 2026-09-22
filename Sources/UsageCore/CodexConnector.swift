import Foundation
import Security

public struct CodexConnector: UsageConnector, Sendable {
    public let provider: ProviderID = .codex
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = CodexConnector.defaultExecutableURL(), timeout: TimeInterval = 8) {
        self.executableURL = executableURL
        self.timeout = max(2, timeout)
    }

    public func refresh() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try refreshBlocking()
        }.value
    }

    private func refreshBlocking() throws -> UsageSnapshot {
        guard let executableURL else {
            throw ConnectorError.unavailable("ChatGPT is not installed. Install the ChatGPT desktop app and sign in.")
        }
        guard Self.isExpectedOpenAIExecutable(executableURL) else {
            throw ConnectorError.unavailable("Codex signature check failed. UsageRail runs only Codex signed by OpenAI.")
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = executableURL
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

        let initializeBudget = min(2.5, timeout / 2)
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

    /// The Codex binary inside the ChatGPT desktop app, in /Applications or ~/Applications.
    public static let trustedPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/ChatGPT.app/Contents/Resources/codex"
    ]

    public static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        trustedPaths.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static let validatedExecutable = ValidatedExecutable()

    private static func isExpectedOpenAIExecutable(_ url: URL) -> Bool {
        let trustedPath = url.standardizedFileURL.path
        guard trustedPaths.contains(trustedPath), url.resolvingSymlinksInPath().path == trustedPath else { return false }
        // Strict validation hashes the ~230 MB binary (~0.4 s CPU). Do it once per file
        // identity; any rewrite, replacement or metadata change (ctime) forces it again.
        let before = ExecutableIdentity(path: trustedPath)
        if let before, validatedExecutable.contains(before) { return true }
        guard hasExpectedSignature(url) else { return false }
        if let before, ExecutableIdentity(path: trustedPath) == before { validatedExecutable.store(before) }
        return true
    }

    private static func hasExpectedSignature(_ url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return teamIdentifier == "2DC432GLL2"
    }
}

/// What identifies one exact file on disk, including its last metadata change.
struct ExecutableIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: [Int]
    let changed: [Int]

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
        changed = [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
    }
}

final class ValidatedExecutable: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ExecutableIdentity?

    func contains(_ candidate: ExecutableIdentity) -> Bool { lock.withLock { identity == candidate } }
    func store(_ candidate: ExecutableIdentity) { lock.withLock { identity = candidate } }
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
