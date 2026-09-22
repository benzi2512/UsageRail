import Darwin
import Foundation

/// Reads Claude plan limits through Claude Code's control protocol with a private profile.
/// Two control packets only; no prompt, tool, plugin, model call or persistent child. UsageRail
/// never reads Claude's credentials: Claude Code uses its own sign-in for that profile.
public struct ClaudeConnector: UsageConnector {
    public let provider: ProviderID = .claude
    /// Folder name for the profile Settings can create, inside UsageRail's Application Support.
    public static let defaultProfileName = "Claude usage profile"
    /// A specific Claude Code launcher to use instead of searching (troubleshooting).
    private let executableURL: URL?
    public init(executableURL: URL? = nil) { self.executableURL = executableURL }

    public static var hasProfileConfiguration: Bool {
        guard let url = try? UsagePaths.applicationSupport().appendingPathComponent("claude-connection.json") else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    public func refresh() async throws -> UsageSnapshot {
        if !Self.hasProfileConfiguration {
            return try await LocalSnapshotConnector(provider: .claude).refresh()
        }
        return try await Task.detached(priority: .utility) { try refreshBlocking() }.value
    }

    public static func configuredProfile() throws -> URL {
        let configuration = try UsagePaths.applicationSupport().appendingPathComponent("claude-connection.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              configuration.resolvingSymlinksInPath() == configuration else {
            throw ConnectorError.unavailable("Create or choose a Claude profile in Settings. No credentials are copied.")
        }
        struct Configuration: Decodable { let profilePath: String }
        guard let data = try? Data(contentsOf: configuration),
              let value = try? JSONDecoder().decode(Configuration.self, from: data),
              value.profilePath.hasPrefix("/"), !value.profilePath.contains("\n") else {
            throw ConnectorError.unavailable("The Claude connection file needs an existing profilePath, not a token.")
        }
        return try validateProfile(URL(fileURLWithPath: value.profilePath, isDirectory: true))
    }

    public static func validateProfile(_ url: URL) throws -> URL {
        let profile = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        guard profile.path.hasPrefix(home), profile.resolvingSymlinksInPath() == profile,
              let attributes = try? FileManager.default.attributesOfItem(atPath: profile.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw ConnectorError.unavailable("The configured Claude profile must be a private folder owned by you.")
        }
        // get_usage also summarizes local behavior. Keep this read-only profile free of
        // conversations so checking quota cannot enumerate the user's project history.
        let projects = profile.appendingPathComponent("projects", isDirectory: true)
        if FileManager.default.fileExists(atPath: projects.path) {
            guard projects.resolvingSymlinksInPath() == projects,
                  (try? FileManager.default.contentsOfDirectory(atPath: projects.path).isEmpty) == true else {
                throw ConnectorError.unavailable("Use a dedicated signed-in Claude profile without project conversation history for quota checks.")
            }
        }
        return profile
    }

    public static func saveProfile(_ url: URL) throws {
        let profile = try validateProfile(url)
        let configuration = try UsagePaths.applicationSupport().appendingPathComponent("claude-connection.json")
        guard configuration.resolvingSymlinksInPath() == configuration else {
            throw ConnectorError.unavailable("The Claude connection file cannot be a symbolic link.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["profilePath": profile.path], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configuration, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
    }

    /// Creates UsageRail's own empty, owner-only profile folder (or reuses it) and selects it.
    /// Signing in to it stays a command the user runs in Terminal.
    @discardableResult
    public static func createDefaultProfile(in support: URL? = nil) throws -> URL {
        let parent = try support ?? UsagePaths.applicationSupport()
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let profile = parent.appendingPathComponent(defaultProfileName, isDirectory: true)
        if !manager.fileExists(atPath: profile.path) {
            try manager.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try saveProfile(profile)
        return profile
    }

    /// The command Settings copies for the user to run: sign in to this profile only.
    public static func loginCommand(profile: URL, launcher: URL) -> String {
        "CLAUDE_CONFIG_DIR=\(shellQuoted(profile.path)) \(shellQuoted(launcher.path)) auth login"
    }

    static func shellQuoted(_ text: String) -> String {
        if !text.isEmpty, text.range(of: "^[A-Za-z0-9/._-]+$", options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func environment(profile: URL) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "CLAUDE_CONFIG_DIR": profile.path,
         "DISABLE_UPDATES": "1", "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
         "DISABLE_ERROR_REPORTING": "1", "DISABLE_GROWTHBOOK": "1", "DO_NOT_TRACK": "1"]
        // Do not set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: it also blocks get_usage.
    }

    static let arguments = ["--safe-mode", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-chrome", "--tools", "",
                            "--max-turns", "0", "--no-session-persistence", "--input-format", "stream-json",
                            "--output-format", "stream-json", "--verbose", "-p"]

    private func refreshBlocking() throws -> UsageSnapshot {
        let profile = try Self.configuredProfile()
        let claude = ClaudeExecutable.standard
        let executable = try executableURL.map { try claude.verified($0) } ?? claude.verifiedURL()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let replies = ClaudeControlReplies()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.currentDirectoryURL = profile
        process.environment = Self.environment(profile: profile)
        process.arguments = Self.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal(); replies.finish() }
        output.fileHandleForReading.readabilityHandler = { replies.ingest($0.availableData) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
        }
        do { try process.run() } catch {
            throw ConnectorError.unavailable("Unable to start Claude Code.")
        }
        try writeRequest("initialize", id: "usage-rail-init", to: input.fileHandleForWriting)
        let initialize = try replies.wait(for: "usage-rail-init", seconds: 6)
        guard let root = try? JSONSerialization.jsonObject(with: initialize) as? [String: Any],
              (root["response"] as? [String: Any])?["subtype"] as? String == "success" else {
            throw ConnectorError.malformedResponse("Claude Code did not start its control protocol as expected.")
        }
        try writeRequest("get_usage", id: "usage-rail-read", to: input.fileHandleForWriting)
        return try ClaudeUsageParser.parse(replies.wait(for: "usage-rail-read", seconds: 15))
    }

    private func writeRequest(_ subtype: String, id: String, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id,
                                                              "request": ["subtype": subtype]])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

final class ClaudeControlReplies: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var total = 0
    private var exceeded = false
    private var finished = false
    private var responses: [String: Data] = [:]

    func ingest(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        if data.isEmpty { finished = true; return }
        total += data.count
        guard total <= SnapshotCache.maximumBytes else { exceeded = true; buffer.removeAll(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  root["type"] as? String == "control_response",
                  let response = root["response"] as? [String: Any],
                  let id = response["request_id"] as? String,
                  ["usage-rail-init", "usage-rail-read"].contains(id) else { continue }
            responses[id] = line
        }
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for id: String, seconds: TimeInterval) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while responses[id] == nil, !exceeded, !finished {
            if !condition.wait(until: deadline) { throw ConnectorError.timedOut }
        }
        if exceeded { throw ConnectorError.outputTooLarge }
        guard let data = responses[id] else { throw ConnectorError.unavailable("Claude quota lookup failed before a response was received.") }
        return data
    }
}
