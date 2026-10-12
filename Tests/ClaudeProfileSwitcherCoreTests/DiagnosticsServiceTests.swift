import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class DiagnosticsServiceTests: XCTestCase {
    private var fm: FileManager { .default }

    private struct Harness {
        let service: DiagnosticsService
        let manager: ProfileManager
        let store: ProfileStore
        let claudeApp: FakeClaudeAppController
        let home: URL
        let desktop: URL
        let active: Profile
        let inactive: Profile
        let cleanup: () -> Void
    }

    /// Healthy v2 layout: the active profile is the real canonical Desktop
    /// directory and the inactive profile lives under profiles/<id>/desktop.
    /// `symlinkLibrary` replaces `home/Library` with a symlink to a sibling dir.
    private func makeHarness(symlinkLibrary: Bool = false) throws -> Harness {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        if symlinkLibrary {
            let realLibrary = root.appendingPathComponent("RealLibrary", isDirectory: true)
            try fm.createDirectory(at: realLibrary, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: home.appendingPathComponent("Library"), withDestinationURL: realLibrary)
        }
        let store = ProfileStore(supportRoot: root.appendingPathComponent("support", isDirectory: true))
        store.load()
        let cli = home.appendingPathComponent(".claude", isDirectory: true)
        let desktop = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try fm.createDirectory(at: cli, withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        let app = FakeClaudeAppController()
        let manager = ProfileManager(
            store: store,
            claudeApp: app,
            cliCanonicalPath: cli,
            desktopCanonicalPath: desktop)
        let active = Profile(name: "Privat")
        let inactive = Profile(name: "Work")
        try manager.layout.prepareNewProfile(active)
        try manager.layout.prepareNewProfile(inactive)
        try fm.moveItem(at: store.desktopDirectory(active), to: desktop)
        try store.upsertThrowing(active)
        try store.upsertThrowing(inactive)
        try store.setActiveThrowing(active)
        let shell = ShellIntegrationService(
            store: store,
            configDirectoryOverride: root.appendingPathComponent("config", isDirectory: true),
            zshrcOverride: home.appendingPathComponent(".zshrc"),
            shellIsZshOverride: true,
            bashrcOverride: home.appendingPathComponent(".bashrc"),
            bashProfileOverride: home.appendingPathComponent(".bash_profile"),
            fishConfigOverride: home.appendingPathComponent(".config/fish/conf.d/claude-profile-switcher.fish"))
        let service = DiagnosticsService(manager: manager, shellIntegration: shell, home: home)
        return Harness(
            service: service,
            manager: manager,
            store: store,
            claudeApp: app,
            home: home,
            desktop: desktop,
            active: active,
            inactive: inactive,
            cleanup: cleanup)
    }

    private func write(_ value: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    /// claude-code-vm/<version>/claude as a real binary placeholder plus the
    /// `.sdk-version` file Claude Desktop writes.
    private func makeVMTree(in desktop: URL, version: String = "2.1.295") throws -> URL {
        let vm = desktop.appendingPathComponent("claude-code-vm", isDirectory: true)
        try write(version, to: vm.appendingPathComponent(".sdk-version"))
        try write("binary", to: vm.appendingPathComponent("\(version)/claude"))
        try write("", to: vm.appendingPathComponent("\(version)/.verified"))
        return vm
    }

    private func errors(_ findings: [DiagnosticFinding]) -> [DiagnosticFinding] {
        findings.filter { $0.severity == .error }
    }

    private func moveAsideTarget(_ finding: DiagnosticFinding?) -> (URL, UUID?)? {
        guard case .moveAside(let url, let profileID) = finding?.repair else { return nil }
        return (url, profileID)
    }

    func testHealthyLayoutHasNoErrorsOrWarnings() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        _ = try makeVMTree(in: h.desktop)
        try fm.createDirectory(
            at: h.desktop.appendingPathComponent("vm_bundles/claudevm.bundle"), withIntermediateDirectories: true)

        let findings = h.service.run()

        XCTAssertTrue(findings.allSatisfy { $0.severity == .ok }, "\(findings)")
        XCTAssertFalse(findings.isEmpty)
    }

    func testLegacySymlinkedDesktopRequiresMigration() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let stored = h.store.desktopDirectory(h.active)
        try fm.moveItem(at: h.desktop, to: stored)
        try fm.createSymbolicLink(at: h.desktop, withDestinationURL: stored)

        let findings = h.service.run()

        let migration = findings.first { $0.repair == .runMigration }
        XCTAssertEqual(migration?.severity, .error)
        XCTAssertEqual(findings.filter { $0.repair == .runMigration }.count, 1)
    }

    func testSymlinkedSDKBinaryIsErrorWithMoveAside() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let vm = try makeVMTree(in: h.desktop)
        let binary = vm.appendingPathComponent("2.1.295/claude")
        let elsewhere = h.home.appendingPathComponent("real-claude")
        try write("binary", to: elsewhere)
        try fm.removeItem(at: binary)
        try fm.createSymbolicLink(at: binary, withDestinationURL: elsewhere)

        let findings = h.service.run()

        let finding = errors(findings).first { $0.detail.contains("2.1.295/claude") }
        XCTAssertNotNil(finding, "\(findings)")
        let target = moveAsideTarget(finding)
        XCTAssertEqual(target?.0.standardizedFileURL.path, vm.standardizedFileURL.path)
        XCTAssertNil(target?.1)
    }

    func testSymlinkLoopIsFlaggedWithoutHanging() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let vm = try makeVMTree(in: h.desktop)
        let a = vm.appendingPathComponent("a")
        let b = vm.appendingPathComponent("b")
        try fm.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try fm.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)

        let findings = h.service.run()

        let finding = errors(findings).first { moveAsideTarget($0)?.0.lastPathComponent == "claude-code-vm" }
        XCTAssertNotNil(finding, "\(findings)")
        XCTAssertTrue(finding?.detail.contains("loop") ?? false, finding?.detail ?? "")
    }

    func testDanglingLinkIsFlagged() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let bundles = h.desktop.appendingPathComponent("vm_bundles", isDirectory: true)
        try fm.createDirectory(at: bundles, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: bundles.appendingPathComponent("rootfs.img").path,
            withDestinationPath: h.home.appendingPathComponent("missing.img").path)

        let findings = h.service.run()

        let finding = errors(findings).first { moveAsideTarget($0)?.0.lastPathComponent == "vm_bundles" }
        XCTAssertNotNil(finding, "\(findings)")
        XCTAssertTrue(finding?.detail.contains("dangling") ?? false, finding?.detail ?? "")
    }

    func testMissingSDKBinaryIsWarning() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let vm = try makeVMTree(in: h.desktop)
        try fm.removeItem(at: vm.appendingPathComponent("2.1.295/claude"))

        let findings = h.service.run()

        XCTAssertTrue(errors(findings).isEmpty, "\(findings)")
        XCTAssertTrue(
            findings.contains { $0.severity == .warning && $0.detail.contains("2.1.295") }, "\(findings)")
    }

    func testSymlinkedLibraryAncestorIsReported() throws {
        let h = try makeHarness(symlinkLibrary: true)
        defer { h.cleanup() }

        let findings = h.service.run()

        let finding = errors(findings).first { $0.detail.contains("Library") && $0.repair == nil }
        XCTAssertNotNil(finding, "\(findings)")
    }

    func testInactiveProfileDesktopIsScanned() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let stored = h.store.desktopDirectory(h.inactive)
        let vm = try makeVMTree(in: stored)
        let binary = vm.appendingPathComponent("2.1.295/claude")
        try fm.removeItem(at: binary)
        try fm.createSymbolicLink(atPath: binary.path, withDestinationPath: "/usr/bin/true")

        let findings = h.service.run()

        let target = errors(findings).compactMap { moveAsideTarget($0) }.first
        XCTAssertEqual(target?.0.standardizedFileURL.path, vm.standardizedFileURL.path)
        XCTAssertEqual(target?.1, h.inactive.id)
    }

    func testMoveAsideMovesIntoRepairsAndRefusesWhileDesktopRuns() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let vm = try makeVMTree(in: h.desktop)
        let action = RepairAction.moveAside(vm, profileID: nil)

        h.claudeApp.isClaudeRunning = true
        XCTAssertThrowsError(try h.service.apply(action))
        XCTAssertTrue(fm.fileExists(atPath: vm.path))

        h.claudeApp.isClaudeRunning = false
        try h.service.apply(action)

        XCTAssertFalse(fm.fileExists(atPath: vm.path))
        let repairs = h.store.supportDirectory.appendingPathComponent("repairs", isDirectory: true)
        let stamps = try fm.contentsOfDirectory(atPath: repairs.path)
        XCTAssertEqual(stamps.count, 1)
        let moved = repairs.appendingPathComponent("\(stamps[0])/active/claude-code-vm/2.1.295/claude")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "binary")
    }

    func testMoveAsideRefusesPathsOutsideDesktopVMTrees() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        XCTAssertThrowsError(try h.service.apply(.moveAside(h.desktop, profileID: nil)))
        XCTAssertTrue(fm.fileExists(atPath: h.desktop.path))
    }

    func testReportContainsFindingTitles() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let vm = try makeVMTree(in: h.desktop)
        try fm.createSymbolicLink(
            atPath: vm.appendingPathComponent("dangling").path, withDestinationPath: "/nonexistent/path")

        let findings = h.service.run()
        let report = DiagnosticsService.textReport(findings)

        XCTAssertFalse(findings.isEmpty)
        for finding in findings {
            XCTAssertTrue(report.contains(finding.title), finding.title)
        }
        XCTAssertTrue(report.contains("macOS"))
        let json = try DiagnosticsService.jsonReport(findings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: json)
        XCTAssertEqual(decoded.findings, findings)
    }

    func testSharedConfigBrokenAndDriftFindings() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let bundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedConfig", isDirectory: true)
        let shared = SharedConfigService(
            bundleURL: bundle,
            deployedURL: SharedConfigService.deployedURL(home: h.home),
            profilesDirectory: h.store.profilesDirectory,
            runner: TestModeClaudeCodeRunner())
        let service = DiagnosticsService(
            manager: h.manager, shellIntegration: h.service.shellIntegration, home: h.home, sharedConfig: shared)
        try shared.install(profileID: h.inactive.id, yolo: true)
        XCTAssertTrue(service.run().contains { $0.id == "shared.ok" })

        try fm.removeItem(at: h.store.cliDirectory(h.inactive).appendingPathComponent("agents"))
        let broken = try XCTUnwrap(service.run().first { $0.id == "shared.\(h.inactive.id.uuidString).broken" })
        XCTAssertEqual(broken.severity, .error)
        let repair = try XCTUnwrap(broken.repair)
        XCTAssertEqual(repair, .installSharedConfig(profileID: h.inactive.id, overwriteLocalEdits: false))
        XCTAssertFalse(repair.isSafe)
        try service.apply(repair)
        XCTAssertEqual(shared.status(profileID: h.inactive.id), .installed(yolo: true))

        try "edited".write(
            to: SharedConfigService.deployedURL(home: h.home).appendingPathComponent("CLAUDE.md"),
            atomically: true, encoding: .utf8)
        try fm.removeItem(at: h.store.cliDirectory(h.inactive).appendingPathComponent("agents"))
        let findings = service.run()
        let drift = try XCTUnwrap(findings.first { $0.id == "shared.drift" })
        XCTAssertEqual(drift.severity, .warning)
        XCTAssertEqual(drift.repair?.isSafe, false)
        let unsafe = try XCTUnwrap(findings.first { $0.id.hasSuffix(".broken") }?.repair)
        XCTAssertFalse(unsafe.isSafe)
    }

    func testSharedConfigWarnsWithoutJQ() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let bundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SharedConfig", isDirectory: true)
        let shared = SharedConfigService(
            bundleURL: bundle,
            deployedURL: SharedConfigService.deployedURL(home: h.home),
            profilesDirectory: h.store.profilesDirectory,
            runner: TestModeClaudeCodeRunner(),
            jqSearchPaths: [])
        let service = DiagnosticsService(
            manager: h.manager, shellIntegration: h.service.shellIntegration, home: h.home, sharedConfig: shared)
        XCTAssertFalse(service.run().contains { $0.id == "shared.jq" })

        try shared.install(profileID: h.inactive.id, yolo: false)

        let finding = try XCTUnwrap(service.run().first { $0.id == "shared.jq" })
        XCTAssertEqual(finding.severity, .warning)
    }

    func testElectronSingletonLinksAreNotReported() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        for name in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
            try fm.createSymbolicLink(
                atPath: h.desktop.appendingPathComponent(name).path, withDestinationPath: "host-12345")
        }

        XCTAssertFalse(h.service.run().contains { $0.id.hasPrefix("desktop.") })

        try fm.createSymbolicLink(
            atPath: h.desktop.appendingPathComponent("Preferences").path, withDestinationPath: "/tmp/elsewhere")
        XCTAssertTrue(h.service.run().contains { $0.id.hasPrefix("desktop.") })
    }
}
