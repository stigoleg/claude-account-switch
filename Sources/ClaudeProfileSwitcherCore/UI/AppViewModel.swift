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
    public let diagnostics: DiagnosticsService
    public let sharedConfig: SharedConfigService

    public var isSwitching = false
    public var lastError: String?
    /// Tracked by ProfilesWindow's onAppear/onDisappear so `reportError` knows
    /// whether the window-scoped alert will actually be seen.
    public var profilesWindowVisible = false
    public var showMigrationSheet = false
    public var pendingSignInProfile: Profile?  // shown as a sheet after Create
    /// The TARGET profile of a "Copy config from…" action; drives the sheet.
    public var copyConfigTarget: Profile?
    /// The profile the shared Claude setup sheet installs into.
    public var sharedConfigTarget: Profile?
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
    public var backupVerificationMessage: String?
    public private(set) var diagnosticFindings: [DiagnosticFinding] = []
    public private(set) var sharedConfigStatuses: [UUID: SharedConfigStatus] = [:]

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

    public var layoutHealth: LayoutHealth {
        manager.layout.health(activeProfileID: store.activeProfileID, profiles: store.profiles)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let testRoot = environment["CPS_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let s = ProfileStore(supportRoot: testRoot?.appendingPathComponent("support", isDirectory: true))
        s.load()
        self.store = s
        if let testRoot {
            let cli = testRoot.appendingPathComponent("home/.claude", isDirectory: true)
            let desktop = testRoot.appendingPathComponent(
                "home/Library/Application Support/Claude", isDirectory: true)
            self.manager = ProfileManager(
                store: s,
                claudeApp: TestModeClaudeAppController(),
                surfaceLocator: TestModeSurfaceLocator(),
                cliCanonicalPath: cli,
                desktopCanonicalPath: desktop,
                claudeCodeRunner: TestModeClaudeCodeRunner())
            self.shellIntegration = ShellIntegrationService(
                store: s,
                configDirectoryOverride: testRoot.appendingPathComponent("config"),
                zshrcOverride: testRoot.appendingPathComponent("home/.zshrc"),
                shellIsZshOverride: true,
                bashrcOverride: testRoot.appendingPathComponent("home/.bashrc"),
                bashProfileOverride: testRoot.appendingPathComponent("home/.bash_profile"),
                fishConfigOverride: testRoot.appendingPathComponent(
                    "home/.config/fish/conf.d/claude-profile-switcher.fish"))
            self.sync = ProfileSyncService(
                store: s, cloudDirectory: testRoot.appendingPathComponent("icloud"))
        } else {
            self.manager = ProfileManager(store: s)
            self.shellIntegration = ShellIntegrationService(store: s)
            self.sync = ProfileSyncService(store: s)
        }
        self.desktopHint = DesktopHintWatcher(store: s)
        let home =
            testRoot?.appendingPathComponent("home", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.sharedConfig = SharedConfigService(
            bundleURL: SharedConfigService.bundledResourceURL,
            deployedURL: SharedConfigService.deployedURL(home: home),
            profilesDirectory: s.profilesDirectory,
            runner: testRoot == nil ? ClaudeCodeRunner(timeout: 300) : TestModeClaudeCodeRunner())
        self.diagnostics = DiagnosticsService(
            manager: manager,
            shellIntegration: shellIntegration,
            home: home,
            sharedConfig: sharedConfig)
        self.surfaces =
            testRoot == nil
            ? SurfaceAvailability()
            : SurfaceAvailability(locator: TestModeSurfaceLocator())
        // Seed the toggle state from UserDefaults. didSet won't fire during
        // init, so we trigger the appropriate watchers/sync explicitly below.
        self.syncEnabled = testRoot == nil && UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        self.desktopHintsEnabled = testRoot == nil && UserDefaults.standard.bool(forKey: Self.desktopHintsKey)

        do {
            try self.manager.recoverLayoutIfNeeded()
            try self.manager.recoverConfigCopyIfNeeded()
        } catch {
            self.lastError = error.localizedDescription
        }
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
            if let error = self.shellIntegration.writeProfilePathsManifest() {
                self.reportError(error)
            }
            self.sync.localDidChange()
        }
        if let error = shellIntegration.writeProfilePathsManifest() {
            lastError = error
        }
        runDiagnostics()
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
            next[p.id] = manager.credentials.status(for: p, activeProfileID: store.activeProfileID)
        }
        loginStatuses = next
        refreshSharedConfigStatuses()

        // Then off-main keychain probe to fill in the .unknown notes.
        let inspector = manager.credentials
        let profiles = store.profiles
        Task { [weak self] in
            var withKeychain: [UUID: ProfileLoginStatus] = [:]
            for p in profiles {
                withKeychain[p.id] = await inspector.statusWithKeychain(
                    for: p, activeProfileID: self?.store.activeProfileID)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loginStatuses = withKeychain
            }
        }
    }

    public func refreshShellIntegrationState() {
        shellIntegrationInstalled =
            shellIntegration.integrationStatuses().allSatisfy(\.installed)
            && shellIntegration.dispatcherSignatureValid()
    }

    public var cliIntegrationStatuses: [CLIIntegrationStatus] {
        shellIntegration.integrationStatuses()
    }

    public var latestBackup: MigrationBackup? {
        manager.layout.availableBackups().first
    }

    public var syncStatusText: String {
        switch sync.status {
        case .disabled: return "iCloud sync disabled"
        case .syncing: return "iCloud sync in progress"
        case .current: return "iCloud metadata current"
        case .offline(let message): return "iCloud offline: \(message)"
        case .failed(let message): return "iCloud sync failed: \(message)"
        }
    }

    public var pendingRemoteDeletionProfiles: [Profile] {
        store.profiles.filter { sync.pendingRemoteDeletions.contains($0.id) }
    }

    public func keepPendingRemoteProfile(_ profile: Profile) {
        do {
            _ = try manager.keepOnThisMac(profile)
            sync.resolvePendingRemoteDeletion(for: profile.id)
            refreshLoginStatuses()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func acceptPendingRemoteDeletion(_ profile: Profile) {
        guard profile.id != store.activeProfileID else {
            reportError("Switch to another profile before accepting deletion of “\(profile.name)”.")
            return
        }
        do {
            try manager.delete(profile)
            sync.resolvePendingRemoteDeletion(for: profile.id)
            refreshLoginStatuses()
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func verifyLatestBackup() {
        guard let backup = latestBackup else { return }
        let layout = manager.layout
        Task { [weak self] in
            do {
                let valid = try await Task.detached(priority: .utility) {
                    try layout.verifyBackup(backup)
                }.value
                self?.backupVerificationMessage = valid ? "Backup verified" : "Backup verification failed"
            } catch {
                self?.backupVerificationMessage = "Backup verification failed: \(error.localizedDescription)"
            }
        }
    }

    public func revealLatestBackup() {
        guard let backup = latestBackup else { return }
        NSWorkspace.shared.activateFileViewerSelecting([backup.directory])
    }

    public func requestRestoreLatestBackup() {
        guard let backup = latestBackup else { return }
        let alert = NSAlert()
        alert.messageText = "Restore the verified pre-v2 backup?"
        alert.informativeText =
            "Claude Desktop and all Claude Code sessions must be closed. Current profile data will be retained in a new pre-restore backup, and the selected backup will be restored into the safe v2 physical layout. iCloud sync will be disabled until you turn it on again."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Restore Backup")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        syncEnabled = false
        runExclusive { [self] in
            try await manager.restorePreV2Backup(backup)
            if let error = shellIntegration.writeProfilePathsManifest() {
                throw ShellIntegrationService.IntegrationError.manifest(error)
            }
            refreshLoginStatuses()
            backupVerificationMessage = "Backup restored; previous v2 data was retained"
        }
    }

    public func requestTrashLatestBackup() {
        guard let backup = latestBackup else { return }
        let alert = NSAlert()
        alert.messageText = "Move the pre-v2 backup to the Trash?"
        alert.informativeText =
            "This removes your automatic rollback point. The backup is moved to the Trash and is not permanently erased."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.layout.moveBackupToTrash(backup)
            backupVerificationMessage = "Backup moved to Trash"
        } catch {
            reportError(error.localizedDescription)
        }
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
        runExclusive { [self] in
            try await manager.runFirstRunMigrationAsync()
            showMigrationSheet = false
            do {
                try shellIntegration.installAllSupportedShells()
                try await manager.logoutLegacyGlobalCLI()
            } catch {
                reportError(
                    "Your profile data was migrated safely, but CLI setup still needs attention: \(error.localizedDescription)"
                )
            }
            if let manifestError = shellIntegration.writeProfilePathsManifest() {
                reportError("CLI manifest needs repair: \(manifestError)")
            }
            refreshLoginStatuses()
            refreshShellIntegrationState()
            pendingSignInProfile = store.activeProfile
        }
    }

    public func createProfile(named name: String, installSharedConfig: Bool = false) {
        do {
            let profile = try manager.createProfile(name: name)
            refreshLoginStatuses()
            pendingSignInProfile = profile
            if installSharedConfig {
                self.installSharedConfig(profile, yolo: nil, documentSkills: false)
            }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func setupLocalProfile(_ profile: Profile) {
        do {
            try manager.setupLocalProfile(profile)
            refreshLoginStatuses()
            pendingSignInProfile = profile
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func localState(for profile: Profile) -> LocalProfileState {
        manager.layout.localState(for: profile, activeProfileID: store.activeProfileID)
    }

    public func rename(_ profile: Profile, to name: String) {
        do {
            try manager.rename(profile, to: name)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    public func setColor(_ profile: Profile, hex: String) {
        do {
            try manager.setColor(profile, hex: hex)
        } catch {
            reportError(error.localizedDescription)
        }
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
                // Refresh after profile changes in case the available real
                // Claude binary came from a profile-local installation.
                surfaces.refreshSoon(force: true)
            }
            let result = try await manager.switchTo(profile, relaunchDesktop: relaunchDesktop)
            if let relaunchError = result.relaunchError {
                reportError(
                    "Switched to “\(profile.name)”, but Claude Desktop couldn't be reopened: \(relaunchError)"
                )
            }
        }
    }

    /// Confirms with the user, then restores stock Desktop/CLI paths while
    /// retaining other profiles and backups. Optionally quits afterward.
    public func requestDisableAndRestore() {
        guard let active = store.activeProfile else {
            reportError("There is no active profile to restore.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore the default Claude layout?"
        alert.informativeText =
            "Claude Desktop stays in its real support folder. \"\(active.name)\"'s CLI files move back to ~/.claude, managed shell hooks are removed, and other profiles and backups stay on disk. Claude Desktop will be quit first."
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
            try shellIntegration.uninstallAllSupportedShells()
            refreshLoginStatuses()
            refreshShellIntegrationState()
            reportError(
                "The default layout was restored and the managed shell hooks were removed. Run `claude auth login` in a new terminal to create a global CLI login. Your other profiles and backups remain on disk."
            )
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

    // MARK: - Shared Claude setup

    public func refreshSharedConfigStatuses() {
        var next: [UUID: SharedConfigStatus] = [:]
        for p in store.profiles {
            next[p.id] = sharedConfig.status(profileID: p.id)
        }
        sharedConfigStatuses = next
    }

    public func sharedConfigStatus(for profile: Profile) -> SharedConfigStatus {
        sharedConfigStatuses[profile.id] ?? .notInstalled
    }

    /// Default for the new-profile checkbox.
    public var anyProfileHasSharedConfig: Bool {
        sharedConfigStatuses.values.contains { $0 != .notInstalled }
    }

    /// Install or update the shared setup in one profile. `yolo`: true sets
    /// the permission keys, false removes them (sheet unchecked), nil leaves
    /// them alone.
    public func installSharedConfig(_ profile: Profile, yolo: Bool?, documentSkills: Bool) {
        var overwrite = false
        if sharedConfig.deployedHasLocalEdits() {
            guard confirmOverwriteSharedEdits() else { return }
            overwrite = true
        }
        runExclusive { [self] in
            defer {
                refreshSharedConfigStatuses()
                runDiagnostics()
            }
            let outcome = try sharedConfig.install(profileID: profile.id, yolo: yolo, overwriteLocalEdits: overwrite)
            store.appendLog("shared-config: installed in \(profile.id) (yolo: \(yolo.map(String.init) ?? "unchanged"))")
            reportKeptSharedCopy(outcome)
            guard documentSkills else { return }
            let failures = await sharedConfig.installDocumentSkills(profileID: profile.id)
            if !failures.isEmpty {
                reportError(
                    "The shared Claude setup was installed in “\(profile.name)”, but the Anthropic document skills were not:\n"
                        + failures.joined(separator: "\n"))
            }
        }
    }

    public func requestRemoveSharedConfig(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Remove the shared Claude setup from “\(profile.name)”?"
        alert.informativeText =
            "The CLAUDE.md, agents and skill links are removed, and the settings the setup added are taken out of settings.json (backed up first). Your model choice, other settings and profile-local skills stay. Other profiles keep the shared setup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runExclusive { [self] in
            defer {
                refreshSharedConfigStatuses()
                runDiagnostics()
            }
            try sharedConfig.uninstall(profileID: profile.id)
            store.appendLog("shared-config: removed from \(profile.id)")
        }
    }

    private func confirmOverwriteSharedEdits() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Overwrite local edits to the shared Claude setup?"
        alert.informativeText =
            "\(sharedConfig.deployedURL.path) differs from what the app installed (or from the bundled setup, for a copy made by install.sh or by hand). Continuing replaces it with the copy bundled with the app, for every profile that uses the shared setup. The edited copy is kept as \(sharedConfig.deployedURL.lastPathComponent).backup-<timestamp> next to it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func reportKeptSharedCopy(_ outcome: SharedConfigDeployOutcome) {
        guard case .deployed(let kept?) = outcome else { return }
        store.appendLog("shared-config: kept the edited copy at \(kept.path)")
        reportError("The shared Claude setup was updated. Your edited copy was kept at \(kept.path).")
    }

    /// Spells out what a doctor reinstall changes before it runs.
    private func confirmSharedReinstall(_ profileID: UUID, overwriteLocalEdits: Bool) -> Bool {
        let name = store.profiles.first { $0.id == profileID }?.name ?? profileID.uuidString
        let alert = NSAlert()
        alert.messageText = "Reinstall the shared Claude setup in “\(name)”?"
        alert.informativeText =
            "CLAUDE.md, agents and the shared skills are linked again to \(sharedConfig.deployedURL.path) (a real file in the way is renamed to .backup-<timestamp>), and settings.json is rewritten after a backup: status line, fallback model and the subagent model hook. Permission settings are left as they are."
            + (overwriteLocalEdits
                ? " \(sharedConfig.deployedURL.path) has local edits; it is replaced and the edited copy kept as \(sharedConfig.deployedURL.lastPathComponent).backup-<timestamp>."
                : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reinstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Shell integration

    public func installShellIntegration() {
        do {
            try shellIntegration.installAllSupportedShells()
            refreshShellIntegrationState()
        } catch {
            reportError("Couldn't install shell integration: \(error.localizedDescription)")
        }
    }

    public func uninstallShellIntegration() {
        do {
            try shellIntegration.uninstallAllSupportedShells()
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

    // MARK: - Diagnose & Repair

    public var diagnosticsHasErrors: Bool {
        diagnosticFindings.contains { $0.severity == .error }
    }

    /// Distinct repairs that "Fix all safe issues" would apply.
    public var safeRepairActions: [RepairAction] {
        var seen: Set<RepairAction> = []
        return diagnosticFindings.compactMap(\.repair).filter { $0.isSafe && seen.insert($0).inserted }
    }

    public func runDiagnostics() {
        diagnosticFindings = diagnostics.run()
    }

    /// `.runMigration` is handled by the caller, which opens the migration
    /// sheet; every other repair is confirmed where needed and applied here.
    public func applyRepair(_ action: RepairAction) {
        switch action {
        case .moveAside(let url, _):
            guard confirmMoveAside([url]) else { return }
        case .overwriteSharedConfig:
            guard confirmOverwriteSharedEdits() else { return }
        case .installSharedConfig(let profileID, let overwriteLocalEdits):
            guard confirmSharedReinstall(profileID, overwriteLocalEdits: overwriteLocalEdits) else { return }
        default:
            break
        }
        runRepairs([action])
    }

    public func applySafeRepairs() {
        let actions = safeRepairActions
        let moves = actions.compactMap { action -> URL? in
            if case .moveAside(let url, _) = action { return url }
            return nil
        }
        guard !actions.isEmpty, moves.isEmpty || confirmMoveAside(moves) else { return }
        runRepairs(actions)
    }

    public var repairsFolderExists: Bool {
        FileManager.default.fileExists(atPath: diagnostics.repairsDirectory.path)
    }

    public func revealRepairsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.repairsDirectory])
    }

    public func copyDiagnosticsReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsService.textReport(diagnosticFindings), forType: .string)
    }

    private func confirmMoveAside(_ urls: [URL]) -> Bool {
        let running = manager.claudeApp.isClaudeRunning
        let alert = NSAlert()
        alert.messageText =
            urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” aside?" : "Move \(urls.count) folders aside?"
        alert.informativeText =
            urls.map(\.path).joined(separator: "\n")
            + "\n\nThe folders are moved to \(diagnostics.repairsDirectory.path), not deleted, and keep using disk space there (vm_bundles can be many GB). Claude Desktop downloads fresh copies when Cowork next starts; delete the moved folders once Claude Desktop works again."
            + (running ? " Claude Desktop is running and will be quit first." : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: running ? "Quit Claude and Move" : "Move Aside")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runRepairs(_ actions: [RepairAction]) {
        runExclusive { [self] in
            defer {
                runDiagnostics()
                refreshShellIntegrationState()
                refreshLoginStatuses()
            }
            let movesAside = actions.contains { action in
                if case .moveAside = action { return true }
                return false
            }
            if movesAside, manager.claudeApp.isClaudeRunning {
                guard await manager.claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
            }
            var failures: [String] = []
            for action in actions {
                do {
                    try diagnostics.apply(action)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if !failures.isEmpty {
                reportError(failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Sync

    private func startSync() {
        do {
            try sync.start { [weak self] in
                self?.refreshLoginStatuses()
                if let self, let error = self.shellIntegration.writeProfilePathsManifest() {
                    self.reportError(error)
                }
            }
        } catch {
            reportError("iCloud Drive sync couldn't start: \(error.localizedDescription)")
            syncEnabled = false
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
