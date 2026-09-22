import Darwin
import Foundation
import Security

/// Finds Claude Code where its installers put it and runs it only when Anthropic signed it, so
/// any Claude Code version works without trusting an unknown binary.
public enum ClaudeExecutable {
    public static let teamIdentifier = "Q6L2SF6YDW"
    public static let signingIdentifier = "com.anthropic.claude-code"
    static let requirement = "anchor apple generic and identifier \"\(signingIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    private static let verified = VerifiedExecutables()

    /// Launchers in the order a default shell finds them: Homebrew or npm on Apple silicon,
    /// then Intel, then the native installer. Each may be a symlink to the real binary.
    public static func candidatePaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude",
         "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
         "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"]
    }

    /// The first installed launcher, used for the sign-in command UsageRail copies. It is
    /// only located here; `verifiedURL()` checks the signature before anything runs.
    public static func installedLauncher(fileManager: FileManager = .default) -> URL? {
        candidatePaths().first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The real binary behind the first launcher that is Anthropic-signed and safely owned.
    static func verifiedURL() throws -> URL {
        var found = false
        for path in candidatePaths() where FileManager.default.isExecutableFile(atPath: path) {
            found = true
            let binary = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if isTrusted(binary) { return binary }
        }
        throw ConnectorError.unavailable(found
            ? "Claude Code signature check failed. UsageRail runs only Claude Code signed by Anthropic."
            : "Claude Code is not installed. UsageRail never installs or updates it.")
    }

    /// Owned by you or root, not writable by others, and signed by Anthropic. Strict validation
    /// hashes the ~300 MB binary, so it runs once per file identity; an update re-checks.
    public static func isTrusted(_ binary: URL) -> Bool {
        let path = binary.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_size <= 512 * 1024 * 1024, let before = ExecutableIdentity(path: path) else { return false }
        if verified.contains(before) { return true }
        guard hasAnthropicSignature(binary) else { return false }
        if ExecutableIdentity(path: path) == before { verified.store(before) }
        return true
    }

    static func hasAnthropicSignature(_ binary: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

/// Identities of binaries that already passed signature validation.
final class VerifiedExecutables: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ExecutableIdentity] = []

    func contains(_ candidate: ExecutableIdentity) -> Bool { lock.withLock { identities.contains(candidate) } }
    func store(_ candidate: ExecutableIdentity) {
        lock.withLock {
            identities.removeAll { $0.device == candidate.device && $0.inode == candidate.inode }
            identities = Array((identities + [candidate]).suffix(4))
        }
    }
}

/// Reads Claude plan limits through Claude Code's control protocol with a private profile.
/// Two control packets only; no prompt, tool, plugin, model call or persistent child. UsageRail
/// never reads Claude's credentials: Claude Code uses its own sign-in for that profile.
public struct ClaudeConnector: UsageConnector {
    public let provider: ProviderID = .claude
    /// Folder name for the profile Settings can create, inside UsageRail's Application Support.
    public static let defaultProfileName = "Claude usage profile"
    public init() {}

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
        let executable = try ClaudeExecutable.verifiedURL()
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
