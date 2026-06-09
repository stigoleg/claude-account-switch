import Foundation

/// Mirrors `profiles.json` to iCloud Drive so the same profile list shows up
/// on every Mac signed into the user's iCloud account.
///
/// **Privacy**: only metadata (id, name, color, timestamps, tombstones) leaves
/// the device. No tokens, credentials, or project paths are uploaded.
///
/// **Conflict resolution**: per-profile last-writer-wins on `updatedAt`.
/// Deletions are represented as tombstones so a "deleted on Mac A" doesn't get
/// resurrected by a stale entry from Mac B.
///
/// Uses iCloud Drive at `~/Library/Mobile Documents/com~apple~CloudDocs/` —
/// not the CloudKit / NSUbiquitousKeyValueStore API — so we don't need an
/// iCloud entitlement (which would require a Developer ID signing identity).
@MainActor
public final class ProfileSyncService {
    private let store: ProfileStore
    private let fm = FileManager.default
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var onChange: (() -> Void)?
    private var isRunning = false

    public init(store: ProfileStore) {
        self.store = store
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeProfileSwitcher/`
    public var cloudDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/ClaudeProfileSwitcher", isDirectory: true)
    }

    public var cloudFileURL: URL {
        cloudDirectory.appendingPathComponent("profiles.json")
    }

    public var iCloudDriveAvailable: Bool {
        // ubiquityIdentityToken is non-nil whenever the user is signed into
        // iCloud. The CloudDocs folder is reachable as long as iCloud Drive is
        // turned on.
        fm.ubiquityIdentityToken != nil && fm.fileExists(atPath: cloudDirectory.deletingLastPathComponent().path)
    }

    /// Begin mirroring. Performs an initial merge with whatever is in the
    /// cloud, writes the local state out, and starts watching for remote
    /// updates.
    public func start(onMerge: @escaping () -> Void) throws {
        guard !isRunning else { return }
        guard iCloudDriveAvailable else {
            throw SyncError.unavailable
        }
        self.onChange = onMerge

        try fm.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)

        // Initial merge: pull from cloud first so we don't blow over any
        // updates made on another Mac.
        if fm.fileExists(atPath: cloudFileURL.path) {
            mergeFromCloud()
        }
        // Then push current local state.
        writeLocalToCloud()
        try startWatching()
        isRunning = true
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
    }

    /// Called by `ProfileStore.didPersist` so any local mutation pushes to
    /// the cloud. No-op when sync is disabled.
    public func localDidChange() {
        guard isRunning else { return }
        writeLocalToCloud()
    }

    // MARK: - Private

    private func startWatching() throws {
        // The cloud file may not exist on first run; touch it so we have an
        // FD to watch.
        if !fm.fileExists(atPath: cloudFileURL.path) {
            fm.createFile(atPath: cloudFileURL.path, contents: nil)
        }
        let fd = open(cloudFileURL.path, O_EVTONLY)
        guard fd >= 0 else { throw SyncError.cannotWatch }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.mergeFromCloud()
                self?.onChange?()
            }
        }
        src.setCancelHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.fileDescriptor >= 0 {
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
            }
        }
        src.resume()
        self.source = src
    }

    private func writeLocalToCloud() {
        let snapshot = LocalSnapshot(
            profiles: store.profiles,
            tombstones: store.tombstones
        )
        guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
        try? fm.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
        try? data.write(to: cloudFileURL, options: .atomic)
    }

    private func mergeFromCloud() {
        guard let data = try? Data(contentsOf: cloudFileURL),
            !data.isEmpty,
            let remote = try? JSONDecoder.iso.decode(LocalSnapshot.self, from: data)
        else { return }

        let merged = Self.merge(
            localProfiles: store.profiles,
            localTombstones: store.tombstones,
            remoteProfiles: remote.profiles,
            remoteTombstones: remote.tombstones
        )
        store.replaceFromSync(profiles: merged.profiles, tombstones: merged.tombstones)
    }

    /// Pure merge function. No file I/O, no shared state — given local and
    /// remote snapshots, produces a deterministic merged result. Extracted so
    /// the conflict-resolution policy can be tested in isolation from the
    /// DispatchSource / FileManager plumbing.
    public nonisolated static func merge(
        localProfiles: [Profile],
        localTombstones: [UUID: Date],
        remoteProfiles: [Profile],
        remoteTombstones: [UUID: Date]
    ) -> (profiles: [Profile], tombstones: [UUID: Date]) {
        var localById = Dictionary(uniqueKeysWithValues: localProfiles.map { ($0.id, $0) })
        var tombstones = localTombstones

        // Pull in remote tombstones — keep the later of the two if both sides
        // tombstoned the same id.
        for (id, when) in remoteTombstones {
            tombstones[id] = max(tombstones[id] ?? .distantPast, when)
        }

        // Honor tombstones: remove any local entries that the cloud says are
        // deleted *after* the local entry was last updated.
        for (id, deletedAt) in tombstones {
            if let local = localById[id], local.updatedAt <= deletedAt {
                localById.removeValue(forKey: id)
            }
        }

        // Merge remote profiles in.
        for remoteProfile in remoteProfiles {
            // Skip if tombstoned more recently than the remote update.
            if let deletedAt = tombstones[remoteProfile.id], deletedAt >= remoteProfile.updatedAt {
                continue
            }
            if let local = localById[remoteProfile.id] {
                if remoteProfile.updatedAt > local.updatedAt {
                    localById[remoteProfile.id] = remoteProfile
                }
            } else {
                localById[remoteProfile.id] = remoteProfile
            }
        }

        let merged = localById.values.sorted { $0.createdAt < $1.createdAt }
        return (Array(merged), tombstones)
    }

    private struct LocalSnapshot: Codable {
        var profiles: [Profile]
        var tombstones: [UUID: Date]

        enum CodingKeys: String, CodingKey {
            case profiles
            case tombstones
        }

        init(profiles: [Profile], tombstones: [UUID: Date]) {
            self.profiles = profiles
            self.tombstones = tombstones
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.profiles = try c.decode([Profile].self, forKey: .profiles)
            let strKeyed = try c.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
            var out: [UUID: Date] = [:]
            for (k, v) in strKeyed { if let id = UUID(uuidString: k) { out[id] = v } }
            self.tombstones = out
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(profiles, forKey: .profiles)
            let strKeyed = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.key.uuidString, $0.value) })
            try c.encode(strKeyed, forKey: .tombstones)
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
}
