import AppKit
import UsageCore

extension NSAppearance {
    var usageRailIsDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Shared metrics, fonts and dynamic colors for the Settings window.
/// Colors are resolved while drawing, so light/dark switches never leave a stale CGColor behind.
@MainActor
enum SettingsStyle {
    static let contentInset: CGFloat = 28
    static let maxContentWidth: CGFloat = 600
    static let rowInset: CGFloat = 14
    static let cornerRadius: CGFloat = 10
    static let sectionSpacing: CGFloat = 20

    static let paneTitleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
    static let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.systemFont(ofSize: 12)
    static let footnoteFont = NSFont.systemFont(ofSize: 11.5)

    static let groupFill = NSColor(name: nil) { appearance in
        appearance.usageRailIsDark ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0, alpha: 0.045)
    }
    static let platterFill = NSColor(name: nil) { appearance in
        appearance.usageRailIsDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 1, alpha: 0.92)
    }
    static let platterStroke = NSColor(name: nil) { appearance in
        appearance.usageRailIsDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
    }
}

struct SettingsMessage: Equatable {
    enum Tone: Equatable { case info, progress, success, warning, error }
    let text: String
    let tone: Tone

    static func info(_ text: String) -> Self { Self(text: text, tone: .info) }
    static func progress(_ text: String) -> Self { Self(text: text, tone: .progress) }
    static func success(_ text: String) -> Self { Self(text: text, tone: .success) }
    static func warning(_ text: String) -> Self { Self(text: text, tone: .warning) }
    static func error(_ text: String) -> Self { Self(text: text, tone: .error) }
}

/// A label that wraps to whatever width Auto Layout gives it.
final class SettingsLabel: NSTextField {
    static func make(_ text: String, font: NSFont = SettingsStyle.bodyFont,
                     color: NSColor = .labelColor, wraps: Bool = true) -> SettingsLabel {
        let label = wraps ? SettingsLabel(wrappingLabelWithString: text) : SettingsLabel(labelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return label
    }

    override func layout() {
        super.layout()
        guard cell?.wraps == true, abs(preferredMaxLayoutWidth - bounds.width) > 0.5 else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// A System Settings style rounded platter holding rows separated by hairlines.
final class SettingsGroupView: NSView {
    private let stack = NSStackView()

    init(rows: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        rows.forEach(addRow)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    var rows: [NSView] { stack.arrangedSubviews }

    func addRow(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        needsDisplay = true
    }

    func removeAllRows() {
        for row in stack.arrangedSubviews {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = SettingsStyle.cornerRadius
        SettingsStyle.groupFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.separatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            outline.lineWidth = 1
            outline.stroke()
        }
        let hairline = 1 / max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        for row in stack.arrangedSubviews.filter({ !$0.isHidden }).dropFirst() {
            let y = convert(row.frame, from: stack).minY
            NSRect(x: SettingsStyle.rowInset, y: y - hairline / 2, width: bounds.width - SettingsStyle.rowInset, height: hairline).fill()
        }
    }
}

/// One row: optional icon, title with optional subtitle, and trailing accessories.
final class SettingsRowView: NSView {
    let titleLabel: SettingsLabel
    let subtitleLabel: SettingsLabel
    let iconView = NSImageView()
    private let labels = NSStackView()
    private let accessories = NSStackView()

    init(title: String, subtitle: String? = nil, icon: NSImage? = nil, accessories views: [NSView] = [],
         minimumHeight: CGFloat = 40) {
        titleLabel = SettingsLabel.make(title, font: SettingsStyle.bodyFont)
        subtitleLabel = SettingsLabel.make(subtitle ?? "", font: SettingsStyle.detailFont, color: .secondaryLabelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(subtitleLabel)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(labels)

        accessories.orientation = .horizontal
        accessories.alignment = .centerY
        accessories.spacing = 8
        accessories.translatesAutoresizingMaskIntoConstraints = false
        // Hug the controls tightly so they sit at the trailing edge and the labels take the rest.
        accessories.setHuggingPriority(.required, for: .horizontal)
        accessories.setContentHuggingPriority(.required, for: .horizontal)
        accessories.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(accessories)
        setAccessories(views)

        var leading = leadingAnchor
        var leadingConstant = SettingsStyle.rowInset
        if let icon {
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .labelColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsStyle.rowInset),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18)
            ])
            leading = iconView.trailingAnchor
            leadingConstant = 10
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leading, constant: leadingConstant),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -12),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsStyle.rowInset),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessories.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        ])
        // Slightly above the labels' hugging so wrapping text uses the whole row.
        let fill = labels.trailingAnchor.constraint(equalTo: accessories.leadingAnchor, constant: -12)
        fill.priority = .init(260)
        fill.isActive = true
        // Stay as short as the content allows; the >= constraints above grow it when needed.
        let compact = heightAnchor.constraint(equalToConstant: minimumHeight)
        compact.priority = .defaultLow
        compact.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var subtitle: String? {
        get { subtitleLabel.isHidden ? nil : subtitleLabel.stringValue }
        set {
            subtitleLabel.stringValue = newValue ?? ""
            subtitleLabel.isHidden = newValue?.isEmpty ?? true
        }
    }

    func setAccessories(_ views: [NSView]) {
        for view in accessories.arrangedSubviews {
            accessories.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.forEach { accessories.addArrangedSubview($0) }
    }
}

/// A small status dot.
final class SettingsDotView: NSView {
    enum Tone: Equatable { case green, orange, gray }

    var tone: Tone? {
        didSet { isHidden = tone == nil; needsDisplay = true }
    }

    init(tone: Tone? = nil, diameter: CGFloat = 8) {
        self.tone = tone
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = tone == nil
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter),
                                     heightAnchor.constraint(equalToConstant: diameter)])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tone else { return }
        switch tone {
        case .green: NSColor.systemGreen.setFill()
        case .orange: NSColor.systemOrange.setFill()
        case .gray: NSColor.tertiaryLabelColor.setFill()
        }
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// Rounded tile behind a provider mark, like an app icon in System Settings.
final class SettingsIconPlatter: NSView {
    let imageView = NSImageView()
    private let side: CGFloat

    init(image: NSImage, side: CGFloat = 52, iconSide: CGFloat = 32) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = image.isTemplate ? .labelColor : nil
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSide),
            imageView.heightAnchor.constraint(equalToConstant: iconSide)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = side * 0.24
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        SettingsStyle.platterFill.setFill()
        path.fill()
        SettingsStyle.platterStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Pane header: icon tile, name, one live status line and an optional trailing action.
final class SettingsPaneHeaderView: NSView {
    let platter: SettingsIconPlatter
    let titleLabel: SettingsLabel
    let statusDot = SettingsDotView()
    let statusLabel = SettingsLabel.make("", font: SettingsStyle.detailFont, color: .secondaryLabelColor)

    init(icon: NSImage, title: String, status: String? = nil, accessory: NSView? = nil) {
        platter = SettingsIconPlatter(image: icon)
        titleLabel = SettingsLabel.make(title, font: SettingsStyle.paneTitleFont, wraps: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        let text = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, statusDot, statusLabel] as [NSView] { text.addSubview(view) }
        statusLeadingWithDot = statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6)
        statusLeadingPlain = statusLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor)
        addSubview(platter)
        addSubview(text)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: text.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: text.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: text.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: text.bottomAnchor),
            statusDot.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.firstBaselineAnchor, constant: -4),
            // Whichever is taller, icon or text, sets the height; both stay centred.
            platter.leadingAnchor.constraint(equalTo: leadingAnchor),
            platter.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            platter.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: platter.trailingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: platter.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
        let compact = heightAnchor.constraint(equalToConstant: 0)
        compact.priority = .defaultLow
        compact.isActive = true
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
                accessory.centerYAnchor.constraint(equalTo: platter.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12)
            ])
        } else {
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        }
        setStatus(status, tone: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var statusLeadingWithDot: NSLayoutConstraint!
    private var statusLeadingPlain: NSLayoutConstraint!

    func setStatus(_ text: String?, tone: SettingsDotView.Tone?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text?.isEmpty ?? true
        statusDot.tone = (text?.isEmpty ?? true) ? nil : tone
        let showsDot = statusDot.tone != nil
        statusLeadingPlain.isActive = !showsDot
        statusLeadingWithDot.isActive = showsDot
    }
}

/// Inline, non-modal feedback under a setup action.
final class SettingsMessageView: NSView {
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    let label = SettingsLabel.make("", font: SettingsStyle.detailFont, color: .secondaryLabelColor)
    private(set) var message: SettingsMessage?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        label.setAccessibilityRole(.staticText)
        for view in [spinner, symbol, label] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 14), symbol.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ message: SettingsMessage?) {
        self.message = message
        isHidden = message == nil
        label.stringValue = message?.text ?? ""
        spinner.stopAnimation(nil)
        symbol.isHidden = true
        guard let message else { return }
        let symbolName: String?
        let tint: NSColor
        switch message.tone {
        case .progress: spinner.startAnimation(nil); symbolName = nil; tint = .secondaryLabelColor
        case .info: symbolName = "info.circle"; tint = .secondaryLabelColor
        case .success: symbolName = "checkmark.circle.fill"; tint = .systemGreen
        case .warning: symbolName = "exclamationmark.triangle.fill"; tint = .systemOrange
        case .error: symbolName = "exclamationmark.circle.fill"; tint = .systemRed
        }
        if let symbolName {
            symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbol.contentTintColor = tint
            symbol.isHidden = false
        }
        label.textColor = message.tone == .error ? .systemRed : .secondaryLabelColor
    }
}

/// "More" disclosure keeping long help out of the way.
final class SettingsDisclosureView: NSView {
    let toggle = NSButton()
    let body = NSStackView()

    init(title: String = "More", content: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toggle.title = title
        toggle.isBordered = false
        toggle.imagePosition = .imageLeading
        toggle.font = .systemFont(ofSize: 12, weight: .medium)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleExpanded)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityLabel(title == "More" ? "Show more help" : title)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in content {
            body.addArrangedSubview(view)
            if view is SettingsLabel || view is SettingsGroupView {
                view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }
        addSubview(toggle)
        addSubview(body)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            toggle.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 8)
        ])
        collapsedBottom = toggle.bottomAnchor.constraint(equalTo: bottomAnchor)
        expandedBottom = body.bottomAnchor.constraint(equalTo: bottomAnchor)
        setExpanded(false)
    }

    required init?(coder: NSCoder) { nil }

    private var collapsedBottom: NSLayoutConstraint!
    private var expandedBottom: NSLayoutConstraint!
    private(set) var isExpanded = false

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        body.isHidden = !expanded
        collapsedBottom.isActive = !expanded
        expandedBottom.isActive = expanded
        toggle.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        toggle.setAccessibilityExpanded(expanded)
    }

    @objc private func toggleExpanded() { setExpanded(!isExpanded) }
}

/// Flipped document view so panes start at the top.
final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
enum SettingsUI {
    static func sectionHeader(_ text: String) -> SettingsLabel {
        let label = SettingsLabel.make(text, font: SettingsStyle.sectionFont, color: .secondaryLabelColor, wraps: false)
        label.setAccessibilityRole(.staticText)
        return label
    }

    static func footnote(_ text: String) -> SettingsLabel {
        SettingsLabel.make(text, font: SettingsStyle.footnoteFont, color: .secondaryLabelColor)
    }

    static func button(_ title: String, target: AnyObject?, action: Selector, accessibility: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        button.setAccessibilityLabel(accessibility ?? title)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    static func textField(placeholder: String, accessibility: String) -> NSTextField {
        let field = NSTextField()
        configure(field, placeholder: placeholder, accessibility: accessibility)
        return field
    }

    static func secureField(placeholder: String, accessibility: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        configure(field, placeholder: placeholder, accessibility: accessibility)
        return field
    }

    static func configure(_ field: NSTextField, placeholder: String, accessibility: String) {
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.font = SettingsStyle.bodyFont
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(accessibility)
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Label on the left, control on the right, like a System Settings form row.
    static func formRow(_ title: String, control: NSView, width: CGFloat = 270) -> SettingsRowView {
        control.translatesAutoresizingMaskIntoConstraints = false
        let preferred = control.widthAnchor.constraint(equalToConstant: width)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: min(width, 150)).isActive = true
        control.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return SettingsRowView(title: title, accessories: [control])
    }

    /// Leading and trailing controls on one line.
    static func buttonBar(leading: [NSView], trailing: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: leading + [spacer] + trailing)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    static func symbol(_ name: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Menu-sized copy; never resize the shared artwork instances.
    static func menuIcon(for provider: ProviderID, side: CGFloat = 16) -> NSImage? {
        let icon = ProviderIconArtwork.image(for: provider).copy() as? NSImage
        icon?.size = NSSize(width: side, height: side)
        return icon
    }

    /// A vertically scrolling pane whose content is centered and capped in width.
    static func scrollView(containing content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let fill = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -2 * SettingsStyle.contentInset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsStyle.maxContentWidth),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: SettingsStyle.contentInset),
            fill
        ])
        return scroll
    }
}
