import AppKit
import Foundation
import Observation
import SwiftUI

/// The single source of truth wired up to the menu bar UI.
/// Owns ProfileStore + ProfileManager and exposes loading/error state.
@MainActor
@Observable
public final class AppViewModel {
    public let store: ProfileStore
    public let manager: ProfileManager
    public let launchAtLogin = LaunchAtLoginService()
    public let shellIntegration: ShellIntegrationService
    public let sync: ProfileSyncService
    public let desktopHint: DesktopHintWatcher
    /// Which Claude surfaces (Desktop / CLI) are installed on this machine.
    /// The UI reads this to hide or disable impossible options.
    public let surfaces: SurfaceAvailability

    public var isSwitching = false
    public var lastError: String?
    /// Tracked by ProfilesWindow's onAppear/onDisappear so `reportError` knows
    /// whether the window-scoped alert will actually be seen.
    public var profilesWindowVisible = false
    public var showMigrationSheet = false
    public var pendingSignInProfile: Profile?  // shown as a sheet after Create
    /// The TARGET profile of a "Copy config from…" action; drives the sheet.
    public var copyConfigTarget: Profile?
    public var signInPhase: ProfileManager.SignInPhase?
    public var signingInProfileID: UUID?
    /// When a sign-in started — drives the elapsed-time display.
    public var signInStartedAt: Date?
    /// Set when a sign-in fails; drives the inline Retry row on the profile card.
    public var signInFailure: SignInFailure?
    private var signInTask: Task<Void, Never>?

    public struct SignInFailure: Equatable {
        public let profileID: UUID
        public let method: ProfileManager.SignInMethod
        public let message: String
    }
    public private(set) var loginStatuses: [UUID: ProfileLoginStatus] = [:]
    public private(set) var shellIntegrationInstalled: Bool = false

    // Toggle state must live as stored properties so @Observable can track
    // it. The earlier computed-property version wrapped UserDefaults and
    // SwiftUI never saw the value change — checkboxes appeared dead.
    public var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            UserDefaults.standard.set(syncEnabled, forKey: Self.syncEnabledKey)
            if syncEnabled { startSync() } else { sync.stop() }
        }
    }
    public var desktopHintsEnabled: Bool {
        didSet {
            guard desktopHintsEnabled != oldValue else { return }
            UserDefaults.standard.set(desktopHintsEnabled, forKey: Self.desktopHintsKey)
            if desktopHintsEnabled { desktopHint.start() } else { desktopHint.stop() }
        }
    }

    private static let syncEnabledKey = "com.stigole.ClaudeProfileSwitcher.iCloudSyncEnabled"
    private static let desktopHintsKey = "com.stigole.ClaudeProfileSwitcher.desktopHintsEnabled"

    public var signInStatusText: String? {
        guard let phase = signInPhase else { return nil }
        switch phase {
        case .quittingDesktop: return "Quitting current Claude Desktop session…"
        case .launchingDesktop: return "Opening Claude Desktop in the foreground…"
        case .waitingForDesktop:
            return "Waiting for sign-in… click \"Sign in\" in Claude Desktop and complete it in your browser."
        case .launchingCLI: return "Opening Terminal — Claude Code will prompt for /login."
        case .waitingForCLI: return "Waiting for CLI sign-in…"
        case .done: return nil
        }
    }

    public init() {
        let s = ProfileStore()
        s.load()
        self.store = s
        self.manager = ProfileManager(store: s)
        self.shellIntegration = ShellIntegrationService(store: s)
        self.sync = ProfileSyncService(store: s)
        self.desktopHint = DesktopHintWatcher(store: s)
        self.surfaces = SurfaceAvailability()
        // Seed the toggle state from UserDefaults. didSet won't fire during
        // init, so we trigger the appropriate watchers/sync explicitly below.
        self.syncEnabled = UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        self.desktopHintsEnabled = UserDefaults.standard.bool(forKey: Self.desktopHintsKey)

        if case .needed = manager.migrationState() {
            self.showMigrationSheet = true
        }
        refreshLoginStatuses()
        refreshShellIntegrationState()
        surfaces.refreshSoon()
        // Clean up any temp symlinks orphaned by a crashed/failed swap.
        manager.symlinks.sweepStaleTempLinks(siblingsOf: manager.cliCanonicalPath)
        manager.symlinks.sweepStaleTempLinks(siblingsOf: manager.desktopCanonicalPath)

        // Wire the desktop hint callback so it goes through requestSwitch which
        // already handles the "Claude Desktop is running" confirmation.
        desktopHint.onProfileRequested = { [weak self] profile in
            guard let self else { return }
            self.requestSwitch(to: profile)
        }

        if syncEnabled { startSync() }
        if desktopHintsEnabled { desktopHint.start() }
        // Keep the shell integration's profile-paths manifest up to date whenever
        // the profile list changes; surface any persistence errors that came
        // from the last save.
        store.didPersist = { [weak self] in
            guard let self else { return }
            if let err = self.store.lastPersistError {
                self.reportError(err)
            }
            self.shellIntegration.writeProfilePathsManifest()
            self.sync.localDidChange()
        }
        shellIntegration.writeProfilePathsManifest()
    }

    /// Re-stat every profile's credential files. The file inspection is sync
    /// and instant; the optional keychain probe runs off-main with a short
    /// TTL cache (see `KeychainProbe`), so this returns immediately and the
    /// UI keeps working off the previous snapshot until the keychain results
    /// land.
    public func refreshLoginStatuses() {
        // Sync first pass — file-only — so the badges flip to the right
        // value the moment a credential file appears.
        var next: [UUID: ProfileLoginStatus] = [:]
        for p in store.profiles {
            next[p.id] = manager.credentials.status(for: p)
        }
        loginStatuses = next

        // Then off-main keychain probe to fill in the .unknown notes.
        let inspector = manager.credentials
        let profiles = store.profiles
        Task { [weak self] in
            var withKeychain: [UUID: ProfileLoginStatus] = [:]
            for p in profiles {
                withKeychain[p.id] = await inspector.statusWithKeychain(for: p)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loginStatuses = withKeychain
            }
        }
    }

    public func refreshShellIntegrationState() {
        shellIntegrationInstalled = shellIntegration.isInstalledInZshrc()
    }

    public func status(for profile: Profile) -> ProfileLoginStatus {
        loginStatuses[profile.id] ?? ProfileLoginStatus(cli: .signedOut, desktop: .signedOut)
    }

    // MARK: - Errors

    /// Route an error to wherever the user can actually see it. The Profiles
    /// window has an alert bound to `lastError`; when it's closed (menu-bar
    /// triggered actions), fall back to a modal NSAlert so failures are never
    /// silently dropped.
    public func reportError(_ message: String) {
        if profilesWindowVisible {
            lastError = message
        } else {
            let alert = NSAlert()
            alert.messageText = "Claude Profile Switcher"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Actions

    public func performMigration() {
        do {
            try manager.runFirstRunMigration()
            showMigrationSheet = false
            shellIntegration.writeProfilePathsManifest()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func createProfile(named name: String) {
        do {
            let profile = try manager.createProfile(name: name)
            refreshLoginStatuses()
            pendingSignInProfile = profile
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func rename(_ profile: Profile, to name: String) {
        do {
            try manager.rename(profile, to: name)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func setColor(_ profile: Profile, hex: String) {
        manager.setColor(profile, hex: hex)
    }

    public func delete(_ profile: Profile) {
        do {
            try manager.delete(profile)
            refreshLoginStatuses()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// Entry point used by every UI surface. Confirms with the user before
    /// switching if Claude Desktop is currently running — otherwise the swap
    /// would terminate their in-flight chat.
    public func requestSwitch(to profile: Profile) {
        if profile.id == store.activeProfileID { return }
        if manager.claudeApp.isClaudeRunning {
            let alert = NSAlert()
            alert.messageText = "Switch to “\(profile.name)”?"
            alert.informativeText =
                "Claude Desktop is currently running and will be closed before the profile is switched. Any unsaved work in the active conversation may be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Switch and Quit Claude")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        switchTo(profile)
    }

    /// Run a mutually-exclusive async operation behind the `isSwitching` flag.
    /// The flag is always reset (even when `op` throws or an unexpected error
    /// escapes), errors are routed through `reportError`, and a user-initiated
    /// cancellation is swallowed silently.
    private func runExclusive(_ op: @escaping @MainActor () async throws -> Void) {
        guard !isSwitching else { return }
        isSwitching = true
        Task { [weak self] in
            defer { self?.isSwitching = false }
            do {
                try await op()
            } catch is CancellationError {
                // User cancelled — not an error.
            } catch {
                self?.reportError(error.localizedDescription)
            }
        }
    }

    public func switchTo(_ profile: Profile, relaunchDesktop: Bool = true) {
        runExclusive { [self] in
            defer {
                refreshLoginStatuses()
                // ~/.claude/local/claude resolves through the profile symlink,
                // so CLI availability can change across a switch.
                surfaces.refreshSoon(force: true)
            }
            do {
                try await manager.switchTo(profile, relaunchDesktop: relaunchDesktop)
            } catch let error as ClaudeAppError {
                // The switch itself committed — only the Desktop relaunch failed.
                reportError(
                    "Switched to “\(profile.name)”, but Claude Desktop couldn't be reopened: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Confirms with the user, then tears down the symlinks and moves the
    /// active profile's data back to the canonical paths. Optionally quits
    /// the app afterward.
    public func requestDisableAndRestore() {
        guard let active = store.activeProfile else {
            reportError("There is no active profile to restore.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore the default Claude layout?"
        alert.informativeText =
            "This removes the symlinks at ~/.claude and ~/Library/Application Support/Claude, and moves \"\(active.name)\"'s files back into those paths. Other profiles stay on disk but become inactive. Claude Desktop will be quit first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore and Quit App")
        alert.addButton(withTitle: "Restore (keep app running)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let quitAfter = (response == .alertFirstButtonReturn)

        runExclusive { [self] in
            try await manager.disableAndRestore(targetProfile: active)
            refreshLoginStatuses()
            shellIntegration.writeProfilePathsManifest()
            if quitAfter { NSApp.terminate(nil) }
        }
    }

    public func signIn(_ profile: Profile, method: ProfileManager.SignInMethod) {
        // One sign-in at a time — a second click while in flight is a no-op
        // rather than a competing flow racing for the same credential files.
        guard signInTask == nil, !isSwitching else { return }
        isSwitching = true
        signingInProfileID = profile.id
        signInPhase = nil
        signInStartedAt = Date()
        signInFailure = nil

        signInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.signInTask = nil
                self.refreshLoginStatuses()
                self.signInPhase = nil
                self.signingInProfileID = nil
                self.signInStartedAt = nil
                self.isSwitching = false
            }

            // Refresh the badge once a second while the sign-in is in progress
            // so the green check appears the moment the token lands on disk.
            // Lives inside the sign-in task so cancelSignIn() kills both.
            let refresher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    await MainActor.run { self?.refreshLoginStatuses() }
                }
            }
            defer { refresher.cancel() }

            do {
                try await self.manager.signIn(profile, method: method) { phase in
                    self.signInPhase = phase
                }
            } catch is CancellationError {
                // User cancelled — leave quietly, no failure row.
            } catch {
                self.signInFailure = SignInFailure(
                    profileID: profile.id, method: method, message: error.localizedDescription)
                if !self.profilesWindowVisible {
                    self.reportError(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel an in-flight sign-in (and its badge refresher). Safe to call
    /// when nothing is running.
    public func cancelSignIn() {
        signInTask?.cancel()
    }

    public func signOut(_ profile: Profile, surfaces: Set<Surface> = [.cli, .desktop]) {
        runExclusive { [self] in
            defer { refreshLoginStatuses() }
            try await manager.signOut(profile, surfaces: surfaces)
        }
    }

    // MARK: - Copy configuration

    /// Read-only dry run for the copy sheet. Fast, doesn't toggle isSwitching.
    /// Errors are thrown so the sheet can show them inline (the window-level
    /// alert can't reliably present over a sheet).
    public func planConfigCopy(
        from source: Profile, to target: Profile,
        categories: Set<CopyCategory>, mode: CopyMode
    ) throws -> CopyPlan {
        try manager.copyConfigPlan(from: source, to: target, categories: categories, mode: mode)
    }

    /// Mutating phase. Manual isSwitching management (the signIn precedent)
    /// because the sheet needs the CopySummary back, which fire-and-forget
    /// runExclusive can't return. Returns nil on failure after routing the
    /// error to reportError.
    public func performConfigCopy(
        plan: CopyPlan, resolutions: [CopyItem.ID: ConflictResolution],
        source: Profile, target: Profile
    ) async -> CopySummary? {
        guard !isSwitching else { return nil }
        isSwitching = true
        defer {
            isSwitching = false
            refreshLoginStatuses()
        }
        do {
            return try await manager.performConfigCopy(
                plan, resolutions: resolutions, from: source, to: target)
        } catch {
            reportError(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Shell integration

    public func installShellIntegration() {
        do {
            try shellIntegration.install()
            refreshShellIntegrationState()
        } catch {
            reportError("Couldn't install shell integration: \(error.localizedDescription)")
        }
    }

    public func uninstallShellIntegration() {
        do {
            try shellIntegration.uninstall()
            refreshShellIntegrationState()
        } catch {
            reportError("Couldn't uninstall shell integration: \(error.localizedDescription)")
        }
    }

    public func revealShellFunctionInFinder() {
        let url = shellIntegration.functionFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Sync

    private func startSync() {
        do {
            try sync.start { [weak self] in
                self?.refreshLoginStatuses()
            }
        } catch {
            reportError("iCloud Drive sync couldn't start: \(error.localizedDescription)")
            UserDefaults.standard.set(false, forKey: Self.syncEnabledKey)
        }
    }

    // MARK: - Convenience

    public func openClaudeDesktop() {
        Task {
            do {
                try await manager.claudeApp.launchClaude(activate: true)
            } catch {
                reportError(error.localizedDescription)
            }
        }
    }

    public func revealActiveProfileInFinder() {
        guard let active = store.activeProfile else { return }
        let url = store.profileDirectory(active)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        } catch {
            reportError("Couldn't update Launch at Login: \(error.localizedDescription)")
        }
    }

    public var launchAtLoginEnabled: Bool { launchAtLogin.isEnabled }
}
