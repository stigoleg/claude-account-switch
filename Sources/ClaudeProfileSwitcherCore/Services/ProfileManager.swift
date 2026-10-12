import AppKit
import Foundation

public enum MigrationState: Equatable {
    case notNeeded
    case needed(cliRealDir: Bool, desktopRealDir: Bool)
}

public enum ProfileError: LocalizedError {
    case nameEmpty
    case nameTaken(String)
    case nameInvalid(String)
    case noProfilesYet
    case profileNotFound
    case migrationConflict(String)

    public var errorDescription: String? {
        switch self {
        case .nameEmpty: return "Profile name can't be empty."
        case .nameTaken(let n): return "A profile named \"\(n)\" already exists."
        case .nameInvalid(let m): return m
        case .noProfilesYet: return "No profiles configured yet."
        case .profileNotFound: return "Profile no longer exists."
        case .migrationConflict(let m): return m
        }
    }
}

public enum SignInError: LocalizedError, Equatable {
    case desktopNotInstalled
    case cliNotInstalled
    case terminalAutomationDenied
    case terminalLaunchFailed(String)
    case timedOut
    case desktopQuitUnexpectedly

    public var errorDescription: String? {
        switch self {
        case .desktopNotInstalled:
            return
                "Claude Desktop isn't installed on this Mac. Download it from claude.ai/download, or sign in with the CLI only."
        case .cliNotInstalled:
            return
                "The claude CLI wasn't found on this Mac. Install Claude Code first (see docs.anthropic.com/claude-code), or sign in with Desktop only."
        case .terminalAutomationDenied:
            return
                "macOS blocked the app from controlling Terminal. Allow it under System Settings → Privacy & Security → Automation, then retry."
        case .terminalLaunchFailed(let reason):
            return "Couldn't open Terminal for the CLI sign-in: \(reason)"
        case .timedOut:
            return
                "Timed out waiting for the Claude Desktop sign-in to complete. Retry when you're ready — the profile is still selected."
        case .desktopQuitUnexpectedly:
            return "Claude Desktop quit before the sign-in completed. Retry to relaunch it."
        }
    }
}

/// Orchestrates the high-level operations the UI cares about:
/// migration, create / rename / delete, and the switch flow.
@MainActor
public final class ProfileManager {
    public let store: ProfileStore
    public let symlinks: any SymlinkServicing
    public let claudeApp: any ClaudeAppControlling
    public let credentials: CredentialsInspector
    /// Resolves where the `claude` CLI lives; injected so sign-in preflight
    /// can be tested against fake CLI-only / Desktop-only systems.
    public let surfaceLocator: any SurfaceLocator
    /// Profile-to-profile configuration copy (MCP servers, plugins, skills…).
    public let configCopy: ConfigCopyService
    public let layout: any ProfileLayoutServicing
    public let claudeCodeRunner: any ClaudeCodeRunning
    /// Path of the CLI canonical mount point (`~/.claude` in prod). Injectable
    /// so tests can drive migration against a tmp dir without touching real
    /// user data.
    public let cliCanonicalPath: URL
    /// Path of the Desktop canonical mount point. See `cliCanonicalPath`.
    public let desktopCanonicalPath: URL

    public init(
        store: ProfileStore,
        symlinks: any SymlinkServicing = SymlinkService(),
        claudeApp: any ClaudeAppControlling = ClaudeAppController(),
        surfaceLocator: any SurfaceLocator = SystemSurfaceLocator(),
        configCopy: ConfigCopyService? = nil,
        cliCanonicalPath: URL = ProfileStore.claudeCLIPath,
        desktopCanonicalPath: URL = ProfileStore.claudeDesktopPath,
        layout: (any ProfileLayoutServicing)? = nil,
        claudeCodeRunner: (any ClaudeCodeRunning)? = nil
    ) {
        self.store = store
        self.symlinks = symlinks
        self.claudeApp = claudeApp
        self.surfaceLocator = surfaceLocator
        self.configCopy =
            configCopy
            ?? ConfigCopyService(
                recoveryDirectory: store.supportDirectory.appendingPathComponent(
                    "CopyConfigRecovery", isDirectory: true))
        let runner =
            claudeCodeRunner
            ?? ClaudeCodeRunner(
                candidates: store.profiles.map {
                    store.cliDirectory($0).appendingPathComponent("local/claude")
                } + SystemSurfaceLocator.defaultCandidatePaths())
        self.claudeCodeRunner = runner
        self.credentials = CredentialsInspector(
            store: store,
            canonicalDesktopPath: desktopCanonicalPath,
            claudeCodeRunner: runner)
        self.cliCanonicalPath = cliCanonicalPath
        self.desktopCanonicalPath = desktopCanonicalPath
        self.layout =
            layout
            ?? ProfileLayoutService(
                store: store,
                canonicalDesktop: desktopCanonicalPath,
                canonicalCLI: cliCanonicalPath)
    }

    // MARK: - Migration

    /// Inspect the canonical paths and report whether first-run migration is needed.
    public func migrationState() -> MigrationState {
        switch layout.health(activeProfileID: store.activeProfileID, profiles: store.profiles) {
        case .healthy:
            return .notNeeded
        case .migrationRequired, .recoveryRequired, .unsupportedFilesystem:
            break
        }
        let cliReal = symlinks.itemExists(cliCanonicalPath) && !symlinks.isSymlink(cliCanonicalPath)
        let desktopReal = symlinks.itemExists(desktopCanonicalPath) && !symlinks.isSymlink(desktopCanonicalPath)
        if !cliReal && !desktopReal,
            !symlinks.isSymlink(cliCanonicalPath),
            !symlinks.isSymlink(desktopCanonicalPath)
        {
            return .notNeeded
        }
        return .needed(cliRealDir: cliReal, desktopRealDir: desktopReal)
    }

    /// Back up and convert a stock or v1 symlink installation to the v2 physical
    /// Desktop layout. Every mutating step is journaled and recoverable.
    public func runFirstRunMigration(profileName: String = "default") throws {
        guard !claudeApp.isClaudeRunning else { throw ProfileLayoutError.desktopStillRunning }
        try preflightLegacyCLIProcesses()
        if symlinks.isSymlink(cliCanonicalPath), symlinks.isSymlink(desktopCanonicalPath) {
            guard let active = store.activeProfile else { throw ProfileError.noProfilesYet }
            _ = try layout.createPreV2Backup(profiles: store.profiles)
            try layout.migrateLegacyLayout(active: active, profiles: store.profiles)
            try store.setActiveThrowing(active)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: converted legacy symlink layout for \(active.name) (\(active.id))")
            return
        }

        // Fresh v2 adoption: keep Desktop at its canonical real path and move
        // the existing CLI directory into the default profile. No symlinks are
        // created for either surface.
        if store.profiles.isEmpty {
            let profile = Profile(name: try Self.normalizeProfileName(profileName))
            _ = try layout.createPreV2Backup(profiles: [])
            try store.upsertThrowing(profile)
            try layout.adoptCurrentLayout(active: profile)
            try store.setActiveThrowing(profile)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: adopted default layout as \(profile.name) (\(profile.id))")
            return
        }

        if let disabledID = store.disabledProfileID,
            let profile = store.profiles.first(where: { $0.id == disabledID })
        {
            _ = try layout.createPreV2Backup(profiles: store.profiles)
            try layout.adoptCurrentLayout(active: profile)
            try store.setActiveThrowing(profile)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: re-enabled profile \(profile.name) (\(profile.id))")
            return
        }

        throw ProfileError.migrationConflict(
            "The current layout is neither a valid v1 symlink layout nor an unconfigured v2 layout. Open Diagnose & Repair from the menu bar."
        )

    }

    /// UI variant that performs the potentially large copy-on-write backup off
    /// the main actor, then commits the short rename-based layout conversion.
    public func runFirstRunMigrationAsync(profileName: String = "default") async throws {
        guard !claudeApp.isClaudeRunning else { throw ProfileLayoutError.desktopStillRunning }
        try preflightLegacyCLIProcesses()
        let profiles = store.profiles
        let layout = self.layout
        if symlinks.isSymlink(cliCanonicalPath), symlinks.isSymlink(desktopCanonicalPath) {
            guard let active = store.activeProfile else { throw ProfileError.noProfilesYet }
            _ = try await Task.detached(priority: .userInitiated) {
                try layout.createPreV2Backup(profiles: profiles)
            }.value
            try layout.migrateLegacyLayout(active: active, profiles: profiles)
            try store.setActiveThrowing(active)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: converted legacy symlink layout for \(active.name) (\(active.id))")
            return
        }
        if profiles.isEmpty {
            let profile = Profile(name: try Self.normalizeProfileName(profileName))
            _ = try await Task.detached(priority: .userInitiated) {
                try layout.createPreV2Backup(profiles: [])
            }.value
            try store.upsertThrowing(profile)
            try layout.adoptCurrentLayout(active: profile)
            try store.setActiveThrowing(profile)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: adopted default layout as \(profile.name) (\(profile.id))")
            return
        }
        if let disabledID = store.disabledProfileID,
            let profile = profiles.first(where: { $0.id == disabledID })
        {
            _ = try await Task.detached(priority: .userInitiated) {
                try layout.createPreV2Backup(profiles: profiles)
            }.value
            try layout.adoptCurrentLayout(active: profile)
            try store.setActiveThrowing(profile)
            try layout.completeSwitchJournal()
            store.appendLog("migration-v2: re-enabled profile \(profile.name) (\(profile.id))")
            return
        }
        throw ProfileError.migrationConflict(
            "The current layout is neither a valid v1 symlink layout nor an unconfigured v2 layout. Open Diagnose & Repair from the menu bar."
        )
    }

    @discardableResult
    public func recoverLayoutIfNeeded() throws -> UUID? {
        guard let outcome = try layout.recoverPendingOperation() else { return nil }
        let recoveredID: UUID
        switch outcome {
        case .active(let id), .disabled(let id), .restoredBackup(let id): recoveredID = id
        }
        if case .restoredBackup = outcome {
            store.load()
        }
        guard let recovered = store.profiles.first(where: { $0.id == recoveredID }) else {
            throw ProfileLayoutError.pendingRecovery("the recovered profile is missing from metadata")
        }
        switch outcome {
        case .active:
            try store.setActiveThrowing(recovered)
            store.appendLog("recovery: active Desktop profile is \(recovered.name) (\(recovered.id))")
        case .disabled:
            try store.markDisabledThrowing(recovered)
            store.appendLog("recovery: completed default-layout restore for \(recovered.name) (\(recovered.id))")
        case .restoredBackup:
            guard store.activeProfileID == recovered.id else {
                throw ProfileLayoutError.pendingRecovery("restored metadata does not select the restored profile")
            }
            store.appendLog("recovery: restored pre-v2 backup with active profile \(recovered.name)")
        }
        try layout.completeSwitchJournal()
        return recoveredID
    }

    /// Restore stock behavior while retaining every profile and backup. Desktop
    /// is already real in v2; the selected CLI data returns to ~/.claude.
    public func disableAndRestore(targetProfile: Profile) async throws {
        guard store.profiles.contains(where: { $0.id == targetProfile.id }) else {
            throw ProfileError.profileNotFound
        }

        if claudeApp.isClaudeRunning {
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }
        try layout.restoreDefaultLayout(active: targetProfile)
        try store.markDisabledThrowing(targetProfile)
        try layout.completeSwitchJournal()
        store.appendLog("restore: \(targetProfile.name) (\(targetProfile.id))")
    }

    public func restorePreV2Backup(_ backup: MigrationBackup) async throws {
        if claudeApp.isClaudeRunning {
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }
        try preflightLegacyCLIProcesses()
        let restoredID = try layout.restorePreV2Backup(backup, currentActiveID: store.activeProfileID)
        store.load()
        guard store.activeProfileID == restoredID,
            let restored = store.profiles.first(where: { $0.id == restoredID })
        else {
            throw ProfileLayoutError.pendingRecovery("restored metadata could not be loaded")
        }
        try layout.completeSwitchJournal()
        store.appendLog("restore-backup: \(backup.directory.lastPathComponent), active \(restored.name)")
    }

    public func recoverConfigCopyIfNeeded() throws {
        try configCopy.recoverPendingCopy()
    }

    // MARK: - CRUD

    /// Shared name validation for create and rename: trims whitespace,
    /// rejects empty/control-character names, caps the length. Names are
    /// display-only (profile directories are keyed by UUID), so this is a
    /// UX guard, not a path-safety one.
    static func normalizeProfileName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.nameEmpty }
        guard trimmed.count <= 64 else {
            throw ProfileError.nameInvalid("Profile names are capped at 64 characters.")
        }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw ProfileError.nameInvalid("Profile names can't contain control characters.")
        }
        return trimmed
    }

    @discardableResult
    public func createProfile(name: String) throws -> Profile {
        let trimmed = try Self.normalizeProfileName(name)
        if store.profiles.contains(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.aliases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }) {
            throw ProfileError.nameTaken(trimmed)
        }
        let profile = Profile(name: trimmed)
        try layout.prepareNewProfile(profile)
        try store.upsertThrowing(profile)
        store.appendLog("create: \(profile.name) (\(profile.id))")
        return profile
    }

    public func setupLocalProfile(_ profile: Profile) throws {
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileError.profileNotFound
        }
        try layout.prepareNewProfile(profile)
        store.appendLog("setup-local: \(profile.name) (\(profile.id))")
    }

    /// Change the display color of a profile. Persists immediately so the
    /// sync layer can pick it up; the iCloud merge treats this like any other
    /// edit (last-writer-wins on `updatedAt`).
    public func setColor(_ profile: Profile, hex: String) throws {
        var updated = profile
        updated.colorHex = hex
        try store.upsertThrowing(updated)
        store.appendLog("color: \(profile.id) -> \(hex)")
    }

    public func rename(_ profile: Profile, to newName: String) throws {
        let trimmed = try Self.normalizeProfileName(newName)
        if store.profiles.contains(where: {
            $0.id != profile.id
                && ($0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                    || $0.aliases.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        }) {
            throw ProfileError.nameTaken(trimmed)
        }
        try store.renameProfileThrowing(profile, to: trimmed)
        store.appendLog("rename: \(profile.id) -> \(trimmed)")
    }

    /// Delete a non-active profile. Its on-disk data is moved to the Trash.
    public func delete(_ profile: Profile) throws {
        if store.activeProfileID == profile.id {
            throw ProfileError.migrationConflict("Can't delete the active profile.")
        }
        let dir = store.profileDirectory(profile)
        if symlinks.itemExists(dir) {
            try symlinks.trashProfileDirectory(dir)
        }
        try store.removeThrowing(profile)
        store.appendLog("delete: \(profile.name) (\(profile.id))")
    }

    /// Preserve local bytes after iCloud tombstoned the old profile ID. The
    /// directory is renamed on the same volume and metadata is committed as a
    /// new UUID; failures roll the directory identity back.
    @discardableResult
    public func keepOnThisMac(_ profile: Profile) throws -> Profile {
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileError.profileNotFound
        }
        let replacement = Profile(
            name: profile.name,
            colorHex: profile.colorHex,
            createdAt: profile.createdAt,
            aliases: profile.aliases)
        let wasActive = store.activeProfileID == profile.id
        try layout.reassignLocalProfileData(from: profile, to: replacement, active: wasActive)
        do {
            try store.replaceProfileIDThrowing(from: profile, with: replacement)
        } catch {
            try layout.reassignLocalProfileData(from: replacement, to: profile, active: wasActive)
            throw error
        }
        store.appendLog("sync-keep-local: \(profile.name) \(profile.id) -> \(replacement.id)")
        return replacement
    }

    // MARK: - Switch

    /// Switch the active profile. Quits Claude Desktop first; relaunches when requested.
    @discardableResult
    public func switchTo(_ profile: Profile, relaunchDesktop: Bool) async throws -> SwitchResult {
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileError.profileNotFound
        }
        if store.activeProfileID == profile.id {
            return SwitchResult(switched: false, desktopRelaunched: false)
        }

        guard case .healthy = layout.health(activeProfileID: store.activeProfileID, profiles: store.profiles) else {
            throw ProfileLayoutError.migrationRequired
        }
        guard let previous = store.activeProfile else { throw ProfileLayoutError.noActiveProfile }

        let wasRunning = claudeApp.isClaudeRunning
        if wasRunning {
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }
        try layout.switchDesktop(from: previous, to: profile)
        try store.setActiveThrowing(profile)
        try layout.completeSwitchJournal()
        store.appendLog("switch: -> \(profile.name) (\(profile.id))")

        if relaunchDesktop, wasRunning {
            do {
                try await claudeApp.launchClaude()
                return SwitchResult(switched: true, desktopRelaunched: true)
            } catch {
                return SwitchResult(
                    switched: true,
                    desktopRelaunched: false,
                    relaunchError: error.localizedDescription)
            }
        }
        return SwitchResult(switched: true, desktopRelaunched: false)
    }

    // MARK: - Sign in / out

    public enum SignInMethod: Sendable, Equatable {
        case both  // launch Desktop, wait for tokens, then launch CLI
        case desktop  // Desktop only
        case cli  // CLI only
    }

    public enum SignInPhase: Sendable, Equatable {
        case quittingDesktop
        case launchingDesktop
        case waitingForDesktop
        case launchingCLI
        case waitingForCLI
        case done
    }

    /// Callback invoked on the main actor whenever the sign-in phase changes —
    /// the view model uses this to surface progress in the UI.
    public typealias PhaseObserver = @MainActor (SignInPhase) -> Void

    /// Make `profile` active (if not already) and launch the chosen surfaces.
    ///
    /// For `.both`, this runs Desktop first, polls until its credential file
    /// shows up, then kicks off the CLI sign-in. Because the user's claude.ai
    /// browser session is shared, the second flow is usually a one-click
    /// approval.
    ///
    /// Required surfaces are preflighted **before** anything is launched or
    /// switched — a missing Desktop app or `claude` binary fails immediately
    /// with install guidance instead of a silent multi-minute poll.
    ///
    /// Cancelling the surrounding `Task` aborts the credential wait and
    /// rethrows `CancellationError`. `phase(.done)` fires only on success.
    public func signIn(
        _ profile: Profile,
        method: SignInMethod,
        timeout: TimeInterval = 180,
        phase: PhaseObserver? = nil
    ) async throws {
        // Preflight installed surfaces.
        if method == .desktop || method == .both {
            guard claudeApp.locateClaudeBundleURL() != nil else {
                throw SignInError.desktopNotInstalled
            }
        }
        var cliPath: URL?
        if method == .cli || method == .both {
            guard let url = await surfaceLocator.cliExecutableURL() else {
                throw SignInError.cliNotInstalled
            }
            cliPath = url
        }

        if method != .cli, store.activeProfileID != profile.id {
            try await switchTo(profile, relaunchDesktop: false)
        }

        switch method {
        case .desktop:
            try await runDesktopSignIn(profile: profile, timeout: timeout, phase: phase)
        case .cli:
            phase?(.launchingCLI)
            try await openTerminalForCLILogin(
                claudePath: cliPath!, configDirectory: store.cliDirectory(profile))
        // Terminal owns the interactive OAuth flow. The UI refreshes
        // profile-scoped `claude auth status --json` after launch.
        case .both:
            try await runDesktopSignIn(profile: profile, timeout: timeout, phase: phase)
            phase?(.launchingCLI)
            try await openTerminalForCLILogin(
                claudePath: cliPath!, configDirectory: store.cliDirectory(profile))
        // Don't block the app while Terminal owns the interactive flow.
        }

        phase?(.done)
        store.appendLog("signin: \(method) for \(profile.name)")
    }

    private func runDesktopSignIn(
        profile: Profile,
        timeout: TimeInterval,
        phase: PhaseObserver?
    ) async throws {
        if claudeApp.isClaudeRunning {
            phase?(.quittingDesktop)
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }
        phase?(.launchingDesktop)
        try await claudeApp.launchClaude(activate: true)
        phase?(.waitingForDesktop)
        switch await waitForCredentials(profile: profile, surface: .desktop, timeout: timeout) {
        case .found: break
        case .timedOut: throw SignInError.timedOut
        case .desktopExited: throw SignInError.desktopQuitUnexpectedly
        case .cancelled: throw CancellationError()
        }
    }

    enum CredentialWaitResult {
        case found
        case timedOut
        case desktopExited
        case cancelled
    }

    /// Poll until the credential marker for `surface` shows up, the wait is
    /// cancelled, Desktop exits mid-sign-in, or `timeout` elapses.
    private func waitForCredentials(
        profile: Profile,
        surface: Surface,
        timeout: TimeInterval
    ) async -> CredentialWaitResult {
        let start = Date()
        // Give Desktop a moment to register as running before treating "not
        // running" as the user having quit it.
        let launchGrace = min(5, timeout / 4)
        while Date().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return .cancelled }
            let status = credentials.status(for: profile, activeProfileID: store.activeProfileID)
            let s = surface == .cli ? status.cli : status.desktop
            if s.isSignedIn { return .found }
            if surface == .desktop,
                Date().timeIntervalSince(start) > launchGrace,
                !claudeApp.isClaudeRunning
            {
                return .desktopExited
            }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
            } catch {
                return .cancelled
            }
        }
        return .timedOut
    }

    /// Clear credentials for one or both surfaces. The user stays in the same
    /// profile — only the auth state is removed.
    ///
    /// - Desktop: rewrites `config.json` with the `oauth:tokenCache` field
    ///   removed (Claude Desktop stores its OAuth token there). Also clears
    ///   the Electron `Cookies` file so the web session is reset.
    /// - CLI: deletes any legacy `.credentials.json` file. We do **not** touch
    ///   the macOS keychain entry — it's shared across profiles, and we don't
    ///   want to silently sign the user out of other profiles' CLI sessions.
    public func signOut(_ profile: Profile, surfaces: Set<Surface> = [.cli, .desktop]) async throws {
        if surfaces.contains(.desktop),
            store.activeProfileID == profile.id,
            claudeApp.isClaudeRunning
        {
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }

        if surfaces.contains(.desktop) {
            if try clearDesktopOAuthToken(
                in: layout.desktopDirectory(for: profile, activeProfileID: store.activeProfileID)) == .unreadable
            {
                throw ProfileError.migrationConflict(
                    "Couldn't sign out Desktop: this profile's config.json is unreadable. Delete it manually (or re-sign-in first), then retry."
                )
            }
        }

        if surfaces.contains(.cli) {
            try await claudeCodeRunner.logout(configDirectory: store.cliDirectory(profile))
            await credentials.invalidateCLIStatus(for: profile)
        }

        store.appendLog("signout: \(surfaces) for \(profile.name)")
    }

    enum DesktopClearResult: Equatable {
        case cleared
        case nothingToClear
        case unreadable
    }

    /// Remove the OAuth token (and session cookies) from a profile's Desktop
    /// directory. `.unreadable` means a config.json exists but can't be parsed
    /// or rewritten — callers must surface that instead of silently skipping.
    @discardableResult
    private func clearDesktopOAuthToken(in desktopDir: URL) throws -> DesktopClearResult {
        let configURL = desktopDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            try clearDesktopCookies(in: desktopDir)
            return .nothingToClear
        }
        let data: Data
        var json: [String: Any]
        do {
            data = try Data(contentsOf: configURL)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable
            }
            json = decoded
        } catch {
            return .unreadable
        }

        let keysToClear = ["oauth:tokenCache"]
        var changed = false
        for k in keysToClear where json[k] != nil {
            json.removeValue(forKey: k)
            changed = true
        }
        guard changed else {
            try clearDesktopCookies(in: desktopDir)
            return .nothingToClear
        }

        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: configURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: configURL)
            try handle.synchronize()
            try handle.close()
        } catch {
            return .unreadable
        }

        try clearDesktopCookies(in: desktopDir)
        return .cleared
    }

    /// Reset the web session — the OAuth callback drops a cookie that would
    /// let Claude Desktop silently re-auth on next launch.
    private func clearDesktopCookies(in desktopDir: URL) throws {
        let cookies = desktopDir.appendingPathComponent("Cookies")
        if FileManager.default.fileExists(atPath: cookies.path) {
            try FileManager.default.removeItem(at: cookies)
        }
        let cookiesJournal = desktopDir.appendingPathComponent("Cookies-journal")
        if FileManager.default.fileExists(atPath: cookiesJournal.path) {
            try FileManager.default.removeItem(at: cookiesJournal)
        }
    }

    // MARK: - Copy configuration between profiles

    /// Which categories the copy sheet can offer for this source profile.
    public func copyConfigAvailability(source: Profile) -> Set<CopyCategory> {
        configCopy.availableCategories(
            sourceCLI: store.cliDirectory(source),
            sourceDesktop: layout.desktopDirectory(for: source, activeProfileID: store.activeProfileID))
    }

    /// Read-only dry run. Deliberately does NOT quit Claude Desktop — planning
    /// never mutates anything.
    public func copyConfigPlan(
        from source: Profile, to target: Profile,
        categories: Set<CopyCategory>, mode: CopyMode
    ) throws -> CopyPlan {
        guard source.id != target.id else { throw ConfigCopyError.sourceEqualsTarget }
        guard store.profiles.contains(where: { $0.id == source.id }),
            store.profiles.contains(where: { $0.id == target.id })
        else { throw ProfileError.profileNotFound }
        return try configCopy.plan(
            sourceCLI: store.cliDirectory(source),
            sourceDesktop: layout.desktopDirectory(for: source, activeProfileID: store.activeProfileID),
            targetCLI: store.cliDirectory(target),
            targetDesktop: layout.desktopDirectory(for: target, activeProfileID: store.activeProfileID),
            categories: categories, mode: mode)
    }

    /// Apply a copy plan. Quits Claude Desktop first only when the plan will
    /// mutate desktop files of the ACTIVE profile while Desktop is running
    /// (it caches its config at launch — same constraint as switching).
    public func performConfigCopy(
        _ plan: CopyPlan,
        resolutions: [CopyItem.ID: ConflictResolution],
        from source: Profile, to target: Profile
    ) async throws -> CopySummary {
        if plan.mutatesDesktop, store.activeProfileID == target.id, claudeApp.isClaudeRunning {
            guard await claudeApp.quitClaude() else { throw ProfileLayoutError.desktopStillRunning }
        }
        // The service is Sendable and pure I/O — hop off the main actor.
        let service = configCopy
        let summary = try await Task.detached(priority: .userInitiated) {
            try service.execute(plan, resolutions: resolutions)
        }.value
        store.appendLog(
            "copyconfig: \(source.name) -> \(target.name) "
                + "(\(summary.copied.count) copied, \(summary.trashed.count) trashed, mode \(plan.mode.rawValue))")
        return summary
    }

    /// Open a fresh Terminal window running the resolved `claude` binary.
    /// Claude Code will detect the missing credentials and prompt for /login
    /// on its own.
    ///
    /// Using the absolute path (instead of relying on the Terminal session's
    /// PATH) makes "command not found" impossible. Failures — most notably the
    /// user denying the Automation permission — are thrown, not logged.
    private func openTerminalForCLILogin(claudePath: URL, configDirectory: URL) async throws {
        let script = Self.cliLoginScript(claudePath: claudePath, configDirectory: configDirectory)
        let result = await Self.runOSAScript(script)
        if let error = Self.mapOSAScriptFailure(status: result.status, stderr: result.stderr) {
            throw error
        }
    }

    /// Pure helper (unit-tested): the AppleScript for the CLI login window.
    /// The path is single-quoted for the shell, then escaped for the
    /// AppleScript string literal.
    static func cliLoginScript(claudePath: URL, configDirectory: URL? = nil) -> String {
        let shellQuoted = "'" + claudePath.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let configPrefix: String
        if let configDirectory {
            let quoted = "'" + configDirectory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            configPrefix = "env CLAUDE_CONFIG_DIR=\(quoted) "
        } else {
            configPrefix = ""
        }
        let appleScriptEscaped =
            (configPrefix + shellQuoted + " auth login")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped)"
            end tell
            """
    }

    /// Removes the unsafe legacy global keychain context. The migration UI
    /// invokes this only after the user has closed legacy Claude Code sessions.
    public func logoutLegacyGlobalCLI() async throws {
        try preflightLegacyCLIProcesses()
        try await claudeCodeRunner.logout(configDirectory: nil)
        store.appendLog("migration-v2: logged out legacy global Claude Code context")
    }

    private func preflightLegacyCLIProcesses() throws {
        // Test harnesses inject temporary canonical paths and must never inspect
        // or affect the developer's real sessions.
        guard cliCanonicalPath.standardizedFileURL == ProfileStore.claudeCLIPath.standardizedFileURL else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-U", "\(getuid())", "-x", "claude"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { throw ProfileLayoutError.legacyCLIStillRunning }
        } catch let error as ProfileLayoutError {
            throw error
        } catch {
            throw ProfileError.migrationConflict(
                "Could not verify whether legacy Claude Code sessions are running: \(error.localizedDescription)")
        }
    }

    /// Pure helper (unit-tested): map an osascript failure to a SignInError.
    /// Returns nil for success. Error -1743 is "Not authorized to send Apple
    /// events" — the user declined the Automation permission prompt.
    static func mapOSAScriptFailure(status: Int32, stderr: String) -> SignInError? {
        guard status != 0 else { return nil }
        if stderr.contains("-1743")
            || stderr.localizedCaseInsensitiveContains("not authorized")
            || stderr.localizedCaseInsensitiveContains("not allowed to send")
        {
            return .terminalAutomationDenied
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .terminalLaunchFailed(trimmed.isEmpty ? "osascript exited with status \(status)" : trimmed)
    }

    /// Run an AppleScript via osascript off the main actor, capturing exit
    /// status and stderr. The generous timeout leaves room for the one-time
    /// macOS Automation permission prompt, which blocks the Apple event until
    /// the user responds.
    nonisolated private static func runOSAScript(
        _ script: String,
        timeout: TimeInterval = 60
    ) async -> (status: Int32, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]
                task.standardOutput = Pipe()
                let errPipe = Pipe()
                task.standardError = errPipe

                var timedOut = false
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
                timer.schedule(deadline: .now() + timeout)
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
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                timer.cancel()

                let stderr = String(data: data, encoding: .utf8) ?? ""
                if timedOut {
                    continuation.resume(
                        returning: (-1, "Timed out waiting for Terminal — check for a pending permission prompt."))
                    return
                }
                continuation.resume(returning: (task.terminationStatus, stderr))
            }
        }
    }
}
