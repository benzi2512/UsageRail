import AppKit
import UsageCore

/// Monochrome vector artwork used everywhere in the rail. The marks are bundled
/// as SVG paths so rendering never depends on another app being installed and
/// never requires a network request.
@MainActor
enum ProviderIconArtwork {
    static func image(for provider: ProviderID) -> NSImage {
        if provider.isCustom { return brandImage(named: provider.displayName) ?? monogram(provider.glyph) }
        if provider == .codex { return openAI }
        if provider == .kie { return kieWordmark }
        return images[provider] ?? fallback
    }

    /// Official mark color where the brand's mark is colored (Claude's terracotta spark).
    /// Menu-bar items stay monochrome, as macOS expects; panels show the brand color.
    static func brandColor(for provider: ProviderID) -> NSColor? {
        provider == .claude ? NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1) : nil
    }

    static func image(for entry: ConnectionResearch) -> NSImage {
        brandImage(named: entry.name) ?? monogram(entry.iconText)
    }
    static func verifyBundledMarksForQA() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: ConnectionResearch.entries.map { ($0.name, brandImage(named: $0.name)?.isValid == true) })
    }

    private static func brandImage(named name: String) -> NSImage? {
        let name = name.lowercased()
        if name.hasPrefix("grok") || name.hasPrefix("xai") { return grokMark }
        if name.hasPrefix("cursor") { return cursorMark }
        if name.hasPrefix("arcads") { return arcadsMark }
        if name.hasPrefix("higgsfield") { return higgsfieldMark }
        return nil
    }

    // Canonical site favicon paths reviewed 2026-09-05. Only numeric path geometry is
    // retained from SVG: no foreignObject, filters, scripts, styles or remote references.
    private static let grokMark = makeSVG(viewBox: "56 56 400 400", path: "M210.484 312.759L343.465 210.383C349.984 205.364 359.302 207.322 362.408 215.117C378.758 256.231 371.454 305.64 338.925 339.563C306.397 373.487 261.137 380.927 219.768 363.983L174.577 385.803C239.394 432.008 318.104 420.581 367.289 369.251C406.303 328.564 418.386 273.104 407.088 223.091L407.19 223.198C390.807 149.726 411.218 120.359 453.03 60.3072C454.02 58.8833 455.01 57.4595 456 56L400.978 113.382V113.204L210.45 312.794Z M183.042 337.641C136.519 291.294 144.54 219.567 184.236 178.203C213.59 147.59 261.683 135.096 303.666 153.464L348.755 131.75C340.632 125.627 330.221 119.042 318.275 114.414C264.277 91.2407 199.63 102.774 155.735 148.516C113.513 192.549 100.236 260.254 123.036 318.027C140.069 361.206 112.148 391.748 84.0229 422.575C74.0561 433.503 64.0553 444.431 56 456L183.007 337.677Z")
    private static let cursorMark = makeSVG(viewBox: "96 73 321 366", path: "m410.344 159.545-146.38-84.5111c-4.7-2.7145-10.5-2.7145-15.2 0l-146.373 84.5111c-3.9515 2.282-6.391 6.501-6.391 11.071v170.418c0 4.569 2.4395 8.789 6.391 11.07l146.379 84.512c4.701 2.714 10.501 2.714 15.201 0l146.38-84.512c3.951-2.281 6.391-6.501 6.391-11.07v-170.418c0-4.57-2.44-8.789-6.391-11.071zm-9.195 17.902-141.308 244.751c-.955 1.65-3.477.976-3.477-.934v-160.261c0-3.203-1.711-6.164-4.487-7.772l-138.786-80.127c-1.65-.956-.976-3.478.934-3.478h282.616c4.013 0 6.522 4.35 4.515 7.828h-.007z")
    private static let higgsfieldMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "higgsfield-icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    // Arcads' homepage links this 48x48 PNG favicon on its Webflow CDN (493 bytes).
    private static let arcadsMark = NSImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAGCSURBVHgB7ZjRrUVAEIbn3NwCTglKoQMdoAI6QAdUgEroQAl0QAd7d5Lr1QxmLcl+yXk6k+x867eGDwAoeDE/8HKcgG2cgG2cgG2cgG1eL/ALhgnDEL7fL1nXti2cRZn6eZ6nOBRFcWUdcwLTNJHNY83Fdcw0n+e54oBX6XEC3OhUVSWxnrzAOI5k8xgdfXM/TyBNU8XB932pNeWax+gsy0I23zSN5KbJCeiznGweoyNw48oLxHGsOERRJNm8jADuKOfMF46OnICl6MgIWIzOdYGj0cGZZ48zM9GlcVovCFpit2aeZyjLEkxxWkBHB3QsyDqURAlTnBLA+V4Pa2TdMAzQdR2Y5JQANk9FZ11XSJIETHNYQM8wkGUZWVfXtdHobBwW0CcKWYONY/bv4JAAJzpIEARwF2wBbJyzq3hk3hGdDbZA3/dkzZ3R2WAJPDE6G6TAU6OzQX7YwubxgbQHnvkcSf22tiuJ/x/lA/8T3VtxH3dt4wRs4wRs4wRs4wRs8wcg9U9BQjgrGQAAAABJRU5ErkJggg==") ?? Data())

    /// Local identifying wordmarks; never download or execute a website's favicon/SVG.
    static func monogram(_ text: String) -> NSImage {
        let value = String(text.prefix(3))
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: value.count > 2 ? 12 : 18, weight: .bold), .foregroundColor: NSColor.black]
            let size = (value as NSString).size(withAttributes: attributes)
            (value as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    // Kie's public homepage uses the uppercase KIE wordmark. Draw it locally;
    // no remote image fetch, embedded script, or runtime web content is needed.
    private static let kieWordmark: NSImage = {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let style: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .heavy),
                .foregroundColor: NSColor.black
            ]
            let text = "KIE" as NSString
            let size = text.size(withAttributes: style)
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: style)
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let openAI = makeSVG(
        viewBox: "0 0 158.7128 157.296",
        path: "M60.8734 57.2556V42.3124c0-1.2586.4722-2.2029 1.5728-2.8314l30.0443-17.3023c4.0899-2.3593 8.9662-3.4599 13.9988-3.4599 18.8759 0 30.8307 14.6289 30.8307 30.2006 0 1.1007 0 2.3593-.158 3.6178l-31.1446-18.2467c-1.8872-1.1006-3.7754-1.1006-5.6629 0L60.8734 57.2556Zm70.1542 58.2005V79.7487c0-2.2028-.9446-3.7756-2.8318-4.8763l-39.481-22.9651 12.8982-7.3934c1.1007-.6285 2.0453-.6285 3.1458 0l30.0441 17.3024c8.6523 5.0341 14.4708 15.7296 14.4708 26.1107 0 11.9539-7.0769 22.965-18.2461 27.527v.0021ZM51.593 83.9964 38.6948 76.4467c-1.1007-.6285-1.5728-1.5728-1.5728-2.8314V39.0105c0-16.8303 12.8982-29.5722 30.3585-29.5722 6.607 0 12.7403 2.2029 17.9324 6.1349L54.4259 33.5056c-1.8871 1.1007-2.8314 2.6735-2.8314 4.8764v45.6159l-.0014-.0015Zm27.7632 16.0439L60.8733 89.6592V67.6383l18.4829-10.3811 18.4812 10.3811v22.0209l-18.4812 10.3811Zm11.8757 47.8188c-6.607 0-12.7403-2.2031-17.9324-6.1344l30.9866-17.9333c1.8872-1.1005 2.8318-2.6728 2.8318-4.8759V73.2995l13.0564 7.5498c1.1005.6285 1.5723 1.5728 1.5723 2.8314v34.6051c0 16.8297-13.0564 29.5723-30.5147 29.5723v.001ZM53.9522 112.7822 23.9079 95.4798c-8.652-5.0343-14.471-15.7296-14.471-26.1107 0-12.1119 7.2356-22.9652 18.403-27.5272v35.8634c0 2.2028.9443 3.7756 2.8314 4.8763l39.3248 22.8068-12.8982 7.3938c-1.1007.6287-2.045.6287-3.1456 0Zm-1.7293 25.7969c-17.7745 0-30.8306-13.3713-30.8306-29.8871 0-1.2585.1578-2.5169.3143-3.7754l30.987 17.9323c1.8871 1.1005 3.7757 1.1005 5.6628 0l39.4811-22.807v14.9435c0 1.2585-.4721 2.2021-1.5728 2.8308l-30.0443 17.3025c-4.0898 2.359-8.9662 3.4605-13.9989 3.4605h.0014ZM91.2319 157.296c19.0327 0 34.9188-13.5272 38.5383-31.4594 17.6164-4.562 28.9425-21.0779 28.9425-37.908 0-11.0112-4.719-21.7066-13.2133-29.4143.7867-3.3035 1.2595-6.607 1.2595-9.909 0-22.4929-18.2471-39.3247-39.3251-39.3247-4.2461 0-8.3363.6285-12.4262 2.045C87.9284 4.4043 78.1758 0 67.4805 0 48.4474 0 32.5614 13.5268 28.9421 31.4591 11.3255 36.0212 0 52.5373 0 69.3675c0 11.0112 4.7184 21.7065 13.2125 29.4142-.7865 3.3035-1.2586 6.6067-1.2586 9.9092 0 22.4923 18.2466 39.3241 39.3248 39.3241 4.2462 0 8.3362-.6277 12.426-2.0441 7.0776 6.921 16.8302 11.3251 27.5271 11.3251Z"
    )

    private static let images: [ProviderID: NSImage] = [
        // Runpod's official homepage mark, geometry only; never load remote SVG at runtime.
        .runpod: makeSVG(viewBox: "0 0 31 32", path: "M26.415 25.4391C27.9958 24.5286 28.9696 22.846 28.9696 21.0249V10.9763C28.9696 9.15531 27.9958 7.47266 26.415 6.56217L17.6922 1.53785C16.1113 0.627356 14.1639 0.627358 12.5831 1.53785L3.86019 6.56217C2.27944 7.47266 1.30566 9.15531 1.30566 10.9763V21.0249C1.30566 22.846 2.27945 24.5286 3.86019 25.4391L12.5831 30.4634C14.1639 31.3738 16.1115 31.3738 17.6922 30.4634L26.415 25.4391ZM26.415 21.0249C26.415 21.9354 25.9282 22.7767 25.1378 23.232L20.5724 25.8616C20.1701 26.0933 19.9689 26.2092 19.8038 26.192C19.6598 26.1769 19.529 26.1016 19.4438 25.9846C19.3463 25.8507 19.3463 25.6189 19.3463 25.1554V19.8962C19.3463 18.9858 19.8331 18.1445 20.6235 17.6892L23.0679 16.2812C23.4036 16.0879 23.5714 15.9911 23.6935 15.8558C23.8013 15.7362 23.8828 15.5952 23.9324 15.442C23.9886 15.2689 23.9883 15.0755 23.9875 14.6889L23.9874 14.5727C23.9863 13.9943 23.9858 13.7051 23.8637 13.5379C23.7573 13.3921 23.5939 13.2982 23.414 13.2794C23.2077 13.2579 22.9567 13.4025 22.4546 13.6917L19.3463 15.4821C17.7656 16.3925 16.7917 18.0752 16.7917 19.8962V27.6051C16.7917 27.8739 16.648 28.1219 16.4149 28.2563C15.6245 28.7116 14.6507 28.7116 13.8604 28.2563L5.13746 23.232C4.34709 22.7767 3.86019 21.9354 3.86019 21.0249V15.8454C3.86019 15.3818 3.86019 15.1501 3.95776 15.0161C4.04287 14.8992 4.17368 14.8239 4.31768 14.8088C4.48278 14.7915 4.68396 14.9073 5.08635 15.1391L9.55724 17.7142C10.3476 18.1693 10.8345 19.0108 10.8345 19.9212V22.603C10.8345 22.9897 10.8345 23.1831 10.8909 23.356C10.9409 23.5091 11.0226 23.65 11.1307 23.7695C11.2529 23.9045 11.4209 24.0009 11.7569 24.1937L11.8579 24.2515C12.3605 24.5398 12.6118 24.6841 12.8179 24.6622C12.9978 24.6431 13.161 24.5488 13.2673 24.4028C13.389 24.2355 13.389 23.9462 13.389 23.3678V19.9212C13.389 18.1002 12.4152 16.4175 10.8345 15.5071L4.30628 11.7471C4.03024 11.5881 3.86019 11.2943 3.86019 10.9763C3.86019 10.0658 4.34707 9.22447 5.13746 8.76923L13.8604 3.74492C14.6507 3.28967 15.6245 3.28967 16.4149 3.74492L20.9306 6.34595C21.3331 6.57773 21.5343 6.69361 21.6018 6.8449C21.6607 6.97686 21.6607 7.12757 21.6018 7.25953C21.5343 7.41082 21.3331 7.5267 20.9306 7.75848L16.3444 10.4002C15.5538 10.8554 14.5801 10.8554 13.7897 10.4002L11.2201 8.9201C10.9643 8.77277 10.8364 8.6991 10.7003 8.66952C10.5799 8.64335 10.4553 8.6423 10.3344 8.66646C10.1979 8.69374 10.0687 8.76526 9.8105 8.90826L9.49191 9.08471C8.97543 9.37074 8.71721 9.51376 8.62983 9.70349C8.55366 9.86893 8.55206 10.059 8.62544 10.2257C8.7096 10.4168 8.96538 10.5642 9.47695 10.8588L12.5125 12.6073C14.0932 13.5178 16.0408 13.5178 17.6216 12.6073L24.2849 8.76923C24.5488 8.61723 24.8739 8.61723 25.1378 8.76923C25.9282 9.22447 26.415 10.0658 26.415 10.9763V21.0249Z"),
        .codex: makeSVG(
            viewBox: "0 0 24 24",
            path: "M8.086.457a6.105 6.105 0 0 1 3.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 0 0 .107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198a5.62 5.62 0 0 1 .421 2.126 5.655 5.655 0 0 1-.18 1.631.167.167 0 0 0 .04.155 5.982 5.982 0 0 1 1.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 0 1-2.934 1.851.162.162 0 0 0-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 0 0-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 0 1-2.595-.622 6.058 6.058 0 0 1-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 0 1-.495-1.283 6.11 6.11 0 0 1-.017-3.064.166.166 0 0 0 .008-.074.115.115 0 0 0-.037-.064 5.958 5.958 0 0 1-1.38-2.202 5.196 5.196 0 0 1-.333-1.589 6.915 6.915 0 0 1 .188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 0 0 .087-.087A6.016 6.016 0 0 1 5.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 0 0-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 0 0 1.46.864l1.94-3.272a.849.849 0 0 0 .007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 0 0 0 1.695h4.848a.849.849 0 0 0 0-1.696h-4.848z"
        ),
        .claude: makeSVG(
            viewBox: "0 0 24 24",
            path: "m4.709 15.955 4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 0 1-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
        ),
        .copilot: makeSVG(
            viewBox: "0 0 24 24",
            path: "M7.25 3.15C8.62 2.41 10.25 2 12 2s3.38.41 4.75 1.15l1.2-1.02a1 1 0 0 1 1.63.77v2.05C21.1 6.2 22 7.89 22 9.75v4.5C22 18.53 17.52 22 12 22S2 18.53 2 14.25v-4.5c0-1.86.9-3.55 2.42-4.8V2.9a1 1 0 0 1 1.63-.77l1.2 1.02ZM12 4.1c-4.32 0-7.8 2.54-7.8 5.65v4.5c0 3.1 3.48 5.65 7.8 5.65s7.8-2.55 7.8-5.65v-4.5C19.8 6.64 16.32 4.1 12 4.1Zm-3.55 5.05a1.45 1.45 0 1 1 0 2.9 1.45 1.45 0 0 1 0-2.9Zm7.1 0a1.45 1.45 0 1 1 0 2.9 1.45 1.45 0 0 1 0-2.9ZM7.2 15h9.6a1.05 1.05 0 0 1 0 2.1H7.2a1.05 1.05 0 0 1 0-2.1Z"
        ),
        .antigravity: makeSVG(
            viewBox: "0 0 112 112",
            path: "M89.754 92.75c4.667 3.5 11.667 1.167 5.25-5.25-19.25-18.667-15.167-70-39.083-70-23.917 0-19.834 51.333-39.084 70-7 7 .584 8.75 5.25 5.25C40.171 80.5 39.004 58.917 55.921 58.917c16.916 0 15.75 21.583 33.833 33.833Z"
        ),
        .gemini: makeSVG(
            viewBox: "0 0 24 24",
            path: "M12 1c.72 6.18 4.82 10.28 11 11-6.18.72-10.28 4.82-11 11-.72-6.18-4.82-10.28-11-11 6.18-.72 10.28-4.82 11-11Z"
        )
    ]

    private static let fallback: NSImage = {
        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private static func makeSVG(viewBox: String, path: String) -> NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox)">
          <path fill="black" fill-rule="evenodd" clip-rule="evenodd" d="\(path)"/>
        </svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
