import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class CredentialsInspectorTests: XCTestCase {
    private var fm: FileManager { .default }

    private func makeInspector(in tmp: URL) -> (CredentialsInspector, ProfileStore) {
        let store = ProfileStore(supportRoot: tmp)
        store.load()
        let inspector = CredentialsInspector(store: store, keychainProbeEnabled: false)
        return (inspector, store)
    }

    func testDesktopSignedInDetectsToken() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let desktopDir = tmp.appendingPathComponent("desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let fixture = try TestSupport.fixtureURL("desktop-signed-in-config.json")
        try fm.copyItem(at: fixture, to: desktopDir.appendingPathComponent("config.json"))

        let status = inspector.inspectDesktop(directory: desktopDir)
        XCTAssertEqual(status.state, .signedIn)
    }

    func testDesktopSignedOutWhenTokenIsEmptyString() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let desktopDir = tmp.appendingPathComponent("desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let fixture = try TestSupport.fixtureURL("desktop-signed-out-config.json")
        try fm.copyItem(at: fixture, to: desktopDir.appendingPathComponent("config.json"))

        let status = inspector.inspectDesktop(directory: desktopDir)
        XCTAssertEqual(status.state, .signedOut)
    }

    func testDesktopSignedOutWhenTokenFieldMissing() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let desktopDir = tmp.appendingPathComponent("desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let fixture = try TestSupport.fixtureURL("desktop-no-token-config.json")
        try fm.copyItem(at: fixture, to: desktopDir.appendingPathComponent("config.json"))

        let status = inspector.inspectDesktop(directory: desktopDir)
        XCTAssertEqual(status.state, .signedOut)
    }

    func testDesktopMalformedJSONReportsUnknown() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let desktopDir = tmp.appendingPathComponent("desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        let fixture = try TestSupport.fixtureURL("desktop-malformed-config.json")
        try fm.copyItem(at: fixture, to: desktopDir.appendingPathComponent("config.json"))

        let status = inspector.inspectDesktop(directory: desktopDir)
        XCTAssertEqual(status.state, .unknown)
        XCTAssertNotNil(status.note)
    }

    func testDesktopMissingConfigSignedOut() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let desktopDir = tmp.appendingPathComponent("desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)

        let status = inspector.inspectDesktop(directory: desktopDir)
        XCTAssertEqual(status.state, .signedOut)
    }

    func testCLIWithLegacyCredentialsFileSignedIn() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let cliDir = tmp.appendingPathComponent("cli", isDirectory: true)
        try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
        let creds = cliDir.appendingPathComponent(".credentials.json")
        try "{\"token\":\"x\"}".write(to: creds, atomically: true, encoding: .utf8)

        let status = inspector.inspectCLI(directory: cliDir)
        XCTAssertEqual(status.state, .signedIn)
    }

    func testCLINoFileNoKeychainSignedOut() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)  // keychainProbeEnabled = false

        let cliDir = tmp.appendingPathComponent("cli", isDirectory: true)
        try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)

        let status = inspector.inspectCLI(directory: cliDir)
        XCTAssertEqual(status.state, .signedOut)
    }

    func testCLIEmptyCredentialsFileStillSignedOut() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let (inspector, _) = makeInspector(in: tmp)

        let cliDir = tmp.appendingPathComponent("cli", isDirectory: true)
        try fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
        let creds = cliDir.appendingPathComponent(".credentials.json")
        fm.createFile(atPath: creds.path, contents: nil)

        let status = inspector.inspectCLI(directory: cliDir)
        XCTAssertEqual(status.state, .signedOut)
    }
}
