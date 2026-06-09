import AppKit
import Foundation

public enum ClaudeAppError: LocalizedError {
    case desktopNotInstalled
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .desktopNotInstalled:
            return "Claude Desktop is not installed. Download it from claude.ai/download, or use a CLI-only sign-in."
        case .launchFailed(let reason):
            return "Couldn't launch Claude Desktop: \(reason)"
        }
    }
}

/// Seam over `ClaudeAppController` so flows that quit/launch the real Claude
/// Desktop app can be exercised in tests without touching running processes.
@MainActor
public protocol ClaudeAppControlling {
    var isClaudeRunning: Bool { get }
    func quitClaude(timeout: TimeInterval) async -> Bool
    func locateClaudeBundleURL() -> URL?
    func launchClaude(activate: Bool) async throws
}

extension ClaudeAppControlling {
    public func quitClaude() async -> Bool { await quitClaude(timeout: 8.0) }
    public func launchClaude() async throws { try await launchClaude(activate: false) }
}

/// Detects, quits, and relaunches the Claude Desktop app.
///
/// Claude.app caches `~/Library/Application Support/Claude/config.json` at launch,
/// so a profile swap is only safe if the app isn't running. We terminate it
/// gracefully, wait for the process to exit, then relaunch.
public struct ClaudeAppController: ClaudeAppControlling {
    /// Bundle identifier of the Claude Desktop app.
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    public init() {}

    @MainActor
    public func runningClaudeApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
    }

    @MainActor
    public var isClaudeRunning: Bool {
        !runningClaudeApps().isEmpty
    }

    /// Politely ask Claude.app to quit. Returns true once all instances are gone
    /// (or were never running). Times out after `timeout` seconds.
    @MainActor
    public func quitClaude(timeout: TimeInterval = 8.0) async -> Bool {
        let apps = runningClaudeApps()
        guard !apps.isEmpty else { return true }

        for app in apps { _ = app.terminate() }

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
            if runningClaudeApps().isEmpty { return true }
        }
        // Force-terminate any holdouts.
        for app in runningClaudeApps() { _ = app.forceTerminate() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        return runningClaudeApps().isEmpty
    }

    /// Locate the Claude.app bundle on disk (first launch services hit wins).
    @MainActor
    public func locateClaudeBundleURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    /// Launch Claude.app fresh.
    ///
    /// `activate` brings the app to the foreground — pass `true` for sign-in
    /// flows so the user actually sees the login screen, `false` for silent
    /// post-switch relaunches.
    @MainActor
    public func launchClaude(activate: Bool) async throws {
        guard let url = locateClaudeBundleURL() else {
            throw ClaudeAppError.desktopNotInstalled
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            throw ClaudeAppError.launchFailed(error.localizedDescription)
        }
    }

}
