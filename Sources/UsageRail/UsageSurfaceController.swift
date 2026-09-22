import AppKit
import QuartzCore
import UsageCore

private final class SurfacePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Transparent full-size root. Pixels outside the glass stay empty, so clicks there reach
/// the app underneath and the glass can grow, shrink and move without resizing the window.
@MainActor
private final class SurfaceRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Clips the two content views to the glass' rounded shape and reports pointer presence.
@MainActor
private final class SurfaceClipView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// One floating Liquid Glass surface under the menu bar. It presents either the hover strip
/// or one provider's details and morphs between them instead of swapping windows.
@MainActor
final class UsageSurfaceController: NSObject, NSWindowDelegate {
    enum Mode: Equatable { case hidden, strip, detail(ProviderID) }

    let strip = ProviderStripView()
    let detail = ProviderDetailView()
    private(set) var mode: Mode = .hidden
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onFocusLost: (() -> Void)?
    var onEscape: (() -> Void)?
    /// QA renders everything without ordering a window on screen.
    var presentsWindow = true
    var glassStyle: GlassStyle = .regular { didSet { applyGlassStyle() } }

    private let panel: SurfacePanel
    private let root = SurfaceRootView()
    private let glass = NSGlassEffectView()
    private let clip = SurfaceClipView()
    private var generation = 0
    private var anchor: NSRect = .zero
    private weak var screen: NSScreen?
    static let cornerRadius: CGFloat = 26
    static let menuBarGap: CGFloat = 6

    override init() {
        panel = SurfacePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass owns its edge; a window shadow would outline the transparent band.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.onEscape?() }

        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        glass.cornerRadius = Self.cornerRadius
        glass.focusRingType = .none
        glass.alphaValue = 0
        root.addSubview(glass)
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.addSubview(strip)
        clip.addSubview(detail)
        // The glass does not size its content view; keep it filling the glass while it morphs.
        clip.frame = glass.bounds
        clip.autoresizingMask = [.width, .height]
        glass.contentView = clip
        strip.isHidden = true
        detail.isHidden = true
        clip.onPointerEntered = { [weak self] in self?.onPointerEntered?() }
        clip.onPointerExited = { [weak self] in self?.onPointerExited?() }
        clip.onAppearanceChange = { [weak self] in
            guard let self else { return }
            Motion.crossfade(self.clip.layer)
            self.applyGlassStyle()
        }
        applyGlassStyle()
    }

    var isVisible: Bool { mode != .hidden }
    var window: NSWindow { panel }
    /// Current glass rectangle in screen coordinates (for geometry QA).
    var glassScreenFrame: NSRect { panel.convertToScreen(glass.frame) }
    var glassStyleForQA: NSGlassEffectView.Style { glass.style }

    // MARK: Presentation

    func showStrip(anchor: NSRect, screen: NSScreen?) {
        let size = strip.preferredSize(maxWidth: availableWidth(on: screen))
        present(content: strip, size: size, mode: .strip, anchor: anchor, screen: screen, makeKey: false)
    }

    func showDetail(anchor: NSRect, screen: NSScreen?) {
        guard let provider = detail.provider else { return }
        let size = NSSize(width: ProviderDetailView.width, height: detail.preferredHeight(maxHeight: availableHeight(on: screen)))
        present(content: detail, size: size, mode: .detail(provider), anchor: anchor, screen: screen, makeKey: true)
    }

    /// Resizes the visible content in place, e.g. when a refresh adds a limit or a provider.
    func relayout(animated: Bool) {
        switch mode {
        case .hidden: return
        case .strip:
            let size = strip.preferredSize(maxWidth: availableWidth(on: screen))
            strip.frame.size = size
            move(to: glassRect(size: size), animated: animated)
        case .detail:
            let size = NSSize(width: ProviderDetailView.width, height: detail.preferredHeight(maxHeight: availableHeight(on: screen)))
            detail.frame.size = size
            move(to: glassRect(size: size), animated: animated)
        }
    }

    func hide(animated: Bool = true) {
        guard mode != .hidden else { return }
        mode = .hidden
        generation += 1
        let token = generation
        let collapsed = collapsedRect(from: glass.frame)
        let finish = { [weak self] in
            guard let self, self.generation == token else { return }
            self.panel.orderOut(nil)
            self.strip.isHidden = true
            self.detail.isHidden = true
            self.detail.resetScroll()
        }
        guard animated, !Motion.reduceMotion, presentsWindow else {
            glass.alphaValue = 0
            finish()
            return
        }
        Motion.animate(Motion.dismiss, Motion.easeIn, changes: {
            glass.animator().alphaValue = 0
            glass.animator().frame = collapsed
        }, completion: finish)
    }

    private func present(content: NSView, size: NSSize, mode next: Mode, anchor: NSRect, screen: NSScreen?, makeKey: Bool) {
        generation += 1
        let wasHidden = mode == .hidden
        self.anchor = anchor
        self.screen = screen ?? NSScreen.main
        placePanel()
        let target = glassRect(size: size)
        let outgoing: NSView? = content === strip ? detail : strip
        content.frame = NSRect(origin: .zero, size: size)
        mode = next

        if wasHidden || !presentsWindow {
            outgoing?.isHidden = true
            content.isHidden = false
            content.alphaValue = 1
            if presentsWindow {
                if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
            }
            guard presentsWindow, !Motion.reduceMotion else {
                glass.frame = target
                glass.alphaValue = 1
                return
            }
            // Drop down from the menu bar like a liquid sheet: grow, sharpen and fade in.
            glass.frame = collapsedRect(from: target)
            glass.alphaValue = 0
            content.alphaValue = 0
            Motion.animate(Motion.reveal, changes: {
                glass.animator().frame = target
                glass.animator().alphaValue = 1
                content.animator().alphaValue = 1
            })
            return
        }

        if makeKey, !panel.isKeyWindow { panel.makeKey() }
        guard outgoing?.isHidden == false else {
            content.isHidden = false
            content.alphaValue = 1
            move(to: target, animated: true)
            return
        }
        // Morph: the glass reshapes while the old content fades out and the new fades in.
        content.alphaValue = 0
        content.isHidden = false
        let token = generation
        Motion.animate(Motion.morph, changes: {
            glass.animator().frame = target
            glass.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
            content.animator().alphaValue = 1
        }, completion: { [weak self] in
            guard let self, self.generation == token else { return }
            outgoing?.isHidden = true
            outgoing?.alphaValue = 1
        })
    }

    private func move(to target: NSRect, animated: Bool) {
        guard glass.frame != target else { return }
        if animated, presentsWindow, !Motion.reduceMotion {
            Motion.animate(Motion.morph, changes: { glass.animator().frame = target })
        } else {
            glass.frame = target
        }
    }

    // MARK: Geometry

    private func visibleFrame(on screen: NSScreen?) -> NSRect {
        (screen ?? self.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func availableWidth(on screen: NSScreen?) -> CGFloat { visibleFrame(on: screen).width - 16 }
    private func availableHeight(on screen: NSScreen?) -> CGFloat { min(560, visibleFrame(on: screen).height - 24) }

    /// The panel spans the top band of the screen; only the glass inside it is ever visible.
    private func placePanel() {
        let visible = visibleFrame(on: screen)
        let height = min(visible.height, 600)
        let frame = NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// Centered under the anchor, clamped to the screen, hanging just below the menu bar.
    private func glassRect(size: NSSize) -> NSRect {
        let visible = visibleFrame(on: screen)
        let midX = anchor == .zero ? visible.midX : anchor.midX
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor == .zero ? visible.maxY : anchor.minY, visible.maxY) - Self.menuBarGap
        let screenRect = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        let origin = panel.frame.origin
        return screenRect.offsetBy(dx: -origin.x, dy: -origin.y).integral
    }

    private func collapsedRect(from rect: NSRect) -> NSRect {
        let width = rect.width * 0.94
        let height = max(Self.cornerRadius * 2, rect.height * 0.6)
        return NSRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height)
    }

    private func applyGlassStyle() {
        switch glassStyle {
        case .clear:
            glass.style = .clear
            glass.tintColor = UsagePalette.clearGlassTint
        case .regular:
            glass.style = .regular
            glass.tintColor = UsagePalette.regularGlassTint
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if case .detail = mode { onFocusLost?() }
    }
}
