import Foundation

public enum RailPlacement: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case top
    case bottom

    public var isVertical: Bool { self == .left || self == .right }
}

/// Liquid Glass material for the floating usage surfaces.
public enum GlassStyle: String, Codable, CaseIterable, Sendable {
    /// See-through glass with a legibility tint.
    case clear
    /// Frosted, higher-contrast glass. The default.
    case regular
}

public struct AppSettings: Equatable, Sendable {
    public static let maximumMenuBarItems = 3

    public var providerOrder: [ProviderID]
    /// Providers shown as their own menu-bar items, in pin order. Never empty.
    public private(set) var menuBarProviders: [ProviderID]
    /// The limit that represents a provider wherever one number is shown (menu bar and hover bar).
    /// No entry means automatic: the lowest remaining limit.
    public private(set) var limitSelections: [String: String]
    public var railPlacement: RailPlacement
    public var positionFraction: Double
    public var autoHide: Bool
    public var githubUsername: String
    public var githubAllowance: Double?
    public var glassStyle: GlassStyle

    /// The first menu-bar pin. It is refreshed first and anchors Settings defaults.
    public var selectedProvider: ProviderID { menuBarProviders[0] }
    public var enabledProviders: Set<ProviderID> { Set(menuBarProviders) }
    public var visibleProviders: [ProviderID] { menuBarProviders }

    public init(
        providerOrder: [ProviderID] = ProviderID.allCases,
        enabledProviders: Set<ProviderID> = [.codex, .claude, .copilot],
        railPlacement: RailPlacement = .left,
        positionFraction: Double = 0.5,
        autoHide: Bool = true,
        githubUsername: String = "",
        githubAllowance: Double? = nil,
        selectedProvider: ProviderID? = nil,
        menuBarProviders: [ProviderID] = [],
        limitSelections: [String: String] = [:],
        glassStyle: GlassStyle = .regular
    ) {
        let uniqueOrder = providerOrder.reduce(into: [ProviderID]()) { result, provider in
            if !result.contains(provider) { result.append(provider) }
        }
        self.providerOrder = uniqueOrder + ProviderID.allCases.filter { !uniqueOrder.contains($0) }
        let pins = menuBarProviders.reduce(into: [ProviderID]()) { result, provider in
            if !result.contains(provider) { result.append(provider) }
        }
        if pins.isEmpty {
            // Legacy selection: the explicit provider, else the first previously enabled one.
            let legacy = self.providerOrder.first { enabledProviders.contains($0) }
            self.menuBarProviders = [selectedProvider ?? legacy ?? .codex]
        } else {
            self.menuBarProviders = Array(pins.prefix(Self.maximumMenuBarItems))
        }
        self.limitSelections = limitSelections
        self.railPlacement = railPlacement
        self.positionFraction = min(1, max(0, positionFraction))
        self.autoHide = autoHide
        self.githubUsername = githubUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        self.githubAllowance = githubAllowance.flatMap { $0 > 0 ? $0 : nil }
        self.glassStyle = glassStyle
    }

    public func isPinnedToMenuBar(_ provider: ProviderID) -> Bool { menuBarProviders.contains(provider) }

    public func limitSelection(for provider: ProviderID) -> String? { limitSelections[provider.rawValue] }

    /// Adds a provider as the newest menu-bar item. When the bar is full the oldest pin
    /// makes room and is returned so the caller can say what changed.
    @discardableResult
    public mutating func pinToMenuBar(_ provider: ProviderID) -> ProviderID? {
        guard !menuBarProviders.contains(provider) else { return nil }
        var displaced: ProviderID?
        if menuBarProviders.count >= Self.maximumMenuBarItems { displaced = menuBarProviders.removeFirst() }
        menuBarProviders.append(provider)
        return displaced
    }

    /// The menu bar always keeps one item, otherwise the app would have no visible entry point.
    @discardableResult
    public mutating func unpinFromMenuBar(_ provider: ProviderID) -> Bool {
        guard menuBarProviders.count > 1, let index = menuBarProviders.firstIndex(of: provider) else { return false }
        menuBarProviders.remove(at: index)
        return true
    }

    /// Replaces every menu-bar pin, e.g. after a provider was removed. Keeps at least one.
    public mutating func setMenuBarProviders(_ providers: [ProviderID]) {
        let unique = providers.reduce(into: [ProviderID]()) { result, provider in
            if !result.contains(provider) { result.append(provider) }
        }
        guard !unique.isEmpty else { return }
        menuBarProviders = Array(unique.prefix(Self.maximumMenuBarItems))
    }

    /// `nil` returns the provider to automatic (lowest remaining limit).
    public mutating func selectLimit(_ limitID: String?, for provider: ProviderID) {
        limitSelections[provider.rawValue] = limitID
    }

    /// Pinning one limit shows exactly that limit in the menu bar and hover bar.
    @discardableResult
    public mutating func pinLimit(_ limitID: String, of provider: ProviderID) -> ProviderID? {
        selectLimit(limitID, for: provider)
        return pinToMenuBar(provider)
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        let order = (defaults.stringArray(forKey: "providerOrder") ?? [])
            .compactMap(ProviderID.init(rawValue:))
        let enabled = Set((defaults.stringArray(forKey: "enabledProviders") ?? [
            ProviderID.codex.rawValue,
            ProviderID.claude.rawValue,
            ProviderID.copilot.rawValue
        ]).compactMap(ProviderID.init(rawValue:)))
        let legacySelected = defaults.string(forKey: "selectedProvider")
            .flatMap(ProviderID.init(rawValue:))
            ?? order.first(where: enabled.contains)
            ?? .codex
        let placement = RailPlacement(
            rawValue: defaults.string(forKey: "railPlacement")
                ?? defaults.string(forKey: "railSide")
                ?? "left"
        ) ?? .left
        let fraction: Double
        if defaults.object(forKey: "positionFraction") != nil {
            fraction = defaults.double(forKey: "positionFraction")
        } else if defaults.object(forKey: "verticalFraction") != nil {
            fraction = defaults.double(forKey: "verticalFraction")
        } else {
            fraction = 0.5
        }
        let allowance = defaults.object(forKey: "githubAllowance") == nil
            ? nil
            : defaults.double(forKey: "githubAllowance")

        let custom = CustomConnection.load(defaults: defaults).map(\.provider)
        func exists(_ provider: ProviderID) -> Bool { !provider.isCustom || custom.contains(provider) }
        let currentOrder = order.filter(exists)
        let storedPins = (defaults.stringArray(forKey: "menuBarProviders") ?? [])
            .compactMap(ProviderID.init(rawValue:)).filter(exists)
        let pins = storedPins.isEmpty ? [exists(legacySelected) ? legacySelected : .codex] : storedPins

        let selections: [String: String]
        if let stored = defaults.dictionary(forKey: "limitSelections") as? [String: String] {
            selections = stored
        } else {
            // Build 23 and earlier kept two separate choices: a hover-bar limit per provider and a
            // top-bar limit for the one menu-bar provider. They become the single display choice.
            var migrated = defaults.dictionary(forKey: "stripLimitIDs") as? [String: String] ?? [:]
            if let topBarLimit = defaults.string(forKey: "selectedLimitID") { migrated[legacySelected.rawValue] = topBarLimit }
            selections = migrated
        }

        // Build 24 saved its Clear default with every change, and it read as too transparent.
        // Only a style saved by revision 2 or later is a choice to keep; older values start on Regular.
        let storedGlassStyle = defaults.integer(forKey: "glassStyleRevision") >= 2
            ? defaults.string(forKey: "glassStyle").flatMap(GlassStyle.init(rawValue:)) : nil
        return AppSettings(
            providerOrder: currentOrder + custom.filter { !currentOrder.contains($0) },
            railPlacement: placement,
            positionFraction: fraction,
            autoHide: defaults.object(forKey: "autoHide") == nil ? true : defaults.bool(forKey: "autoHide"),
            githubUsername: defaults.string(forKey: "githubUsername") ?? "",
            githubAllowance: allowance,
            menuBarProviders: pins,
            limitSelections: selections,
            glassStyle: storedGlassStyle ?? .regular
        )
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.providerOrder.map(\.rawValue), forKey: "providerOrder")
        defaults.set(settings.menuBarProviders.map(\.rawValue), forKey: "menuBarProviders")
        defaults.set(settings.limitSelections, forKey: "limitSelections")
        // Keep the build 23 keys meaningful so a rollback shows the same primary item and limits.
        defaults.set(settings.selectedProvider.rawValue, forKey: "selectedProvider")
        defaults.set([settings.selectedProvider.rawValue], forKey: "enabledProviders")
        defaults.set(settings.limitSelection(for: settings.selectedProvider), forKey: "selectedLimitID")
        defaults.set(settings.limitSelections, forKey: "stripLimitIDs")
        defaults.set(settings.railPlacement.rawValue, forKey: "railPlacement")
        defaults.set(settings.positionFraction, forKey: "positionFraction")
        defaults.set(settings.autoHide, forKey: "autoHide")
        defaults.set(settings.githubUsername, forKey: "githubUsername")
        defaults.set(settings.glassStyle.rawValue, forKey: "glassStyle")
        defaults.set(2, forKey: "glassStyleRevision")
        if let allowance = settings.githubAllowance {
            defaults.set(allowance, forKey: "githubAllowance")
        } else {
            defaults.removeObject(forKey: "githubAllowance")
        }
    }
}
