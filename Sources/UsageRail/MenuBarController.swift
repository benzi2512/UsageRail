import AppKit
import UsageCore

/// Owns the menu-bar capsule (every pinned provider in one item) and the floating glass surface.
@MainActor
final class MenuBarController: NSObject {
    /// A pin or limit choice changed; persist it. The UI has already been updated.
    var onSettingsChange: ((AppSettings) -> Void)?
    var onRefresh: ((ProviderID) -> Void)?
    /// Providers the user is looking at; the app refreshes only the stale ones, one at a time.
    var onHoverRefresh: (([ProviderID]) -> Void)?
    var onOpenSettings: ((ProviderID?) -> Void)?

    let surface = UsageSurfaceController()
    private(set) var settings: AppSettings
    private var states: [ProviderState] = []
    private let statusItem: StatusBarItem
    private let presentsStatusItems: Bool
    private var inspected: ProviderID?
    private var notice: (provider: ProviderID, text: String)?
    private var noticeWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var hoverRefreshWorkItem: DispatchWorkItem?
    private(set) var iconRenderCountForQA = 0

    init(settings: AppSettings, presentsStatusItems: Bool = true, autosavesPositions: Bool = true) {
        self.settings = settings
        self.presentsStatusItems = presentsStatusItems
        statusItem = StatusBarItem(presents: presentsStatusItems, autosave: autosavesPositions && presentsStatusItems)
        super.init()
        surface.presentsWindow = presentsStatusItems
        surface.glassStyle = settings.glassStyle
        configureSurface()
        wireStatusItem()
        syncStatusItem()
    }

    func update(states: [ProviderState], settings: AppSettings) {
        let styleChanged = self.settings.glassStyle != settings.glassStyle
        self.states = states
        self.settings = settings
        if styleChanged { surface.glassStyle = settings.glassStyle }
        syncStatusItem()
        refreshSurface(animated: true)
    }

    func closeSurface() {
        hideWorkItem?.cancel()
        inspected = nil
        surface.hide()
    }

    /// Opens a provider's details under the menu-bar capsule.
    func showDetails(for provider: ProviderID) { openDetail(provider) }

    var hasVisibleSurface: Bool { surface.isVisible }

    // MARK: Menu-bar capsule

    private func syncStatusItem() {
        if statusItem.render(states: settings.menuBarStates(from: states)) { iconRenderCountForQA += 1 }
    }

    private func wireStatusItem() {
        statusItem.view.onHover = { [weak self] _ in self?.statusItemHovered() }
        statusItem.view.onExit = { [weak self] in self?.scheduleHide() }
        statusItem.view.onClick = { [weak self] index in self?.segmentClicked(index) }
        statusItem.view.onContextMenu = { [weak self] index in self?.showContextMenu(forSegment: index) }
    }

    private func statusItemHovered() {
        hideWorkItem?.cancel()
        // A visible strip or detail stays put; only a hidden surface opens under the pointer.
        guard !surface.isVisible else { return }
        showStrip()
    }

    /// A click on a provider in the capsule opens its details; clicking it again returns to the strip.
    private func segmentClicked(_ index: Int) {
        hideWorkItem?.cancel()
        guard let provider = statusItem.providers[safe: index] else { return }
        if case .detail(let current) = surface.mode, current == provider {
            showStrip()
            if !surface.isVisible { closeSurface() }
        } else {
            openDetail(provider)
        }
    }

    private func showContextMenu(forSegment index: Int) {
        closeSurface()
        guard let button = statusItem.item.button, let provider = statusItem.providers[safe: index] else { return }
        let menu = NSMenu()
        menu.addItem(ContextAction("Refresh \(provider.shortName)", key: "r") { [weak self] in self?.onRefresh?(provider) })
        if settings.menuBarProviders.count > 1 {
            menu.addItem(ContextAction("Remove \(provider.shortName) from Menu Bar") { [weak self] in
                guard let self else { return }
                var updated = self.settings
                if updated.unpinFromMenuBar(provider) { self.commit(updated) }
            })
        }
        menu.addItem(ContextAction("Settings…", key: ",") { [weak self] in self?.onOpenSettings?(nil) })
        menu.addItem(.separator())
        menu.addItem(ContextAction("Quit UsageRail", key: "q") { NSApp.terminate(nil) })
        let x = statusItem.localFrame(ofSegment: index)?.minX ?? 0
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: button.bounds.minY), in: button)
    }

    // MARK: Surface

    private func configureSurface() {
        surface.onPointerEntered = { [weak self] in self?.hideWorkItem?.cancel() }
        surface.onPointerExited = { [weak self] in self?.scheduleHide() }
        surface.onEscape = { [weak self] in self?.closeSurface() }
        surface.onFocusLost = { [weak self] in self?.handleFocusLoss(event: NSApp.currentEvent) }
        surface.strip.onSelect = { [weak self] provider in self?.openDetail(provider) }
        let detail = surface.detail
        detail.onClose = { [weak self] in self?.closeSurface() }
        detail.onBack = { [weak self] in
            guard let self else { return }
            self.showStrip()
            if !self.surface.isVisible { self.closeSurface() } else { self.surface.strip.focusFirstProvider() }
        }
        detail.onRefresh = { [weak self] in
            guard let self, let provider = self.inspected else { return }
            self.onRefresh?(provider)
        }
        detail.onOpenSettings = { [weak self] in
            guard let self else { return }
            let provider = self.inspected
            self.closeSurface()
            self.onOpenSettings?(provider)
        }
        detail.onTogglePin = { [weak self] in self?.toggleMenuBarPin() }
        detail.onSelectLimit = { [weak self] id in self?.selectLimit(id) }
        detail.onUseAuto = { [weak self] in
            guard let self, let provider = self.inspected else { return }
            var updated = self.settings
            updated.selectLimit(nil, for: provider)
            self.commit(updated)
        }
    }

    private func showStrip() {
        let hover = settings.hoverStates(from: states)
        guard !hover.isEmpty, let anchor = statusItem.screenFrame ?? fallbackAnchor else {
            surface.hide()
            return
        }
        let wasVisible = surface.isVisible
        inspected = nil
        surface.strip.update(states: hover, pinned: settings.menuBarProviders, animated: wasVisible)
        surface.showStrip(anchor: anchor, screen: statusItem.screen)
        if !wasVisible { scheduleHoverRefresh(hover.map(\.provider)) }
    }

    /// Strip and details both hang centered under the capsule, so the glass morphs in place.
    private func openDetail(_ provider: ProviderID) {
        hideWorkItem?.cancel()
        guard let anchor = statusItem.screenFrame ?? fallbackAnchor else { return }
        inspected = provider
        renderDetail(animated: false)
        surface.showDetail(anchor: anchor, screen: statusItem.screen)
        onHoverRefresh?([provider])
    }

    /// Hidden QA status items have no window; geometry then falls back to the screen centre.
    private var fallbackAnchor: NSRect? { presentsStatusItems ? nil : .zero }

    private func refreshSurface(animated: Bool) {
        switch surface.mode {
        case .hidden:
            return
        case .strip:
            let hover = settings.hoverStates(from: states)
            guard !hover.isEmpty else { surface.hide(); return }
            let before = surface.strip.providers
            surface.strip.update(states: hover, pinned: settings.menuBarProviders, animated: animated)
            if before != hover.map(\.provider) { surface.relayout(animated: animated) }
        case .detail:
            renderDetail(animated: animated)
            surface.relayout(animated: animated)
        }
    }

    private func renderDetail(animated: Bool) {
        guard let provider = inspected else { return }
        let context = ProviderDetailView.Context(
            isPinned: settings.isPinnedToMenuBar(provider),
            canUnpin: settings.menuBarProviders.count > 1,
            selectedLimitID: settings.limitSelection(for: provider),
            notice: notice?.provider == provider ? notice?.text : nil)
        surface.detail.update(state: state(for: provider), context: context, animated: animated)
    }

    private func scheduleHide() {
        guard surface.mode == .strip else { return }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.surface.mode == .strip else { return }
            self.surface.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Hover refreshes start after the reveal animation so subprocess work never competes with it.
    private func scheduleHoverRefresh(_ providers: [ProviderID]) {
        hoverRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.surface.isVisible else { return }
            self.onHoverRefresh?(providers)
        }
        hoverRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func handleFocusLoss(event: NSEvent?) {
        guard case .detail = surface.mode else { return }
        // A click on one of our menu-bar items can resign the panel's key status before its
        // mouseDown arrives. That click decides what happens; any other focus change closes.
        if let event, event.type == .leftMouseDown, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25,
           let window = statusItem.window, event.windowNumber == window.windowNumber,
           statusItem.screenFrame?.contains(NSEvent.mouseLocation) == true {
            return
        }
        closeSurface()
    }

    // MARK: Pins

    private func toggleMenuBarPin() {
        guard let provider = inspected, state(for: provider).hasDisplayableUsage else { return }
        var updated = settings
        if updated.isPinnedToMenuBar(provider) {
            guard updated.unpinFromMenuBar(provider) else {
                flash("The menu bar keeps at least one item", for: provider)
                renderDetail(animated: true)
                return
            }
            flash("Removed from the menu bar", for: provider)
        } else {
            let displaced = updated.pinToMenuBar(provider)
            flash(displaced.map { "Added to the menu bar · replaced \($0.shortName)" } ?? "Added to the menu bar", for: provider)
        }
        commit(updated)
    }

    private func selectLimit(_ id: String) {
        guard let provider = inspected, state(for: provider).hasDisplayableUsage,
              state(for: provider).snapshot?.windows.contains(where: { $0.id == id && $0.hasDisplayableMetric }) == true else { return }
        var updated = settings
        if updated.limitSelection(for: provider) == id {
            updated.selectLimit(nil, for: provider)
        } else {
            let wasPinned = updated.isPinnedToMenuBar(provider)
            let displaced = updated.pinLimit(id, of: provider)
            if !wasPinned {
                flash(displaced.map { "Added to the menu bar · replaced \($0.shortName)" } ?? "Added to the menu bar", for: provider)
            }
        }
        commit(updated)
    }

    /// Render from the snapshot already on hand, then persist. Never waits for a network read.
    private func commit(_ updated: AppSettings) {
        update(states: states, settings: updated)
        onSettingsChange?(updated)
    }

    private func flash(_ text: String, for provider: ProviderID) {
        noticeWorkItem?.cancel()
        notice = (provider, text)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notice = nil
            if case .detail = self.surface.mode { self.renderDetail(animated: true) }
        }
        noticeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func state(for provider: ProviderID) -> ProviderState {
        states.first { $0.provider == provider }
            ?? ProviderState(provider: provider, status: .unavailable, snapshot: nil, message: "No data yet")
    }

    // MARK: QA (hidden: no status item or window is shown)

    var statusTitlesForQA: [String] { statusItem.titles }
    var statusProvidersForQA: [ProviderID] { statusItem.providers }
    var statusValueForQA: String { statusTitlesForQA.first ?? "" }
    var hasVisibleSurfaceForQA: Bool { surface.isVisible || surface.window.isVisible }
    var statusItemVisibleForQA: Bool { statusItem.item.isVisible }
    var statusWindowForQA: NSWindow? { statusItem.window }

    func verifyPinsForQA() -> [String: Bool] {
        let week = [UsageShare(id: "claude_code", title: "Claude Code", percent: 30), UsageShare(id: "chat", title: "Chats", percent: 6),
                    UsageShare(id: "cowork", title: "Cowork", percent: 64)]
        let claude = ProviderState(provider: .claude, status: .fresh, snapshot: UsageSnapshot(provider: .claude, windows: [
            UsageWindow(id: "five-hour", title: "5-hour session", usedPercent: 9, resetAt: Date().addingTimeInterval(14_000), kind: .shortTerm),
            UsageWindow(id: "seven-day", title: "Weekly · all models", usedPercent: 51, resetAt: Date().addingTimeInterval(400_000), kind: .weekly,
                        breakdown: week),
            UsageWindow(id: "model-Fable", title: "Weekly · Fable", usedPercent: 60, resetAt: Date().addingTimeInterval(400_000), kind: .model)
        ], source: .claudeCode))
        let codex = ProviderState(provider: .codex, status: .fresh, snapshot: UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "codex-primary", title: "Weekly", usedPercent: 20, kind: .weekly),
            UsageWindow(id: "codex-credits", title: "Codex credits", usedPercent: nil, kind: .credits, balance: 1_234.56, balanceUnit: .credits)
        ], source: .codexAppServer, availableResetCount: 0))
        let kie = ProviderState(provider: .kie, status: .fresh, snapshot: UsageSnapshot(provider: .kie, windows: [
            UsageWindow(id: "account-credit", title: "Account credits", usedPercent: nil, kind: .credits, balance: 2, balanceUnit: .credits)
        ], source: .kieAPI, creditBalance: 2))
        let runpod = ProviderState(provider: .runpod, status: .fresh, snapshot: UsageSnapshot(provider: .runpod, windows: [],
            source: .runpodAPI, creditBalance: 23.4568, balanceUnit: .usd))
        var persisted: [AppSettings] = []
        onSettingsChange = { persisted.append($0) }
        update(states: [claude, codex, kie, runpod], settings: AppSettings(selectedProvider: .claude))
        var checks = ["automaticTopBarShowsLowestFable40": statusTitlesForQA == ["40%"]]

        showDetails(for: .claude)
        checks["detailListsEveryClaudeLimit"] = surface.detail.displayedLimitIDsForQA.count == 3
        checks["detailExplainsAutomatic"] = surface.detail.captionForQA.contains("Auto")
        checks["detailHeaderShowsInMenuBar"] = surface.detail.pinTitleForQA == "In menu bar"
        checks["weeklyRowShowsProductBreakdown"] = surface.detail.breakdownForQA("seven-day").count == 3
            && surface.detail.breakdownForQA("seven-day").first?.contains("Cowork") == true
        surface.detail.clickRowPinForQA("seven-day")
        checks["weeklyRowPinDrivesTopBar49"] = statusTitlesForQA == ["49%"]
        checks["weeklyRowPinIsPersisted"] = persisted.last?.limitSelection(for: .claude) == "seven-day"
        checks["weeklyRowShownSelected"] = surface.detail.selectedRowIDForQA == "seven-day"
        checks["captionNamesWeekly"] = surface.detail.captionForQA == "Menu bar Weekly · all models"
        checks["hoverStripUsesWeeklyToo"] = settings.hoverStates(from: states).first?.displayValue == "49%"
        surface.detail.clickRowPinForQA("seven-day")
        checks["secondRowPinClickReturnsToAuto"] = statusTitlesForQA == ["40%"] && persisted.last?.limitSelection(for: .claude) == nil
        surface.detail.clickRowPinForQA("seven-day")
        surface.detail.clickAutoForQA()
        checks["useAutoChipClearsChoice"] = statusTitlesForQA == ["40%"] && surface.detail.selectedRowIDForQA == nil
        checks["claudeResetsShowButtonWithoutCount"] = surface.detail.resetTextForQA == "Claude doesn't report a count"
            && surface.detail.resetBadgeForQA == "Reset"
        checks["resetButtonIsDisplayOnly"] = surface.detail.resetIsDisplayOnlyForQA && surface.isVisible

        showDetails(for: .codex)
        checks["codexResetsShowReportedCount"] = surface.detail.resetTextForQA == "None available right now"
            && surface.detail.resetBadgeForQA == "Reset 0"
        surface.detail.clickPinForQA()
        checks["headerPinAddsSecondMenuBarItem"] = statusProvidersForQA == [.claude, .codex] && statusTitlesForQA == ["40%", "80%"]
        checks["pinsShareOneCapsuleItem"] = statusItem.segmentCountForQA == 2 && statusItem.itemCountForQA == 1
        checks["capsuleHitTestFindsEachProvider"] = (0..<2).allSatisfy { index in
            statusItem.localFrame(ofSegment: index).map { statusItem.segment(atButtonX: $0.midX) == index } ?? false
        }
        checks["pinFeedbackIsShown"] = surface.detail.captionForQA == "Added to the menu bar"
        surface.detail.clickRowPinForQA("codex-credits")
        checks["creditRowPinShowsBalanceInTopBar"] = statusTitlesForQA == ["40%", "1,234.56 cr"]
        showDetails(for: .kie)
        checks["singleLimitProviderHasNoRowPins"] = surface.detail.rowPinCountForQA == 0 && surface.detail.resetBadgeForQA == nil
        surface.detail.clickPinForQA()
        checks["thirdMenuBarItem"] = statusProvidersForQA == [.claude, .codex, .kie] && statusItem.itemCountForQA == 1
        showDetails(for: .runpod)
        surface.detail.clickPinForQA()
        checks["fourthPinReplacesOldest"] = statusProvidersForQA == [.codex, .kie, .runpod]
            && surface.detail.captionForQA.contains("replaced Claude")
        for provider in [ProviderID.runpod, .kie] {
            showDetails(for: provider)
            surface.detail.clickPinForQA()
        }
        checks["headerPinRemovesItems"] = statusProvidersForQA == [.codex]
        showDetails(for: .codex)
        surface.detail.clickPinForQA()
        checks["lastItemCannotBeRemoved"] = statusProvidersForQA == [.codex]
            && surface.detail.captionForQA.contains("at least one")
        showDetails(for: .claude)
        surface.detail.clickRowPinForQA("seven-day")
        checks["rowPinOnUnpinnedProviderAddsIt"] = statusProvidersForQA == [.codex, .claude] && statusTitlesForQA.last == "49%"
        checks["qaNeverShowsAWindow"] = !surface.window.isVisible
        closeSurface()
        onSettingsChange = nil
        return checks
    }

    func verifyTransitionsForQA() -> [String: Bool] {
        let fixture = { (weekly: Double) in
            ProviderState(provider: .claude, status: .fresh, snapshot: UsageSnapshot(provider: .claude, windows: [
                UsageWindow(id: "week", title: "Weekly", usedPercent: 100 - weekly),
                UsageWindow(id: "model", title: "Model", usedPercent: 27)], source: .claudeCode))
        }
        var settings = AppSettings(selectedProvider: .claude)
        settings.selectLimit("week", for: .claude)
        let codex = ProviderState(provider: .codex, status: .fresh, snapshot: UsageSnapshot(provider: .codex,
            windows: [UsageWindow(id: "test", title: "Test", usedPercent: 5)], source: .manual))
        update(states: [fixture(85), codex], settings: settings)
        var checks = ["topBarShowsPinnedLimit85": statusTitlesForQA == ["85%"]]
        statusItemHovered()
        checks["hoverOpensStrip"] = surface.mode == .strip && surface.strip.providers == [.claude, .codex]
        checks["stripShowsPinBadge"] = surface.strip.pinBadgeVisibleForQA(.claude) && !surface.strip.pinBadgeVisibleForQA(.codex)
        checks["stripShowsPinnedLimit"] = surface.strip.displayedValueForQA(.claude) == "85%"
        checks["stripShowsUpdateTime"] = surface.strip.updatedTextForQA(.claude)?.hasSuffix("M") == true
        update(states: [fixture(84), codex], settings: settings)
        checks["refreshUpdatesStripInPlace"] = surface.strip.displayedValueForQA(.claude) == "84%" && surface.mode == .strip
        surface.strip.selectForQA(.codex)
        checks["chipOpensDetailInSameSurface"] = surface.mode == .detail(.codex)
        surface.detail.clickBackForQA()
        checks["backMorphsToStrip"] = surface.mode == .strip
        segmentClicked(0)
        checks["itemClickOpensItsDetail"] = surface.mode == .detail(.claude)
        segmentClicked(0)
        checks["secondClickReturnsToStrip"] = surface.mode == .strip
        surface.onEscape?()
        checks["escapeCloses"] = surface.mode == .hidden
        let expired = ProviderState(provider: .claude, status: .loginRequired, snapshot: fixture(84).snapshot)
        update(states: [expired, codex], settings: settings)
        checks["expiredTopBarShowsDash"] = statusTitlesForQA == ["—"]
        statusItemHovered()
        checks["expiredProviderLeavesStrip"] = surface.strip.providers == [.codex]
        update(states: [expired], settings: settings)
        checks["noConnectedProviderHidesStrip"] = surface.mode == .hidden
        showDetails(for: .claude)
        checks["disconnectedDetailOffersSettings"] = surface.detail.isEmptyStateForQA && surface.detail.pinTitleForQA.isEmpty
        closeSurface()
        update(states: [fixture(84), codex], settings: settings)
        statusItemHovered()
        checks.merge(surface.strip.verifyKeyboardForQA()) { _, new in new }
        checks["surfaceUsesRegularGlassByDefault"] = surface.glassStyleForQA == .regular
        var clear = settings
        clear.glassStyle = .clear
        update(states: [fixture(84), codex], settings: clear)
        checks["glassStyleAppliesLive"] = surface.glassStyleForQA == .clear
        checks["qaNeverShowsAWindow"] = !surface.window.isVisible
        closeSurface()
        return checks
    }
}

/// Every pinned provider in one menu-bar item: a small glass capsule holding a ring gauge and
/// value per provider. Separate status items sit far apart; one item keeps them together and
/// costs one status window instead of three.
@MainActor
private final class StatusBarItem {
    let item: NSStatusItem
    let view = StatusItemView()
    private(set) var states: [ProviderState] = []
    private var presentations: [MenuBarPresentation] = []
    private var segments: [NSRect] = []
    private var imageWidth: CGFloat = 0

    init(presents: Bool, autosave: Bool) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Keeps the position of build 24's first item.
        if autosave { item.autosaveName = "UsageRail.MenuBar" }
        item.isVisible = presents
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = nil
            button.wantsLayer = true
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        view.segmentAt = { [weak self] x in self?.segment(atButtonX: x) ?? 0 }
        view.segmentScreenFrame = { [weak self] index in self?.screenFrame(ofSegment: index) }
        view.onAppearanceChange = { [weak self] in self?.redraw(animated: true) }
    }

    var providers: [ProviderID] { states.map(\.provider) }
    var titles: [String] { states.map(\.displayValue) }
    var segmentCountForQA: Int { segments.count }
    var itemCountForQA: Int { 1 }

    /// Returns true when the pixels changed.
    @discardableResult
    func render(states next: [ProviderState]) -> Bool {
        let nextPresentations = next.map(MenuBarPresentation.init)
        let spoken = next.map { "\($0.provider.displayName), \($0.usageAccessibilityValue)" }
        if spoken != states.map({ "\($0.provider.displayName), \($0.usageAccessibilityValue)" }) {
            item.button?.setAccessibilityLabel(spoken.joined(separator: "; "))
            view.segmentLabels = spoken.map { $0 + ". Opens details." }
        }
        states = next
        guard nextPresentations != presentations else { return false }
        let animated = !presentations.isEmpty
        presentations = nextPresentations
        redraw(animated: animated)
        return true
    }

    private func redraw(animated: Bool) {
        guard let button = item.button else { return }
        let drawing = MenuBarIconRenderer.capsule(for: states)
        if animated { Motion.crossfade(button.layer, duration: 0.24) }
        button.image = drawing.image
        segments = drawing.segments
        imageWidth = drawing.image.size.width
    }

    /// The capsule image is centered in the button; segments are laid out left to right.
    private var imageOriginX: CGFloat {
        guard let button = item.button, button.bounds.width > 0 else { return 0 }
        return ((button.bounds.width - imageWidth) / 2).rounded()
    }

    func segment(atButtonX x: CGFloat) -> Int {
        let local = x - imageOriginX
        return segments.firstIndex { local < $0.maxX + MenuBarIconRenderer.segmentGap / 2 } ?? max(0, segments.count - 1)
    }

    func localFrame(ofSegment index: Int) -> NSRect? {
        guard let frame = segments[safe: index] else { return nil }
        return NSRect(x: frame.minX + imageOriginX, y: 0, width: frame.width, height: item.button?.bounds.height ?? frame.height)
    }

    func screenFrame(ofSegment index: Int) -> NSRect? {
        guard let button = item.button, let window = button.window, let local = localFrame(ofSegment: index) else { return nil }
        return window.convertToScreen(button.convert(local, to: nil))
    }

    var screenFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var screen: NSScreen? { item.button?.window?.screen }
    var window: NSWindow? { item.button?.window }
}

/// Transparent overlay on the status button: hover, clicks and VoiceOver per provider segment.
@MainActor
private final class StatusItemView: NSView {
    var onHover: ((Int) -> Void)?
    var onExit: (() -> Void)?
    var onClick: ((Int) -> Void)?
    var onContextMenu: ((Int) -> Void)?
    var onAppearanceChange: (() -> Void)?
    var segmentAt: ((CGFloat) -> Int)?
    var segmentScreenFrame: ((Int) -> NSRect?)?
    var segmentLabels: [String] = [] { didSet { rebuildAccessibility() } }
    private var tracking: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var elements: [SegmentAccessibilityElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("UsageRail")
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hoverWorkItem?.cancel()
        let index = segment(for: event)
        let work = DispatchWorkItem { [weak self] in self?.onHover?(index) }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    override func mouseExited(with event: NSEvent) {
        hoverWorkItem?.cancel()
        onExit?()
    }
    override func mouseDown(with event: NSEvent) {
        let index = segment(for: event)
        if event.modifierFlags.contains(.control) { onContextMenu?(index) } else { onClick?(index) }
    }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(segment(for: event)) }
    override func accessibilityPerformPress() -> Bool {
        onClick?(0)
        return true
    }
    override func accessibilityChildren() -> [Any]? { elements }

    private func segment(for event: NSEvent) -> Int {
        segmentAt?(convert(event.locationInWindow, from: nil).x) ?? 0
    }

    private func rebuildAccessibility() {
        elements = segmentLabels.enumerated().map { index, label in
            let element = SegmentAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.onPress = { [weak self] in self?.onClick?(index) }
            element.frameProvider = { [weak self] in self?.segmentScreenFrame?(index) ?? .zero }
            return element
        }
    }
}

/// One provider inside the capsule, as its own VoiceOver button. AppKit calls these on the main thread.
private final class SegmentAccessibilityElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?
    nonisolated(unsafe) var frameProvider: (@MainActor () -> NSRect)?
    override func accessibilityPerformPress() -> Bool {
        let press = onPress
        MainActor.assumeIsolated { press?() }
        return true
    }
    override func accessibilityFrame() -> NSRect {
        let frame = frameProvider
        return MainActor.assumeIsolated { frame?() ?? .zero }
    }
}

/// Menu item that runs a closure; keeps the context menu free of selector plumbing.
private final class ContextAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc private func run() { handler() }
}

@MainActor
enum MenuBarIconRenderer {
    static let segmentGap: CGFloat = 11
    private static let ringSide: CGFloat = 16
    private static let capsuleHeight: CGFloat = 20
    private static let imageHeight: CGFloat = 22
    private static let padding: CGFloat = 7
    private static let textGap: CGFloat = 4
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    static func progressPercent(for state: ProviderState) -> Double? {
        MenuBarPresentation(state).percent
    }

    /// The capsule for all pins, with each segment's rectangle in image coordinates.
    static func capsule(for states: [ProviderState]) -> (image: NSImage, segments: [NSRect]) {
        let texts = states.map(\.displayValue)
        var segments: [NSRect] = []
        var x = padding
        for (index, text) in texts.enumerated() {
            let width = ringSide + textGap + ceil((text as NSString).size(withAttributes: [.font: font]).width)
            segments.append(NSRect(x: x, y: 0, width: width, height: imageHeight))
            x += width + (index < texts.count - 1 ? segmentGap : 0)
        }
        let size = NSSize(width: max(ringSide + padding * 2, x + padding), height: imageHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            let pill = NSRect(x: 0.5, y: ((rect.height - capsuleHeight) / 2).rounded(), width: rect.width - 1, height: capsuleHeight)
            let shape = NSBezierPath(roundedRect: pill, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
            // A glass-like capsule that follows the menu bar's own light or dark text color:
            // a translucent fill, a brighter top edge and a hairline rim.
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            shape.fill()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))?
                .draw(in: shape, angle: -90)
            NSColor.labelColor.withAlphaComponent(0.24).setStroke()
            shape.lineWidth = 0.75
            shape.stroke()
            for (index, state) in states.enumerated() {
                let frame = segments[index]
                if index > 0 {
                    NSColor.labelColor.withAlphaComponent(0.22).setFill()
                    NSRect(x: (frame.minX - segmentGap / 2).rounded(), y: pill.midY - 5, width: 1, height: 10).fill()
                }
                drawRing(for: state, in: NSRect(x: frame.minX, y: ((rect.height - ringSide) / 2).rounded(), width: ringSide, height: ringSide))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: state.hasDisplayableUsage ? NSColor.labelColor : NSColor.secondaryLabelColor
                ]
                let text = texts[index] as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: frame.minX + ringSide + textGap, y: ((rect.height - textSize.height) / 2).rounded(.down) + 0.5),
                          withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return (image, segments)
    }

    /// A single ring gauge image, e.g. for places that show one provider.
    static func image(for state: ProviderState, size side: CGFloat = 23) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawRing(for: state, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Ring for the remaining quota (none for balances) with the provider mark inside.
    private static func drawRing(for state: ProviderState, in rect: NSRect) {
        let remaining = progressPercent(for: state)
        let isBalance = MenuBarPresentation(state).isBalance
        let lineWidth = max(1.6, rect.width * 0.11)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - lineWidth / 2 - 0.25
        if !isBalance {
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            let track = NSBezierPath()
            track.lineWidth = lineWidth
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.stroke()
        }
        if let remaining {
            UsagePalette.color(forRemaining: remaining, status: state.status).setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - (360 * remaining / 100), clockwise: true)
            arc.stroke()
        }
        let markSide = rect.width * (isBalance ? 0.74 : 0.5)
        let markRect = NSRect(x: rect.midX - markSide / 2, y: rect.midY - markSide / 2, width: markSide, height: markSide)
        NSGraphicsContext.saveGraphicsState()
        ProviderIconArtwork.image(for: state.provider).draw(in: markRect)
        NSColor.labelColor.setFill()
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSBezierPath(rect: markRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
