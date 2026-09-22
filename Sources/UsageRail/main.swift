import AppKit
import UsageCore

/// Troubleshooting: `UsageRail --check-usage=<codex|claude|copilot|kie|runpod>` runs one real
/// check with the saved setup and prints the reading as JSON, or the error. Secrets never print.
let checkArgument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--check-usage=") }
    ?? (ProcessInfo.processInfo.arguments.contains("--check-claude-usage") ? "--check-usage=claude" : nil)
if let checkArgument {
    let name = String(checkArgument.dropFirst("--check-usage=".count))
    let connector: (any UsageConnector)? = switch ProviderID(rawValue: name) {
    case .codex?: CodexConnector()
    case .claude?: ClaudeConnector()
    case .copilot?: CopilotConnector(settings: { SettingsStore().load() })
    case .kie?: KieConnector()
    case .runpod?: RunpodConnector()
    default: nil
    }
    guard let connector else {
        FileHandle.standardError.write(Data("Use --check-usage= with codex, claude, copilot, kie or runpod.\n".utf8))
        exit(64)
    }
    Task {
        do {
            let snapshot = try await connector.refresh()
            FileHandle.standardOutput.write(try JSONEncoder.usageRail.encode(snapshot) + Data("\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(connector.provider.displayName) check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

@MainActor
private func runUI() throws {
let application = NSApplication.shared
if ProcessInfo.processInfo.arguments.contains("--demo-runloop-check") {
    application.setActivationPolicy(.prohibited)
    // Exercise the same AppKit event loop as production, without windows,
    // credentials, provider requests or an AppDelegate.
    Task { @MainActor in
        let workerCompleted = await Task.detached { true }.value
        let passed = workerCompleted && Thread.isMainThread
        FileHandle.standardOutput.write(Data("{\"mainActorRoundTrip\":\(passed)}\n".utf8))
        exit(passed ? 0 : 1)
    }
    _ = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
        FileHandle.standardOutput.write(Data("{\"mainActorRoundTrip\":false,\"error\":\"runloop_starved\"}\n".utf8))
        exit(1)
    }
    application.run()
    exit(1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-ux-check") {
    application.setActivationPolicy(.accessory)
    let controller = MenuBarController(settings: AppSettings(), presentsStatusItems: false)
    var checks = controller.verifyTransitionsForQA()
    let output = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--qa-output=") }
        .map { URL(fileURLWithPath: String($0.dropFirst(12)), isDirectory: true) }
    checks.merge(try SurfaceRenderQA.run(outputDirectory: output)) { _, new in new }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]))
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-icons-check") {
    application.setActivationPolicy(.accessory)
    let checks = ProviderIconArtwork.verifyBundledMarksForQA()
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]))
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-custom-check") {
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            let checks = try await SettingsWindowController.runCustomConnectionQA()
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { exit(1) }
    }
    application.run()
    exit(1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-pin-check") {
    application.setActivationPolicy(.accessory)
    let controller = MenuBarController(settings: AppSettings(), presentsStatusItems: false)
    let checks = controller.verifyPinsForQA()
    let output = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(output)
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-refresh-check") {
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            let result = try await RefreshRuntimeCheck.run()
            let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(output)
            exit(result["pass"] as? Bool == true ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Hidden refresh QA failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    application.run()
    exit(1)
}
if ProcessInfo.processInfo.arguments.contains("--demo-background-check") {
    application.setActivationPolicy(.accessory)
    let checks = SettingsWindowController.runBackgroundQA()
    let output = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(output)
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(
    ProcessInfo.processInfo.arguments.contains("--demo-settings") ? .regular : .accessory
)
application.run()
}

// NSApplication owns the main-thread run loop. Enter synchronously: nesting
// application.run() inside a MainActor Task holds the dispatch-main job open
// and starves startup refreshes, actor continuations and asynchronous quit.
MainActor.assumeIsolated {
    do {
        try runUI()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("UsageRail startup failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
