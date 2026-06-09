import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class ShellIntegrationServiceTests: XCTestCase {
    private func makeService(
        in tmp: URL,
        store: ProfileStore,
        shellIsZsh: Bool = true
    ) -> ShellIntegrationService {
        ShellIntegrationService(
            store: store,
            configDirectoryOverride: tmp.appendingPathComponent("config", isDirectory: true),
            zshrcOverride: tmp.appendingPathComponent("zshrc"),
            shellIsZshOverride: shellIsZsh
        )
    }

    func testProfilePathsManifestShape() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support"))
        store.load()
        store.upsert(Profile(name: "Work"))
        store.upsert(Profile(name: "Personal"))

        let svc = makeService(in: tmp, store: store)
        _ = svc.writeProfilePathsManifest()

        let data = try Data(contentsOf: svc.profilePathsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let profiles = json?["profiles"] as? [String: [String: String]]
        XCTAssertNotNil(profiles?["work"]?["cli"])
        XCTAssertNotNil(profiles?["personal"]?["cli"])
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        // Names normalized lower-case.
        XCTAssertNil(profiles?["Work"])
    }

    func testInstallIsIdempotent() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support"))
        store.load()
        let svc = makeService(in: tmp, store: store)

        // Seed an existing rc with user customizations.
        try "alias g=git\n".write(to: svc.zshrcURL, atomically: true, encoding: .utf8)

        try svc.install()
        let after1 = try String(contentsOf: svc.zshrcURL, encoding: .utf8)
        XCTAssertTrue(svc.isInstalledInZshrc())
        XCTAssertTrue(after1.contains("alias g=git"))

        try svc.install()
        let after2 = try String(contentsOf: svc.zshrcURL, encoding: .utf8)
        XCTAssertEqual(after1, after2, "second install should not change anything")

        // Exactly one source line.
        let lines = after2.split(separator: "\n").filter { $0.contains("claude-profile.zsh") }
        XCTAssertEqual(lines.count, 1)
    }

    func testUninstallLeavesUserCustomizations() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support"))
        store.load()
        let svc = makeService(in: tmp, store: store)

        try "alias g=git\n".write(to: svc.zshrcURL, atomically: true, encoding: .utf8)
        try svc.install()
        try svc.uninstall()

        let after = try String(contentsOf: svc.zshrcURL, encoding: .utf8)
        XCTAssertFalse(after.contains("claude-profile.zsh"))
        XCTAssertFalse(after.contains("Added by Claude Profile Switcher"))
        XCTAssertTrue(after.contains("alias g=git"))
    }

    func testInstallRejectsNonZshShell() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support"))
        store.load()
        let svc = makeService(in: tmp, store: store, shellIsZsh: false)

        XCTAssertThrowsError(try svc.install()) { error in
            guard case ShellIntegrationService.IntegrationError.notZsh = error else {
                return XCTFail("expected notZsh, got \(error)")
            }
        }
        XCTAssertFalse(svc.isInstalledInZshrc())
    }

    func testInstallFunctionFileOnlyWritesNoZshrc() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp.appendingPathComponent("support"))
        store.load()
        let svc = makeService(in: tmp, store: store, shellIsZsh: false)

        try svc.installFunctionFileOnly()
        XCTAssertTrue(FileManager.default.fileExists(atPath: svc.functionFileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: svc.zshrcURL.path),
            "force-install must not touch the rc file")
    }
}
