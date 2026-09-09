import Foundation

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case syncing
    case current(Date)
    case offline(String)
    case failed(String)
}

/// Mirrors `profiles.json` to iCloud Drive so the same profile list shows up
/// on every Mac signed into the user's iCloud account.
///
/// **Privacy**: only metadata (id, name, color, timestamps, tombstones) leaves
/// the device. No tokens, credentials, or project paths are uploaded.
///
/// **Conflict resolution**: deterministic per-profile logical revisions.
/// Deletions are represented as tombstones so a "deleted on Mac A" doesn't get
/// resurrected by a stale entry from Mac B.
///
/// Uses the app's registered ubiquity container. The previous general
/// CloudDocs file is read once for migration and preserved as a backup.
@MainActor
public final class ProfileSyncService {
    private let store: ProfileStore
    private let fm = FileManager.default
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onChange: (() -> Void)?
    private var isRunning = false
    private let cloudDirectoryOverride: URL?
    public private(set) var status: SyncStatus = .disabled
    public private(set) var pendingRemoteDeletions: Set<UUID> = []

    public init(store: ProfileStore, cloudDirectory: URL? = nil) {
        self.store = store
        self.cloudDirectoryOverride = cloudDirectory
    }

    private var ubiquityContainer: URL? {
        fm.url(forUbiquityContainerIdentifier: "iCloud.com.stigole.ClaudeProfileSwitcher")
    }

    public var cloudDirectory: URL {
        if let cloudDirectoryOverride { return cloudDirectoryOverride }
        if let container = ubiquityContainer {
            return container.appendingPathComponent("Documents/ClaudeProfileSwitcher", isDirectory: true)
        }
        // This value is only diagnostic when the registered container is
        // unavailable; iCloudDriveAvailable stays false and start() fails.
        return legacyCloudDirectory
    }

    public var legacyCloudDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/ClaudeProfileSwitcher", isDirectory: true)
    }

    public var cloudFileURL: URL {
        cloudDirectory.appendingPathComponent("profiles.json")
    }

    public var iCloudDriveAvailable: Bool {
        if cloudDirectoryOverride != nil {
            return fm.fileExists(atPath: cloudDirectory.deletingLastPathComponent().path)
        }
        return fm.ubiquityIdentityToken != nil && ubiquityContainer != nil
    }

    /// Begin mirroring. Performs an initial merge with whatever is in the
    /// cloud, writes the local state out, and starts watching for remote
    /// updates.
    public func start(onMerge: @escaping () -> Void) throws {
        guard !isRunning else { return }
        guard iCloudDriveAvailable else {
            status = .offline("the registered iCloud container is unavailable")
            throw SyncError.unavailable
        }
        self.onChange = onMerge
        status = .syncing

        try fm.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
        try migrateLegacyFileIfNeeded()

        // Initial merge: pull from cloud first so we don't blow over any
        // updates made on another Mac.
        if fm.fileExists(atPath: cloudFileURL.path) {
            mergeFromCloud()
        }
        // Then push current local state.
        writeLocalToCloud()
        try startWatching()
        isRunning = true
        status = .current(.now)
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        onChange = nil
        isRunning = false
        status = .disabled
    }

    /// Called by `ProfileStore.didPersist` so any local mutation pushes to
    /// the cloud. No-op when sync is disabled.
    public func localDidChange() {
        guard isRunning else { return }
        writeLocalToCloud()
    }

    public func resolvePendingRemoteDeletion(for profileID: UUID) {
        pendingRemoteDeletions.remove(profileID)
        localDidChange()
    }

    // MARK: - Private

    private func startWatching() throws {
        // Watch the parent directory. Atomic writes replace the file inode; a
        // watcher attached to the old file silently stops receiving updates.
        let fd = open(cloudDirectory.path, O_EVTONLY)
        guard fd >= 0 else { throw SyncError.cannotWatch }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.mergeFromCloud()
                self?.onChange?()
            }
        }
        src.resume()
        self.source = src
    }

    private func writeLocalToCloud() {
        let snapshot = LocalSnapshot(
            profiles: store.profiles,
            tombstones: store.tombstones,
            tombstoneRevisions: store.tombstoneRevisions
        )
        do {
            let data = try JSONEncoder.iso.encode(snapshot)
            try fm.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
            try coordinatedWrite(data, to: cloudFileURL)
            status = .current(.now)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func mergeFromCloud() {
        guard fm.fileExists(atPath: cloudFileURL.path) else { return }
        let remote: LocalSnapshot
        do {
            let data = try coordinatedRead(from: cloudFileURL)
            guard !data.isEmpty else { return }
            remote = try JSONDecoder.iso.decode(LocalSnapshot.self, from: data)
        } catch {
            status = .failed("Could not read iCloud profile metadata: \(error.localizedDescription)")
            return
        }

        let merged = Self.merge(
            localProfiles: store.profiles,
            localTombstones: store.tombstones,
            remoteProfiles: remote.profiles,
            remoteTombstones: remote.tombstones,
            localTombstoneRevisions: store.tombstoneRevisions,
            remoteTombstoneRevisions: remote.tombstoneRevisions
        )
        var protectedProfiles = merged.profiles
        let mergedIDs = Set(merged.profiles.map(\.id))
        for local in store.profiles where !mergedIDs.contains(local.id) {
            pendingRemoteDeletions.insert(local.id)
            protectedProfiles.append(local)
        }
        protectedProfiles.sort { $0.createdAt < $1.createdAt }
        do {
            try store.replaceFromSyncThrowing(
                profiles: protectedProfiles,
                tombstones: merged.tombstones,
                tombstoneRevisions: merged.tombstoneRevisions)
            status = .current(.now)
        } catch {
            status = .failed("Could not persist merged iCloud metadata: \(error.localizedDescription)")
        }
    }

    /// Pure merge function. No file I/O, no shared state — given local and
    /// remote snapshots, produces a deterministic merged result. Extracted so
    /// the conflict-resolution policy can be tested in isolation from the
    /// DispatchSource / FileManager plumbing.
    public nonisolated static func merge(
        localProfiles: [Profile],
        localTombstones: [UUID: Date],
        remoteProfiles: [Profile],
        remoteTombstones: [UUID: Date],
        localTombstoneRevisions: [UUID: ProfileRevision] = [:],
        remoteTombstoneRevisions: [UUID: ProfileRevision] = [:]
    ) -> (
        profiles: [Profile],
        tombstones: [UUID: Date],
        tombstoneRevisions: [UUID: ProfileRevision]
    ) {
        var localById = Dictionary(uniqueKeysWithValues: localProfiles.map { ($0.id, $0) })
        var tombstones = localTombstones
        var tombstoneRevisions = localTombstoneRevisions

        // Pull in remote tombstones — keep the later of the two if both sides
        // tombstoned the same id.
        for (id, when) in remoteTombstones {
            let localRevision = tombstoneRevisions[id] ?? .legacy
            let remoteRevision = remoteTombstoneRevisions[id] ?? .legacy
            if localRevision != .legacy || remoteRevision != .legacy {
                if remoteRevision > localRevision {
                    tombstones[id] = when
                    tombstoneRevisions[id] = remoteRevision
                }
            } else {
                tombstones[id] = max(tombstones[id] ?? .distantPast, when)
            }
        }

        // Honor tombstones: remove any local entries that the cloud says are
        // deleted *after* the local entry was last updated.
        for (id, deletedAt) in tombstones {
            if let local = localById[id] {
                let deletionRevision = tombstoneRevisions[id] ?? .legacy
                let deletionWins =
                    deletionRevision != .legacy
                    ? deletionRevision >= local.revision
                    : local.updatedAt <= deletedAt
                if deletionWins { localById.removeValue(forKey: id) }
            }
        }

        // Merge remote profiles in.
        for remoteProfile in remoteProfiles {
            // Skip if tombstoned more recently than the remote update.
            if let deletedAt = tombstones[remoteProfile.id] {
                let deletionRevision = tombstoneRevisions[remoteProfile.id] ?? .legacy
                let deletionWins =
                    deletionRevision != .legacy
                    ? deletionRevision >= remoteProfile.revision
                    : deletedAt >= remoteProfile.updatedAt
                if deletionWins { continue }
            }
            if let local = localById[remoteProfile.id] {
                let remoteWins: Bool
                if remoteProfile.revision != .legacy || local.revision != .legacy {
                    remoteWins = remoteProfile.revision > local.revision
                } else {
                    remoteWins = remoteProfile.updatedAt > local.updatedAt
                }
                if remoteWins {
                    localById[remoteProfile.id] = remoteProfile
                }
            } else {
                localById[remoteProfile.id] = remoteProfile
            }
        }

        let merged = localById.values.sorted { $0.createdAt < $1.createdAt }
        return (Array(merged), tombstones, tombstoneRevisions)
    }

    private struct LocalSnapshot: Codable {
        var profiles: [Profile]
        var tombstones: [UUID: Date]
        var tombstoneRevisions: [UUID: ProfileRevision]

        enum CodingKeys: String, CodingKey {
            case profiles
            case tombstones
            case tombstoneRevisions
        }

        init(
            profiles: [Profile],
            tombstones: [UUID: Date],
            tombstoneRevisions: [UUID: ProfileRevision]
        ) {
            self.profiles = profiles
            self.tombstones = tombstones
            self.tombstoneRevisions = tombstoneRevisions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.profiles = try c.decode([Profile].self, forKey: .profiles)
            let strKeyed = try c.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
            var out: [UUID: Date] = [:]
            for (k, v) in strKeyed { if let id = UUID(uuidString: k) { out[id] = v } }
            self.tombstones = out
            let revisionStrings =
                try c.decodeIfPresent([String: ProfileRevision].self, forKey: .tombstoneRevisions) ?? [:]
            var revisions: [UUID: ProfileRevision] = [:]
            for (key, value) in revisionStrings {
                if let id = UUID(uuidString: key) { revisions[id] = value }
            }
            self.tombstoneRevisions = revisions
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(profiles, forKey: .profiles)
            let strKeyed = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.key.uuidString, $0.value) })
            try c.encode(strKeyed, forKey: .tombstones)
            let revisionStrings = Dictionary(
                uniqueKeysWithValues: tombstoneRevisions.map { ($0.key.uuidString, $0.value) })
            try c.encode(revisionStrings, forKey: .tombstoneRevisions)
        }
    }

    public enum SyncError: LocalizedError {
        case unavailable
        case cannotWatch

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return
                    "iCloud Drive is not available on this Mac. Turn it on in System Settings → [Your Name] → iCloud."
            case .cannotWatch: return "Couldn't open the iCloud Drive file for watching."
            }
        }
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SyncError.cannotWatch }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func migrateLegacyFileIfNeeded() throws {
        guard cloudDirectoryOverride == nil,
            cloudDirectory.standardizedFileURL != legacyCloudDirectory.standardizedFileURL
        else { return }
        let oldFile = legacyCloudDirectory.appendingPathComponent("profiles.json")
        guard fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: cloudFileURL.path) else { return }
        try fm.copyItem(at: oldFile, to: cloudFileURL)
        let preserved = legacyCloudDirectory.appendingPathComponent("profiles.pre-v2-migrated.json")
        if !fm.fileExists(atPath: preserved.path) {
            try fm.copyItem(at: oldFile, to: preserved)
        }
    }
}
