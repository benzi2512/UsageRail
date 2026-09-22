import AppKit
import UsageCore

/// The hover surface: one gauge chip per connected provider, left to right.
@MainActor
final class ProviderStripView: NSView {
    static let height: CGFloat = 116
    static let chipWidth: CGFloat = 76
    static let inset: CGFloat = 10

    var onSelect: ((ProviderID) -> Void)?
    private let scroll = NSScrollView()
    private let document = StripDocumentView()
    private var chips: [ProviderChip] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Connected providers")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var providers: [ProviderID] { chips.map(\.provider) }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let full = CGFloat(chips.count) * Self.chipWidth + Self.inset * 2
        return NSSize(width: min(full, max(Self.chipWidth + Self.inset * 2, maxWidth)), height: Self.height)
    }

    /// Updates values in place; chips are rebuilt only when the provider list changes.
    func update(states: [ProviderState], pinned: [ProviderID], animated: Bool) {
        if chips.map(\.provider) != states.map(\.provider) {
            let previous = Dictionary(uniqueKeysWithValues: chips.map { ($0.provider, $0) })
            chips.forEach { $0.removeFromSuperview() }
            chips = states.map { state in
                let chip = previous[state.provider] ?? ProviderChip(provider: state.provider)
                chip.target = self
                chip.action = #selector(select(_:))
                chip.onMove = { [weak self, weak chip] delta in
                    guard let self, let chip, let index = self.chips.firstIndex(of: chip) else { return }
                    let next = self.chips[(index + delta + self.chips.count) % self.chips.count]
                    next.scrollToVisible(next.bounds)
                    self.window?.makeFirstResponder(next)
                }
                document.addSubview(chip)
                return chip
            }
            needsLayout = true
        }
        for (chip, state) in zip(chips, states) {
            chip.update(state: state, isPinned: pinned.contains(state.provider), animated: animated)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let full = CGFloat(chips.count) * Self.chipWidth + Self.inset * 2
        document.frame = NSRect(x: 0, y: 0, width: max(full, bounds.width), height: bounds.height)
        scroll.hasHorizontalScroller = full > bounds.width + 0.5
        for (index, chip) in chips.enumerated() {
            chip.frame = NSRect(x: Self.inset + CGFloat(index) * Self.chipWidth, y: 8,
                                width: Self.chipWidth, height: Self.height - 16)
        }
    }

    @objc private func select(_ sender: ProviderChip) { onSelect?(sender.provider) }

    func focusFirstProvider() { if let first = chips.first { window?.makeFirstResponder(first) } }
    func selectForQA(_ provider: ProviderID) { chips.first { $0.provider == provider }?.performClick(nil) }
    func displayedValueForQA(_ provider: ProviderID) -> String? { chips.first { $0.provider == provider }?.valueText }
    func updatedTextForQA(_ provider: ProviderID) -> String? { chips.first { $0.provider == provider }?.updatedText }
    func pinBadgeVisibleForQA(_ provider: ProviderID) -> Bool { chips.first { $0.provider == provider }?.isPinBadgeVisible == true }
    func verifyKeyboardForQA() -> [String: Bool] {
        guard chips.count > 1, let window else { return ["stripKeyboardFixtureReady": false] }
        window.makeFirstResponder(chips[0])
        func event(_ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)
        }
        if let right = event(124) { chips[0].keyDown(with: right) }
        let moved = window.firstResponder === chips[1]
        var selected: ProviderID?
        let original = onSelect
        onSelect = { selected = $0 }
        if let enter = event(36) { chips[1].keyDown(with: enter) }
        onSelect = original
        return ["stripArrowMovesFocus": moved, "stripEnterSelectsFocusedProvider": selected == chips[1].provider]
    }
}

@MainActor
private final class StripDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Ring gauge with the provider mark, the displayed value and the short name.
@MainActor
private final class ProviderChip: NSButton {
    let provider: ProviderID
    var onMove: ((Int) -> Void)?
    private let platter = PlatterView()
    private let ring = RingGaugeView()
    private let value = GlassControls.label(size: 12.5, weight: .semibold)
    private let name = GlassControls.label(size: 9.5, weight: .medium, color: UsagePalette.secondaryText)
    private let updated = GlassControls.label(size: 9, weight: .regular, color: UsagePalette.tertiaryText, monospacedDigits: true)
    private let pinBadge = NSImageView()
    private var tracking: NSTrackingArea?
    private var presentation: MenuBarPresentation?
    private var hovering = false { didSet { updatePlatter(animated: true) } }
    private(set) var valueText = "—"
    var isPinBadgeVisible: Bool { !pinBadge.isHidden }

    init(provider: ProviderID) {
        self.provider = provider
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        platter.fill = .clear
        platter.cornerRadius = 18
        addSubview(platter)
        addSubview(ring)
        value.font = GlassControls.valueFont(size: 12.5)
        value.alignment = .center
        name.alignment = .center
        name.stringValue = provider.shortName
        updated.alignment = .center
        addSubview(value)
        addSubview(name)
        addSubview(updated)
        pinBadge.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinBadge.symbolConfiguration = .init(pointSize: 7.5, weight: .bold)
        pinBadge.contentTintColor = .controlAccentColor
        pinBadge.isHidden = true
        addSubview(pinBadge)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    func update(state: ProviderState, isPinned: Bool, animated: Bool) {
        pinBadge.isHidden = !isPinned
        // When this value was read, so a glance tells how current it is.
        let time = state.snapshot.map { Self.timeFormatter.string(from: $0.updatedAt) }
        updated.stringValue = time.map { state.status == .stale || state.status == .cached ? "Saved \($0)" : $0 } ?? ""
        updatedText = updated.stringValue
        let next = MenuBarPresentation(state)
        guard next != presentation else { return }
        let first = presentation == nil
        presentation = next
        ring.configure(image: ProviderIconArtwork.image(for: provider), tint: ProviderIconArtwork.brandColor(for: provider),
                       remaining: next.percent, isBalance: next.isBalance, status: state.status, animated: animated && !first)
        valueText = state.displayValue
        if animated, !first { Motion.crossfade(value.layer, duration: Motion.fade) }
        value.stringValue = valueText
        value.textColor = state.snapshot == nil ? UsagePalette.secondaryText : .labelColor
        let spoken = state.usageAccessibilityValue
        setAccessibilityLabel("\(provider.displayName), \(spoken)\(isPinned ? ", in menu bar" : ""). Opens details.")
        toolTip = "\(provider.displayName) · \(state.metricDescription)" + (time.map { " · updated \($0)" } ?? "")
    }

    private(set) var updatedText = ""
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    override func layout() {
        super.layout()
        platter.frame = bounds.insetBy(dx: 3, dy: 0)
        let ringSide: CGFloat = 42
        ring.frame = NSRect(x: (bounds.width - ringSide) / 2, y: 7, width: ringSide, height: ringSide)
        value.frame = NSRect(x: 2, y: 54, width: bounds.width - 4, height: 17)
        name.frame = NSRect(x: 2, y: 71, width: bounds.width - 4, height: 13)
        updated.frame = NSRect(x: 2, y: 85, width: bounds.width - 4, height: 12)
        pinBadge.frame = NSRect(x: ring.frame.maxX - 6, y: ring.frame.minY - 1, width: 11, height: 11)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {}
    override var isHighlighted: Bool { didSet { updatePlatter(animated: false) } }

    private func updatePlatter(animated: Bool) {
        let fill: NSColor = isHighlighted ? UsagePalette.platterHover : (hovering ? UsagePalette.platter : .clear)
        if animated { Motion.crossfade(platter.layer, duration: Motion.fade) }
        platter.fill = fill
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMove?(-1)
        case 124: onMove?(1)
        case 36, 49: performClick(nil)
        case 53: window?.cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }
}
