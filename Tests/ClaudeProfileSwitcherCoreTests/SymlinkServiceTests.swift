import XCTest

@testable import ClaudeProfileSwitcherCore

final class SymlinkServiceTests: XCTestCase {
    private var fm: FileManager { .default }

    func testReplaceSymlinkCreatesFreshLink() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")

        let svc = SymlinkService()
        try svc.replaceSymlink(at: link, pointingTo: target)

        XCTAssertTrue(svc.isSymlink(link))
        XCTAssertEqual(svc.symlinkDestination(link)?.path, target.path)
    }

    func testReplaceSymlinkAtomicallyReplacesExisting() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")

        let svc = SymlinkService()
        try svc.replaceSymlink(at: link, pointingTo: a)
        XCTAssertEqual(svc.symlinkDestination(link)?.path, a.path)

        try svc.replaceSymlink(at: link, pointingTo: b)
        XCTAssertEqual(svc.symlinkDestination(link)?.path, b.path)
        XCTAssertTrue(svc.isSymlink(link))
    }

    func testReplaceSymlinkRefusesToClobberRealDirectory() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let realDir = tmp.appendingPathComponent("important", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        // Write a sentinel file so we can confirm it's untouched after the throw.
        let sentinel = realDir.appendingPathComponent("don-t-touch.txt")
        try "important data".write(to: sentinel, atomically: true, encoding: .utf8)

        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let svc = SymlinkService()
        XCTAssertThrowsError(try svc.replaceSymlink(at: realDir, pointingTo: target)) { error in
            guard case SymlinkError.targetIsDirectoryNotSymlink = error else {
                XCTFail("Expected targetIsDirectoryNotSymlink, got \(error)")
                return
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: sentinel.path), "real data must be untouched")
    }

    func testRemoveSymlinkRefusesRealDirectory() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let realDir = tmp.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)

        let svc = SymlinkService()
        XCTAssertThrowsError(try svc.removeSymlink(at: realDir)) { error in
            guard case SymlinkError.notASymlink = error else {
                XCTFail("Expected notASymlink, got \(error)")
                return
            }
        }
        XCTAssertTrue(svc.itemExists(realDir))
    }

    func testRemoveSymlinkSucceedsOnSymlink() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")

        let svc = SymlinkService()
        try svc.replaceSymlink(at: link, pointingTo: target)
        try svc.removeSymlink(at: link)

        XCTAssertFalse(svc.itemExists(link))
        XCTAssertTrue(svc.itemExists(target), "removing symlink must not affect target")
    }

    func testMoveDirectoryPreservesContents() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("payload.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let dst = tmp.appendingPathComponent("dst", isDirectory: true)

        let svc = SymlinkService()
        try svc.moveDirectory(from: src, to: dst)

        XCTAssertFalse(svc.itemExists(src))
        XCTAssertTrue(svc.itemExists(dst))
        let contents = try String(contentsOf: dst.appendingPathComponent("payload.txt"), encoding: .utf8)
        XCTAssertEqual(contents, "hello")
    }

    func testSweepStaleTempLinksRemovesOnlyMatchingSymlinks() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let svc = SymlinkService()
        let canonical = tmp.appendingPathComponent(".claude")
        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        // A stale temp symlink that matches the naming scheme.
        let stale = tmp.appendingPathComponent(".\(canonical.lastPathComponent).new-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: stale, withDestinationURL: target)

        // Must survive: wrong suffix, regular file with matching prefix, the canonical itself.
        let wrongSuffix = tmp.appendingPathComponent(".\(canonical.lastPathComponent).new-not-a-uuid")
        try fm.createSymbolicLink(at: wrongSuffix, withDestinationURL: target)
        let regularFile = tmp.appendingPathComponent(".\(canonical.lastPathComponent).new-\(UUID().uuidString)")
        try "data".write(to: regularFile, atomically: true, encoding: .utf8)
        try svc.replaceSymlink(at: canonical, pointingTo: target)

        svc.sweepStaleTempLinks(siblingsOf: canonical)

        XCTAssertFalse(svc.itemExists(stale), "matching stale temp symlink must be removed")
        XCTAssertTrue(svc.itemExists(wrongSuffix), "non-UUID suffix must be left alone")
        XCTAssertTrue(svc.itemExists(regularFile), "regular files must be left alone")
        XCTAssertTrue(svc.isSymlink(canonical), "the canonical symlink must be untouched")
    }

    func testIsSymlinkAndItemExistsHandleMissingPath() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let missing = tmp.appendingPathComponent("does-not-exist")
        let svc = SymlinkService()
        XCTAssertFalse(svc.isSymlink(missing))
        XCTAssertFalse(svc.itemExists(missing))
        XCTAssertNil(svc.symlinkDestination(missing))
    }
}
