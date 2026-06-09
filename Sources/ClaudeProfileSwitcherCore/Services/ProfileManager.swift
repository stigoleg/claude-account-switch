import AppKit
import Foundation

public enum MigrationState: Equatable {
    case notNeeded  // both canonical paths are already symlinks (or absent)
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
        configCopy: ConfigCopyService = ConfigCopyService(),
        cliCanonicalPath: URL = ProfileStore.claudeCLIPath,
        desktopCanonicalPath: URL = ProfileStore.claudeDesktopPath
    ) {
        self.store = store
        self.symlinks = symlinks
        self.claudeApp = claudeApp
        self.surfaceLocator = surfaceLocator
        self.configCopy = configCopy
        self.credentials = CredentialsInspector(store: store)
        self.cliCanonicalPath = cliCanonicalPath
        self.desktopCanonicalPath = desktopCanonicalPath
    }

    // MARK: - Migration

    /// Inspect the canonical paths and report whether first-run migration is needed.
    public func migrationState() -> MigrationState {
        let cliReal = symlinks.itemExists(cliCanonicalPath) && !symlinks.isSymlink(cliCanonicalPath)
        let desktopReal = symlinks.itemExists(desktopCanonicalPath) && !symlinks.isSymlink(desktopCanonicalPath)
        if !cliReal && !desktopReal { return .notNeeded }
        return .needed(cliRealDir: cliReal, desktopRealDir: desktopReal)
    }

    /// Move existing real directories into a freshly-created "default" profile and
    /// replace the originals with symlinks. Idempotent — safe to call again later;
    /// it just won't do anything if both paths are already symlinks.
    ///
    /// **Atomicity**: both destination conflicts are checked before any data is
    /// moved. If an I/O failure still hits the Desktop half after the CLI half
    /// committed (or the symlink flip fails after a move), the completed steps
    /// are undone in reverse so the user can retry from a clean state.
    public func runFirstRunMigration(profileName: String = "default") throws {
        // Reuse an existing "default" profile if the user already created one.
        let existing = store.profiles.first { $0.name.lowercased() == profileName.lowercased() }
        let profile = existing ?? Profile(name: profileName)
        let cliDst = store.cliDirectory(profile)
        let desktopDst = store.desktopDirectory(profile)

        let cliIsReal = symlinks.itemExists(cliCanonicalPath) && !symlinks.isSymlink(cliCanonicalPath)
        let desktopIsReal = symlinks.itemExists(desktopCanonicalPath) && !symlinks.isSymlink(desktopCanonicalPath)

        // Preflight both halves before touching anything so a conflict on the
        // Desktop side can't surface after the CLI side already moved data.
        if cliIsReal, symlinks.itemExists(cliDst) {
            throw ProfileError.migrationConflict(
                "\(cliDst.path) already exists. Move it aside and try again.")
        }
        if desktopIsReal, symlinks.itemExists(desktopDst) {
            throw ProfileError.migrationConflict(
                "\(desktopDst.path) already exists. Move it aside and try again.")
        }

        try symlinks.ensureDirectory(store.profileDirectory(profile))

        // CLI half — record prior state so any later failure can undo it.
        let prevCLISymlinkTarget = symlinks.symlinkDestination(cliCanonicalPath)
        var cliWasMoved = false
        func rollbackCLI() {
            if cliWasMoved {
                try? symlinks.removeSymlink(at: cliCanonicalPath)
                try? symlinks.moveDirectory(from: cliDst, to: cliCanonicalPath)
            } else if let prevCLISymlinkTarget {
                try? symlinks.replaceSymlink(at: cliCanonicalPath, pointingTo: prevCLISymlinkTarget)
            } else {
                // Canonical path was absent before — restore "absent".
                try? symlinks.removeSymlink(at: cliCanonicalPath)
            }
        }

        if cliIsReal {
            try symlinks.moveDirectory(from: cliCanonicalPath, to: cliDst)
            cliWasMoved = true
        } else if !symlinks.itemExists(cliDst) {
            try symlinks.ensureDirectory(cliDst)
        }
        do {
            try symlinks.replaceSymlink(at: cliCanonicalPath, pointingTo: cliDst)
        } catch {
            rollbackCLI()
            throw ProfileError.migrationConflict(
                "Migration failed and was rolled back: \(error.localizedDescription)")
        }

        // Desktop half — on failure, undo it and the CLI half.
        var desktopWasMoved = false
        do {
            if desktopIsReal {
                try symlinks.moveDirectory(from: desktopCanonicalPath, to: desktopDst)
                desktopWasMoved = true
            } else if !symlinks.itemExists(desktopDst) {
                try symlinks.ensureDirectory(desktopDst)
            }
            try symlinks.replaceSymlink(at: desktopCanonicalPath, pointingTo: desktopDst)
        } catch {
            if desktopWasMoved, !symlinks.itemExists(desktopCanonicalPath) {
                try? symlinks.moveDirectory(from: desktopDst, to: desktopCanonicalPath)
            }
            rollbackCLI()
            throw ProfileError.migrationConflict(
                "Migration failed and was rolled back: \(error.localizedDescription)")
        }

        if existing == nil { store.upsert(profile) }
        store.setActive(profile)
        store.appendLog("migration: moved into profile \(profile.name) (\(profile.id))")
    }

    /// The inverse of `runFirstRunMigration`. Removes the symlinks at the
    /// canonical paths and moves the chosen profile's CLI and Desktop
    /// directories back into place. After this, Claude reads/writes the real
    /// directories directly again — the app is "out of the way."
    ///
    /// The profile entry is **not** deleted; the user can re-migrate later.
    /// We also clear `activeProfileID` so the UI reflects "no active profile"
    /// and the first-run migration sheet appears again on next launch.
    ///
    /// **Atomicity**: pre-flight checks reject before any mutation. If the
    /// Desktop half fails after the CLI half succeeded, we roll the CLI back
    /// into the profile dir so the user is never left half-restored. Worst
    /// case the user sees a clear error and can retry.
    public func disableAndRestore(targetProfile: Profile) async throws {
        guard store.profiles.contains(where: { $0.id == targetProfile.id }) else {
            throw ProfileError.profileNotFound
        }

        let cliCanonical = cliCanonicalPath
        let desktopCanonical = desktopCanonicalPath
        let cliSrc = store.cliDirectory(targetProfile)
        let desktopSrc = store.desktopDirectory(targetProfile)

        // Pre-flight: both canonical paths must be either absent or symlinks,
        // and the profile source dirs must exist (otherwise we have nothing
        // to restore and the user is probably looking at the wrong profile).
        try preflightRestore(canonicalPaths: [cliCanonical, desktopCanonical])

        if claudeApp.isClaudeRunning {
            _ = await claudeApp.quitClaude()
        }

        // CLI side.
        let originalCLISymlinkTarget = symlinks.symlinkDestination(cliCanonical)
        if symlinks.isSymlink(cliCanonical) {
            try symlinks.removeSymlink(at: cliCanonical)
        }
        let cliWasMoved = symlinks.itemExists(cliSrc)
        if cliWasMoved {
            try symlinks.moveDirectory(from: cliSrc, to: cliCanonical)
        }

        // Desktop side. If anything below throws, undo the CLI half so the
        // user can retry from a clean state.
        do {
            if symlinks.isSymlink(desktopCanonical) {
                try symlinks.removeSymlink(at: desktopCanonical)
            }
            if symlinks.itemExists(desktopSrc) {
                try symlinks.moveDirectory(from: desktopSrc, to: desktopCanonical)
            }
        } catch {
            // Roll CLI back.
            if cliWasMoved, symlinks.itemExists(cliCanonical), !symlinks.isSymlink(cliCanonical) {
                try? symlinks.moveDirectory(from: cliCanonical, to: cliSrc)
            }
            if let target = originalCLISymlinkTarget {
                try? symlinks.replaceSymlink(at: cliCanonical, pointingTo: target)
            }
            throw ProfileError.migrationConflict(
                "Desktop restore failed and the CLI half was rolled back: \(error.localizedDescription)")
        }

        store.clearActive()
        store.appendLog("restore: \(targetProfile.name) (\(targetProfile.id))")
    }

    /// Verifies that the canonical paths are either absent or symlinks before
    /// we touch anything. Throws a clear error if a real directory is in the
    /// way — that means the user already has Claude data outside this app and
    /// removing it could destroy work.
    private func preflightRestore(canonicalPaths: [URL]) throws {
        for path in canonicalPaths {
            if symlinks.itemExists(path), !symlinks.isSymlink(path) {
                throw ProfileError.migrationConflict(
                    "\(path.path) is a real directory, not a symlink — refusing to overwrite. Resolve manually first.")
            }
        }
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
        if store.profiles.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            throw ProfileError.nameTaken(trimmed)
        }
        let profile = Profile(name: trimmed)
        try symlinks.ensureDirectory(store.cliDirectory(profile))
        try symlinks.ensureDirectory(store.desktopDirectory(profile))
        store.upsert(profile)
        store.appendLog("create: \(profile.name) (\(profile.id))")
        return profile
    }

    /// Change the display color of a profile. Persists immediately so the
    /// sync layer can pick it up; the iCloud merge treats this like any other
    /// edit (last-writer-wins on `updatedAt`).
    public func setColor(_ profile: Profile, hex: String) {
        var updated = profile
        updated.colorHex = hex
        store.upsert(updated)
        store.appendLog("color: \(profile.id) -> \(hex)")
    }

    public func rename(_ profile: Profile, to newName: String) throws {
        let trimmed = try Self.normalizeProfileName(newName)
        if store.profiles.contains(where: { $0.id != profile.id && $0.name.lowercased() == trimmed.lowercased() }) {
            throw ProfileError.nameTaken(trimmed)
        }
        store.renameProfile(profile, to: trimmed)
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
        store.remove(profile)
        store.appendLog("delete: \(profile.name) (\(profile.id))")
    }

    // MARK: - Switch

    /// Switch the active profile. Quits Claude Desktop first; relaunches when requested.
    public func switchTo(_ profile: Profile, relaunchDesktop: Bool) async throws {
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileError.profileNotFound
        }
        if store.activeProfileID == profile.id { return }

        let cliDst = store.cliDirectory(profile)
        let desktopDst = store.desktopDirectory(profile)
        try symlinks.ensureDirectory(cliDst)
        try symlinks.ensureDirectory(desktopDst)

        let wasRunning = claudeApp.isClaudeRunning
        if wasRunning {
            _ = await claudeApp.quitClaude()
        }

        // Capture previous targets so we can roll back the symlinks if the second
        // swap fails midway through.
        let prevCLI = symlinks.symlinkDestination(cliCanonicalPath)
        let prevDesktop = symlinks.symlinkDestination(desktopCanonicalPath)

        do {
            try symlinks.replaceSymlink(at: cliCanonicalPath, pointingTo: cliDst)
            try symlinks.replaceSymlink(at: desktopCanonicalPath, pointingTo: desktopDst)
        } catch {
            // Best-effort rollback. When no previous target was captured the
            // canonical path was absent before the switch — restore "absent"
            // rather than leaving a half-flipped pair behind.
            if let prevCLI {
                try? symlinks.replaceSymlink(at: cliCanonicalPath, pointingTo: prevCLI)
            } else if symlinks.isSymlink(cliCanonicalPath) {
                try? symlinks.removeSymlink(at: cliCanonicalPath)
            }
            if let prevDesktop {
                try? symlinks.replaceSymlink(at: desktopCanonicalPath, pointingTo: prevDesktop)
            } else if symlinks.isSymlink(desktopCanonicalPath) {
                try? symlinks.removeSymlink(at: desktopCanonicalPath)
            }
            throw error
        }

        store.setActive(profile)
        store.appendLog("switch: -> \(profile.name) (\(profile.id))")

        if relaunchDesktop, wasRunning {
            // The switch itself is already committed at this point — a relaunch
            // failure must not read as a failed switch. Rethrow the dedicated
            // error so the UI can say "switched, but Desktop didn't relaunch".
            try await claudeApp.launchClaude()
        }
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

        if store.activeProfileID != profile.id {
            try await switchTo(profile, relaunchDesktop: false)
        }

        switch method {
        case .desktop:
            try await runDesktopSignIn(profile: profile, timeout: timeout, phase: phase)
        case .cli:
            phase?(.launchingCLI)
            try await openTerminalForCLILogin(claudePath: cliPath!)
        // CLI auth lives in the keychain; we can't reliably detect when the
        // user has completed `/login`, so don't block here.
        case .both:
            try await runDesktopSignIn(profile: profile, timeout: timeout, phase: phase)
            phase?(.launchingCLI)
            try await openTerminalForCLILogin(claudePath: cliPath!)
        // Don't poll for CLI; see above.
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
            _ = await claudeApp.quitClaude()
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
            let status = credentials.status(for: profile)
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
            _ = await claudeApp.quitClaude()
        }

        if surfaces.contains(.desktop) {
            if clearDesktopOAuthToken(in: store.desktopDirectory(profile)) == .unreadable {
                throw ProfileError.migrationConflict(
                    "Couldn't sign out Desktop: this profile's config.json is unreadable. Delete it manually (or re-sign-in first), then retry."
                )
            }
        }

        if surfaces.contains(.cli) {
            for url in credentials.credentialFiles(for: profile, surface: .cli) {
                try? FileManager.default.removeItem(at: url)
            }
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
    private func clearDesktopOAuthToken(in desktopDir: URL) -> DesktopClearResult {
        let configURL = desktopDir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            clearDesktopCookies(in: desktopDir)
            return .nothingToClear
        }
        guard let data = try? Data(contentsOf: configURL),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }

        let keysToClear = ["oauth:tokenCache"]
        var changed = false
        for k in keysToClear where json[k] != nil {
            json.removeValue(forKey: k)
            changed = true
        }
        guard changed else {
            clearDesktopCookies(in: desktopDir)
            return .nothingToClear
        }

        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
            (try? out.write(to: configURL, options: .atomic)) != nil
        else { return .unreadable }

        clearDesktopCookies(in: desktopDir)
        return .cleared
    }

    /// Reset the web session — the OAuth callback drops a cookie that would
    /// let Claude Desktop silently re-auth on next launch.
    private func clearDesktopCookies(in desktopDir: URL) {
        let cookies = desktopDir.appendingPathComponent("Cookies")
        try? FileManager.default.removeItem(at: cookies)
        let cookiesJournal = desktopDir.appendingPathComponent("Cookies-journal")
        try? FileManager.default.removeItem(at: cookiesJournal)
    }

    // MARK: - Copy configuration between profiles

    /// Which categories the copy sheet can offer for this source profile.
    public func copyConfigAvailability(source: Profile) -> Set<CopyCategory> {
        configCopy.availableCategories(
            sourceCLI: store.cliDirectory(source),
            sourceDesktop: store.desktopDirectory(source))
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
            sourceDesktop: store.desktopDirectory(source),
            targetCLI: store.cliDirectory(target),
            targetDesktop: store.desktopDirectory(target),
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
            _ = await claudeApp.quitClaude()
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
    private func openTerminalForCLILogin(claudePath: URL) async throws {
        let script = Self.cliLoginScript(claudePath: claudePath)
        let result = await Self.runOSAScript(script)
        if let error = Self.mapOSAScriptFailure(status: result.status, stderr: result.stderr) {
            throw error
        }
    }

    /// Pure helper (unit-tested): the AppleScript for the CLI login window.
    /// The path is single-quoted for the shell, then escaped for the
    /// AppleScript string literal.
    static func cliLoginScript(claudePath: URL) -> String {
        let shellQuoted = "'" + claudePath.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let appleScriptEscaped =
            shellQuoted
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped)"
            end tell
            """
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
