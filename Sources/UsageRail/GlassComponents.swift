import AppKit
import QuartzCore
import UsageCore

/// Shared motion, color and small layer-backed building blocks for the glass surfaces.
/// Everything here is drawn with Core Animation so value changes and light/dark
/// switches animate instead of snapping.
@MainActor
enum Motion {
    static let reveal: TimeInterval = 0.26
    static let dismiss: TimeInterval = 0.16
    static let morph: TimeInterval = 0.34
    static let fade: TimeInterval = 0.14
    static let value: TimeInterval = 0.45
    static let theme: TimeInterval = 0.32
    /// Fast start, long soft landing — close to the system's spring feel without overshoot.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    static let standard = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = easeOut,
                        changes: () -> Void, completion: (() -> Void)? = nil) {
        // AppKit calls animation completions on the main thread.
        nonisolated(unsafe) let completion = completion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    /// Crossfades a layer tree into its next appearance instead of repainting in steps.
    static func crossfade(_ layer: CALayer?, duration: TimeInterval = theme) {
        guard let layer, !reduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = standard
        layer.add(transition, forKey: "usageRail.crossfade")
    }
}

@MainActor
enum UsagePalette {
    static func color(forRemaining remaining: Double, status: ProviderStatus) -> NSColor {
        if status == .stale || status == .cached { return .secondaryLabelColor }
        if remaining < 10 { return .systemRed }
        if remaining < 30 { return .systemOrange }
        if remaining <= 60 { return .systemYellow }
        return .systemGreen
    }

    /// Supporting text on glass. The system's secondary label washes out over busy backdrops.
    static let secondaryText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.76) : NSColor(white: 0, alpha: 0.68)
    }
    /// Quiet text (zero shares, pin outlines) that still reads on glass.
    static let tertiaryText = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.52) : NSColor(white: 0, alpha: 0.46)
    }

    /// Soft fill for rows and chips that sit on glass.
    static let platter = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.075) : NSColor.black.withAlphaComponent(0.045)
    }
    static let platterHover = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.08)
    }
    static let track = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.09)
    }
    static let hairline = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.07)
    }
    /// Legibility tint for clear glass: still see-through, but text never fights the wallpaper.
    static let clearGlassTint = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.black.withAlphaComponent(0.42) : NSColor.white.withAlphaComponent(0.5)
    }
    /// A light milky base under frosted glass so busy windows behind it stay quiet.
    static let regularGlassTint = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.black.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.24)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSView {
    /// Resolves a dynamic color for this view's current appearance.
    func resolved(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

/// Rounded fill behind a row or chip. Colors follow light/dark without a redraw pass.
@MainActor
final class PlatterView: NSView {
    var fill: NSColor = UsagePalette.platter { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 14 { didSet { layer?.cornerRadius = cornerRadius } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = resolved(fill)
        layer?.borderColor = stroke.map { resolved($0) }
        layer?.borderWidth = stroke == nil ? 0 : 1
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Circular quota gauge. Progress animates from the previous value.
@MainActor
final class RingGaugeView: NSView {
    private let disc = CAShapeLayer()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let mark = NSImageView()
    private var color: NSColor = .systemGreen
    private var fraction: CGFloat?
    var lineWidth: CGFloat = 3.2 { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Balances have no quota ring; a soft disc keeps them in rhythm with the gauges.
        disc.isHidden = true
        layer?.addSublayer(disc)
        for shape in [track, progress] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        progress.strokeEnd = 0
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = .labelColor
        addSubview(mark)
    }
    required init?(coder: NSCoder) { nil }
    // Unflipped on purpose: the ring path below is written in y-up coordinates.
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    func configure(image: NSImage, tint: NSColor? = nil, remaining: Double?, isBalance: Bool, status: ProviderStatus, animated: Bool) {
        mark.image = image
        mark.contentTintColor = tint ?? .labelColor
        mark.alphaValue = status == .stale || status == .cached ? 0.7 : 1
        let next = remaining.map { CGFloat(max(0, min(100, $0)) / 100) }
        color = remaining.map { UsagePalette.color(forRemaining: $0, status: status) } ?? .secondaryLabelColor
        track.isHidden = isBalance
        disc.isHidden = !isBalance
        progress.isHidden = next == nil
        let from = progress.presentation()?.strokeEnd ?? progress.strokeEnd
        let target = next ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeEnd = target
        progress.strokeColor = resolved(color)
        CATransaction.commit()
        if animated, fraction != next, !Motion.reduceMotion {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = fraction == nil ? 0 : from
            animation.toValue = target
            animation.duration = Motion.value
            animation.timingFunction = Motion.easeOut
            progress.add(animation, forKey: "progress")
        }
        fraction = next
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = lineWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Start at 12 o'clock and run clockwise (y-up space).
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for shape in [track, progress] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
        disc.frame = bounds
        disc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        let markSide = track.isHidden ? bounds.width * 0.5 : bounds.width * 0.46
        mark.frame = NSRect(x: (bounds.width - markSide) / 2, y: (bounds.height - markSide) / 2,
                            width: markSide, height: markSide)
    }

    override func updateLayer() {
        track.strokeColor = resolved(UsagePalette.track)
        progress.strokeColor = resolved(color)
        disc.fillColor = resolved(UsagePalette.platterHover)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Horizontal capsule meter with an animated fill.
@MainActor
final class CapsuleBarView: NSView {
    private let fillLayer = CALayer()
    private var fraction: CGFloat = 0
    private var color: NSColor = .systemGreen

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fillLayer.anchorPoint = .zero
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    func configure(remaining: Double, status: ProviderStatus, animated: Bool) {
        let next = CGFloat(max(0, min(100, remaining)) / 100)
        color = UsagePalette.color(forRemaining: remaining, status: status)
        let previous = fraction
        fraction = next
        layoutFill(animated: animated && previous != next)
        needsDisplay = true
    }

    private func layoutFill(animated: Bool) {
        let target = CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduceMotion)
        CATransaction.setAnimationDuration(Motion.value)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        fillLayer.bounds = CGRect(origin: .zero, size: target.size)
        fillLayer.position = .zero
        fillLayer.isHidden = fraction <= 0
        fillLayer.backgroundColor = resolved(color)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        fillLayer.cornerRadius = bounds.height / 2
        layoutFill(animated: false)
    }

    override func updateLayer() {
        layer?.backgroundColor = resolved(UsagePalette.track)
        fillLayer.backgroundColor = resolved(color)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
enum GlassControls {
    /// Circular glass button with an SF Symbol, for panel chrome.
    static func circleButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: target, action: action)
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    /// Small capsule glass button with a symbol and a short title.
    static func capsuleButton(title: String, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: target, action: action)
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .labelColor
        return button
    }

    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, monospacedDigits: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.allowsDefaultTighteningForTruncation = true
        return field
    }

    /// Rounded-number font for prominent values.
    static func valueFont(size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }
}
