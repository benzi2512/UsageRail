import Darwin
import Foundation
import Security

/// A vendor CLI UsageRail may run. It is found where the vendor's installers put it and trusted
/// only when the vendor's Developer ID signed it, so any version works without trusting an
/// unknown binary. Candidates may be symlinks; the real binary behind one is what gets checked
/// and run.
public struct SignedExecutable: Sendable {
    public let product: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let candidatePaths: [String]
    private static let verified = VerifiedExecutables()

    public var requirement: String {
        "anchor apple generic and identifier \"\(signingIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// The first installed launcher, e.g. for a command the user runs. Located, not verified.
    public func installedLauncher(fileManager: FileManager = .default) -> URL? {
        candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The real binary behind the first installed launcher that passes every check.
    func verifiedURL(fileManager: FileManager = .default) throws -> URL {
        var found = false
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            found = true
            if let binary = trustedBinary(behind: URL(fileURLWithPath: path)) { return binary }
        }
        throw found ? signatureFailure : ConnectorError.unavailable("\(product) is not installed. UsageRail never installs or updates it.")
    }

    /// The real binary behind a launcher the user named, if it passes every check.
    func verified(_ launcher: URL) throws -> URL {
        guard let binary = trustedBinary(behind: launcher) else { throw signatureFailure }
        return binary
    }

    public func trustedBinary(behind launcher: URL) -> URL? {
        let binary = launcher.resolvingSymlinksInPath()
        return isTrusted(binary) ? binary : nil
    }

    /// Owned by you or root, not writable by others, and signed by the vendor. Strict validation
    /// hashes the whole binary (hundreds of MB), so it runs once per file identity; an update,
    /// replacement or metadata change checks again.
    public func isTrusted(_ binary: URL) -> Bool {
        let path = binary.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_size <= 512 * 1024 * 1024, let before = ExecutableIdentity(path: path) else { return false }
        if Self.verified.contains(before, for: requirement) { return true }
        guard hasVendorSignature(binary) else { return false }
        if ExecutableIdentity(path: path) == before { Self.verified.store(before, for: requirement) }
        return true
    }

    private func hasVendorSignature(_ binary: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private var signatureFailure: ConnectorError {
        .unavailable("\(product) signature check failed. UsageRail runs only \(product) signed by its publisher.")
    }
}

/// Claude Code from Anthropic's native installer, Homebrew or npm.
public enum ClaudeExecutable {
    public static let teamIdentifier = "Q6L2SF6YDW"
    public static let signingIdentifier = "com.anthropic.claude-code"
    public static var standard: SignedExecutable { executable(home: FileManager.default.homeDirectoryForCurrentUser.path) }
    static var requirement: String { standard.requirement }

    static func executable(home: String) -> SignedExecutable {
        SignedExecutable(product: "Claude Code", signingIdentifier: signingIdentifier, teamIdentifier: teamIdentifier,
                         candidatePaths: candidatePaths(home: home))
    }

    /// Launchers in the order a default shell finds them: Homebrew or npm on Apple silicon,
    /// then Intel, then the native installer.
    public static func candidatePaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude",
         "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
         "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"]
    }

    public static func installedLauncher(fileManager: FileManager = .default) -> URL? { standard.installedLauncher(fileManager: fileManager) }
    public static func isTrusted(_ binary: URL) -> Bool { standard.isTrusted(binary) }
}

/// Codex inside the ChatGPT desktop app, or the standalone Codex CLI from Homebrew or npm.
public enum CodexExecutable {
    public static let teamIdentifier = "2DC432GLL2"
    public static let signingIdentifier = "codex"
    public static var standard: SignedExecutable { executable(home: FileManager.default.homeDirectoryForCurrentUser.path) }

    static func executable(home: String) -> SignedExecutable {
        SignedExecutable(product: "Codex", signingIdentifier: signingIdentifier, teamIdentifier: teamIdentifier,
                         candidatePaths: candidatePaths(home: home))
    }

    /// The ChatGPT app first (in /Applications or ~/Applications), then the Codex CLI: the
    /// Homebrew cask's `codex`, then npm's platform binary (npm's own `codex` is a JS launcher).
    public static func candidatePaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        ["/Applications/ChatGPT.app/Contents/Resources/codex",
         home + "/Applications/ChatGPT.app/Contents/Resources/codex",
         "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
         "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
         "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"]
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

/// Binaries that already passed one signing requirement, by file identity.
final class VerifiedExecutables: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(requirement: String, identity: ExecutableIdentity)] = []

    func contains(_ identity: ExecutableIdentity, for requirement: String) -> Bool {
        lock.withLock { entries.contains { $0.requirement == requirement && $0.identity == identity } }
    }

    func store(_ identity: ExecutableIdentity, for requirement: String) {
        lock.withLock {
            entries.removeAll { $0.requirement == requirement && $0.identity.device == identity.device && $0.identity.inode == identity.inode }
            entries = Array((entries + [(requirement, identity)]).suffix(8))
        }
    }
}
