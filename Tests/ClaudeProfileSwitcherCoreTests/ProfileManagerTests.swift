import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var fm: FileManager { .default }

    private struct Harness {
        let manager: ProfileManager
        let store: ProfileStore
        let claudeApp: FakeClaudeAppController
        let cleanup: () -> Void
    }

    private func makeHarness() throws -> Harness {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support", isDirectory: true))
        store.load()
        let cli = tmp.appendingPathComponent("home/.claude", isDirectory: true)
        let desktop = tmp.appendingPathComponent("home/Library/Application Support/Claude", isDirectory: true)
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        let app = FakeClaudeAppController()
        let manager = ProfileManager(
            store: store,
            claudeApp: app,
            cliCanonicalPath: cli,
            desktopCanonicalPath: desktop)
        return Harness(manager: manager, store: store, claudeApp: app, cleanup: cleanup)
    }

    private func write(_ value: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func migrateFresh(_ harness: Harness) throws -> Profile {
        try write("cli", to: harness.manager.cliCanonicalPath.appendingPathComponent("settings.json"))
        try write("desktop", to: harness.manager.desktopCanonicalPath.appendingPathComponent("config.json"))
        try harness.manager.runFirstRunMigration()
        return try XCTUnwrap(harness.store.activeProfile)
    }

    func testFreshMigrationCreatesPhysicalLayoutBackupAndRestores() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let active = try migrateFresh(h)

        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.cliCanonicalPath))
        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.desktopCanonicalPath))
        XCTAssertEqual(
            try String(contentsOf: h.store.cliDirectory(active).appendingPathComponent("settings.json")),
            "cli")
        XCTAssertEqual(
            try String(contentsOf: h.manager.desktopCanonicalPath.appendingPathComponent("config.json")),
            "desktop")
        XCTAssertEqual(h.manager.migrationState(), .notNeeded)
        let backups = h.store.supportDirectory.appendingPathComponent("Backups")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: backups.path).isEmpty)

        try await h.manager.disableAndRestore(targetProfile: active)
        XCTAssertNil(h.store.activeProfileID)
        XCTAssertEqual(
            try String(contentsOf: h.manager.cliCanonicalPath.appendingPathComponent("settings.json")),
            "cli")
        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.desktopCanonicalPath))

        try h.manager.runFirstRunMigration()
        XCTAssertEqual(h.store.activeProfileID, active.id)
        XCTAssertNil(h.store.disabledProfileID)
        XCTAssertEqual(
            try String(contentsOf: h.store.cliDirectory(active).appendingPathComponent("settings.json")),
            "cli")
    }

    func testLegacyMigrationPreservesEveryProfile() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let first = Profile(name: "Privat")
        let second = Profile(name: "Sopra Steria")
        for profile in [first, second] {
            try h.manager.layout.prepareNewProfile(profile)
            try write(profile.name, to: h.store.cliDirectory(profile).appendingPathComponent("settings.json"))
            try write(profile.name, to: h.store.desktopDirectory(profile).appendingPathComponent("config.json"))
            try h.store.upsertThrowing(profile)
        }
        try h.store.setActiveThrowing(first)
        try h.manager.symlinks.replaceSymlink(
            at: h.manager.cliCanonicalPath, pointingTo: h.store.cliDirectory(first))
        try h.manager.symlinks.replaceSymlink(
            at: h.manager.desktopCanonicalPath, pointingTo: h.store.desktopDirectory(first))

        try h.manager.runFirstRunMigration()

        XCTAssertEqual(h.store.activeProfileID, first.id)
        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.desktopCanonicalPath))
        XCTAssertEqual(
            try String(contentsOf: h.manager.desktopCanonicalPath.appendingPathComponent("config.json")),
            "Privat")
        XCTAssertEqual(
            try String(contentsOf: h.store.desktopDirectory(second).appendingPathComponent("config.json")),
            "Sopra Steria")
        XCTAssertEqual(
            try String(contentsOf: h.store.cliDirectory(first).appendingPathComponent("settings.json")),
            "Privat")
    }

    func testRestorePreV2BackupRestoresLegacyBytesIntoPhysicalLayout() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let first = Profile(name: "Privat")
        let second = Profile(name: "Sopra Steria")
        for profile in [first, second] {
            try h.manager.layout.prepareNewProfile(profile)
            try write("cli-\(profile.name)", to: h.store.cliDirectory(profile).appendingPathComponent("settings.json"))
            try write(
                "desktop-\(profile.name)",
                to: h.store.desktopDirectory(profile).appendingPathComponent("config.json"))
            try h.store.upsertThrowing(profile)
        }
        try h.store.setActiveThrowing(first)
        try h.manager.symlinks.replaceSymlink(
            at: h.manager.cliCanonicalPath, pointingTo: h.store.cliDirectory(first))
        try h.manager.symlinks.replaceSymlink(
            at: h.manager.desktopCanonicalPath, pointingTo: h.store.desktopDirectory(first))
        try h.manager.runFirstRunMigration()
        let backup = try XCTUnwrap(h.manager.layout.availableBackups().first)
        try write("changed", to: h.manager.desktopCanonicalPath.appendingPathComponent("config.json"))
        try write("changed", to: h.store.cliDirectory(first).appendingPathComponent("settings.json"))

        try await h.manager.restorePreV2Backup(backup)

        XCTAssertEqual(h.store.activeProfileID, first.id)
        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.desktopCanonicalPath))
        XCTAssertEqual(
            try String(contentsOf: h.manager.desktopCanonicalPath.appendingPathComponent("config.json")),
            "desktop-Privat")
        XCTAssertEqual(
            try String(contentsOf: h.store.cliDirectory(first).appendingPathComponent("settings.json")),
            "cli-Privat")
        let recoveryDirectories = try fm.contentsOfDirectory(
            at: h.store.supportDirectory.appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil)
        let recovery = try XCTUnwrap(
            recoveryDirectories.first { $0.lastPathComponent.hasPrefix("pre-restore-v2-") })
        XCTAssertEqual(
            try String(contentsOf: recovery.appendingPathComponent("canonical-desktop/config.json")),
            "changed")
    }

    func testBackupRestoreRecoveryCompletesAfterRestartBeforeJournalRemoval() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let backup = try XCTUnwrap(h.manager.layout.availableBackups().first)
        try write("changed", to: h.manager.desktopCanonicalPath.appendingPathComponent("config.json"))

        _ = try h.manager.layout.restorePreV2Backup(
            backup, currentActiveID: h.store.activeProfileID)
        XCTAssertTrue(
            fm.fileExists(atPath: h.store.supportDirectory.appendingPathComponent("operation-journal.json").path))

        let reloadedStore = ProfileStore(supportRoot: h.store.supportDirectory)
        reloadedStore.load()
        let restarted = ProfileManager(
            store: reloadedStore,
            claudeApp: FakeClaudeAppController(),
            cliCanonicalPath: h.manager.cliCanonicalPath,
            desktopCanonicalPath: h.manager.desktopCanonicalPath)
        let recoveredID = try restarted.recoverLayoutIfNeeded()

        XCTAssertEqual(recoveredID, reloadedStore.activeProfileID)
        XCTAssertEqual(
            try String(contentsOf: h.manager.desktopCanonicalPath.appendingPathComponent("config.json")),
            "desktop")
        XCTAssertFalse(
            fm.fileExists(atPath: h.store.supportDirectory.appendingPathComponent("operation-journal.json").path))
    }

    func testDesktopSwitchUsesPhysicalDirectoriesAndPreservesPreviousProfile() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let previous = try migrateFresh(h)
        let target = try h.manager.createProfile(name: "work")
        try write("work", to: h.store.desktopDirectory(target).appendingPathComponent("account"))

        try await h.manager.switchTo(target, relaunchDesktop: false)

        XCTAssertEqual(h.store.activeProfileID, target.id)
        XCTAssertEqual(
            try String(contentsOf: h.manager.desktopCanonicalPath.appendingPathComponent("account")),
            "work")
        XCTAssertEqual(
            try String(contentsOf: h.store.desktopDirectory(previous).appendingPathComponent("config.json")),
            "desktop")
        XCTAssertFalse(h.manager.symlinks.isSymlink(h.manager.desktopCanonicalPath))
        XCTAssertFalse(fm.fileExists(atPath: h.store.desktopDirectory(target).path))
    }

    func testSwitchAbortsWhenDesktopWillNotQuit() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let previous = try migrateFresh(h)
        let target = try h.manager.createProfile(name: "work")
        h.claudeApp.isClaudeRunning = true
        h.claudeApp.quitSucceeds = false

        await assertThrowsErrorAsync(try await h.manager.switchTo(target, relaunchDesktop: false))
        XCTAssertEqual(h.store.activeProfileID, previous.id)
        XCTAssertTrue(fm.fileExists(atPath: h.store.desktopDirectory(target).path))
    }

    func testSwitchResultReportsCommittedSwitchWhenRelaunchFails() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let target = try h.manager.createProfile(name: "work")
        h.claudeApp.isClaudeRunning = true
        h.claudeApp.launchShouldFail = true

        let result = try await h.manager.switchTo(target, relaunchDesktop: true)

        XCTAssertTrue(result.switched)
        XCTAssertFalse(result.desktopRelaunched)
        XCTAssertNotNil(result.relaunchError)
        XCTAssertEqual(h.store.activeProfileID, target.id)
    }

    func testDesktopSignOutClearsToken() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let profile = try h.manager.createProfile(name: "p")
        let config = h.store.desktopDirectory(profile).appendingPathComponent("config.json")
        try #"{"oauth:tokenCache":"tok","other":"kept"}"#.write(to: config, atomically: true, encoding: .utf8)

        try await h.manager.signOut(profile, surfaces: [.desktop])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        XCTAssertNil(json?["oauth:tokenCache"])
        XCTAssertEqual(json?["other"] as? String, "kept")
    }

    func testDesktopSignOutThrowsOnUnreadableConfig() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let profile = try h.manager.createProfile(name: "p")
        let config = h.store.desktopDirectory(profile).appendingPathComponent("config.json")
        try "not json {{{".write(to: config, atomically: true, encoding: .utf8)
        await assertThrowsErrorAsync(try await h.manager.signOut(profile, surfaces: [.desktop]))
        XCTAssertTrue(fm.fileExists(atPath: config.path))
    }

    func testCopyConfigRefusesSameProfile() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let profile = try h.manager.createProfile(name: "only")
        XCTAssertThrowsError(
            try h.manager.copyConfigPlan(from: profile, to: profile, categories: [.cliSettings], mode: .merge))
    }

    func testCopyPlanNeverQuitsAndExecutionQuitsOnlyForActiveDesktop() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let source = try h.manager.createProfile(name: "src")
        let target = try h.manager.createProfile(name: "tgt")
        try #"{"mcpServers":{"s":{"command":"x"}}}"#.write(
            to: h.store.desktopDirectory(source).appendingPathComponent("claude_desktop_config.json"),
            atomically: true, encoding: .utf8)

        h.claudeApp.isClaudeRunning = true
        var plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.desktopMCPAndConfig], mode: .merge)
        XCTAssertEqual(h.claudeApp.quitCalls, 0)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        XCTAssertEqual(h.claudeApp.quitCalls, 0)

        h.claudeApp.isClaudeRunning = false
        try await h.manager.switchTo(target, relaunchDesktop: false)
        try #"{"mcpServers":{"s":{"command":"x"},"t":{"command":"y"}}}"#.write(
            to: h.store.desktopDirectory(source).appendingPathComponent("claude_desktop_config.json"),
            atomically: true, encoding: .utf8)
        h.claudeApp.isClaudeRunning = true
        plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.desktopMCPAndConfig], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        XCTAssertEqual(h.claudeApp.quitCalls, 1)
    }

    func testCopyConfigAppendsLog() async throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try migrateFresh(h)
        let source = try h.manager.createProfile(name: "src")
        let target = try h.manager.createProfile(name: "tgt")
        try "{}".write(
            to: h.store.cliDirectory(source).appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8)
        let plan = try h.manager.copyConfigPlan(
            from: source, to: target, categories: [.cliSettings], mode: .merge)
        _ = try await h.manager.performConfigCopy(plan, resolutions: [:], from: source, to: target)
        let log = try String(contentsOf: h.store.logFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("copyconfig: src -> tgt"))
    }

    func testProfileNameValidationAndRenameAlias() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "  old name  ")
        try h.manager.rename(profile, to: "new name")
        let renamed = try XCTUnwrap(h.store.profiles.first(where: { $0.id == profile.id }))
        XCTAssertEqual(renamed.name, "new name")
        XCTAssertEqual(renamed.aliases, ["old name"])
        XCTAssertThrowsError(try h.manager.createProfile(name: "   "))
        XCTAssertThrowsError(try h.manager.createProfile(name: String(repeating: "x", count: 65)))
        XCTAssertThrowsError(try h.manager.rename(renamed, to: "evil\u{0000}"))
    }

    func testKeepOnThisMacAssignsNewIDWithoutLosingActiveData() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let old = try migrateFresh(h)
        let oldCLI = h.store.cliDirectory(old).appendingPathComponent("settings.json")
        XCTAssertEqual(try String(contentsOf: oldCLI), "cli")

        let replacement = try h.manager.keepOnThisMac(old)

        XCTAssertNotEqual(replacement.id, old.id)
        XCTAssertEqual(h.store.activeProfileID, replacement.id)
        XCTAssertTrue(h.store.tombstones.keys.contains(old.id))
        XCTAssertFalse(fm.fileExists(atPath: h.store.profileDirectory(old).path))
        XCTAssertEqual(
            try String(contentsOf: h.store.cliDirectory(replacement).appendingPathComponent("settings.json")),
            "cli")
        XCTAssertEqual(
            (h.manager.layout as? ProfileLayoutService)?.marker(at: h.manager.desktopCanonicalPath),
            replacement.id)
    }
}

@MainActor
private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
