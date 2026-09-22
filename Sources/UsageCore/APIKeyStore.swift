import Darwin
import Foundation

/// Kie and Runpod API keys live in the macOS Keychain, one item per provider. Settings writes a
/// key only on an explicit save; presence checks read metadata, never the key itself. A key
/// saved by UsageRail 0.3 or earlier keeps working from its private file until one is saved here.
public enum APIKeyStore {
    public static func account(for provider: ProviderID) -> String? {
        switch provider {
        case .kie: "kie-api-key"
        case .runpod: "runpod-api-key"
        default: nil
        }
    }

    /// The trimmed key if it has the shape both providers issue; otherwise a message for Settings.
    public static func validated(_ key: String, for provider: ProviderID) throws -> String {
        guard account(for: provider) != nil else { throw SetupError("This service doesn't use an API key here.") }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9_.-]{16,512}$", options: .regularExpression) != nil else {
            throw SetupError("Enter a valid API key (16–512 letters, numbers, dots, underscores or hyphens).")
        }
        return value
    }

    public static func hasSavedKey(_ provider: ProviderID, keychain: KeychainStore = .shared,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let account = account(for: provider) else { return false }
        return keychain.contains(account: account) || LegacyKeyFile.exists(for: provider, home: home)
    }

    /// The saved key, or nil when none is saved. The Keychain wins over an earlier version's file;
    /// a malformed value counts as missing.
    static func read(_ provider: ProviderID, keychain: KeychainStore,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String? {
        guard let account = account(for: provider) else { return nil }
        if let value = try keychain.read(account: account) { return try? validated(value, for: provider) }
        return LegacyKeyFile.read(for: provider, home: home)
    }

    public struct SetupError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

/// UsageRail 0.3 and earlier kept these keys in `~/.codex/connectors/<provider>/.env`. It is read
/// only when the Keychain has no key, with the same checks those versions applied: a regular,
/// owner-only file that is not a symlink and did not change while it was opened.
enum LegacyKeyFile {
    static let maximumBytes = 16 * 1024

    static func variable(for provider: ProviderID) -> String? {
        switch provider {
        case .kie: "KIE_API_KEY"
        case .runpod: "RUNPOD_API_KEY"
        default: nil
        }
    }

    static func path(for provider: ProviderID, home: URL) -> String? {
        guard variable(for: provider) != nil else { return nil }
        return home.appendingPathComponent(".codex/connectors/\(provider.rawValue)/.env").path
    }

    /// From metadata only; the file is not opened.
    static func exists(for provider: ProviderID, home: URL) -> Bool {
        guard let path = path(for: provider, home: home) else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && isPrivateFile(info)
    }

    static func read(for provider: ProviderID, home: URL) -> String? {
        guard let path = path(for: provider, home: home), let name = variable(for: provider) else { return nil }
        var before = stat()
        guard lstat(path, &before) == 0, isPrivateFile(before) else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8),
              let value = value(named: name, in: text) else { return nil }
        return try? APIKeyStore.validated(value, for: provider)
    }

    /// `NAME=value` from dotenv text: blank lines and `#` comments are skipped, and one pair of
    /// matching quotes around the value is removed. The last assignment wins.
    static func value(named name: String, in text: String) -> String? {
        var found: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            found = value
        }
        return found
    }

    private static func isPrivateFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o077 == 0
            && info.st_size > 0 && info.st_size <= maximumBytes
    }
}

/// One bounded HTTPS request for a built-in balance: no cookies, cache, stored credentials or
/// redirects, so the key is only ever sent to the fixed provider host.
enum BalanceRequest {
    static let maximumBytes = 64 * 1024

    static func send(_ request: URLRequest, session injected: URLSession?, service: String) async throws -> (Data, HTTPURLResponse) {
        let session = injected ?? makeSession()
        defer { if injected == nil { session.finishTasksAndInvalidate() } }
        var request = request
        request.setValue("UsageRail", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ConnectorError.timedOut
        } catch {
            throw ConnectorError.unavailable("\(service) is offline or unreachable")
        }
        guard let http = response as? HTTPURLResponse, http.url?.host == request.url?.host else {
            throw ConnectorError.malformedResponse("\(service) returned an unexpected response")
        }
        guard data.count <= maximumBytes else { throw ConnectorError.outputTooLarge }
        return (data, http)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
