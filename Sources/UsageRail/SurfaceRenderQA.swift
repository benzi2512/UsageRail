import AppKit
import QuartzCore
import UsageCore

/// Hidden layout checks plus optional PNG renders of the strip and detail content.
/// Glass is system-composited and cannot be captured offscreen, so renders place the
/// content on a translucent stand-in card over a wallpaper-like gradient.
@MainActor
enum SurfaceRenderQA {
    static func run(outputDirectory: URL?) throws -> [String: Bool] {
        let now = Date()
        let claude = ProviderState(provider: .claude, status: .fresh, snapshot: UsageSnapshot(provider: .claude, windows: [
            UsageWindow(id: "five-hour", title: "5-hour session", usedPercent: 9, resetAt: now.addingTimeInterval(13_800), kind: .shortTerm),
            UsageWindow(id: "seven-day", title: "Weekly · all models", usedPercent: 51, resetAt: now.addingTimeInterval(430_000), kind: .weekly,
                        breakdown: [UsageShare(id: "claude_code", title: "Claude Code", percent: 30), UsageShare(id: "chat", title: "Chats", percent: 6),
                                    UsageShare(id: "cowork", title: "Cowork", percent: 64), UsageShare(id: "other", title: "Other", percent: 0)]),
            UsageWindow(id: "model-Fable", title: "Weekly · Fable", usedPercent: 60, resetAt: now.addingTimeInterval(430_000), kind: .model)
        ], updatedAt: now, source: .claudeCode))
        let codex = ProviderState(provider: .codex, status: .fresh, snapshot: UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "codex-primary", title: "Weekly", usedPercent: 94, resetAt: now.addingTimeInterval(300_000), kind: .weekly),
            UsageWindow(id: "codex-credits", title: "Codex credits", usedPercent: nil, kind: .credits, balance: 1_234.567, balanceUnit: .credits)
        ], updatedAt: now, source: .codexAppServer, availableResetCount: 1))
        let kie = ProviderState(provider: .kie, status: .fresh, snapshot: UsageSnapshot(provider: .kie, windows: [
            UsageWindow(id: "account-credit", title: "Account credits", usedPercent: nil, kind: .credits, balance: 12_345.67, balanceUnit: .credits)
        ], updatedAt: now, source: .kieAPI, creditBalance: 12_345.67))
        let runpod = ProviderState(provider: .runpod, status: .fresh, snapshot: UsageSnapshot(provider: .runpod, windows: [
            UsageWindow(id: "account-balance", title: "Account balance (USD)", usedPercent: nil, kind: .credits, balance: 23.4568, balanceUnit: .usd)
        ], updatedAt: now, source: .runpodAPI, creditBalance: 23.4568, balanceUnit: .usd))
        let copilot = ProviderState(provider: .copilot, status: .loginRequired, snapshot: nil, message: "Add your GitHub username")

        var checks: [String: Bool] = [:]
        let detail = ProviderDetailView(frame: NSRect(x: 0, y: 0, width: ProviderDetailView.width, height: 400))
        func show(_ state: ProviderState, selected: String?, pinned: Bool = true) {
            detail.update(state: state, context: .init(isPinned: pinned, canUnpin: true, selectedLimitID: selected, notice: nil), animated: false)
            detail.frame.size = NSSize(width: ProviderDetailView.width, height: detail.preferredHeight(maxHeight: 560))
            detail.layoutSubtreeIfNeeded()
        }
        func layoutIsClean() -> Bool {
            let rows = detail.rowFramesForQA
            let rowsSeparate = zip(rows, rows.dropFirst()).allSatisfy { $0.maxY <= $1.minY }
            let chromeInside = detail.chromeFramesForQA.allSatisfy { detail.bounds.contains($0) }
            return rowsSeparate && chromeInside
        }
        show(claude, selected: "seven-day")
        checks["renderThreeLimitsFitWithoutScrolling"] = detail.frame.height < 560 && layoutIsClean()
        checks["renderSelectedRowIsWeekly"] = detail.selectedRowIDForQA == "seven-day"
        checks["renderValuesAreRounded"] = detail.valueTextForQA("seven-day") == "49% left"
        checks["renderWeeklyShowsAllFourProducts"] = detail.breakdownForQA("seven-day").count == 4
        checks["renderClaudeHasResetsRow"] = detail.resetTextForQA == "Claude doesn't report a count" && detail.resetBadgeForQA == "Reset"
        let claudeHeight = detail.frame.height
        try outputDirectory.map { try render(detail, name: "detail-claude", in: $0) }
        show(codex, selected: nil)
        checks["renderMixedCreditRowRoundsBalance"] = detail.valueTextForQA("codex-credits") == "1,234.57 credits" && layoutIsClean()
        checks["renderCodexResetCount"] = detail.resetTextForQA == "1 available" && detail.resetBadgeForQA == "Reset 1"
            && detail.resetIsDisplayOnlyForQA
        try outputDirectory.map { try render(detail, name: "detail-codex", in: $0) }
        show(kie, selected: nil)
        checks["renderBalanceOnlyCardIsCompact"] = detail.frame.height < claudeHeight && detail.rowPinCountForQA == 0 && layoutIsClean()
        show(copilot, selected: nil, pinned: false)
        checks["renderDisconnectedShowsHint"] = detail.isEmptyStateForQA && layoutIsClean()
        try outputDirectory.map { try render(detail, name: "detail-disconnected", in: $0) }

        let strip = ProviderStripView()
        strip.update(states: [claude, codex, kie, runpod].map { AppSettings(selectedProvider: .claude).displayState(from: $0) },
                     pinned: [.claude, .codex], animated: false)
        strip.frame.size = strip.preferredSize(maxWidth: 1_200)
        strip.layoutSubtreeIfNeeded()
        checks["renderStripSizedToProviders"] = strip.frame.width == CGFloat(4) * ProviderStripView.chipWidth + ProviderStripView.inset * 2
        checks["renderStripValues"] = strip.displayedValueForQA(.runpod) == "$23.46" && strip.displayedValueForQA(.claude) == "40%"
        try outputDirectory.map { try render(strip, name: "strip", in: $0) }

        let capsule = MenuBarIconRenderer.capsule(for: [AppSettings(selectedProvider: .claude).displayState(from: claude), codex])
        checks["renderCapsuleHoldsBothPins"] = capsule.segments.count == 2 && capsule.image.size.height == 22
            && capsule.segments[1].minX - capsule.segments[0].maxX == MenuBarIconRenderer.segmentGap
        try outputDirectory.map { try renderMenuBar(capsule.image, in: $0) }
        return checks
    }

    /// Offscreen capture cannot draw glass bezels: titles come out black and symbols white in
    /// both appearances, unlike on screen. For the capture only, glass buttons become borderless
    /// with the same tint and a platter behind them. Returns the restore action.
    private static func glassButtonStandIns(in view: NSView, appearance: NSAppearance) -> () -> Void {
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] } + view.subviews.flatMap(buttons(in:))
        }
        let glass = buttons(in: view).filter { $0.bezelStyle == .glass && !$0.isHidden }
        let saved = glass.map { (button: $0, tint: $0.contentTintColor) }
        for button in glass {
            let prominent = button.tintProminence == .primary
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = button.bounds.height / 2
            var fill = NSColor.clear.cgColor
            appearance.performAsCurrentDrawingAppearance {
                fill = (prominent ? NSColor.controlAccentColor : UsagePalette.platterHover).cgColor
            }
            button.layer?.backgroundColor = fill
            button.contentTintColor = prominent ? .white : (button.isEnabled ? NSColor.labelColor : UsagePalette.tertiaryText)
        }
        return {
            for (button, tint) in saved {
                button.isBordered = true
                button.bezelStyle = .glass
                button.contentTintColor = tint
                button.layer?.backgroundColor = nil
            }
        }
    }

    /// The capsule on a menu-bar-like strip: a blue wallpaper tint with light text, and a light bar.
    private static func renderMenuBar(_ image: NSImage, in directory: URL) throws {
        for dark in [true, false] {
            let size = NSSize(width: image.size.width + 80, height: 30)
            let view = NSImageView(frame: NSRect(x: 40, y: 4, width: image.size.width, height: image.size.height))
            view.image = image
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            container.layer?.backgroundColor = (dark ? NSColor(calibratedRed: 0.24, green: 0.47, blue: 0.72, alpha: 1)
                                                     : NSColor(calibratedWhite: 0.93, alpha: 1)).cgColor
            container.addSubview(view)
            try write(container, size: size, to: directory.appendingPathComponent("menubar-\(dark ? "dark" : "light").png"))
        }
    }

    private static func write(_ container: NSView, size: NSSize, to url: URL) throws {
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        context.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        container.appearance?.performAsCurrentDrawingAppearance {
            container.displayIgnoringOpacity(container.bounds, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.contentView = nil
    }

    private static func render(_ view: NSView, name: String, in directory: URL) throws {
        for dark in [false, true] {
            let margin: CGFloat = 28
            let size = NSSize(width: view.frame.width + margin * 2, height: view.frame.height + margin * 2)
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let wallpaper = CAGradientLayer()
            wallpaper.frame = container.bounds
            wallpaper.colors = dark
                ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 1).cgColor, NSColor(calibratedRed: 0.28, green: 0.12, blue: 0.30, alpha: 1).cgColor]
                : [NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.95, alpha: 1).cgColor, NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.70, alpha: 1).cgColor]
            wallpaper.startPoint = CGPoint(x: 0, y: 0)
            wallpaper.endPoint = CGPoint(x: 1, y: 1)
            container.layer?.addSublayer(wallpaper)
            let card = NSView(frame: NSRect(x: margin, y: margin, width: view.frame.width, height: view.frame.height))
            card.wantsLayer = true
            card.layer?.cornerRadius = UsageSurfaceController.cornerRadius
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
            card.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.16, alpha: 0.86) : NSColor(calibratedWhite: 0.97, alpha: 0.84)).cgColor
            card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.7)).cgColor
            card.layer?.borderWidth = 1
            container.addSubview(card)
            let origin = view.frame.origin
            let parent = view.superview
            view.frame.origin = .zero
            card.addSubview(view)
            let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = container
            container.layoutSubtreeIfNeeded()
            let standIns = glassButtonStandIns(in: view, appearance: container.effectiveAppearance)
            defer { standIns() }
            container.displayIfNeeded()
            CATransaction.flush()
            let scale: CGFloat = 2
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { throw CocoaError(.fileWriteUnknown) }
            context.scaleBy(x: scale, y: scale)
            container.layer?.render(in: context)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            view.removeFromSuperview()
            view.frame.origin = origin
            parent?.addSubview(view)
            window.contentView = nil
        }
    }
}
