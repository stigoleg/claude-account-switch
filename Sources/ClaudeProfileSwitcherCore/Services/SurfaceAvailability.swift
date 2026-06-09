import AppKit
import Foundation
import Observation

/// Whether a Claude surface (Desktop app or `claude` CLI) is present on this
/// system, and where.
public enum SurfaceInstallState: Equatable, Sendable {
    case unknown
    case installed(URL)
    case notInstalled

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Locates the two Claude surfaces. Injectable so the UI layer can be tested
/// against fake "CLI only" / "Desktop only" / "neither" systems.
public protocol SurfaceLocator: Sendable {
    @MainActor func desktopAppURL() -> URL?
    func cliExecutableURL() async -> URL?
}

/// Production locator.
///
/// - Desktop: Launch Services lookup by bundle identifier.
/// - CLI: fast scan of well-known install locations first, then a one-shot
///   `command -v claude` in the user's login shell (with a hard timeout) so
///   PATH customizations in rc files are honored.
public struct SystemSurfaceLocator: SurfaceLocator {
    /// Wall-clock cap on the login-shell lookup. Login shells that hang on a
    /// slow rc file shouldn't stall surface detection; we fail closed.
    public static let shellTimeout: TimeInterval = 2.0

    public let cliCandidatePaths: [URL]
    let shellLookup: @Sendable () async -> String?

    public init(
        cliCandidatePaths: [URL]? = nil,
        shellLookup: (@Sendable () async -> String?)? = nil
    ) {
        self.cliCandidatePaths = cliCandidatePaths ?? Self.defaultCandidatePaths()
        self.shellLookup = shellLookup ?? { await Self.loginShellLookup() }
    }

    @MainActor
    public func desktopAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ClaudeAppController.bundleIdentifier)
    }

    public func cliExecutableURL() async -> URL? {
        let fm = FileManager.default
        for candidate in cliCandidatePaths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
                !isDir.boolValue,
                fm.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        guard let path = await shellLookup(), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return fm.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Well-known `claude` install locations, cheapest checks first.
    /// `~/.claude/local/claude` resolves through the per-profile symlink, so
    /// callers should re-refresh availability after a profile switch.
    static func defaultCandidatePaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent("bin/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
        ]
    }

    /// `command -v claude` via the user's login shell, off-main, with the same
    /// subprocess-timeout pattern as `KeychainProbe`.
    static func loginShellLookup() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let task = Process()
                task.launchPath = shell
                task.arguments = ["-l", "-c", "command -v claude"]
                let out = Pipe()
                task.standardOutput = out
                task.standardError = Pipe()

                var timedOut = false
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
                timer.schedule(deadline: .now() + Self.shellTimeout)
                timer.setEventHandler {
                    if task.isRunning {
                        timedOut = true
                        task.terminate()
                    }
                }
                timer.resume()

                do {
                    try task.run()
                } catch {
                    timer.cancel()
                    continuation.resume(returning: nil)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                timer.cancel()

                guard !timedOut, task.terminationStatus == 0,
                    let output = String(data: data, encoding: .utf8)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }
}

/// Observable cache of which surfaces are installed. Owned by the view model;
/// menus and sheets read it directly so they adapt to CLI-only / Desktop-only
/// systems without re-probing on every render.
@MainActor
@Observable
public final class SurfaceAvailability {
    public private(set) var desktop: SurfaceInstallState = .unknown
    public private(set) var cli: SurfaceInstallState = .unknown

    /// How long a refresh result stays fresh. Installs/uninstalls are rare;
    /// a forced refresh is available for "Check again" UI.
    public static let ttl: TimeInterval = 30

    private let locator: any SurfaceLocator
    private var lastRefresh: Date?

    public init(locator: any SurfaceLocator = SystemSurfaceLocator()) {
        self.locator = locator
    }

    /// Recompute both surfaces. Cheap-but-cached: callers can invoke this
    /// liberally (menu open, window appear, post-switch).
    public func refresh(force: Bool = false) async {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < Self.ttl { return }
        lastRefresh = Date()
        desktop = locator.desktopAppURL().map(SurfaceInstallState.installed) ?? .notInstalled
        let cliURL = await locator.cliExecutableURL()
        cli = cliURL.map(SurfaceInstallState.installed) ?? .notInstalled
    }

    /// Fire-and-forget variant for synchronous UI contexts.
    public func refreshSoon(force: Bool = false) {
        Task { await refresh(force: force) }
    }
}
