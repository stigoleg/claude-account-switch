import Darwin
import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class ProfileLayoutServiceTests: XCTestCase {
    private struct Harness {
        let store: ProfileStore
        let layout: ProfileLayoutService
        let active: Profile
        let target: Profile
        let canonicalDesktop: URL
        let cleanup: () -> Void
    }

    private func makeHarness() throws -> Harness {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        let store = ProfileStore(supportRoot: root.appendingPathComponent("support"))
        store.load()
        let desktop = root.appendingPathComponent("home/Library/Application Support/Claude")
        let cli = root.appendingPathComponent("home/.claude")
        try FileManager.default.createDirectory(
            at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        let layout = ProfileLayoutService(
            store: store, canonicalDesktop: desktop, canonicalCLI: cli)
        let active = Profile(name: "Privat")
        let target = Profile(name: "Sopra Steria")
        try layout.prepareNewProfile(active)
        try layout.prepareNewProfile(target)
        try "private".write(
            to: store.desktopDirectory(active).appendingPathComponent("value"),
            atomically: true,
            encoding: .utf8)
        try "work".write(
            to: store.desktopDirectory(target).appendingPathComponent("value"),
            atomically: true,
            encoding: .utf8)
        try FileManager.default.moveItem(at: store.desktopDirectory(active), to: desktop)
        try store.upsertThrowing(active)
        try store.upsertThrowing(target)
        try store.setActiveThrowing(active)
        return Harness(
            store: store,
            layout: layout,
            active: active,
            target: target,
            canonicalDesktop: desktop,
            cleanup: cleanup)
    }

    func testPhysicalSwapPreservesBothProfiles() throws {
        let h = try makeHarness()
        defer { h.cleanup() }

        try h.layout.switchDesktop(from: h.active, to: h.target)
        try h.store.setActiveThrowing(h.target)
        try h.layout.completeSwitchJournal()

        XCTAssertEqual(h.layout.marker(at: h.canonicalDesktop), h.target.id)
        XCTAssertEqual(
            try String(contentsOf: h.canonicalDesktop.appendingPathComponent("value")),
            "work")
        XCTAssertEqual(
            try String(contentsOf: h.store.desktopDirectory(h.active).appendingPathComponent("value")),
            "private")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.layout.journalURL.path))
    }

    func testRecoveryRollsForwardAfterAtomicSwap() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let targetStored = h.store.desktopDirectory(h.target)
        let journal = OperationJournal(
            kind: .desktopSwitch,
            previousProfileID: h.active.id,
            targetProfileID: h.target.id,
            phase: .swapped)
        try JSONEncoder.iso.encode(journal).write(to: h.layout.journalURL, options: .atomic)

        let result = h.canonicalDesktop.path.withCString { left in
            targetStored.path.withCString { right in
                renameatx_np(AT_FDCWD, left, AT_FDCWD, right, UInt32(RENAME_SWAP))
            }
        }
        XCTAssertEqual(result, 0)

        XCTAssertEqual(try h.layout.recoverPendingOperation(), .active(h.target.id))
        XCTAssertEqual(h.layout.marker(at: h.canonicalDesktop), h.target.id)
        XCTAssertEqual(h.layout.marker(at: h.store.desktopDirectory(h.active)), h.active.id)
        try h.layout.completeSwitchJournal()
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.layout.journalURL.path))
    }

    func testHealthRejectsLegacySymlink() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let replacement = h.canonicalDesktop.deletingLastPathComponent().appendingPathComponent("legacy")
        try FileManager.default.moveItem(at: h.canonicalDesktop, to: replacement)
        try FileManager.default.createSymbolicLink(at: h.canonicalDesktop, withDestinationURL: replacement)
        XCTAssertEqual(
            h.layout.health(activeProfileID: h.active.id, profiles: [h.active, h.target]),
            .migrationRequired)
    }

    func testSingleInstanceLockRejectsSecondOwner() throws {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let url = root.appendingPathComponent("app.lock")
        let first = try SingleInstanceLock(lockFileURL: url)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try SingleInstanceLock(lockFileURL: url)) { error in
                guard case SingleInstanceError.alreadyRunning = error else {
                    return XCTFail("expected alreadyRunning, got \(error)")
                }
            }
        }
    }

    func testBackupVerificationIncludesExtendedAttributes() throws {
        let h = try makeHarness()
        defer { h.cleanup() }
        let source = h.store.desktopDirectory(h.target).appendingPathComponent("value")
        try setExtendedAttribute("com.stigole.tests.marker", value: "original", at: source)

        let backup = try h.layout.createPreV2Backup(profiles: [h.active, h.target])
        XCTAssertTrue(try h.layout.verifyBackup(backup))

        let copied = backup.directory
            .appendingPathComponent("profiles")
            .appendingPathComponent(h.target.id.uuidString)
            .appendingPathComponent("desktop/value")
        try setExtendedAttribute("com.stigole.tests.marker", value: "changed", at: copied)
        XCTAssertFalse(try h.layout.verifyBackup(backup))
    }

    private func setExtendedAttribute(_ name: String, value: String, at url: URL) throws {
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes { buffer in
            url.path.withCString { path in
                name.withCString { attribute in
                    setxattr(path, attribute, buffer.baseAddress, buffer.count, 0, 0)
                }
            }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
