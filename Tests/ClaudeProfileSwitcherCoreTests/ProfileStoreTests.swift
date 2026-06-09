import XCTest

@testable import ClaudeProfileSwitcherCore

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testEmptyOnFirstLoad() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let store = ProfileStore(supportRoot: tmp)
        store.load()
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.activeProfileID)
    }

    func testUpsertAndPersist() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp)
        store.load()
        let profile = Profile(name: "work")
        store.upsert(profile)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "work")

        // A fresh store re-reading the same path should see the persisted state.
        let store2 = ProfileStore(supportRoot: tmp)
        store2.load()
        XCTAssertEqual(store2.profiles.count, 1)
        XCTAssertEqual(store2.profiles[0].id, profile.id)
    }

    func testSetActiveAndClearActive() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp)
        store.load()
        let p = Profile(name: "work")
        store.upsert(p)
        store.setActive(p)
        XCTAssertEqual(store.activeProfileID, p.id)

        store.clearActive()
        XCTAssertNil(store.activeProfileID)

        // Persisted across loads.
        let store2 = ProfileStore(supportRoot: tmp)
        store2.load()
        XCTAssertNil(store2.activeProfileID)
        XCTAssertEqual(store2.profiles.count, 1)
    }

    func testRemovingActiveProfileClearsActive() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp)
        store.load()
        let p = Profile(name: "work")
        store.upsert(p)
        store.setActive(p)
        store.remove(p)

        XCTAssertNil(store.activeProfileID)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotNil(store.tombstones[p.id], "Remove should leave a tombstone")
    }

    func testRenameUpdatesUpdatedAt() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp)
        store.load()
        let p = Profile(name: "work", updatedAt: .distantPast)
        store.upsert(p)
        let beforeUpdate = store.profiles[0].updatedAt

        // Pretend a tiny moment passes — call rename, expect updatedAt to advance.
        store.renameProfile(p, to: "work-renamed")
        XCTAssertEqual(store.profiles[0].name, "work-renamed")
        XCTAssertGreaterThan(store.profiles[0].updatedAt, beforeUpdate)
    }

    func testDidPersistFires() throws {
        let (tmp, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }

        let store = ProfileStore(supportRoot: tmp)
        store.load()
        var calls = 0
        store.didPersist = { calls += 1 }
        store.upsert(Profile(name: "work"))
        store.upsert(Profile(name: "personal"))
        XCTAssertEqual(calls, 2)
    }
}
