import AppKit
import UsageCore

/// Every limit of one provider, with the menu-bar pin controls.
@MainActor
final class ProviderDetailView: NSView {
    struct Context: Equatable {
        var isPinned: Bool
        var canUnpin: Bool
        var selectedLimitID: String?
        var notice: String?
    }

    static let width: CGFloat = 348
    private static let headerHeight: CGFloat = 56
    private static let footerHeight: CGFloat = 46
    private static let rowSpacing: CGFloat = 6
    private static let side: CGFloat = 14
    private static let listInset: CGFloat = 10

    var onTogglePin: (() -> Void)?
    var onSelectLimit: ((String) -> Void)?
    var onUseAuto: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var provider: ProviderID?
    private(set) var state = ProviderState(provider: .codex, status: .unavailable, snapshot: nil)
    private(set) var context = Context(isPinned: false, canUnpin: false, selectedLimitID: nil, notice: nil)
    private var order: [String] = []
    private var rows: [String: LimitRowView] = [:]
    private let resetRow = ResetRowView()

    private let iconPlatter = PlatterView()
    private let icon = NSImageView()
    private let titleLabel = GlassControls.label(size: 15, weight: .semibold)
    private let subtitleLabel = GlassControls.label(size: 11, weight: .medium, color: UsagePalette.secondaryText)
    private let footerLabel = GlassControls.label(size: 11, weight: .medium, color: UsagePalette.secondaryText)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let document = DetailDocumentView()
    private lazy var pinButton = GlassControls.capsuleButton(title: "Pin", symbol: "pin", target: self, action: #selector(togglePin))
    private lazy var autoChip = GlassControls.capsuleButton(title: "", symbol: "xmark.circle.fill", target: self, action: #selector(useAuto))
    private lazy var closeButton = GlassControls.circleButton(symbol: "xmark", label: "Close", target: self, action: #selector(close))
    private lazy var backButton = GlassControls.circleButton(symbol: "chevron.left", label: "Back to all providers", target: self, action: #selector(back))
    private lazy var settingsButton = GlassControls.circleButton(symbol: "gearshape", label: "Connection settings", target: self, action: #selector(openSettings))
    private lazy var refreshButton = GlassControls.circleButton(symbol: "arrow.clockwise", label: "Refresh now", target: self, action: #selector(refresh))
    private lazy var emptyButton = GlassControls.capsuleButton(title: "Open Settings", symbol: "gearshape", target: self, action: #selector(openSettings))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconPlatter.cornerRadius = 10
        addSubview(iconPlatter)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        iconPlatter.addSubview(icon)
        for view: NSView in [titleLabel, subtitleLabel, footerLabel, pinButton, autoChip,
                             closeButton, backButton, settingsButton, refreshButton] {
            addSubview(view)
        }
        autoChip.imagePosition = .imageTrailing
        autoChip.font = .systemFont(ofSize: 11, weight: .semibold)
        footerLabel.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        document.addSubview(resetRow)
        addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        emptyLabel.textColor = UsagePalette.secondaryText
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        addSubview(emptyButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    // MARK: Content

    func update(state: ProviderState, context: Context, animated: Bool) {
        let providerChanged = provider != state.provider
        provider = state.provider
        self.state = state
        self.context = context
        let animateValues = animated && !providerChanged

        icon.image = ProviderIconArtwork.image(for: state.provider)
        icon.contentTintColor = ProviderIconArtwork.brandColor(for: state.provider) ?? .labelColor
        titleLabel.stringValue = state.provider.shortName
        subtitleLabel.stringValue = subtitle
        setAccessibilityLabel("\(state.provider.displayName) usage details")

        let usable = state.hasDisplayableUsage
        pinButton.isHidden = !usable
        updatePinButton()
        updateFooter()
        refreshButton.isEnabled = state.status != .refreshing

        let limits = usable ? (state.snapshot?.limitsForDisplay ?? []) : []
        let incoming = limits.map(\.id)
        // Keep the reading order stable across refreshes; new limits join at the end.
        order = providerChanged ? incoming : order.filter(incoming.contains) + incoming.filter { !order.contains($0) }
        // A single limit is already what Auto shows; only offer a choice when there is one.
        let selectable = limits.filter(\.hasDisplayableMetric).count > 1
        for id in Array(rows.keys) where !incoming.contains(id) {
            rows[id]?.removeFromSuperview()
            rows[id] = nil
        }
        for limit in limits {
            let row = rows[limit.id] ?? {
                let created = LimitRowView(id: limit.id)
                created.onPin = { [weak self] id in self?.onSelectLimit?(id) }
                document.addSubview(created)
                rows[limit.id] = created
                return created
            }()
            row.update(limit: limit, status: state.status, isSelected: context.selectedLimitID == limit.id,
                       selectable: selectable && limit.hasDisplayableMetric, animated: animateValues)
        }
        // Providers that offer limit resets get a display-only Resets row with the reported count.
        resetRow.isHidden = !(usable && ConnectionCatalog.entry(for: state.provider).offersResets)
        if !resetRow.isHidden { resetRow.update(count: state.reportedResetCount, provider: state.provider) }

        scroll.isHidden = !usable || limits.isEmpty
        emptyLabel.isHidden = !scroll.isHidden
        emptyButton.isHidden = !scroll.isHidden
        emptyLabel.stringValue = usable ? "No usage limits reported yet." : state.connectionHint
        if providerChanged { resetScroll() }
        needsLayout = true
        layoutRows(animated: animateValues)
    }

    func preferredHeight(maxHeight: CGFloat) -> CGFloat {
        let content = scroll.isHidden ? 132 : listHeight + 6
        let total = Self.headerHeight + content + Self.footerHeight
        return min(max(200, total), maxHeight)
    }

    func resetScroll() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private var listViews: [NSView] {
        order.compactMap { rows[$0] } + (resetRow.isHidden ? [] : [resetRow])
    }

    private var listHeight: CGFloat {
        let heights = listViews.map(Self.height(of:))
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * Self.rowSpacing
    }

    private static func height(of view: NSView) -> CGFloat {
        (view as? LimitRowView)?.preferredHeight ?? ResetRowView.height
    }

    private var subtitle: String {
        let time = state.snapshot.map { Self.timeFormatter.string(from: $0.updatedAt) }
        switch state.status {
        case .loginRequired: return "Sign-in needed"
        case .refreshing: return "Refreshing…"
        case .cached: return time.map { "Saved · \($0)" } ?? "Saved"
        case .stale: return time.map { "Check failed · saved \($0)" } ?? "Check failed"
        case .fresh: return time.map { "Updated \($0)" } ?? "Up to date"
        case .unavailable: return "Not connected"
        }
    }

    private func updatePinButton() {
        let pinned = context.isPinned
        pinButton.title = pinned ? "In menu bar" : "Pin"
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.tintProminence = pinned ? .primary : .automatic
        pinButton.bezelColor = pinned ? .controlAccentColor : nil
        // Tinted glass picks its own contrasting content; plain glass follows the label color.
        pinButton.contentTintColor = pinned ? nil : .labelColor
        pinButton.toolTip = pinned
            ? (context.canUnpin ? "Remove \(state.provider.shortName) from the menu bar" : "The menu bar keeps at least one item")
            : "Show \(state.provider.shortName) in the menu bar"
        pinButton.setAccessibilityLabel(pinned ? "In menu bar. Remove from menu bar" : "Pin to menu bar")
        pinButton.setAccessibilityValue(pinned ? "On" : "Off")
    }

    /// The footer always says what the menu bar shows; a chosen limit is a chip whose × returns to Auto.
    private func updateFooter() {
        let selected = context.selectedLimitID
        let limit = selected.flatMap { id in state.snapshot?.windows.first { $0.id == id } }
        var label = ""
        var chip: String?
        var color = UsagePalette.secondaryText
        if let notice = context.notice {
            label = notice; color = .labelColor
        } else if !state.hasDisplayableUsage {
            label = "Not connected"
        } else if selected != nil && limit?.hasDisplayableMetric != true {
            label = "Pinned limit is missing"; chip = "Use Auto"; color = .systemOrange
        } else if let limit {
            label = context.isPinned ? "Menu bar" : "Hover bar"; chip = limit.title
        } else {
            label = context.isPinned ? "Menu bar · Auto (lowest)" : "Not in menu bar"
        }
        footerLabel.stringValue = label
        footerLabel.textColor = color
        autoChip.isHidden = chip == nil
        autoChip.title = chip ?? ""
        autoChip.toolTip = "Use Auto: show the lowest limit"
        autoChip.setAccessibilityLabel(chip.map { $0 == "Use Auto" ? "Use Auto" : "\($0). Use Auto instead" } ?? "")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        iconPlatter.frame = NSRect(x: Self.side, y: 12, width: 32, height: 32)
        icon.frame = NSRect(x: 6, y: 6, width: 20, height: 20)
        closeButton.frame = NSRect(x: width - Self.side - 26, y: 15, width: 26, height: 26)
        let pinWidth = pinButton.isHidden ? 0 : ceil(pinButton.fittingSize.width) + 4
        pinButton.frame = NSRect(x: closeButton.frame.minX - 8 - pinWidth, y: 16, width: pinWidth, height: 24)
        let titleRight = (pinButton.isHidden ? closeButton.frame.minX : pinButton.frame.minX) - 8
        titleLabel.frame = NSRect(x: 56, y: 11, width: max(40, titleRight - 56), height: 19)
        subtitleLabel.frame = NSRect(x: 56, y: 30, width: max(40, titleRight - 56), height: 14)

        let footerY = bounds.height - Self.footerHeight
        backButton.frame = NSRect(x: Self.side, y: footerY + 10, width: 26, height: 26)
        refreshButton.frame = NSRect(x: width - Self.side - 26, y: footerY + 10, width: 26, height: 26)
        settingsButton.frame = NSRect(x: refreshButton.frame.minX - 8 - 26, y: footerY + 10, width: 26, height: 26)
        layoutFooterCenter(from: backButton.frame.maxX + 8, to: settingsButton.frame.minX - 8, y: footerY + 10)

        let listTop = Self.headerHeight
        scroll.frame = NSRect(x: 0, y: listTop, width: width, height: max(0, footerY - listTop))
        let emptyHeight: CGFloat = 60
        emptyLabel.frame = NSRect(x: 28, y: listTop + 14, width: width - 56, height: emptyHeight)
        let buttonWidth = ceil(emptyButton.fittingSize.width) + 6
        emptyButton.frame = NSRect(x: (width - buttonWidth) / 2, y: listTop + 14 + emptyHeight + 8, width: buttonWidth, height: 26)
        layoutRows(animated: false)
    }

    /// Centers "label [chip ×]" between the footer buttons, truncating the chip first.
    private func layoutFooterCenter(from minX: CGFloat, to maxX: CGFloat, y: CGFloat) {
        let available = max(0, maxX - minX)
        let labelWidth = min(textWidth(footerLabel), available)
        let chipWidth = autoChip.isHidden ? 0 : min(ceil(autoChip.fittingSize.width) + 4, max(0, available - labelWidth - 6))
        let total = labelWidth + (chipWidth > 0 ? 6 + chipWidth : 0)
        var x = minX + (available - total) / 2
        footerLabel.frame = NSRect(x: x, y: y + 5, width: labelWidth, height: 16)
        x += labelWidth + 6
        autoChip.frame = NSRect(x: x, y: y + 2, width: chipWidth, height: 22)
    }

    private func layoutRows(animated: Bool) {
        let width = scroll.frame.width > 0 ? scroll.frame.width : Self.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(listHeight + 6, scroll.contentSize.height))
        var y: CGFloat = 0
        for view in listViews {
            let height = Self.height(of: view)
            let frame = NSRect(x: Self.listInset, y: y, width: width - Self.listInset * 2, height: height)
            if animated, view.frame != .zero, view.frame != frame {
                Motion.animate(Motion.morph, changes: { view.animator().frame = frame })
            } else {
                view.frame = frame
            }
            y += height + Self.rowSpacing
        }
    }

    private func textWidth(_ field: NSTextField) -> CGFloat {
        guard let cell = field.cell else { return field.intrinsicContentSize.width }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width)
    }

    // MARK: Actions

    @objc private func togglePin() { onTogglePin?() }
    @objc private func useAuto() { onUseAuto?() }
    @objc private func close() { onClose?() }
    @objc private func back() { onBack?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func refresh() { onRefresh?() }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    // MARK: QA

    var displayedLimitIDsForQA: [String] { order }
    var rowFramesForQA: [NSRect] { listViews.map(\.frame) }
    var chromeFramesForQA: [NSRect] {
        [closeButton, pinButton, backButton, settingsButton, refreshButton, titleLabel, subtitleLabel, footerLabel, autoChip]
            .filter { !$0.isHidden }.map(\.frame)
    }
    var rowPinCountForQA: Int { rows.values.filter(\.isPinVisible).count }
    var selectedRowIDForQA: String? { rows.first { $0.value.isSelected }?.key }
    /// What the footer says the menu bar shows, e.g. "Menu bar Weekly · all models".
    var captionForQA: String { footerLabel.stringValue + (autoChip.isHidden ? "" : " " + autoChip.title) }
    var pinTitleForQA: String { pinButton.isHidden ? "" : pinButton.title }
    var isEmptyStateForQA: Bool { !emptyLabel.isHidden }
    var resetTextForQA: String? { resetRow.isHidden ? nil : resetRow.summaryText }
    /// What the display-only Reset button shows, e.g. "Reset 1".
    var resetBadgeForQA: String? { resetRow.isHidden ? nil : resetRow.badgeText }
    /// Nothing in the Resets row can act: it holds no button at all.
    var resetIsDisplayOnlyForQA: Bool { resetRow.isHidden || !Self.containsButton(resetRow) }
    private static func containsButton(_ view: NSView) -> Bool { view is NSButton || view.subviews.contains(where: containsButton) }
    func breakdownForQA(_ id: String) -> [String] { rows[id]?.breakdownTextsForQA ?? [] }
    func clickPinForQA() { pinButton.performClick(nil) }
    func clickAutoForQA() { autoChip.performClick(nil) }
    func clickBackForQA() { backButton.performClick(nil) }
    func clickRowPinForQA(_ id: String) { rows[id]?.clickPinForQA() }
    func valueTextForQA(_ id: String) -> String? { rows[id]?.valueTextForQA }
}

@MainActor
private final class DetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One limit: title and value on one line, a meter, then reset time and pin — plus, where the
/// provider reports it, which products used the window (stacked bar and legend).
@MainActor
private final class LimitRowView: NSView {
    let id: String
    var onPin: ((String) -> Void)?
    private let platter = PlatterView()
    private let title = GlassControls.label(size: 12.5, weight: .semibold)
    private let value = GlassControls.label(size: 18, weight: .semibold)
    private let unit = GlassControls.label(size: 11, weight: .medium, color: UsagePalette.secondaryText)
    private let metadata = GlassControls.label(size: 11, weight: .regular, color: UsagePalette.secondaryText)
    private let bar = CapsuleBarView()
    private let shares = ShareBarView()
    private var legend: [NSTextField] = []
    private let pin = NSButton()
    private(set) var isSelected = false
    private var kind = Kind.percent
    private enum Kind { case percent, balance, text }
    private static let baseHeight: CGFloat = 60
    private static let legendLine: CGFloat = 15

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        platter.cornerRadius = 12
        addSubview(platter)
        value.font = GlassControls.valueFont(size: 18)
        value.alignment = .right
        for view: NSView in [title, value, unit, metadata, bar, shares, pin] { addSubview(view) }
        pin.isBordered = false
        pin.imagePosition = .imageOnly
        pin.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
        pin.target = self
        pin.action = #selector(pinClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        switch kind {
        case .percent:
            guard !legend.isEmpty else { return Self.baseHeight }
            return Self.baseHeight + 4 + 8 + CGFloat((legend.count + 1) / 2) * Self.legendLine + 4
        case .balance: return metadata.stringValue.isEmpty ? 42 : 58
        case .text: return 42
        }
    }
    var isPinVisible: Bool { !pin.isHidden }
    var valueTextForQA: String { value.stringValue + (unit.stringValue.isEmpty ? "" : " " + unit.stringValue) }
    var breakdownTextsForQA: [String] { legend.map(\.stringValue) }
    func clickPinForQA() { pin.performClick(nil) }

    func update(limit: UsageWindow, status: ProviderStatus, isSelected: Bool, selectable: Bool, animated: Bool) {
        self.isSelected = isSelected
        title.stringValue = limit.title
        let resetText = limit.resetAt.map(Self.resetText)
        let quantity: String? = {
            if limit.balance != nil { return limit.detail }
            if let detail = limit.detail { return detail }
            if let used = limit.used, let cap = limit.limit { return "\(Self.number(used)) / \(Self.number(cap)) used" }
            if let used = limit.used { return "\(Self.number(used)) used" }
            return nil
        }()
        metadata.stringValue = [resetText, quantity, limit.isEstimated ? "Calculated" : nil].compactMap { $0 }.joined(separator: " · ")

        let previousValue = value.stringValue
        if let remaining = limit.remainingPercent {
            kind = .percent
            value.stringValue = "\(Int(remaining.rounded()))%"
            value.font = GlassControls.valueFont(size: 18)
            value.textColor = remaining < 10 && status == .fresh ? .systemRed : .labelColor
            unit.stringValue = "left"
            bar.isHidden = false
            bar.configure(remaining: remaining, status: status, animated: animated)
        } else if let balance = limit.balance {
            kind = .balance
            value.stringValue = limit.balanceUnit == .usd ? (limit.balanceText ?? "") : balance.formatted(.number.precision(.fractionLength(0...2)))
            value.font = GlassControls.valueFont(size: 16)
            value.textColor = .labelColor
            unit.stringValue = limit.balanceUnit == .usd ? "USD" : "credits"
            bar.isHidden = true
        } else {
            kind = .text
            value.stringValue = limit.detail ?? "Usage unavailable"
            value.font = .systemFont(ofSize: 12, weight: .medium)
            value.textColor = UsagePalette.secondaryText
            unit.stringValue = ""
            bar.isHidden = true
        }
        if animated, previousValue != value.stringValue { Motion.crossfade(value.layer, duration: Motion.fade) }
        updateBreakdown(kind == .percent ? limit.breakdown : nil, animated: animated)

        pin.isHidden = !selectable
        pin.image = NSImage(systemSymbolName: isSelected ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.contentTintColor = isSelected ? .controlAccentColor : UsagePalette.tertiaryText
        pin.toolTip = isSelected ? "Shown in the menu bar — click to use Auto" : "Show \(limit.title) in the menu bar"
        pin.setAccessibilityLabel(pin.toolTip)
        pin.setAccessibilityValue(isSelected ? "Pinned" : "Not pinned")
        if animated { Motion.crossfade(platter.layer, duration: Motion.fade) }
        platter.fill = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : UsagePalette.platter
        platter.stroke = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.42) : nil
        let spoken = limit.remainingPercent.map { "\(Int($0.rounded())) percent remaining" }
            ?? limit.balanceText.map { limit.balanceUnit == .usd ? "\($0) USD balance" : "\($0) credits remaining" }
            ?? (limit.detail ?? "No numeric value")
        let products = (limit.breakdown ?? []).map { "\($0.title) \(Int($0.percent.rounded())) percent" }.joined(separator: ", ")
        setAccessibilityLabel("\(limit.title), \(spoken)\(resetText.map { ", \($0)" } ?? "")"
            + (products.isEmpty ? "" : ". Used by \(products)") + (isSelected ? ", shown in menu bar" : ""))
        needsLayout = true
    }

    /// Legend labels are rebuilt only when the products change; values update in place.
    private func updateBreakdown(_ breakdown: [UsageShare]?, animated: Bool) {
        let items = (breakdown ?? []).sorted { $0.percent > $1.percent }
        shares.isHidden = items.isEmpty
        shares.configure(items, animated: animated)
        if legend.count != items.count {
            legend.forEach { $0.removeFromSuperview() }
            legend = items.map { _ in
                let label = GlassControls.label(size: 11, weight: .medium, color: UsagePalette.secondaryText)
                addSubview(label)
                return label
            }
        }
        for (label, item) in zip(legend, items) {
            let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: ShareBarView.color(for: item, among: items),
                                                                              .font: NSFont.systemFont(ofSize: 9, weight: .bold)])
            text.append(NSAttributedString(string: "\(item.title) ", attributes: [.foregroundColor: UsagePalette.secondaryText,
                                                                                    .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
            text.append(NSAttributedString(string: "\(Int(item.percent.rounded()))%", attributes: [
                .foregroundColor: item.percent > 0 ? NSColor.labelColor : UsagePalette.tertiaryText,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]))
            label.attributedStringValue = text
            label.toolTip = "\(item.title) used \(Int(item.percent.rounded()))% of this window's usage"
        }
    }

    override func layout() {
        super.layout()
        platter.frame = bounds
        let width = bounds.width
        let inset: CGFloat = 12
        let unitWidth = unit.stringValue.isEmpty ? 0 : Self.textWidth(unit) + 1
        let valueWidth = min(Self.textWidth(value) + 2, width * 0.55)
        switch kind {
        case .percent:
            unit.frame = NSRect(x: width - inset - unitWidth, y: 12, width: unitWidth, height: 14)
            value.frame = NSRect(x: unit.frame.minX - 3 - valueWidth, y: 5, width: valueWidth, height: 23)
            title.frame = NSRect(x: inset, y: 9, width: max(40, value.frame.minX - inset - 8), height: 17)
            bar.frame = NSRect(x: inset, y: 33, width: width - inset * 2, height: 5)
            pin.frame = NSRect(x: width - 7 - 22, y: 38, width: 22, height: 20)
            metadata.frame = NSRect(x: inset, y: 42, width: max(0, (pin.isHidden ? width - inset : pin.frame.minX - 4) - inset), height: 14)
            shares.frame = NSRect(x: inset, y: Self.baseHeight + 2, width: width - inset * 2, height: 4)
            let column = (width - inset * 2) / 2
            for (index, label) in legend.enumerated() {
                label.frame = NSRect(x: inset + CGFloat(index % 2) * column, y: Self.baseHeight + 12 + CGFloat(index / 2) * Self.legendLine,
                                     width: column - 4, height: 14)
            }
        case .balance, .text:
            let right = pin.isHidden ? width - inset : width - 7 - 22 - 6
            pin.frame = NSRect(x: width - 7 - 22, y: 11, width: 22, height: 20)
            unit.frame = NSRect(x: right - unitWidth, y: 15, width: unitWidth, height: 14)
            let valueRight = unitWidth > 0 ? unit.frame.minX - 3 : right
            value.frame = NSRect(x: valueRight - valueWidth, y: kind == .text ? 13 : 10, width: valueWidth, height: kind == .text ? 16 : 21)
            title.frame = NSRect(x: inset, y: 13, width: max(40, value.frame.minX - inset - 8), height: 17)
            metadata.frame = NSRect(x: inset, y: 34, width: width - inset * 2, height: 14)
        }
    }

    @objc private func pinClicked() { onPin?(id) }

    /// Width the label's cell needs, including its text insets.
    private static func textWidth(_ field: NSTextField) -> CGFloat {
        guard let cell = field.cell else { return field.intrinsicContentSize.width }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 100)).width)
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func resetText(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resetting" }
        if interval < 3_600 { return "Resets in \(max(1, Int(interval / 60))) min" }
        if interval < 86_400 {
            let hours = Int(interval / 3_600), minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
            return minutes == 0 ? "Resets in \(hours)h" : "Resets in \(hours)h \(minutes)m"
        }
        return "Resets " + (interval < 6 * 86_400 ? weekdayFormatter : dateFormatter).string(from: date)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

/// Resets, laid out like the providers' own usage pages: a display-only Reset button carrying the
/// number of resets the provider reports. UsageRail never uses a reset, so the button never acts.
@MainActor
private final class ResetRowView: NSView {
    static let height: CGFloat = 50
    private let platter = PlatterView()
    private let symbol = NSImageView()
    private let title = GlassControls.label("Resets", size: 12.5, weight: .semibold)
    private let summary = GlassControls.label(size: 11, weight: .medium, color: UsagePalette.secondaryText)
    private let badge = ResetBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        platter.cornerRadius = 12
        addSubview(platter)
        symbol.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        symbol.contentTintColor = .labelColor
        for view: NSView in [symbol, title, summary, badge] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var summaryText: String { summary.stringValue }
    var badgeText: String { badge.text }

    func update(count: Int?, provider: ProviderID) {
        switch count {
        case 0?: summary.stringValue = "None available right now"
        case let count?: summary.stringValue = "\(count) available"
        case nil: summary.stringValue = "\(provider.shortName) doesn't report a count"
        }
        badge.configure(count: count)
        toolTip = count == nil
            ? "\(provider.shortName)'s usage data doesn't include resets, so UsageRail can't count them. Display only."
            : "Display only. Use resets in \(provider == .codex ? "ChatGPT" : provider.shortName); UsageRail never uses one."
        setAccessibilityLabel("Resets. \(summary.stringValue). Display only.")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        platter.frame = bounds
        symbol.frame = NSRect(x: 12, y: (bounds.height - 20) / 2, width: 18, height: 20)
        let badgeWidth = badge.fittingWidth
        badge.frame = NSRect(x: bounds.width - 10 - badgeWidth, y: (bounds.height - ResetBadgeView.height) / 2,
                             width: badgeWidth, height: ResetBadgeView.height)
        let x = symbol.frame.maxX + 10
        let textWidth = max(0, badge.frame.minX - 8 - x)
        title.frame = NSRect(x: x, y: 8, width: textWidth, height: 17)
        summary.frame = NSRect(x: x, y: 26, width: textWidth, height: 15)
    }
}

/// A capsule drawn like the providers' Reset button, with the count in a pill. It has no action
/// and no hover state: it reports, it doesn't reset. Layers draw the same on screen and offscreen.
@MainActor
private final class ResetBadgeView: NSView {
    static let height: CGFloat = 24
    private let capsule = PlatterView()
    private let pill = PlatterView()
    private let symbol = NSImageView()
    private let label = GlassControls.label("Reset", size: 11, weight: .semibold)
    private let countLabel = GlassControls.label(size: 10.5, weight: .bold, monospacedDigits: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        capsule.cornerRadius = Self.height / 2
        pill.cornerRadius = 8
        symbol.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        countLabel.alignment = .center
        for view: NSView in [capsule, symbol, label, pill] { addSubview(view) }
        pill.addSubview(countLabel)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// "Reset 1", "Reset 0", or "Reset" when the provider reports no count.
    var text: String { label.stringValue + (pill.isHidden ? "" : " " + countLabel.stringValue) }

    func configure(count: Int?) {
        let available = (count ?? 0) > 0
        pill.isHidden = count == nil
        countLabel.stringValue = count.map { $0 > 99 ? "99+" : String($0) } ?? ""
        let content: NSColor = available ? .white : (count == 0 ? UsagePalette.tertiaryText : UsagePalette.secondaryText)
        capsule.fill = available ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.07)
        capsule.stroke = available ? nil : NSColor.labelColor.withAlphaComponent(0.12)
        pill.fill = available ? NSColor.white.withAlphaComponent(0.26) : NSColor.labelColor.withAlphaComponent(0.08)
        symbol.contentTintColor = content
        label.textColor = content
        countLabel.textColor = content
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        let labelWidth = Self.width(of: label)
        let pillWidth = pill.isHidden ? 0 : max(16, Self.width(of: countLabel) + 8)
        return ceil(10 + 12 + 4 + labelWidth + (pill.isHidden ? 0 : 5 + pillWidth) + (pill.isHidden ? 11 : 4))
    }

    override func layout() {
        super.layout()
        capsule.frame = bounds
        symbol.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 12, height: 14)
        let labelWidth = Self.width(of: label)
        label.frame = NSRect(x: symbol.frame.maxX + 4, y: (bounds.height - 15) / 2, width: labelWidth, height: 15)
        let pillWidth = max(16, Self.width(of: countLabel) + 8)
        pill.frame = NSRect(x: label.frame.maxX + 5, y: (bounds.height - 16) / 2, width: pillWidth, height: 16)
        countLabel.frame = NSRect(x: 0, y: 1, width: pillWidth, height: 14)
    }

    private static func width(of field: NSTextField) -> CGFloat {
        guard let cell = field.cell else { return field.intrinsicContentSize.width }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1_000, height: 100)).width)
    }
}

/// Stacked bar of product shares, e.g. Cowork 64% and Claude Code 30% of a week's usage.
@MainActor
final class ShareBarView: NSView {
    private var segments: [CALayer] = []
    private var items: [UsageShare] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    /// Known products keep their color across refreshes; unknown ones take the next free hue.
    static func color(for item: UsageShare, among items: [UsageShare]) -> NSColor {
        switch item.id {
        case "cowork": return .systemPurple
        case "claude_code": return .systemTeal
        case "chat": return .systemBlue
        case "other": return .systemGray
        default:
            let spare: [NSColor] = [.systemPink, .systemIndigo, .systemMint, .systemBrown]
            let unknown = items.filter { !["cowork", "claude_code", "chat", "other"].contains($0.id) }
            return spare[(unknown.firstIndex(of: item) ?? 0) % spare.count]
        }
    }

    func configure(_ items: [UsageShare], animated: Bool) {
        self.items = items
        while segments.count < items.count {
            let segment = CALayer()
            segment.anchorPoint = .zero
            layer?.addSublayer(segment)
            segments.append(segment)
        }
        while segments.count > items.count { segments.removeLast().removeFromSuperlayer() }
        layoutSegments(animated: animated)
        needsDisplay = true
    }

    private func layoutSegments(animated: Bool) {
        let total = max(1, items.map(\.percent).reduce(0, +))
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduceMotion)
        CATransaction.setAnimationDuration(Motion.value)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        for (segment, item) in zip(segments, items) {
            let width = bounds.width * CGFloat(item.percent / total)
            segment.bounds = CGRect(x: 0, y: 0, width: max(0, width - (item == items.last ? 0 : 1)), height: bounds.height)
            segment.position = CGPoint(x: x, y: 0)
            segment.backgroundColor = resolved(Self.color(for: item, among: items))
            x += width
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layoutSegments(animated: false)
    }

    override func updateLayer() {
        layer?.backgroundColor = resolved(UsagePalette.track)
        for (segment, item) in zip(segments, items) { segment.backgroundColor = resolved(Self.color(for: item, among: items)) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
