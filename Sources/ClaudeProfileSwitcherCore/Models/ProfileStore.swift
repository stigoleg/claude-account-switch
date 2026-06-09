import Foundation
import Observation

/// On-disk shape persisted in profiles.json.
struct ProfilesFile: Codable {
    var profiles: [Profile]
    var activeProfileID: UUID?
    var schemaVersion: Int = 1
    /// IDs (as strings, for clean JSON) of profiles that have been deleted, with
    /// the time of deletion. Lets iCloud Drive sync distinguish "never seen on
    /// this machine" from "this machine deleted it" so the second machine
    /// doesn't resurrect them.
    var tombstones: [String: Date]?
}

@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profiles: [Profile] = []
    public private(set) var activeProfileID: UUID?
    /// Soft-deleted profile IDs and when the deletion happened. Used by the
    /// sync layer; the UI never reads this.
    public internal(set) var tombstones: [UUID: Date] = [:]
    /// Last error from `save()` or `load()`. Cleared on the next successful
    /// save. The view model surfaces this through `lastError` so users see
    /// persistent failures (e.g. disk full, permissions) instead of NSLog.
    public private(set) var lastPersistError: String?

    public var activeProfile: Profile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Callback invoked at the end of every `save()`. The sync service hooks in
    /// here to mirror `profiles.json` to iCloud Drive.
    public var didPersist: (@MainActor () -> Void)?

    /// Optional root that overrides the default `~/Library/Application Support`
    /// directory. Used by tests so the store reads/writes inside an isolated
    /// tmp dir without touching the user's real data.
    private let supportRootOverride: URL?

    public init(supportRoot: URL? = nil) {
        self.supportRootOverride = supportRoot
    }

    // MARK: - Paths
    //
    // All static path constants are `nonisolated` so the off-main keychain
    // probe and other background services can compute them without hopping to
    // the main actor. They derive from immutable system paths and are
    // initialized once at module load.

    /// `~/Library/Application Support/ClaudeProfileSwitcher/`
    public nonisolated static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClaudeProfileSwitcher", isDirectory: true)
    }()

    public nonisolated static let profilesDirectory = supportDirectory.appendingPathComponent(
        "profiles", isDirectory: true)
    public nonisolated static let profilesFileURL = supportDirectory.appendingPathComponent("profiles.json")
    public nonisolated static let logFileURL = supportDirectory.appendingPathComponent("logs/switch.log")

    /// Canonical paths Claude reads from — these become symlinks after migration.
    public nonisolated static let claudeCLIPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        ".claude")
    public nonisolated static let claudeDesktopPath: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Claude", isDirectory: true)
    }()

    // Instance-level path accessors honor the test override. They read only
    // the `let supportRootOverride`, so they are safe to call from any actor
    // (e.g. the off-main keychain probe).
    public nonisolated var supportDirectory: URL {
        supportRootOverride ?? Self.supportDirectory
    }
    public nonisolated var profilesDirectory: URL {
        supportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }
    public nonisolated var profilesFileURL: URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }
    public nonisolated var logFileURL: URL {
        supportDirectory.appendingPathComponent("logs/switch.log")
    }

    public nonisolated func profileDirectory(_ profile: Profile) -> URL {
        profilesDirectory.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    public nonisolated func cliDirectory(_ profile: Profile) -> URL {
        profileDirectory(profile).appendingPathComponent("cli", isDirectory: true)
    }

    public nonisolated func desktopDirectory(_ profile: Profile) -> URL {
        profileDirectory(profile).appendingPathComponent("desktop", isDirectory: true)
    }

    // MARK: - Load / save

    public func load() {
        ensureSupportDirectories()
        guard FileManager.default.fileExists(atPath: profilesFileURL.path) else {
            profiles = []
            activeProfileID = nil
            tombstones = [:]
            return
        }
        do {
            let data = try Data(contentsOf: profilesFileURL)
            let file = try JSONDecoder.iso.decode(ProfilesFile.self, from: data)
            self.profiles = file.profiles
            self.activeProfileID = file.activeProfileID
            self.tombstones = Self.decodeTombstones(file.tombstones)
        } catch {
            NSLog("ProfileStore.load failed: \(error)")
            profiles = []
            activeProfileID = nil
            tombstones = [:]
        }
    }

    public func save() {
        ensureSupportDirectories()
        let file = ProfilesFile(
            profiles: profiles,
            activeProfileID: activeProfileID,
            tombstones: tombstones.isEmpty ? nil : Self.encodeTombstones(tombstones)
        )
        do {
            let data = try JSONEncoder.iso.encode(file)
            try data.write(to: profilesFileURL, options: .atomic)
            lastPersistError = nil
        } catch {
            let msg = "Couldn't save profiles.json: \(error.localizedDescription)"
            NSLog("ProfileStore.save failed: \(error)")
            lastPersistError = msg
        }
        didPersist?()
    }

    private func ensureSupportDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    // MARK: - Mutations

    public func upsert(_ profile: Profile) {
        var p = profile
        p.updatedAt = .now
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
        save()
    }

    public func remove(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        tombstones[profile.id] = .now
        save()
    }

    public func setActive(_ profile: Profile) {
        activeProfileID = profile.id
        save()
    }

    /// Detach the active profile pointer without removing any profiles. Used
    /// by "Disable & Restore Original Layout" — after the symlinks come down
    /// there is no longer an "active" profile until the user re-migrates.
    public func clearActive() {
        activeProfileID = nil
        save()
    }

    public func renameProfile(_ profile: Profile, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].name = name
        profiles[idx].updatedAt = .now
        save()
    }

    /// Replace the in-memory profile list and bump activeProfileID. Used by the
    /// sync layer when it has merged a remote update. Skips `didPersist` to
    /// avoid an immediate echo back to the cloud.
    public func replaceFromSync(profiles: [Profile], tombstones: [UUID: Date]) {
        self.profiles = profiles
        self.tombstones = tombstones
        if let active = activeProfileID, !profiles.contains(where: { $0.id == active }) {
            activeProfileID = nil
        }
        // Persist locally without re-triggering didPersist.
        let saved = didPersist
        didPersist = nil
        save()
        didPersist = saved
    }

    private static func encodeTombstones(_ in: [UUID: Date]) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: `in`.map { ($0.key.uuidString, $0.value) })
    }

    private static func decodeTombstones(_ in: [String: Date]?) -> [UUID: Date] {
        guard let `in` else { return [:] }
        var out: [UUID: Date] = [:]
        for (k, v) in `in` { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }

    /// Append a single-line entry to the switch log.
    public func appendLog(_ message: String) {
        ensureSupportDirectories()
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: .now)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            try? data.write(to: logFileURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
