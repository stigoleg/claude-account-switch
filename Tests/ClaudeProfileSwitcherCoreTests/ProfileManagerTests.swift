import XCTest

@testable import ClaudeProfileSwitcherCore

/// Wraps the real `SymlinkService` and fails the Nth `replaceSymlink` call so
/// rollback paths in `ProfileManager` can be exercised deterministically.
private final class FailingSymlinkService: SymlinkServicing {
    struct InjectedError: LocalizedError {
        var errorDescription: String? { "injected failure" }
    }

    private let inner = SymlinkService()
    /// 1-based index of the `replaceSymlink` call that should throw.
    var failOnReplaceCall: Int?
    private(set) var replaceCalls = 0

    func isSymlink(_ url: URL) -> Bool { inner.isSymlink(url) }
    func symlinkDestination(_ url: URL) -> URL? { inner.symlinkDestination(url) }
    func itemExists(_ url: URL) -> Bool { inner.itemExists(url) }
    func removeSymlink(at path: URL) throws { try inner.removeSymlink(at: path) }
    func moveDirectory(from src: URL, to dst: URL) throws { try inner.moveDirectory(from: src, to: dst) }
    func ensureDirectory(_ url: URL) throws { try inner.ensureDirectory(url) }
    func trashProfileDirectory(_ url: URL) throws { try inner.trashProfileDirectory(url) }
    func sweepStaleTempLinks(siblingsOf url: URL) { inner.sweepStaleTempLinks(siblingsOf: url) }

    func replaceSymlink(at path: URL, pointingTo destination: URL) throws {
        replaceCalls += 1
        if replaceCalls == failOnReplaceCall { throw InjectedError() }
        try inner.replaceSymlink(at: path, pointingTo: destination)
    }
}

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var fm: FileManager { .default }

    /// Sets up a fully tmp-rooted manager whose canonical paths point inside
    /// the tmp tree, so migration tests can't touch real `~/.claude`. A
    /// `FakeClaudeAppController` is always injected so tests can never quit or
    /// force-kill the developer's real Claude Desktop app.
    private func makeHarness(
        symlinks: any SymlinkServicing = SymlinkService()
    ) throws -> (ProfileManager, ProfileStore, URL, () -> Void) {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support", isDirectory: true))
        store.load()

        let cliCanonical = tmp.appendingPathComponent("home/.claude", isDirectory: true)
        let desktopCanonical = tmp.appendingPathComponent("home/Library/Application Support/Claude", isDirectory: true)
        try fm.createDirectory(at: cliCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktopCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)

        let manager = ProfileManager(
            store: store,
            symlinks: symlinks,
            claudeApp: FakeClaudeAppController(),
            cliCanonicalPath: cliCanonical,
            desktopCanonicalPath: desktopCanonical
        )
        return (manager, store, tmp, cleanup)
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testMigrationThenRestoreRoundTrip() async throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        // Seed the canonical paths with sentinel files representing the user's
        // existing Claude data.
        try writeFile(
            manager.cliCanonicalPath.appendingPathComponent("settings.json"),
            contents: "{\"cli\":true}")
        try writeFile(
            manager.desktopCanonicalPath.appendingPathComponent("config.json"),
            contents: "{\"oauth:tokenCache\":\"existing\"}")

        XCTAssertEqual(manager.migrationState(), .needed(cliRealDir: true, desktopRealDir: true))

        try manager.runFirstRunMigration()

        // After migration: canonical paths are symlinks, profile dir holds the data.
        XCTAssertTrue(manager.symlinks.isSymlink(manager.cliCanonicalPath))
        XCTAssertTrue(manager.symlinks.isSymlink(manager.desktopCanonicalPath))
        XCTAssertEqual(manager.migrationState(), .notNeeded)
        guard let active = store.activeProfile else {
            return XCTFail("active profile should be set")
        }

        let cliSentinel = store.cliDirectory(active).appendingPathComponent("settings.json")
        XCTAssertEqual(try String(contentsOf: cliSentinel, encoding: .utf8), "{\"cli\":true}")

        try await manager.disableAndRestore(targetProfile: active)

        // After restore: symlinks gone, real dirs back with content, no active profile.
        XCTAssertFalse(manager.symlinks.isSymlink(manager.cliCanonicalPath))
        XCTAssertFalse(manager.symlinks.isSymlink(manager.desktopCanonicalPath))
        XCTAssertTrue(manager.symlinks.itemExists(manager.cliCanonicalPath))
        XCTAssertTrue(manager.symlinks.itemExists(manager.desktopCanonicalPath))
        XCTAssertNil(store.activeProfileID)
        XCTAssertEqual(store.profiles.count, 1, "profile entry should not be deleted")
        XCTAssertEqual(manager.migrationState(), .needed(cliRealDir: true, desktopRealDir: true))

        let restored = try String(
            contentsOf: manager.cliCanonicalPath.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        XCTAssertEqual(restored, "{\"cli\":true}")
    }

    func testDisableAndRestoreIsIdempotent() async throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        try writeFile(manager.cliCanonicalPath.appendingPathComponent("a"), contents: "x")
        try writeFile(manager.desktopCanonicalPath.appendingPathComponent("b"), contents: "y")
        try manager.runFirstRunMigration()
        guard let active = store.activeProfile else { return XCTFail("no active") }

        try await manager.disableAndRestore(targetProfile: active)

        // Second call should throw cleanly (the profile is no longer active and
        // the canonical paths are real dirs).
        do {
            try await manager.disableAndRestore(targetProfile: active)
            XCTFail("second disableAndRestore should throw")
        } catch {
            // Expected: pre-flight rejects because canonical paths are real dirs.
            XCTAssertTrue(
                error.localizedDescription.contains("real directory"),
                "expected a pre-flight error, got: \(error.localizedDescription)")
        }

        // Real data must still be at the canonical paths.
        XCTAssertTrue(manager.symlinks.itemExists(manager.cliCanonicalPath))
        XCTAssertTrue(manager.symlinks.itemExists(manager.desktopCanonicalPath))
    }

    func testPreflightRejectsRealDirectoryAtCanonicalPath() async throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        // Seed migration so we have an active profile.
        try writeFile(manager.cliCanonicalPath.appendingPathComponent("seed"), contents: "x")
        try writeFile(manager.desktopCanonicalPath.appendingPathComponent("seed"), contents: "x")
        try manager.runFirstRunMigration()
        guard let active = store.activeProfile else { return XCTFail("no active") }

        // Replace the CLI symlink with a real directory (simulating the user
        // manually `rm`+`mkdir` outside the app).
        try manager.symlinks.removeSymlink(at: manager.cliCanonicalPath)
        try fm.createDirectory(at: manager.cliCanonicalPath, withIntermediateDirectories: true)
        try "manual".write(
            to: manager.cliCanonicalPath.appendingPathComponent("note"),
            atomically: true,
            encoding: .utf8
        )

        do {
            try await manager.disableAndRestore(targetProfile: active)
            XCTFail("disableAndRestore should reject when canonical path is a real dir")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("real directory"))
        }

        // Manual data must be untouched.
        let note = try String(
            contentsOf: manager.cliCanonicalPath.appendingPathComponent("note"),
            encoding: .utf8
        )
        XCTAssertEqual(note, "manual")
        // Active profile should still be set — we never got to clearActive.
        XCTAssertEqual(store.activeProfileID, active.id)
    }

    // MARK: - Migration rollback

    func testMigrationRollsBackCLIWhenDesktopSymlinkFails() throws {
        let failing = FailingSymlinkService()
        let (manager, store, _, cleanup) = try makeHarness(symlinks: failing)
        defer { cleanup() }

        try writeFile(
            manager.cliCanonicalPath.appendingPathComponent("settings.json"),
            contents: "{\"cli\":true}")
        try writeFile(
            manager.desktopCanonicalPath.appendingPathComponent("config.json"),
            contents: "{\"desktop\":true}")

        // Migration calls replaceSymlink twice: CLI first, Desktop second.
        failing.failOnReplaceCall = 2

        XCTAssertThrowsError(try manager.runFirstRunMigration()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("rolled back"),
                "expected rollback message, got: \(error.localizedDescription)")
        }

        // Both canonical paths must be real directories again with their data.
        XCTAssertFalse(manager.symlinks.isSymlink(manager.cliCanonicalPath))
        XCTAssertFalse(manager.symlinks.isSymlink(manager.desktopCanonicalPath))
        XCTAssertEqual(
            try String(
                contentsOf: manager.cliCanonicalPath.appendingPathComponent("settings.json"),
                encoding: .utf8),
            "{\"cli\":true}")
        XCTAssertEqual(
            try String(
                contentsOf: manager.desktopCanonicalPath.appendingPathComponent("config.json"),
                encoding: .utf8),
            "{\"desktop\":true}")

        XCTAssertNil(store.activeProfileID)
        XCTAssertEqual(manager.migrationState(), .needed(cliRealDir: true, desktopRealDir: true))

        // The migration must be retryable after the failure is gone.
        failing.failOnReplaceCall = nil
        try manager.runFirstRunMigration()
        XCTAssertEqual(manager.migrationState(), .notNeeded)
        XCTAssertNotNil(store.activeProfileID)
    }

    func testMigrationRollsBackWhenCLISymlinkFails() throws {
        let failing = FailingSymlinkService()
        let (manager, store, _, cleanup) = try makeHarness(symlinks: failing)
        defer { cleanup() }

        try writeFile(
            manager.cliCanonicalPath.appendingPathComponent("settings.json"),
            contents: "{\"cli\":true}")
        try writeFile(
            manager.desktopCanonicalPath.appendingPathComponent("config.json"),
            contents: "{\"desktop\":true}")

        failing.failOnReplaceCall = 1

        XCTAssertThrowsError(try manager.runFirstRunMigration())

        // CLI data must be back at the canonical path; Desktop untouched.
        XCTAssertEqual(
            try String(
                contentsOf: manager.cliCanonicalPath.appendingPathComponent("settings.json"),
                encoding: .utf8),
            "{\"cli\":true}")
        XCTAssertEqual(manager.migrationState(), .needed(cliRealDir: true, desktopRealDir: true))
        XCTAssertNil(store.activeProfileID)
    }

    func testMigrationPreflightRejectsDesktopConflictBeforeMutating() throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        try writeFile(
            manager.cliCanonicalPath.appendingPathComponent("settings.json"),
            contents: "{\"cli\":true}")
        try writeFile(
            manager.desktopCanonicalPath.appendingPathComponent("config.json"),
            contents: "{\"desktop\":true}")

        // Pre-create a conflicting Desktop destination inside the would-be
        // "default" profile. The profile ID isn't known up front, so create the
        // profile first and seed its desktop dir. Remove the profile's CLI dir
        // so only the Desktop side conflicts — the bug being guarded against
        // was a Desktop conflict surfacing after the CLI half already moved.
        let profile = try manager.createProfile(name: "default")
        try writeFile(store.desktopDirectory(profile).appendingPathComponent("stale"), contents: "x")
        try fm.removeItem(at: store.cliDirectory(profile))

        XCTAssertThrowsError(try manager.runFirstRunMigration()) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        // Nothing may have moved: both canonical paths are still real dirs.
        XCTAssertFalse(manager.symlinks.isSymlink(manager.cliCanonicalPath))
        XCTAssertEqual(
            try String(
                contentsOf: manager.cliCanonicalPath.appendingPathComponent("settings.json"),
                encoding: .utf8),
            "{\"cli\":true}")
        XCTAssertNil(store.activeProfileID)
    }

    // MARK: - Switch rollback

    func testSwitchRollbackRestoresAbsentCanonicalPaths() async throws {
        let failing = FailingSymlinkService()
        let (manager, store, _, cleanup) = try makeHarness(symlinks: failing)
        defer { cleanup() }

        // No migration: canonical paths start absent (fresh machine, profiles only).
        let profile = try manager.createProfile(name: "work")

        // switchTo calls replaceSymlink twice (CLI, Desktop); fail the second.
        failing.failOnReplaceCall = 2

        do {
            try await manager.switchTo(profile, relaunchDesktop: false)
            XCTFail("switchTo should rethrow the injected failure")
        } catch {
            // expected
        }

        // The CLI symlink created by the first call must be removed again —
        // not left dangling as a half-flipped pair.
        XCTAssertFalse(manager.symlinks.itemExists(manager.cliCanonicalPath))
        XCTAssertFalse(manager.symlinks.itemExists(manager.desktopCanonicalPath))
        XCTAssertNil(store.activeProfileID)
    }

    // MARK: - Sign-out

    func testDesktopSignOutClearsToken() async throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        let profile = try manager.createProfile(name: "p")
        let config = store.desktopDirectory(profile).appendingPathComponent("config.json")
        try #"{"oauth:tokenCache":"tok","other":"kept"}"#.write(to: config, atomically: true, encoding: .utf8)

        try await manager.signOut(profile, surfaces: [.desktop])

        let json =
            try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        XCTAssertNil(json?["oauth:tokenCache"], "token must be removed")
        XCTAssertEqual(json?["other"] as? String, "kept", "unrelated keys must survive")
    }

    func testDesktopSignOutThrowsOnUnreadableConfig() async throws {
        let (manager, store, _, cleanup) = try makeHarness()
        defer { cleanup() }

        let profile = try manager.createProfile(name: "p")
        let config = store.desktopDirectory(profile).appendingPathComponent("config.json")
        try "not json {{{".write(to: config, atomically: true, encoding: .utf8)

        do {
            try await manager.signOut(profile, surfaces: [.desktop])
            XCTFail("sign-out must not silently skip an unreadable config.json")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unreadable"))
        }
        // The corrupt file must be left in place for the user to inspect.
        XCTAssertTrue(fm.fileExists(atPath: config.path))
    }

    // MARK: - Copy configuration orchestration

    /// Variant harness that exposes the fake Desktop controller for quit-count
    /// assertions.
    private func makeCopyHarness() throws -> (
        manager: ProfileManager, store: ProfileStore, claudeApp: FakeClaudeAppController,
        cleanup: () -> Void
    ) {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support", isDirectory: true))
        store.load()
        let cliCanonical = tmp.appendingPathComponent("home/.claude", isDirectory: true)
        let desktopCanonical = tmp.appendingPathComponent(
            "home/Library/Application Support/Claude", isDirectory: true)
        try fm.createDirectory(at: cliCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: desktopCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        let claudeApp = FakeClaudeAppController()
        let manager = ProfileManager(
            store: store,
            claudeApp: claudeApp,
            cliCanonicalPath: cliCanonical,
            desktopCanonicalPath: desktopCanonical
        )
        return (manager, store, claudeApp, cleanup)
    }

    func testCopyConfigRefusesSameProfile() throws {
        let h = try makeCopyHarness()
        defer { h.cleanup() }
        let p = try h.manager.createProfile(name: "only")
        XCTAssertThrowsError(
            try h.manager.copyConfigPlan(from: p, to: p, categories: [.cliSettings], mode: .merge)
        ) { error in
            guard case ConfigCopyError.sourceEqualsTarget = error else {
                return XCTFail("expected sourceEqualsTarget, got \(error)")
            }
        }
    }

    func testCopyConfigPlanNeverQuitsDesktop() throws {
        let h = try makeCopyHarness()
        defer { h.cleanup() }
        let source = try h.manager.createProfile(name: "src")
        let target = try h.manager.createProfile(name: "tgt")
        h.claudeApp.isClaudeRunning = true

        try "{}".write(
            to: h.store.desktopDirectory(source).appendingPathComponent("claude_desktop_config.json"),
            atomically: true, encoding: .utf8)
        _ = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.desktopMCPAndConfig], mode: .merge)
        XCTAssertEqual(h.claudeApp.quitCalls, 0, "planning is read-only and must never quit Desktop")
    }

    func testPerformCopyQuitsDesktopOnlyWhenTargetActiveAndDesktopMutates() async throws {
        let h = try makeCopyHarness()
        defer { h.cleanup() }
        let source = try h.manager.createProfile(name: "src")
        let target = try h.manager.createProfile(name: "tgt")
        try #"{"mcpServers":{"s":{"command":"x"}}}"#.write(
            to: h.store.desktopDirectory(source).appendingPathComponent("claude_desktop_config.json"),
            atomically: true, encoding: .utf8)

        // Case 1: target NOT active → no quit even though Desktop runs.
        h.claudeApp.isClaudeRunning = true
        var plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.desktopMCPAndConfig], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        XCTAssertEqual(h.claudeApp.quitCalls, 0)

        // Case 2: target ACTIVE + desktop mutation → quit once. Re-seed a new
        // server so the plan isn't empty (the first copy already ran).
        try #"{"mcpServers":{"s":{"command":"x"},"t":{"command":"y"}}}"#.write(
            to: h.store.desktopDirectory(source).appendingPathComponent("claude_desktop_config.json"),
            atomically: true, encoding: .utf8)
        h.store.setActive(target)
        h.claudeApp.isClaudeRunning = true
        plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.desktopMCPAndConfig], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        XCTAssertEqual(h.claudeApp.quitCalls, 1)

        // Case 3: CLI-only plan → no further quits even when active + running.
        try "skill".write(
            to: {
                let dir = h.store.cliDirectory(source).appendingPathComponent("skills/x")
                try? self.fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("SKILL.md")
            }(), atomically: true, encoding: .utf8)
        h.claudeApp.isClaudeRunning = true
        plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.cliSkillsAndCommands], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        XCTAssertEqual(h.claudeApp.quitCalls, 1, "CLI-only copy must not quit Desktop")
    }

    func testCopyConfigAppendsLog() async throws {
        let h = try makeCopyHarness()
        defer { h.cleanup() }
        let source = try h.manager.createProfile(name: "src")
        let target = try h.manager.createProfile(name: "tgt")
        try "{}".write(
            to: h.store.cliDirectory(source).appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8)

        let plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.cliSettings], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)

        let log = try String(contentsOf: h.store.logFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("copyconfig: src -> tgt"), "log was: \(log)")
    }

    // MARK: - Name validation

    func testProfileNameValidation() throws {
        let (manager, _, _, cleanup) = try makeHarness()
        defer { cleanup() }

        // Trimming still works.
        let p = try manager.createProfile(name: "  ok  ")
        XCTAssertEqual(p.name, "ok")

        XCTAssertThrowsError(try manager.createProfile(name: "   ")) { error in
            XCTAssertTrue(error is ProfileError)
        }
        XCTAssertThrowsError(try manager.createProfile(name: String(repeating: "x", count: 65))) { error in
            XCTAssertTrue(error.localizedDescription.contains("64"))
        }
        XCTAssertThrowsError(try manager.createProfile(name: "bad\u{0007}name")) { error in
            XCTAssertTrue(error.localizedDescription.contains("control characters"))
        }
        // Rename goes through the same validation.
        XCTAssertThrowsError(try manager.rename(p, to: "evil\u{0000}"))
    }
}
