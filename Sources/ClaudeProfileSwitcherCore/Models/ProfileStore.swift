import Foundation
import Observation

/// On-disk shape persisted in profiles.json.
struct ProfilesFile: Codable {
    var profiles: [Profile]
    var activeProfileID: UUID?
    var disabledProfileID: UUID?
    var schemaVersion: Int = 2
    /// IDs (as strings, for clean JSON) of profiles that have been deleted, with
    /// the time of deletion. Lets iCloud Drive sync distinguish "never seen on
    /// this machine" from "this machine deleted it" so the second machine
    /// doesn't resurrect them.
    var tombstones: [String: Date]?
    var tombstoneRevisions: [String: ProfileRevision]?

    enum CodingKeys: String, CodingKey {
        case profiles
        case activeProfileID
        case disabledProfileID
        case schemaVersion
        case tombstones
        case tombstoneRevisions
    }

    init(
        profiles: [Profile],
        activeProfileID: UUID?,
        disabledProfileID: UUID? = nil,
        schemaVersion: Int = 2,
        tombstones: [String: Date]?,
        tombstoneRevisions: [String: ProfileRevision]? = nil
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.disabledProfileID = disabledProfileID
        self.schemaVersion = schemaVersion
        self.tombstones = tombstones
        self.tombstoneRevisions = tombstoneRevisions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([Profile].self, forKey: .profiles)
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        disabledProfileID = try container.decodeIfPresent(UUID.self, forKey: .disabledProfileID)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones)
        tombstoneRevisions = try container.decodeIfPresent(
            [String: ProfileRevision].self, forKey: .tombstoneRevisions)
    }
}

@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profiles: [Profile] = []
    public private(set) var activeProfileID: UUID?
    public private(set) var disabledProfileID: UUID?
    /// Soft-deleted profile IDs and when the deletion happened. Used by the
    /// sync layer; the UI never reads this.
    public internal(set) var tombstones: [UUID: Date] = [:]
    public internal(set) var tombstoneRevisions: [UUID: ProfileRevision] = [:]
    /// Last error from `save()` or `load()`. Cleared on the next successful
    /// save. The view model surfaces this through `lastError` so users see
    /// persistent failures (e.g. disk full, permissions) instead of NSLog.
    public private(set) var lastPersistError: String?
    /// Set when both the primary and previous metadata snapshots are invalid.
    /// Mutating methods refuse to overwrite either file until recovery.
    public private(set) var requiresMetadataRecovery = false

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
    private var cachedDeviceID: String?

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

    /// Canonical paths Claude reads from. In v2 both remain real directories.
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
    public nonisolated var previousProfilesFileURL: URL {
        supportDirectory.appendingPathComponent("profiles.json.prev")
    }
    public nonisolated var deviceIDFileURL: URL {
        supportDirectory.appendingPathComponent("device-id")
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
        do {
            try ensureSupportDirectoriesThrowing()
        } catch {
            requiresMetadataRecovery = true
            lastPersistError = "Could not prepare profile storage: \(error.localizedDescription)"
            return
        }
        guard FileManager.default.fileExists(atPath: profilesFileURL.path) else {
            profiles = []
            activeProfileID = nil
            disabledProfileID = nil
            tombstones = [:]
            tombstoneRevisions = [:]
            requiresMetadataRecovery = false
            return
        }
        do {
            try apply(fileAt: profilesFileURL)
            requiresMetadataRecovery = false
            lastPersistError = nil
        } catch {
            NSLog("ProfileStore.load failed: \(error)")
            do {
                try apply(fileAt: previousProfilesFileURL)
                requiresMetadataRecovery = true
                lastPersistError =
                    "profiles.json is damaged. The previous valid snapshot was loaded read-only; repair metadata before making changes."
            } catch {
                profiles = []
                activeProfileID = nil
                disabledProfileID = nil
                tombstones = [:]
                tombstoneRevisions = [:]
                requiresMetadataRecovery = true
                lastPersistError =
                    "Both profiles.json and profiles.json.prev are unreadable. The files were preserved; recovery is required."
            }
        }
    }

    public func save() {
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            let msg = error.localizedDescription
            NSLog("ProfileStore.save failed: \(error)")
            lastPersistError = msg
        }
    }

    public func saveThrowing() throws {
        guard !requiresMetadataRecovery else {
            throw ProfileStoreError.recoveryRequired
        }
        try ensureSupportDirectoriesThrowing()
        let file = ProfilesFile(
            profiles: profiles,
            activeProfileID: activeProfileID,
            disabledProfileID: disabledProfileID,
            tombstones: tombstones.isEmpty ? nil : Self.encodeTombstones(tombstones),
            tombstoneRevisions: tombstoneRevisions.isEmpty
                ? nil : Self.encodeTombstoneRevisions(tombstoneRevisions)
        )
        do {
            let data = try JSONEncoder.iso.encode(file)
            let temporary = supportDirectory.appendingPathComponent(".profiles.json.new-\(UUID().uuidString)")
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: profilesFileURL.path) {
                if FileManager.default.fileExists(atPath: previousProfilesFileURL.path) {
                    try FileManager.default.removeItem(at: previousProfilesFileURL)
                }
                try FileManager.default.copyItem(at: profilesFileURL, to: previousProfilesFileURL)
                _ = try FileManager.default.replaceItemAt(profilesFileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: profilesFileURL)
            }
            lastPersistError = nil
        } catch {
            let msg = "Couldn't save profiles.json: \(error.localizedDescription)"
            lastPersistError = msg
            throw ProfileStoreError.persistenceFailed(msg)
        }
    }

    private func ensureSupportDirectories() {
        try? ensureSupportDirectoriesThrowing()
    }

    private func ensureSupportDirectoriesThrowing() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Mutations

    public func upsert(_ profile: Profile) {
        do { try upsertThrowing(profile) } catch { lastPersistError = error.localizedDescription }
    }

    public func upsertThrowing(_ profile: Profile) throws {
        let previous = profiles
        var p = profile
        p.updatedAt = .now
        p.revision = try nextRevision()
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
        }
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            profiles = previous
            throw error
        }
    }

    public func remove(_ profile: Profile) {
        do { try removeThrowing(profile) } catch { lastPersistError = error.localizedDescription }
    }

    public func removeThrowing(_ profile: Profile) throws {
        let oldProfiles = profiles
        let oldActive = activeProfileID
        let oldDisabled = disabledProfileID
        let oldTombstones = tombstones
        let oldTombstoneRevisions = tombstoneRevisions
        let deletionRevision = try nextRevision()
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        if disabledProfileID == profile.id { disabledProfileID = nil }
        tombstones[profile.id] = .now
        tombstoneRevisions[profile.id] = deletionRevision
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            profiles = oldProfiles
            activeProfileID = oldActive
            disabledProfileID = oldDisabled
            tombstones = oldTombstones
            tombstoneRevisions = oldTombstoneRevisions
            throw error
        }
    }

    public func setActive(_ profile: Profile) {
        do { try setActiveThrowing(profile) } catch { lastPersistError = error.localizedDescription }
    }

    public func setActiveThrowing(_ profile: Profile) throws {
        let previous = activeProfileID
        let previousDisabled = disabledProfileID
        activeProfileID = profile.id
        disabledProfileID = nil
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            activeProfileID = previous
            disabledProfileID = previousDisabled
            throw error
        }
    }

    /// Detach the active profile pointer without removing any profiles.
    public func clearActive() {
        do { try clearActiveThrowing() } catch { lastPersistError = error.localizedDescription }
    }

    public func clearActiveThrowing() throws {
        let previous = activeProfileID
        activeProfileID = nil
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            activeProfileID = previous
            throw error
        }
    }

    public func markDisabledThrowing(_ profile: Profile) throws {
        let previousActive = activeProfileID
        let previousDisabled = disabledProfileID
        activeProfileID = nil
        disabledProfileID = profile.id
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            activeProfileID = previousActive
            disabledProfileID = previousDisabled
            throw error
        }
    }

    /// Give a locally retained profile a new identity after another Mac has
    /// tombstoned its old ID. This is one metadata transaction so the old
    /// tombstone can never delete the retained profile again.
    public func replaceProfileIDThrowing(from old: Profile, with replacement: Profile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == old.id }) else { return }
        let oldProfiles = profiles
        let oldActive = activeProfileID
        let oldDisabled = disabledProfileID
        let oldTombstones = tombstones
        let oldTombstoneRevisions = tombstoneRevisions

        var updated = replacement
        updated.updatedAt = .now
        updated.revision = try nextRevision()
        profiles[index] = updated
        if activeProfileID == old.id { activeProfileID = replacement.id }
        if disabledProfileID == old.id { disabledProfileID = replacement.id }
        tombstones[old.id] = .now
        tombstoneRevisions[old.id] = try nextRevision()

        do {
            try saveThrowing()
            didPersist?()
        } catch {
            profiles = oldProfiles
            activeProfileID = oldActive
            disabledProfileID = oldDisabled
            tombstones = oldTombstones
            tombstoneRevisions = oldTombstoneRevisions
            throw error
        }
    }

    public func renameProfile(_ profile: Profile, to name: String) {
        do { try renameProfileThrowing(profile, to: name) } catch { lastPersistError = error.localizedDescription }
    }

    public func renameProfileThrowing(_ profile: Profile, to name: String) throws {
        let previous = profiles
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let revision = try nextRevision()
        let oldName = profiles[idx].name
        if oldName.caseInsensitiveCompare(name) != .orderedSame,
            !profiles[idx].aliases.contains(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame })
        {
            profiles[idx].aliases.append(oldName)
        }
        profiles[idx].name = name
        profiles[idx].updatedAt = .now
        profiles[idx].revision = revision
        do {
            try saveThrowing()
            didPersist?()
        } catch {
            profiles = previous
            throw error
        }
    }

    /// Replace the in-memory profile list and bump activeProfileID. Used by the
    /// sync layer when it has merged a remote update. Skips `didPersist` to
    /// avoid an immediate echo back to the cloud.
    public func replaceFromSync(
        profiles: [Profile],
        tombstones: [UUID: Date],
        tombstoneRevisions: [UUID: ProfileRevision] = [:]
    ) {
        do {
            try replaceFromSyncThrowing(
                profiles: profiles,
                tombstones: tombstones,
                tombstoneRevisions: tombstoneRevisions)
        } catch {
            lastPersistError = error.localizedDescription
        }
    }

    public func replaceFromSyncThrowing(
        profiles: [Profile],
        tombstones: [UUID: Date],
        tombstoneRevisions: [UUID: ProfileRevision] = [:]
    ) throws {
        let oldProfiles = self.profiles
        let oldTombstones = self.tombstones
        let oldTombstoneRevisions = self.tombstoneRevisions
        let oldActive = activeProfileID
        let oldDisabled = disabledProfileID
        self.profiles = profiles
        self.tombstones = tombstones
        self.tombstoneRevisions = tombstoneRevisions
        if let active = activeProfileID, !profiles.contains(where: { $0.id == active }) {
            activeProfileID = nil
        }
        if let disabled = disabledProfileID, !profiles.contains(where: { $0.id == disabled }) {
            disabledProfileID = nil
        }
        do {
            try saveThrowing()
        } catch {
            self.profiles = oldProfiles
            self.tombstones = oldTombstones
            self.tombstoneRevisions = oldTombstoneRevisions
            activeProfileID = oldActive
            disabledProfileID = oldDisabled
            throw error
        }
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

    private static func encodeTombstoneRevisions(
        _ revisions: [UUID: ProfileRevision]
    ) -> [String: ProfileRevision] {
        Dictionary(uniqueKeysWithValues: revisions.map { ($0.key.uuidString, $0.value) })
    }

    private static func decodeTombstoneRevisions(
        _ revisions: [String: ProfileRevision]?
    ) -> [UUID: ProfileRevision] {
        guard let revisions else { return [:] }
        var result: [UUID: ProfileRevision] = [:]
        for (key, value) in revisions {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    /// Append a single-line entry to the switch log.
    public func appendLog(_ message: String) {
        ensureSupportDirectories()
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: .now)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: logFileURL.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue > 1_048_576
        {
            let previous = logFileURL.deletingLastPathComponent().appendingPathComponent("switch.log.1")
            if fm.fileExists(atPath: previous.path) { try? fm.removeItem(at: previous) }
            try? fm.moveItem(at: logFileURL, to: previous)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            try? data.write(to: logFileURL, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func apply(fileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder.iso.decode(ProfilesFile.self, from: data)
        guard file.schemaVersion <= 2 else {
            throw ProfileStoreError.unsupportedSchema(file.schemaVersion)
        }
        profiles = file.profiles
        activeProfileID = file.activeProfileID
        disabledProfileID = file.disabledProfileID
        tombstones = Self.decodeTombstones(file.tombstones)
        tombstoneRevisions = Self.decodeTombstoneRevisions(file.tombstoneRevisions)
    }

    private func nextRevision() throws -> ProfileRevision {
        let next =
            max(
                profiles.map(\.revision.counter).max() ?? 0,
                tombstoneRevisions.values.map(\.counter).max() ?? 0)
            + 1
        return ProfileRevision(counter: next, deviceID: try deviceID())
    }

    private func deviceID() throws -> String {
        if let cachedDeviceID { return cachedDeviceID }
        if FileManager.default.fileExists(atPath: deviceIDFileURL.path) {
            let value = try String(contentsOf: deviceIDFileURL, encoding: .utf8)
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: result) != nil else {
                throw ProfileStoreError.persistenceFailed(
                    "The device-id file is invalid; refusing to change sync identity.")
            }
            cachedDeviceID = result
            return result
        }
        let value = UUID().uuidString
        try ensureSupportDirectoriesThrowing()
        try (value + "\n").write(to: deviceIDFileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: deviceIDFileURL.path)
        let handle = try FileHandle(forWritingTo: deviceIDFileURL)
        try handle.synchronize()
        try handle.close()
        cachedDeviceID = value
        return value
    }
}

public enum ProfileStoreError: LocalizedError {
    case recoveryRequired
    case unsupportedSchema(Int)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .recoveryRequired:
            return "Profile metadata requires recovery; refusing to overwrite the preserved files."
        case .unsupportedSchema(let version):
            return "profiles.json uses unsupported schema version \(version)."
        case .persistenceFailed(let message):
            return message
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
