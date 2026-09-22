import Foundation

public struct ProviderID: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    public let rawValue: String
    private init(builtin: String) { rawValue = builtin }
    public static let codex = Self(builtin: "codex")
    public static let claude = Self(builtin: "claude")
    public static let copilot = Self(builtin: "copilot")
    public static let antigravity = Self(builtin: "antigravity")
    public static let gemini = Self(builtin: "gemini")
    public static let kie = Self(builtin: "kie")
    public static let runpod = Self(builtin: "runpod")
    public static let allCases: [Self] = [.codex, .claude, .copilot, .antigravity, .gemini, .kie, .runpod]
    public var isCustom: Bool { rawValue.hasPrefix("custom:") }
    public init?(rawValue: String) {
        if Self.allCases.contains(where: { $0.rawValue == rawValue }) { self.rawValue = rawValue; return }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "custom", UUID(uuidString: String(parts[1])) != nil,
              let data = Data(base64Encoded: String(parts[2])), let name = String(data: data, encoding: .utf8),
              !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
    public static func custom(name: String, id: UUID = UUID()) -> Self? {
        Self(rawValue: "custom:\(id.uuidString):\(Data(name.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString())")
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid provider")
        }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT · Codex"
        case .claude: "Claude Code"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        case .gemini: "Google Gemini"
        case .kie: "Kie AI"
        case .runpod: "Runpod"
        default: String(data: Data(base64Encoded: String(rawValue.split(separator: ":").last ?? "")) ?? Data(), encoding: .utf8) ?? "Custom"
        }
    }

    public var shortName: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        case .copilot: "Copilot"
        case .antigravity: "Antigravity"
        case .gemini: "Gemini"
        case .kie: "Kie AI"
        case .runpod: "Runpod"
        default: displayName
        }
    }

    public var glyph: String {
        switch self {
        case .codex: "◎"
        case .claude: "A"
        case .copilot: "⌁"
        case .antigravity: "△"
        case .gemini: "✦"
        case .kie: "K"
        case .runpod: "R"
        default: String(displayName.prefix(2)).uppercased()
        }
    }
}

public enum UsageSource: String, Codable, Sendable {
    case codexAppServer
    case claudeCode
    case officialStatusLine
    case githubREST
    case manual
    case kieAPI
    case runpodAPI
    case customAPI
}

public enum BalanceUnit: String, Codable, Sendable {
    case credits
    case usd
}

public enum UsageLimitKind: String, Codable, Sendable {
    case critical
    case shortTerm
    case weekly
    case monthly
    case model
    case credits
    case auxiliary
}

/// One product's share of a window's usage, e.g. Cowork 64% of this week's Claude usage.
public struct UsageShare: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let percent: Double

    public init(id: String, title: String, percent: Double) {
        self.id = id
        self.title = title
        self.percent = min(100, max(0, percent))
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double?
    public let used: Double?
    public let limit: Double?
    public let remainingPercentReported: Double?
    public let resetAt: Date?
    public let isEstimated: Bool
    public let kind: UsageLimitKind?
    public let detail: String?
    public let balance: Double?
    public let balanceUnit: BalanceUnit?
    /// Where the used part went, by product. Informational; never a limit of its own.
    public let breakdown: [UsageShare]?

    public init(
        id: String,
        title: String,
        usedPercent: Double?,
        used: Double? = nil,
        limit: Double? = nil,
        remainingPercentReported: Double? = nil,
        resetAt: Date? = nil,
        isEstimated: Bool = false,
        kind: UsageLimitKind = .auxiliary,
        detail: String? = nil,
        balance: Double? = nil,
        balanceUnit: BalanceUnit? = nil,
        breakdown: [UsageShare]? = nil
    ) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.map { min(100, max(0, $0)) }
        self.used = used
        self.limit = limit
        self.remainingPercentReported = remainingPercentReported.map { min(100, max(0, $0)) }
        self.resetAt = resetAt
        self.isEstimated = isEstimated
        self.kind = kind
        self.detail = detail
        self.balanceUnit = balanceUnit
        self.balance = balance.flatMap { $0.isFinite && ($0 >= 0 || balanceUnit == .usd) ? $0 : nil }
        self.breakdown = breakdown.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var remainingPercent: Double? {
        if let remainingPercentReported { return remainingPercentReported }
        if let usedPercent { return max(0, 100 - usedPercent) }
        if let used, let limit, limit > 0 { return max(0, min(100, ((limit - used) / limit) * 100)) }
        return nil
    }

    public var hasDisplayableMetric: Bool { remainingPercent != nil || balance != nil }

    public var balanceText: String? {
        guard let balance else { return nil }
        if balanceUnit == .usd {
            return balance.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
        }
        return balance.formatted(.number.precision(.fractionLength(0...8)))
    }

    public var compactBalanceText: String? {
        guard let balance else { return nil }
        if balanceUnit == .usd { return balanceText }
        if balance >= 1_000_000 { return String(format: "%.1fM cr", balance / 1_000_000) }
        if balance >= 10_000 { return String(format: "%.1fK cr", balance / 1_000) }
        return balance.formatted(.number.precision(.fractionLength(0...2))) + " cr"
    }

    /// Human-readable amount for a detail row. Provider credit units are not
    /// presented as dollars because their purchase price is not a fixed rate.
    public var prominentBalanceText: String? {
        guard let balance else { return nil }
        if balanceUnit == .usd { return balanceText }
        return balance.formatted(.number.precision(.fractionLength(0...2))) + " credits"
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let windows: [UsageWindow]
    public let sessionTokens: Int?
    public let modelName: String?
    public let updatedAt: Date
    public let source: UsageSource
    public let creditBalance: Double?
    public let balanceUnit: BalanceUnit?
    public let availableResetCount: Int?

    public init(
        provider: ProviderID,
        windows: [UsageWindow],
        sessionTokens: Int? = nil,
        modelName: String? = nil,
        updatedAt: Date = Date(),
        source: UsageSource,
        creditBalance: Double? = nil,
        balanceUnit: BalanceUnit? = nil,
        availableResetCount: Int? = nil
    ) {
        self.provider = provider
        self.windows = windows
        self.sessionTokens = sessionTokens
        self.modelName = modelName
        self.updatedAt = updatedAt
        self.source = source
        self.balanceUnit = balanceUnit
        self.availableResetCount = availableResetCount.flatMap { $0 >= 0 ? $0 : nil }
        self.creditBalance = creditBalance.flatMap { $0.isFinite && ($0 >= 0 || balanceUnit == .usd) ? $0 : nil }
    }

    public var isValidBalance: Bool {
        creditBalance.map { $0.isFinite && ($0 >= 0 || balanceUnit == .usd) } ?? false
    }

    public var formattedUSD: String? {
        guard balanceUnit == .usd, isValidBalance, let creditBalance else { return nil }
        return creditBalance.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
    }

    public var limitingWindow: UsageWindow? {
        windows
            .filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    public var remainingPercent: Double? { limitingWindow?.remainingPercent }

    public var limitsForDisplay: [UsageWindow] {
        windows.sorted {
            let order: [UsageLimitKind: Int] = [
                .critical: 0, .shortTerm: 1, .weekly: 2, .monthly: 3,
                .model: 4, .credits: 5, .auxiliary: 6
            ]
            let lhsRank = ($0.remainingPercent ?? 101) < 10 ? 0 : (order[$0.kind ?? .auxiliary] ?? 99) + 1
            let rhsRank = ($1.remainingPercent ?? 101) < 10 ? 0 : (order[$1.kind ?? .auxiliary] ?? 99) + 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101)
        }
    }
}

public enum ProviderStatus: String, Codable, Sendable {
    case fresh
    case cached
    case refreshing
    case stale
    case loginRequired
    case unavailable
}

public struct ProviderState: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let status: ProviderStatus
    public let snapshot: UsageSnapshot?
    public let message: String?

    public init(provider: ProviderID, status: ProviderStatus, snapshot: UsageSnapshot?, message: String? = nil) {
        self.provider = provider
        self.status = status
        self.snapshot = snapshot
        self.message = message
    }

    public var hasDisplayableUsage: Bool {
        guard status != .loginRequired, status != .unavailable else { return false }
        if snapshot?.isValidBalance == true { return true }
        return snapshot?.remainingPercent != nil
    }

    public var displayValue: String {
        guard hasDisplayableUsage else { return "—" }
        if let dollars = snapshot?.formattedUSD { return dollars }
        if let balance = snapshot?.creditBalance, balance.isFinite, balance >= 0 {
            if balance >= 1_000_000 { return String(format: "%.1fM cr", balance / 1_000_000) }
            if balance >= 10_000 { return String(format: "%.1fK cr", balance / 1_000) }
            return balance.formatted(.number.precision(.fractionLength(0...2))) + " cr"
        }
        return snapshot?.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Show only a current, positive, provider-reported reset count. Never infer it from quota.
    public var displayableResetCount: Int? {
        guard let count = reportedResetCount, count > 0 else { return nil }
        return count
    }

    /// Reset credits a provider currently reports, including zero, for the display-only Reset
    /// control. Saved or failed data shows none: a reset may have been used meanwhile.
    public var reportedResetCount: Int? {
        guard status == .fresh || status == .refreshing, let count = snapshot?.availableResetCount else { return nil }
        return count
    }

    public var usageAccessibilityValue: String {
        guard hasDisplayableUsage else { return connectionHint }
        if let dollars = snapshot?.formattedUSD { return dollars + " USD account balance" }
        if let balance = snapshot?.creditBalance, balance.isFinite, balance >= 0 {
            return balance.formatted(.number.precision(.fractionLength(0...8))) + " credits remaining"
        }
        return snapshot?.remainingPercent.map { "\(Int($0.rounded())) percent remaining" } ?? "usage unavailable"
    }

    /// Fixed, actionable copy. Never echo vendor output, paths or secrets into the UI.
    public var connectionHint: String {
        let reason = (message ?? "").lowercased()
        if reason.contains("not installed") {
            return provider == .codex
                ? "Install the ChatGPT desktop app or the Codex CLI and sign in, then retry."
                : "Install Claude Code, sign in with the command from Settings, then retry."
        }
        if reason.contains("signature") || reason.contains("changed") {
            return "The installed app isn't signed by its publisher, so UsageRail won't run it. Reinstall it from the official download; signing in again will not fix it."
        }
        if provider == .claude && reason.contains("profile") {
            return "In Settings, create or choose a private Claude profile and sign in to it. Your everyday Claude Code setup is unchanged."
        }
        if reason.contains("pinned limit") { return "Selected limit is missing. Open details and choose Auto or another limit." }
        if reason.contains("timed out") || reason.contains("timeout") { return "Connection timed out. Check your network and retry." }
        if status == .loginRequired {
            return provider == .claude || provider == .codex
                ? "Sign-in expired or missing. Open Settings, check the signed-in account or profile, then retry."
                : "Credential missing or rejected. Check the read-only key in Settings, then retry."
        }
        if reason.contains("429") { return "Provider is rate-limiting checks. Wait for the next retry; repeated refreshes will not help." }
        if status == .stale { return "Latest check failed; showing saved usage. Check the connection and retry." }
        if status == .refreshing { return "Checking connection…" }
        if status == .cached { return "Saved usage; awaiting a successful check." }
        if status == .unavailable { return "No supported usage received. Open Settings to set up this provider." }
        return "Connected"
    }

    public var metricDescription: String {
        guard hasDisplayableUsage else { return connectionHint }
        if snapshot?.isValidBalance == true { return snapshot?.balanceUnit == .usd ? "USD balance" : "Credit balance" }
        return snapshot?.limitingWindow?.title ?? "Usage"
    }
}

public enum ConnectorError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case loginRequired(String)
    case malformedResponse(String)
    case timedOut
    case outputTooLarge
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .loginRequired(let message): message
        case .malformedResponse(let message): message
        case .timedOut: "Refresh timed out"
        case .outputTooLarge: "Provider output exceeded the safety limit"
        case .server(let status): "Provider returned HTTP \(status)"
        }
    }
}

public protocol UsageConnector: Sendable {
    var provider: ProviderID { get }
    func refresh() async throws -> UsageSnapshot
}
