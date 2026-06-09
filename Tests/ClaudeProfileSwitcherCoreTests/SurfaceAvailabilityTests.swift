import XCTest

@testable import ClaudeProfileSwitcherCore

/// Configurable fake locator for the observable's state transitions.
@MainActor
private final class FakeSurfaceLocator: SurfaceLocator {
    var desktopURL: URL?
    var cliURL: URL?
    private(set) var desktopProbes = 0
    private(set) var cliProbes = 0

    func desktopAppURL() -> URL? {
        desktopProbes += 1
        return desktopURL
    }

    func cliExecutableURL() async -> URL? {
        cliProbes += 1
        return cliURL
    }
}

@MainActor
final class SurfaceAvailabilityTests: XCTestCase {

    // MARK: - SystemSurfaceLocator CLI resolution

    func testCLIFoundInCandidatePaths() async throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let claude = tmp.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(
            at: claude.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let locator = SystemSurfaceLocator(
            cliCandidatePaths: [tmp.appendingPathComponent("missing/claude"), claude],
            shellLookup: {
                XCTFail("shell fallback must not run when a candidate matches"); return nil
            }
        )
        let found = await locator.cliExecutableURL()
        XCTAssertEqual(found, claude)
    }

    func testCLINonExecutableCandidateIsSkipped() async throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        // Present but not executable — must not count as installed.
        let notExec = tmp.appendingPathComponent("claude")
        try "data".write(to: notExec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExec.path)

        let locator = SystemSurfaceLocator(cliCandidatePaths: [notExec], shellLookup: { nil })
        let found = await locator.cliExecutableURL()
        XCTAssertNil(found)
    }

    func testCLIFallsBackToShellLookup() async throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let claude = tmp.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let path = claude.path
        let locator = SystemSurfaceLocator(cliCandidatePaths: [], shellLookup: { path })
        let found = await locator.cliExecutableURL()
        XCTAssertEqual(found?.path, path)
    }

    func testShellLookupResultMustBeExecutable() async throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let bogus = tmp.appendingPathComponent("claude")
        try "data".write(to: bogus, atomically: true, encoding: .utf8)

        let path = bogus.path
        let locator = SystemSurfaceLocator(cliCandidatePaths: [], shellLookup: { path })
        let found = await locator.cliExecutableURL()
        XCTAssertNil(found)
    }

    // MARK: - SurfaceAvailability observable

    func testRefreshTransitionsFromUnknown() async {
        let fake = FakeSurfaceLocator()
        fake.desktopURL = URL(fileURLWithPath: "/Applications/Claude.app")
        fake.cliURL = nil

        let availability = SurfaceAvailability(locator: fake)
        XCTAssertEqual(availability.desktop, .unknown)
        XCTAssertEqual(availability.cli, .unknown)

        await availability.refresh()
        XCTAssertEqual(availability.desktop, .installed(URL(fileURLWithPath: "/Applications/Claude.app")))
        XCTAssertEqual(availability.cli, .notInstalled)
        XCTAssertTrue(availability.desktop.isInstalled)
        XCTAssertFalse(availability.cli.isInstalled)
    }

    func testRefreshIsCachedWithinTTLUnlessForced() async {
        let fake = FakeSurfaceLocator()
        let availability = SurfaceAvailability(locator: fake)

        await availability.refresh()
        await availability.refresh()
        XCTAssertEqual(fake.desktopProbes, 1, "second refresh within TTL must reuse the cache")

        await availability.refresh(force: true)
        XCTAssertEqual(fake.desktopProbes, 2, "forced refresh must re-probe")
    }
}
