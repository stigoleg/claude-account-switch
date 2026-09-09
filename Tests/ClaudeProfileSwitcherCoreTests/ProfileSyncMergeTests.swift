import XCTest

@testable import ClaudeProfileSwitcherCore

final class ProfileSyncMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func profile(id: String, name: String, updatedAt: Date, createdAt: Date? = nil) -> Profile {
        Profile(
            id: UUID(uuidString: id)!,
            name: name,
            colorHex: "#E07856",
            createdAt: createdAt ?? updatedAt,
            updatedAt: updatedAt
        )
    }

    func testRemoteOnlyProfileEndsUpInMerged() {
        let local: [Profile] = []
        let remote = [profile(id: "11111111-1111-1111-1111-111111111111", name: "work", updatedAt: t(0))]

        let result = ProfileSyncService.merge(
            localProfiles: local,
            localTombstones: [:],
            remoteProfiles: remote,
            remoteTombstones: [:]
        )
        XCTAssertEqual(result.profiles.map(\.name), ["work"])
        XCTAssertTrue(result.tombstones.isEmpty)
    }

    func testLocalNewerThanRemoteWins() {
        let id = "22222222-2222-2222-2222-222222222222"
        let local = [profile(id: id, name: "renamed-local", updatedAt: t(100))]
        let remote = [profile(id: id, name: "old-remote", updatedAt: t(50))]

        let result = ProfileSyncService.merge(
            localProfiles: local,
            localTombstones: [:],
            remoteProfiles: remote,
            remoteTombstones: [:]
        )
        XCTAssertEqual(result.profiles.first?.name, "renamed-local")
    }

    func testRemoteNewerThanLocalWins() {
        let id = "33333333-3333-3333-3333-333333333333"
        let local = [profile(id: id, name: "old-local", updatedAt: t(50))]
        let remote = [profile(id: id, name: "fresh-remote", updatedAt: t(100))]

        let result = ProfileSyncService.merge(
            localProfiles: local,
            localTombstones: [:],
            remoteProfiles: remote,
            remoteTombstones: [:]
        )
        XCTAssertEqual(result.profiles.first?.name, "fresh-remote")
    }

    func testRemoteTombstoneNewerRemovesLocalProfile() {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let local = [profile(id: id.uuidString, name: "ought-to-die", updatedAt: t(50))]
        let remoteTombstones: [UUID: Date] = [id: t(100)]

        let result = ProfileSyncService.merge(
            localProfiles: local,
            localTombstones: [:],
            remoteProfiles: [],
            remoteTombstones: remoteTombstones
        )
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.tombstones[id], t(100))
    }

    func testLocalTombstonePreventsRemoteResurrection() {
        let id = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let localTombstones: [UUID: Date] = [id: t(100)]
        // Remote still has the (old) profile.
        let remote = [profile(id: id.uuidString, name: "stale-remote", updatedAt: t(50))]

        let result = ProfileSyncService.merge(
            localProfiles: [],
            localTombstones: localTombstones,
            remoteProfiles: remote,
            remoteTombstones: [:]
        )
        XCTAssertTrue(result.profiles.isEmpty, "tombstone must block remote resurrection")
        XCTAssertEqual(result.tombstones[id], t(100))
    }

    func testRemoteUpdateAfterTombstoneResurrects() {
        // Edge case: the remote updated the profile *after* both sides
        // tombstoned it. This is the user "undeleting" by upserting on Mac A;
        // Mac B should pick it up.
        let id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let localTombstones: [UUID: Date] = [id: t(50)]
        let remote = [profile(id: id.uuidString, name: "undeleted", updatedAt: t(100))]

        let result = ProfileSyncService.merge(
            localProfiles: [],
            localTombstones: localTombstones,
            remoteProfiles: remote,
            remoteTombstones: [:]
        )
        XCTAssertEqual(result.profiles.first?.name, "undeleted")
    }

    func testLogicalRevisionWinsDespiteClockSkew() {
        let id = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let local = Profile(
            id: id,
            name: "clock-is-newer",
            createdAt: t(0),
            updatedAt: t(1_000),
            revision: ProfileRevision(counter: 2, deviceID: "a"))
        let remote = Profile(
            id: id,
            name: "logical-is-newer",
            createdAt: t(0),
            updatedAt: t(10),
            revision: ProfileRevision(counter: 3, deviceID: "b"))
        let result = ProfileSyncService.merge(
            localProfiles: [local],
            localTombstones: [:],
            remoteProfiles: [remote],
            remoteTombstones: [:])
        XCTAssertEqual(result.profiles.first?.name, "logical-is-newer")
    }

    func testLogicalTombstoneRevisionWinsDespiteClockSkew() {
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let profile = Profile(
            id: id,
            name: "newer-clock",
            createdAt: t(0),
            updatedAt: t(1_000),
            revision: ProfileRevision(counter: 4, deviceID: "mac-a"))
        let result = ProfileSyncService.merge(
            localProfiles: [profile],
            localTombstones: [:],
            remoteProfiles: [],
            remoteTombstones: [id: t(10)],
            remoteTombstoneRevisions: [
                id: ProfileRevision(counter: 5, deviceID: "mac-b")
            ])
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.tombstoneRevisions[id]?.counter, 5)
    }
}

@MainActor
final class ProfileSyncServiceIOTests: XCTestCase {
    func testRemoteDeletionIsPendingAndNeverRemovesLocalProfileAutomatically() throws {
        let (root, cleanup) = try TestSupport.makeTempDirectory()
        defer { cleanup() }
        let store = ProfileStore(supportRoot: root.appendingPathComponent("support"))
        store.load()
        let profile = Profile(name: "Privat", updatedAt: Date(timeIntervalSince1970: 10))
        try store.upsertThrowing(profile)
        let cloud = root.appendingPathComponent("icloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "profiles": [],
            "tombstones": [profile.id.uuidString: "2030-09-03T18:00:00Z"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: cloud.appendingPathComponent("profiles.json"))
        let service = ProfileSyncService(store: store, cloudDirectory: cloud)

        try service.start {}
        defer { service.stop() }
        XCTAssertEqual(store.profiles.map(\.id), [profile.id])
        XCTAssertTrue(service.pendingRemoteDeletions.contains(profile.id))
        service.resolvePendingRemoteDeletion(for: profile.id)
        XCTAssertFalse(service.pendingRemoteDeletions.contains(profile.id))
        guard case .current = service.status else { return XCTFail("expected current sync status") }
    }
}
