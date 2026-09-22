import Foundation

/// How a provider is connected from Settings. The UI builds each setup pane from this,
/// so supporting a new provider is mostly a new `ConnectionCatalog` entry.
public enum ConnectionSetupKind: Equatable, Sendable {
    /// Detected from the signed-in ChatGPT desktop app (Codex).
    case chatGPTApp
    /// A private Claude Code profile folder, created or chosen in Settings; only its path is stored.
    case claudeProfile
    /// An API key pasted in Settings and kept in the Keychain by `APIKeyStore`.
    case apiKey(keyPageURL: URL)
    /// GitHub username and allowance in settings, fine-grained token in the Keychain.
    case copilotToken
    /// A user-added HTTPS GET usage API.
    case custom
    /// Not connectable in this build. Documentation only, never a credential field.
    case guide(url: URL?)

    public var isGuide: Bool {
        if case .guide = self { return true }
        return false
    }
}

/// A prefilled custom API setup offered by a guide. The user still reviews it and the
/// test must pass before anything is saved.
public struct CustomConnectionTemplate: Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let pointer: String
    public let metric: CustomConnection.Metric
    public let authentication: CustomConnection.Authentication
    public let multiplier: Double
    /// What the user still has to change before testing.
    public let note: String
}

public struct ConnectionCatalogEntry: Equatable, Sendable, Identifiable {
    public enum ID: Hashable, Sendable {
        case provider(ProviderID)
        case research(String)
    }

    public let id: ID
    public let title: String
    /// One friendly line shown under the pane title.
    public let summary: String
    public let setup: ConnectionSetupKind
    /// Where the credential lives, in plain words. Never the credential itself.
    public let credentialLocation: String?
    /// Fixed, truthful status for guides. Connectable providers show live state instead.
    public let guideStatus: String?
    /// Longer help, shown only under "More".
    public let details: String?
    public let template: CustomConnectionTemplate?
    /// The provider offers limit resets, so details show the display-only Resets row.
    /// UsageRail never spends a reset.
    public let offersResets: Bool

    public init(id: ID, title: String, summary: String, setup: ConnectionSetupKind,
                credentialLocation: String? = nil, guideStatus: String? = nil,
                details: String? = nil, template: CustomConnectionTemplate? = nil, offersResets: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.setup = setup
        self.credentialLocation = credentialLocation
        self.guideStatus = guideStatus
        self.details = details
        self.template = template
        self.offersResets = offersResets
    }

    public var provider: ProviderID? {
        if case .provider(let provider) = id { return provider }
        return nil
    }

    public var isGuide: Bool { setup.isGuide }

    /// Guides link only to https documentation.
    public var documentationURL: URL? {
        guard case .guide(let url) = setup, let url, url.scheme == "https" else { return nil }
        return url
    }
}

/// Settings sidebar grouping. Every provider appears exactly once.
public struct ConnectionSections: Equatable, Sendable {
    public var connected: [ConnectionCatalogEntry.ID] = []
    public var setUp: [ConnectionCatalogEntry.ID] = []
    public var guides: [ConnectionCatalogEntry.ID] = []

    public init() {}

    public var all: [ConnectionCatalogEntry.ID] { connected + setUp + guides }
}

public struct RefreshScheduleLine: Equatable, Sendable {
    public let title: String
    public let detail: String
}

public enum ConnectionCatalog {
    /// Built-in providers in sidebar order.
    public static let builtIn: [ConnectionCatalogEntry] = [
        ConnectionCatalogEntry(
            id: .provider(.codex), title: ProviderID.codex.displayName,
            summary: "Your Codex limits, read from the ChatGPT desktop app.",
            setup: .chatGPTApp,
            credentialLocation: "Your ChatGPT app sign-in. UsageRail stores no credential.",
            offersResets: true),
        ConnectionCatalogEntry(
            id: .provider(.claude), title: ProviderID.claude.displayName,
            summary: "Claude plan limits, read through Claude Code with a private profile just for UsageRail.",
            setup: .claudeProfile,
            credentialLocation: "Claude Code keeps the sign-in for that profile. UsageRail saves only the folder path.",
            offersResets: true),
        ConnectionCatalogEntry(
            id: .provider(.copilot), title: ProviderID.copilot.displayName,
            summary: "Premium requests used this month, from GitHub's billing API.",
            setup: .copilotToken,
            credentialLocation: "The token stays in your macOS Keychain."),
        ConnectionCatalogEntry(
            id: .provider(.kie), title: ProviderID.kie.displayName,
            summary: "Your Kie credit balance. Only the balance is read; nothing is generated.",
            setup: .apiKey(keyPageURL: URL(string: "https://kie.ai/api-key")!),
            credentialLocation: "The key stays in your macOS Keychain."),
        ConnectionCatalogEntry(
            id: .provider(.runpod), title: ProviderID.runpod.displayName,
            summary: "Your Runpod USD balance, read with a read-only key. No pods are started.",
            setup: .apiKey(keyPageURL: URL(string: "https://console.runpod.io/user/settings")!),
            credentialLocation: "The key stays in your macOS Keychain."),
        ConnectionCatalogEntry(
            id: .provider(.antigravity), title: ProviderID.antigravity.displayName,
            summary: "Shows up once a supported local bridge sends its usage. There's no one-click setup yet.",
            setup: .guide(url: nil),
            guideStatus: "Guide · needs a supported local bridge",
            details: "UsageRail can read Antigravity usage events from a documented local bridge, but it has no verified sign-in or bridge setup. Don't paste a session token or connect an arbitrary endpoint; Antigravity stays hidden until the bridge supplies real usage."),
        ConnectionCatalogEntry(
            id: .provider(.gemini), title: ProviderID.gemini.displayName,
            summary: "There's no Gemini usage connector yet, so an API key wouldn't show real quota.",
            setup: .guide(url: URL(string: "https://ai.google.dev/gemini-api/docs/rate-limits")),
            guideStatus: "Guide · not connectable yet",
            details: "For the Gemini API, Google AI Studio → Dashboard → Usage shows API usage, and Rate Limit shows limits per project and model. That's separate from Gemini app subscription limits. An inference API key alone doesn't expose account quota.")
    ]

    public static var research: [ConnectionCatalogEntry] { ConnectionResearch.entries.map(entry(for:)) }

    public static func entry(for provider: ProviderID) -> ConnectionCatalogEntry {
        if let entry = builtIn.first(where: { $0.provider == provider }) { return entry }
        if provider.isCustom {
            return ConnectionCatalogEntry(
                id: .provider(provider), title: provider.displayName,
                summary: "Your own HTTPS usage API. UsageRail reads one number from it.",
                setup: .custom,
                credentialLocation: "Any token stays in your macOS Keychain.")
        }
        // A provider added to the core without a catalog entry stays a truthful guide.
        return ConnectionCatalogEntry(id: .provider(provider), title: provider.displayName,
                                      summary: "Setup for this provider isn't available here yet.",
                                      setup: .guide(url: nil), guideStatus: "Guide · not connectable yet")
    }

    public static func entry(for research: ConnectionResearch) -> ConnectionCatalogEntry {
        let known = researchCopy[research.name]
        let fallback = research.instructions.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." }
        return ConnectionCatalogEntry(
            id: .research(research.name), title: research.name,
            summary: known?.summary ?? fallback ?? research.status,
            setup: .guide(url: URL(string: research.source)),
            guideStatus: research.status,
            details: research.instructions.replacingOccurrences(of: "In + Add web app:", with: "In Add custom API…:"),
            template: known?.template)
    }

    public static func entry(for id: ConnectionCatalogEntry.ID) -> ConnectionCatalogEntry? {
        switch id {
        case .provider(let provider): return entry(for: provider)
        case .research(let name): return ConnectionResearch.entries.first { $0.name == name }.map(entry(for:))
        }
    }

    /// Connected = has displayable usage; Set up = connectable but not connected (including
    /// failing custom APIs); Guides = not connectable in this build plus every research entry.
    public static func sections(states: [ProviderState], customProviders: [ProviderID]) -> ConnectionSections {
        var result = ConnectionSections()
        var providers = ProviderID.allCases
        for provider in customProviders where provider.isCustom && !providers.contains(provider) { providers.append(provider) }
        for provider in providers {
            if states.first(where: { $0.provider == provider })?.hasDisplayableUsage == true {
                result.connected.append(.provider(provider))
            } else if entry(for: provider).isGuide {
                result.guides.append(.provider(provider))
            } else {
                result.setUp.append(.provider(provider))
            }
        }
        result.guides += ConnectionResearch.entries.map { .research($0.name) }
        return result
    }

    // MARK: - Status copy

    /// The value a provider shows where one number represents it, e.g. "49%" or "$23.46".
    /// Uses the user's limit choice when it is available.
    public static func compactValue(for state: ProviderState, settings: AppSettings) -> String? {
        let shown = settings.displayState(from: state)
        let source = shown.hasDisplayableUsage ? shown : state
        guard source.hasDisplayableUsage else { return nil }
        let value = source.displayValue
        return value == "—" ? nil : value
    }

    /// "49% left" for quotas, the balance itself for credits and USD.
    public static func valueText(for state: ProviderState, settings: AppSettings) -> String? {
        let shown = settings.displayState(from: state)
        let source = shown.hasDisplayableUsage ? shown : state
        guard let value = compactValue(for: state, settings: settings) else { return nil }
        return source.snapshot?.creditBalance != nil ? value : "\(value) left"
    }

    /// One line under a provider's name, e.g. "Connected · 49% left · Updated 2:06 PM".
    /// `isConfigured` separates "Not set up" from "Not checked yet" for saved setups.
    public static func statusLine(for state: ProviderState?, settings: AppSettings = AppSettings(),
                                  isConfigured: Bool = false, now: Date = Date()) -> String {
        guard let state else { return isConfigured ? "Not checked yet" : "Not set up" }
        if state.hasDisplayableUsage {
            if state.status == .stale { return settingsHint(for: state) }
            var parts = ["Connected"]
            if let value = valueText(for: state, settings: settings) { parts.append(value) }
            if let updated = state.snapshot?.updatedAt { parts.append("Updated " + timeText(updated, now: now)) }
            return parts.joined(separator: " · ")
        }
        if state.status == .refreshing { return "Checking…" }
        if isConnectedWithoutValue(state) { return noValueStatus(for: state.provider) }
        if isUntouched(state) { return isConfigured ? "Not checked yet" : "Not set up" }
        return settingsHint(for: state)
    }

    /// A check succeeded, but reported nothing that can be shown as one number
    /// (e.g. Copilot without a monthly allowance). Not "connected" for the menu bar.
    public static func isConnectedWithoutValue(_ state: ProviderState) -> Bool {
        !state.hasDisplayableUsage && state.snapshot != nil && (state.status == .fresh || state.status == .cached)
    }

    public static func noValueStatus(for provider: ProviderID) -> String {
        provider == .copilot ? "Connected · add your monthly allowance to see what's left"
            : "Connected · no usage number reported yet"
    }

    public static func noValueMessage(for provider: ProviderID) -> String {
        provider == .copilot
            ? "Connected, but GitHub doesn't report a limit. Add your monthly allowance to see what's left."
            : "Connected, but the service reported no usage number yet."
    }

    /// No check has produced a result for this provider yet in this session.
    public static func isUntouched(_ state: ProviderState) -> Bool {
        state.snapshot == nil && state.status == .unavailable && (state.message == nil || state.message == "No data yet")
    }

    /// `connectionHint`, reworded for the Settings pane the user is already looking at.
    /// Still fixed copy only: vendor output, paths and secrets are never echoed.
    public static func settingsHint(for state: ProviderState) -> String {
        let replacements = [
            ("Open Settings to set up this provider.", "Set it up below."),
            ("Open Settings, check the signed-in account or profile, then retry.",
             "Check the signed-in account or profile, then choose Check now."),
            ("Check the read-only key in Settings, then retry.", "Check it below, then try again."),
            ("In Settings, create or choose", "Create or choose"),
            ("sign in with the command from Settings, then retry.", "sign in with the command below, then choose Check now.")
        ]
        return replacements.reduce(state.connectionHint) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func timeText(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: - Refresh policy copy

    /// Generated from `RefreshPolicy`, so the explanation cannot drift from the scheduler.
    public static var refreshSchedule: [RefreshScheduleLine] {
        func minutes(_ seconds: TimeInterval?) -> String { "\(Int((seconds ?? 0) / 60)) min" }
        let chatGPT = RefreshPolicy.interval(for: .codex, pinned: [.codex], lowPower: false)
        let others = RefreshPolicy.interval(for: .claude, pinned: [.claude], lowPower: false)
        let chatGPTLow = RefreshPolicy.interval(for: .codex, pinned: [.codex], lowPower: true)
        let othersLow = RefreshPolicy.interval(for: .claude, pinned: [.claude], lowPower: true)
        return [
            RefreshScheduleLine(title: "Menu-bar items",
                                detail: "ChatGPT every \(minutes(chatGPT)), others every \(minutes(others))."),
            RefreshScheduleLine(title: "In Low Power Mode",
                                detail: "ChatGPT every \(minutes(chatGPTLow)), others every \(minutes(othersLow))."),
            RefreshScheduleLine(title: "Everything else",
                                detail: "Refreshes on hover, at most every \(minutes(RefreshPolicy.hoverFreshness(lowPower: false))) (\(minutes(RefreshPolicy.hoverFreshness(lowPower: true))) in Low Power Mode)."),
            RefreshScheduleLine(title: "While nothing changes",
                                detail: "Menu-bar checks space out to at most \(Int(RefreshPolicy.quietMultiplier(unchangedReadings: .max)))× apart until usage moves again.")
        ]
    }

    public static let refreshFootnote = "Checks pause while your Mac sleeps, is locked or is offline."

    // MARK: - Custom API labels

    public static func title(for authentication: CustomConnection.Authentication) -> String {
        switch authentication {
        case .none: "None"
        case .bearer: "Bearer token"
        case .apiKey: "X-API-Key header"
        }
    }

    public static func title(for metric: CustomConnection.Metric) -> String {
        switch metric {
        case .credits: "Credits"
        case .usd: "USD"
        case .remainingPercent: "Percent remaining"
        }
    }

    /// Plain decimal text that parses back with `Double(_:)`, e.g. "1" or "0.01".
    public static func scaleText(_ multiplier: Double) -> String {
        multiplier.formatted(.number.grouping(.never).precision(.fractionLength(0...6)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static let researchCopy: [String: (summary: String, template: CustomConnectionTemplate?)] = [
        "Higgsfield": ("Its CLI can read credits, but UsageRail won't run it until that CLI is reviewed.", nil),
        "Arcads": ("Arcads' public API has no balance endpoint yet, so there's nothing safe to connect.", nil),
        "Grok · SuperGrok": ("SuperGrok's shared allowance has no public usage API. Check it in Grok itself.", nil),
        "Grok · xAI API": ("Track the xAI API prepaid ledger as a custom API with a billing-read management key.",
                           CustomConnectionTemplate(
                            name: "xAI API ledger",
                            endpoint: "https://management-api.x.ai/v1/billing/teams/YOUR_TEAM_ID/prepaid/balance",
                            pointer: "/total/val", metric: .usd, authentication: .bearer, multiplier: 0.01,
                            note: "Replace YOUR_TEAM_ID with your team ID and paste a billing-read management key.")),
        "Cursor": ("Cursor's Admin API reports team spend, not a personal quota. Use Cursor's dashboard.", nil)
    ]
}
