import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class SignInFlowTests: XCTestCase {
    private var fm: FileManager { .default }

    private struct Harness {
        let manager: ProfileManager
        let store: ProfileStore
        let claudeApp: FakeClaudeAppController
        let cleanup: () -> Void
    }

    /// Tmp-rooted manager with a fake Desktop controller and a fixed CLI
    /// location, so sign-in flows never launch real apps or hit real paths.
    private func makeHarness(cliURL: URL? = nil) throws -> Harness {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support", isDirectory: true))
        store.load()

        let cliCanonical = tmp.appendingPathComponent("home/.claude", isDirectory: true)
        let desktopCanonical = tmp.appendingPathComponent("home/Library/Application Support/Claude", isDirectory: true)
        try fm.createDirectory(at: cliCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktopCanonical.deletingLastPathComponent(), withIntermediateDirectories: true)

        let claudeApp = FakeClaudeAppController()
        let manager = ProfileManager(
            store: store,
            claudeApp: claudeApp,
            surfaceLocator: FixedSurfaceLocator(cliURL: cliURL),
            cliCanonicalPath: cliCanonical,
            desktopCanonicalPath: desktopCanonical
        )
        return Harness(manager: manager, store: store, claudeApp: claudeApp, cleanup: cleanup)
    }

    private func writeDesktopToken(for profile: Profile, in store: ProfileStore) throws {
        let dir = store.desktopDirectory(profile)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json")
        try #"{"oauth:tokenCache":"tok"}"#.write(to: config, atomically: true, encoding: .utf8)
    }

    // MARK: - Preflight

    func testDesktopSignInFailsFastWhenDesktopNotInstalled() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        h.claudeApp.installed = false
        let profile = try h.manager.createProfile(name: "p")

        do {
            try await h.manager.signIn(profile, method: .desktop, timeout: 5)
            XCTFail("expected desktopNotInstalled")
        } catch let error as SignInError {
            XCTAssertEqual(error, .desktopNotInstalled)
        }
        XCTAssertEqual(h.claudeApp.launchCalls, 0, "nothing may launch when preflight fails")
    }

    func testCLISignInFailsFastWhenCLINotInstalled() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        do {
            try await h.manager.signIn(profile, method: .cli, timeout: 5)
            XCTFail("expected cliNotInstalled")
        } catch let error as SignInError {
            XCTAssertEqual(error, .cliNotInstalled)
        }
    }

    func testBothRequiresBothSurfaces() async throws {
        let h = makeHarnessOrFail(cliURL: nil)  // Desktop installed, CLI missing
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        do {
            try await h.manager.signIn(profile, method: .both, timeout: 5)
            XCTFail("expected cliNotInstalled")
        } catch let error as SignInError {
            XCTAssertEqual(error, .cliNotInstalled)
        }
    }

    // MARK: - Desktop credential wait

    func testDesktopSignInSucceedsWhenCredentialsAppear() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        let phases = PhaseLog()
        let store = h.store

        // Drop the token shortly after the wait starts.
        let writer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            try? self.writeDesktopToken(for: profile, in: store)
        }
        defer { writer.cancel() }

        try await h.manager.signIn(profile, method: .desktop, timeout: 10) { phase in
            phases.append(phase)
        }
        XCTAssertTrue(phases.contains(.done))
        XCTAssertTrue(phases.contains(.waitingForDesktop))
        XCTAssertEqual(h.claudeApp.launchCalls, 1)
    }

    func testDesktopSignInThrowsTimedOut() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        let phases = PhaseLog()
        do {
            try await h.manager.signIn(profile, method: .desktop, timeout: 1) { phases.append($0) }
            XCTFail("expected timeout")
        } catch let error as SignInError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertFalse(phases.contains(.done), "done must not fire on timeout")
    }

    func testDesktopExitDuringWaitIsDetected() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        // Quit Desktop shortly after the wait begins (after the launch grace
        // period of timeout/4 = 0.5s).
        let quitter = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            h.claudeApp.isClaudeRunning = false
        }
        defer { quitter.cancel() }

        do {
            try await h.manager.signIn(profile, method: .desktop, timeout: 2)
            XCTFail("expected desktopQuitUnexpectedly")
        } catch let error as SignInError {
            XCTAssertEqual(error, .desktopQuitUnexpectedly)
        }
    }

    func testCancellationAbortsWaitWithoutDone() async throws {
        let h = makeHarnessOrFail(cliURL: nil)
        defer { h.cleanup() }
        let profile = try h.manager.createProfile(name: "p")

        let phases = PhaseLog()
        let manager = h.manager
        let signInTask = Task { @MainActor in
            try await manager.signIn(profile, method: .desktop, timeout: 60) { phase in
                phases.append(phase)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        signInTask.cancel()

        do {
            try await signInTask.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(phases.contains(.done))
    }

    // MARK: - Terminal script helpers (pure)

    func testCLILoginScriptQuotesPath() {
        let script = ProfileManager.cliLoginScript(
            claudePath: URL(fileURLWithPath: "/Users/o'brien/my bin/claude"))
        // Shell-quoted inside an AppleScript string literal.
        XCTAssertTrue(
            script.contains(#"do script "'/Users/o'\\''brien/my bin/claude'""#),
            "unexpected script: \(script)")
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
    }

    func testMapOSAScriptFailure() {
        XCTAssertNil(ProfileManager.mapOSAScriptFailure(status: 0, stderr: ""))
        XCTAssertEqual(
            ProfileManager.mapOSAScriptFailure(
                status: 1, stderr: "execution error: Not authorized to send Apple events to Terminal. (-1743)"),
            .terminalAutomationDenied)
        XCTAssertEqual(
            ProfileManager.mapOSAScriptFailure(status: 1, stderr: "some other failure"),
            .terminalLaunchFailed("some other failure"))
        XCTAssertEqual(
            ProfileManager.mapOSAScriptFailure(status: 3, stderr: "  "),
            .terminalLaunchFailed("osascript exited with status 3"))
    }

    // MARK: - helpers

    private func makeHarnessOrFail(cliURL: URL?, file: StaticString = #filePath, line: UInt = #line) -> Harness {
        do {
            return try makeHarness(cliURL: cliURL)
        } catch {
            XCTFail("harness setup failed: \(error)", file: file, line: line)
            fatalError("unreachable")
        }
    }
}

/// Main-actor phase recorder usable from the phase observer closure.
@MainActor
private final class PhaseLog {
    private var phases: [ProfileManager.SignInPhase] = []
    func append(_ p: ProfileManager.SignInPhase) { phases.append(p) }
    func contains(_ p: ProfileManager.SignInPhase) -> Bool { phases.contains(p) }
}
