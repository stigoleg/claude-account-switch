import CryptoKit
import Darwin
import Foundation

public enum LayoutHealth: Equatable, Sendable {
    case healthy
    case migrationRequired
    case recoveryRequired(String)
    case unsupportedFilesystem(String)
}

public enum LocalProfileState: Equatable, Sendable {
    case active
    case ready
    case setupRequired
}

public struct SwitchResult: Equatable, Sendable {
    public let switched: Bool
    public let desktopRelaunched: Bool
    public let relaunchError: String?

    public init(switched: Bool, desktopRelaunched: Bool, relaunchError: String? = nil) {
        self.switched = switched
        self.desktopRelaunched = desktopRelaunched
        self.relaunchError = relaunchError
    }
}

public enum LayoutRecoveryOutcome: Equatable, Sendable {
    case active(UUID)
    case disabled(UUID)
    case restoredBackup(UUID)
}

public struct OperationJournal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case desktopSwitch
        case v1Migration
        case defaultRestore
        case preV2Restore
    }

    public enum Phase: String, Codable, Sendable {
        case prepared
        case swapped
        case previousProfileStored
        case complete
    }

    public let id: UUID
    public let kind: Kind
    public let previousProfileID: UUID?
    public let targetProfileID: UUID
    public var phase: Phase
    public let createdAt: Date
    public let auxiliaryPath: String?
    public let recoveryPath: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        previousProfileID: UUID?,
        targetProfileID: UUID,
        phase: Phase = .prepared,
        createdAt: Date = .now,
        auxiliaryPath: String? = nil,
        recoveryPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.previousProfileID = previousProfileID
        self.targetProfileID = targetProfileID
        self.phase = phase
        self.createdAt = createdAt
        self.auxiliaryPath = auxiliaryPath
        self.recoveryPath = recoveryPath
    }
}

public struct MigrationBackup: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let directory: URL
    public let profilesFileSHA256: String?
    public let profileCount: Int
    public let inventory: BackupInventory

    public init(
        createdAt: Date,
        directory: URL,
        profilesFileSHA256: String?,
        profileCount: Int,
        inventory: BackupInventory
    ) {
        self.createdAt = createdAt
        self.directory = directory
        self.profilesFileSHA256 = profilesFileSHA256
        self.profileCount = profileCount
        self.inventory = inventory
    }
}

public struct BackupInventory: Codable, Equatable, Sendable {
    public let entryCount: Int
    public let logicalBytes: UInt64
    public let manifestSHA256: String
    public let criticalFileHashes: [String: String]

    public init(
        entryCount: Int,
        logicalBytes: UInt64,
        manifestSHA256: String,
        criticalFileHashes: [String: String]
    ) {
        self.entryCount = entryCount
        self.logicalBytes = logicalBytes
        self.manifestSHA256 = manifestSHA256
        self.criticalFileHashes = criticalFileHashes
    }
}

public enum ProfileLayoutError: LocalizedError, Equatable {
    case migrationRequired
    case noActiveProfile
    case canonicalDesktopMissing
    case canonicalDesktopIsSymlink
    case targetDesktopMissing(URL)
    case targetDesktopIsSymlink(URL)
    case previousDesktopAlreadyExists(URL)
    case profileMarkerMismatch(expected: UUID, actual: UUID?)
    case differentVolumes
    case desktopStillRunning
    case legacyCLIStillRunning
    case pendingRecovery(String)
    case unsupportedFilesystem(String)
    case invalidLegacyLayout(String)
    case backupFailed(String)
    case restoreFailed(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .migrationRequired:
            return "The legacy symlink layout must be migrated before switching profiles."
        case .noActiveProfile:
            return "No active profile is recorded."
        case .canonicalDesktopMissing:
            return "The active Claude Desktop directory is missing."
        case .canonicalDesktopIsSymlink:
            return "Claude Desktop still uses the legacy symlink layout. Run the v2 migration first."
        case .targetDesktopMissing(let url):
            return "The target Desktop profile is missing at \(url.path)."
        case .targetDesktopIsSymlink(let url):
            return "The target Desktop profile is a symlink at \(url.path); refusing to switch."
        case .previousDesktopAlreadyExists(let url):
            return "The previous profile already has Desktop data at \(url.path); refusing to overwrite it."
        case .profileMarkerMismatch(let expected, let actual):
            return "Profile marker mismatch. Expected \(expected), found \(actual?.uuidString ?? "none")."
        case .differentVolumes:
            return
                "The active and target Desktop directories are on different volumes; atomic switching is unavailable."
        case .desktopStillRunning:
            return "Claude Desktop did not quit. No profile files were changed."
        case .legacyCLIStillRunning:
            return
                "Close all existing Claude Code sessions before the one-time v2 migration. No profile files were changed."
        case .pendingRecovery(let message):
            return "A previous profile operation needs recovery: \(message)"
        case .unsupportedFilesystem(let message):
            return message
        case .invalidLegacyLayout(let message):
            return "The legacy profile layout is inconsistent: \(message)"
        case .backupFailed(let message):
            return "Could not create the required pre-v2 backup: \(message)"
        case .restoreFailed(let message):
            return "Could not restore the pre-v2 backup: \(message)"
        case .ioFailure(let message):
            return message
        }
    }
}

public protocol ProfileLayoutServicing: Sendable {
    func health(activeProfileID: UUID?, profiles: [Profile]) -> LayoutHealth
    func desktopDirectory(for profile: Profile, activeProfileID: UUID?) -> URL
    func localState(for profile: Profile, activeProfileID: UUID?) -> LocalProfileState
    func prepareNewProfile(_ profile: Profile) throws
    func switchDesktop(from previous: Profile, to target: Profile) throws
    func completeSwitchJournal() throws
    func recoverPendingOperation() throws -> LayoutRecoveryOutcome?
    func createPreV2Backup(profiles: [Profile]) throws -> MigrationBackup
    func availableBackups() -> [MigrationBackup]
    func verifyBackup(_ backup: MigrationBackup) throws -> Bool
    func moveBackupToTrash(_ backup: MigrationBackup) throws
    func restorePreV2Backup(_ backup: MigrationBackup, currentActiveID: UUID?) throws -> UUID
    func migrateLegacyLayout(active: Profile, profiles: [Profile]) throws
    func adoptCurrentLayout(active: Profile) throws
    func restoreDefaultLayout(active: Profile) throws
    func reassignLocalProfileData(from old: Profile, to replacement: Profile, active: Bool) throws
}

/// Owns the v2 on-disk invariant:
/// - the active Desktop profile is the real canonical Claude directory;
/// - each inactive Desktop profile is a real directory under its UUID;
/// - CLI profile directories never move and are selected with CLAUDE_CONFIG_DIR.
public struct ProfileLayoutService: ProfileLayoutServicing, @unchecked Sendable {
    public static let markerFilename = ".claude-profile-switcher-id"

    public let store: ProfileStore
    public let canonicalDesktop: URL
    public let canonicalCLI: URL
    private let fm: FileManager

    public init(
        store: ProfileStore,
        canonicalDesktop: URL = ProfileStore.claudeDesktopPath,
        canonicalCLI: URL = ProfileStore.claudeCLIPath,
        fm: FileManager = .default
    ) {
        self.store = store
        self.canonicalDesktop = canonicalDesktop
        self.canonicalCLI = canonicalCLI
        self.fm = fm
    }

    public var journalURL: URL {
        store.supportDirectory.appendingPathComponent("operation-journal.json")
    }

    public var backupsDirectory: URL {
        store.supportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    public func desktopDirectory(for profile: Profile, activeProfileID: UUID?) -> URL {
        activeProfileID == profile.id ? canonicalDesktop : store.desktopDirectory(profile)
    }

    public func localState(for profile: Profile, activeProfileID: UUID?) -> LocalProfileState {
        if activeProfileID == profile.id {
            return marker(at: canonicalDesktop) == profile.id ? .active : .setupRequired
        }
        let cli = store.cliDirectory(profile)
        let desktop = store.desktopDirectory(profile)
        return isDirectory(cli) && !isSymlink(cli) && marker(at: desktop) == profile.id
            ? .ready : .setupRequired
    }

    public func health(activeProfileID: UUID?, profiles: [Profile]) -> LayoutHealth {
        if fm.fileExists(atPath: journalURL.path) {
            return .recoveryRequired("operation-journal.json is present")
        }
        if isSymlink(canonicalDesktop) || isSymlink(canonicalCLI) {
            return .migrationRequired
        }
        if containsSymlinkComponent(canonicalDesktop.deletingLastPathComponent()) {
            return .unsupportedFilesystem("The canonical Desktop path has a symlinked ancestor.")
        }
        guard let activeProfileID else {
            return profiles.isEmpty ? .migrationRequired : .recoveryRequired("no active profile is recorded")
        }
        guard profiles.contains(where: { $0.id == activeProfileID }) else {
            return .recoveryRequired("the active profile is missing from metadata")
        }
        guard isDirectory(canonicalDesktop), !isSymlink(canonicalDesktop) else {
            return .recoveryRequired("the canonical Desktop directory is missing or is not a real directory")
        }
        guard marker(at: canonicalDesktop) == activeProfileID else {
            return .recoveryRequired("the canonical Desktop marker does not match the active profile")
        }
        return .healthy
    }

    public func prepareNewProfile(_ profile: Profile) throws {
        try ensureDirectory(store.cliDirectory(profile), permissions: 0o700)
        let desktop = store.desktopDirectory(profile)
        try ensureDirectory(desktop, permissions: 0o700)
        try writeMarker(profile.id, at: desktop)
    }

    public func switchDesktop(from previous: Profile, to target: Profile) throws {
        guard !isSymlink(canonicalDesktop) else { throw ProfileLayoutError.migrationRequired }
        guard !containsSymlinkComponent(canonicalDesktop.deletingLastPathComponent()) else {
            throw ProfileLayoutError.invalidLegacyLayout(
                "the canonical Desktop path has a symlinked ancestor")
        }
        guard isDirectory(canonicalDesktop) else { throw ProfileLayoutError.canonicalDesktopMissing }
        guard marker(at: canonicalDesktop) == previous.id else {
            throw ProfileLayoutError.profileMarkerMismatch(
                expected: previous.id, actual: marker(at: canonicalDesktop))
        }

        let targetStored = store.desktopDirectory(target)
        let previousStored = store.desktopDirectory(previous)
        guard isDirectory(targetStored) else { throw ProfileLayoutError.targetDesktopMissing(targetStored) }
        guard !isSymlink(targetStored) else { throw ProfileLayoutError.targetDesktopIsSymlink(targetStored) }
        guard !containsSymlinkComponent(targetStored.deletingLastPathComponent()) else {
            throw ProfileLayoutError.invalidLegacyLayout(
                "the target Desktop profile has a symlinked ancestor")
        }
        guard marker(at: targetStored) == target.id else {
            throw ProfileLayoutError.profileMarkerMismatch(expected: target.id, actual: marker(at: targetStored))
        }
        guard !itemExists(previousStored) else {
            throw ProfileLayoutError.previousDesktopAlreadyExists(previousStored)
        }
        guard deviceID(canonicalDesktop) == deviceID(targetStored) else {
            throw ProfileLayoutError.differentVolumes
        }

        var journal = OperationJournal(
            kind: .desktopSwitch,
            previousProfileID: previous.id,
            targetProfileID: target.id)
        try writeJournal(journal)

        do {
            try atomicSwap(canonicalDesktop, targetStored)
            journal.phase = .swapped
            try writeJournal(journal)

            // targetStored now contains the previous active profile.
            try fm.moveItem(at: targetStored, to: previousStored)
            journal.phase = .previousProfileStored
            try writeJournal(journal)
        } catch {
            // Recovery uses the markers to determine which of the two durable
            // states was reached. Never guess or overwrite either directory.
            throw ProfileLayoutError.pendingRecovery(error.localizedDescription)
        }
    }

    /// Completes an interrupted swap. Returns the profile ID that is physically
    /// active after recovery so the caller can commit matching metadata.
    public func recoverPendingOperation() throws -> LayoutRecoveryOutcome? {
        guard itemExists(journalURL) else { return nil }
        let journal: OperationJournal
        do {
            journal = try JSONDecoder.iso.decode(OperationJournal.self, from: Data(contentsOf: journalURL))
        } catch {
            throw ProfileLayoutError.pendingRecovery("the journal is unreadable: \(error.localizedDescription)")
        }
        if journal.kind == .v1Migration {
            let active = Profile(id: journal.targetProfileID, name: "recovery-active")
            let storedDesktop = store.desktopDirectory(active)
            if isSymlink(canonicalDesktop) {
                try fm.removeItem(at: canonicalDesktop)
            }
            if !itemExists(canonicalDesktop) {
                guard marker(at: storedDesktop) == active.id else {
                    throw ProfileLayoutError.pendingRecovery("the active legacy Desktop directory is missing")
                }
                try fm.moveItem(at: storedDesktop, to: canonicalDesktop)
            }
            if marker(at: canonicalDesktop) == nil, !itemExists(storedDesktop), isDirectory(canonicalDesktop) {
                try writeMarker(active.id, at: canonicalDesktop)
            }
            guard marker(at: canonicalDesktop) == active.id else {
                throw ProfileLayoutError.pendingRecovery("the migrated Desktop marker is invalid")
            }
            let storedCLI = store.cliDirectory(active)
            if !isSymlink(canonicalCLI), isDirectory(canonicalCLI), !itemExists(storedCLI) {
                try ensureDirectory(storedCLI.deletingLastPathComponent(), permissions: 0o700)
                try fm.moveItem(at: canonicalCLI, to: storedCLI)
            }
            if isSymlink(canonicalCLI) { try fm.removeItem(at: canonicalCLI) }
            if !itemExists(canonicalCLI) { try ensureDirectory(canonicalCLI, permissions: 0o700) }
            return .active(active.id)
        }
        if journal.kind == .defaultRestore {
            let active = Profile(id: journal.targetProfileID, name: "restore-active")
            let storedCLI = store.cliDirectory(active)
            guard let backupPath = journal.auxiliaryPath else {
                throw ProfileLayoutError.pendingRecovery("the restore journal has no fallback backup path")
            }
            let fallbackBackup = URL(fileURLWithPath: backupPath)
            if itemExists(storedCLI) {
                if itemExists(canonicalCLI), !itemExists(fallbackBackup) {
                    try ensureDirectory(fallbackBackup.deletingLastPathComponent(), permissions: 0o700)
                    try fm.moveItem(at: canonicalCLI, to: fallbackBackup)
                }
                guard !itemExists(canonicalCLI) else {
                    throw ProfileLayoutError.pendingRecovery("both restored and profile CLI directories are present")
                }
                try fm.moveItem(at: storedCLI, to: canonicalCLI)
            }
            guard isDirectory(canonicalCLI), !isSymlink(canonicalCLI) else {
                throw ProfileLayoutError.pendingRecovery("the restored CLI directory is missing")
            }
            let markerURL = canonicalDesktop.appendingPathComponent(Self.markerFilename)
            if itemExists(markerURL) { try fm.removeItem(at: markerURL) }
            return .disabled(active.id)
        }
        if journal.kind == .preV2Restore {
            try finishPreV2Restore(journal)
            return .restoredBackup(journal.targetProfileID)
        }
        guard let previousID = journal.previousProfileID else {
            throw ProfileLayoutError.pendingRecovery("the switch journal has no previous profile")
        }

        let target = Profile(id: journal.targetProfileID, name: "recovery-target")
        let previous = Profile(id: previousID, name: "recovery-previous")
        let targetStored = store.desktopDirectory(target)
        let previousStored = store.desktopDirectory(previous)
        let canonicalID = marker(at: canonicalDesktop)

        if canonicalID == previousID {
            // Swap never committed. The original layout is intact.
            return .active(previousID)
        }
        guard canonicalID == journal.targetProfileID else {
            throw ProfileLayoutError.pendingRecovery("the canonical marker matches neither journal profile")
        }

        if marker(at: targetStored) == previousID {
            guard !itemExists(previousStored) else {
                throw ProfileLayoutError.previousDesktopAlreadyExists(previousStored)
            }
            try fm.moveItem(at: targetStored, to: previousStored)
        } else if marker(at: previousStored) != previousID {
            throw ProfileLayoutError.pendingRecovery("the previous profile data could not be located")
        }

        return .active(journal.targetProfileID)
    }

    public func completeSwitchJournal() throws {
        if itemExists(journalURL) {
            let journal = try JSONDecoder.iso.decode(
                OperationJournal.self, from: Data(contentsOf: journalURL))
            if journal.kind == .preV2Restore {
                let desktopSetMarker = canonicalDesktop.appendingPathComponent(".claude-profile-restore-set")
                if itemExists(desktopSetMarker) { try fm.removeItem(at: desktopSetMarker) }
                let profilesSetMarker = store.profilesDirectory.appendingPathComponent(".restore-set-id")
                if itemExists(profilesSetMarker) { try fm.removeItem(at: profilesSetMarker) }
                let metadata = restoreMetadataURL(journal.id)
                if itemExists(metadata) { try fm.removeItem(at: metadata) }
                let stage = restoreStageDirectory(journal.id)
                if itemExists(stage),
                    (try fm.contentsOfDirectory(atPath: stage.path)).isEmpty
                {
                    try fm.removeItem(at: stage)
                }
            }
        }
        try removeJournal()
    }

    public func createPreV2Backup(profiles: [Profile]) throws -> MigrationBackup {
        try preflightBackupVolume()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = backupsDirectory.appendingPathComponent(
            "pre-v2-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))")
        guard !itemExists(root) else {
            throw ProfileLayoutError.backupFailed("backup destination already exists")
        }
        do {
            try ensureDirectory(backupsDirectory, permissions: 0o700)
            try ensureDirectory(root, permissions: 0o700)
            let profileBackup = root.appendingPathComponent("profiles", isDirectory: true)
            if itemExists(store.profilesDirectory) {
                try cloneDirectory(store.profilesDirectory, to: profileBackup)
            } else {
                try ensureDirectory(profileBackup, permissions: 0o700)
            }
            if itemExists(store.profilesFileURL) {
                try fm.copyItem(at: store.profilesFileURL, to: root.appendingPathComponent("profiles.json"))
            }
            if isDirectory(canonicalDesktop), !isSymlink(canonicalDesktop) {
                try cloneDirectory(canonicalDesktop, to: root.appendingPathComponent("canonical-desktop"))
            }
            if isDirectory(canonicalCLI), !isSymlink(canonicalCLI) {
                try cloneDirectory(canonicalCLI, to: root.appendingPathComponent("canonical-cli"))
            }
            let sourceInventory = try inventory(
                roots: [
                    "profiles": store.profilesDirectory,
                    "canonical-desktop": canonicalDesktop,
                    "canonical-cli": canonicalCLI,
                ].filter { isDirectory($0.value) && !isSymlink($0.value) })
            let backupInventory = try inventory(
                roots: [
                    "profiles": profileBackup,
                    "canonical-desktop": root.appendingPathComponent("canonical-desktop"),
                    "canonical-cli": root.appendingPathComponent("canonical-cli"),
                ].filter { isDirectory($0.value) && !isSymlink($0.value) })
            guard sourceInventory == backupInventory else {
                throw ProfileLayoutError.backupFailed(
                    "backup inventory verification failed "
                        + "(source: \(sourceInventory.entryCount)/\(sourceInventory.logicalBytes)/\(sourceInventory.manifestSHA256), "
                        + "backup: \(backupInventory.entryCount)/\(backupInventory.logicalBytes)/\(backupInventory.manifestSHA256))"
                )
            }
            let backup = MigrationBackup(
                createdAt: .now,
                directory: root,
                profilesFileSHA256: sha256(of: store.profilesFileURL),
                profileCount: profiles.count,
                inventory: backupInventory)
            try atomicWrite(try JSONEncoder.iso.encode(backup), to: root.appendingPathComponent("backup.json"))
            return backup
        } catch let error as ProfileLayoutError {
            throw error
        } catch {
            throw ProfileLayoutError.backupFailed(error.localizedDescription)
        }
    }

    public func availableBackups() -> [MigrationBackup] {
        guard
            let directories = try? fm.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        return directories.compactMap { directory in
            let manifest = directory.appendingPathComponent("backup.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? JSONDecoder.iso.decode(MigrationBackup.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func verifyBackup(_ backup: MigrationBackup) throws -> Bool {
        let root = backup.directory
        guard isDirectory(root), !isSymlink(root) else { return false }
        let roots = [
            "profiles": root.appendingPathComponent("profiles"),
            "canonical-desktop": root.appendingPathComponent("canonical-desktop"),
            "canonical-cli": root.appendingPathComponent("canonical-cli"),
        ].filter { isDirectory($0.value) && !isSymlink($0.value) }
        return try inventory(roots: roots) == backup.inventory
            && sha256(of: root.appendingPathComponent("profiles.json")) == backup.profilesFileSHA256
    }

    public func moveBackupToTrash(_ backup: MigrationBackup) throws {
        let root = backup.directory.standardizedFileURL
        let expectedParent = backupsDirectory.standardizedFileURL.path + "/"
        guard root.path.hasPrefix(expectedParent),
            isDirectory(root),
            !isSymlink(root),
            itemExists(root.appendingPathComponent("backup.json"))
        else {
            throw ProfileLayoutError.ioFailure("Refusing to remove an unrecognized backup path.")
        }
        var trashed: NSURL?
        try fm.trashItem(at: root, resultingItemURL: &trashed)
    }

    /// Restores backup contents into the safe v2 physical layout. The current
    /// layout is retained under Backups/pre-restore-v2-* and every swap is
    /// recoverable from operation-journal.json.
    public func restorePreV2Backup(_ backup: MigrationBackup, currentActiveID: UUID?) throws -> UUID {
        guard !itemExists(journalURL) else {
            throw ProfileLayoutError.pendingRecovery("finish the existing operation before restoring a backup")
        }
        guard try verifyBackup(backup) else {
            throw ProfileLayoutError.restoreFailed("backup verification failed; no files were changed")
        }
        guard isDirectory(canonicalDesktop), !isSymlink(canonicalDesktop),
            isDirectory(store.profilesDirectory), !isSymlink(store.profilesDirectory)
        else {
            throw ProfileLayoutError.restoreFailed("the current v2 layout is not healthy")
        }

        let journalID = UUID()
        let stage = restoreStageDirectory(journalID)
        let stageProfiles = stage.appendingPathComponent("profiles", isDirectory: true)
        let stageDesktop = stage.appendingPathComponent("canonical-desktop", isDirectory: true)
        let recovery = backupsDirectory.appendingPathComponent(
            "pre-restore-v2-\(journalID.uuidString)", isDirectory: true)
        try ensureDirectory(stage, permissions: 0o700)
        try ensureDirectory(recovery, permissions: 0o700)

        let backupProfilesFile = backup.directory.appendingPathComponent("profiles.json")
        let restoredFile: ProfilesFile
        if itemExists(backupProfilesFile) {
            let decoded = try JSONDecoder.iso.decode(
                ProfilesFile.self, from: Data(contentsOf: backupProfilesFile))
            restoredFile = ProfilesFile(
                profiles: decoded.profiles,
                activeProfileID: decoded.activeProfileID,
                disabledProfileID: nil,
                schemaVersion: 2,
                tombstones: decoded.tombstones,
                tombstoneRevisions: decoded.tombstoneRevisions)
            guard let activeID = restoredFile.activeProfileID,
                let activeProfile = restoredFile.profiles.first(where: { $0.id == activeID })
            else {
                throw ProfileLayoutError.restoreFailed("backup metadata has no valid active profile")
            }
            try cloneDirectory(backup.directory.appendingPathComponent("profiles"), to: stageProfiles)
            for profile in restoredFile.profiles {
                try ensureDirectory(storeCLI(in: stageProfiles, profile: profile), permissions: 0o700)
                let desktop = storeDesktop(in: stageProfiles, profile: profile)
                guard isDirectory(desktop), !isSymlink(desktop) else {
                    throw ProfileLayoutError.restoreFailed("Desktop data is missing for \(profile.name)")
                }
                try writeMarker(profile.id, at: desktop)
            }
            try fm.moveItem(
                at: storeDesktop(in: stageProfiles, profile: activeProfile),
                to: stageDesktop)
        } else {
            let desktopBackup = backup.directory.appendingPathComponent("canonical-desktop")
            let cliBackup = backup.directory.appendingPathComponent("canonical-cli")
            guard isDirectory(desktopBackup), isDirectory(cliBackup) else {
                throw ProfileLayoutError.restoreFailed("backup contains neither profile metadata nor default data")
            }
            let profile = Profile(name: "Restored default")
            restoredFile = ProfilesFile(
                profiles: [profile], activeProfileID: profile.id, tombstones: nil)
            try ensureDirectory(stageProfiles, permissions: 0o700)
            try ensureDirectory(
                stageProfiles.appendingPathComponent(profile.id.uuidString), permissions: 0o700)
            try cloneDirectory(cliBackup, to: storeCLI(in: stageProfiles, profile: profile))
            try cloneDirectory(desktopBackup, to: stageDesktop)
            try writeMarker(profile.id, at: stageDesktop)
        }

        guard let targetID = restoredFile.activeProfileID else {
            throw ProfileLayoutError.restoreFailed("backup has no active profile")
        }
        try atomicWrite(
            Data((journalID.uuidString + "\n").utf8),
            to: stageProfiles.appendingPathComponent(".restore-set-id"))
        try atomicWrite(
            Data((journalID.uuidString + "\n").utf8),
            to: stageDesktop.appendingPathComponent(".claude-profile-restore-set"))
        try atomicWrite(try JSONEncoder.iso.encode(restoredFile), to: restoreMetadataURL(journalID))

        if itemExists(store.profilesFileURL) {
            try fm.copyItem(
                at: store.profilesFileURL,
                to: recovery.appendingPathComponent("profiles.json"))
        }
        if itemExists(store.previousProfilesFileURL) {
            try fm.copyItem(
                at: store.previousProfilesFileURL,
                to: recovery.appendingPathComponent("profiles.json.prev"))
        }
        guard deviceID(canonicalDesktop) == deviceID(stageDesktop),
            deviceID(store.profilesDirectory) == deviceID(stageProfiles)
        else { throw ProfileLayoutError.differentVolumes }

        let journal = OperationJournal(
            id: journalID,
            kind: .preV2Restore,
            previousProfileID: currentActiveID,
            targetProfileID: targetID,
            auxiliaryPath: backup.directory.path,
            recoveryPath: recovery.path)
        try writeJournal(journal)
        do {
            try finishPreV2Restore(journal)
            return targetID
        } catch {
            throw ProfileLayoutError.pendingRecovery("backup restore stopped: \(error.localizedDescription)")
        }
    }

    public func migrateLegacyLayout(active: Profile, profiles: [Profile]) throws {
        guard isSymlink(canonicalDesktop), isSymlink(canonicalCLI) else {
            throw ProfileLayoutError.invalidLegacyLayout("both canonical paths must be legacy symlinks")
        }
        let expectedDesktop = store.desktopDirectory(active).standardizedFileURL
        let expectedCLI = store.cliDirectory(active).standardizedFileURL
        guard symlinkDestination(canonicalDesktop)?.standardizedFileURL == expectedDesktop else {
            throw ProfileLayoutError.invalidLegacyLayout("Desktop symlink does not point to the active profile")
        }
        guard symlinkDestination(canonicalCLI)?.standardizedFileURL == expectedCLI else {
            throw ProfileLayoutError.invalidLegacyLayout("CLI symlink does not point to the active profile")
        }
        for profile in profiles {
            let desktop = store.desktopDirectory(profile)
            guard isDirectory(desktop), !isSymlink(desktop) else {
                throw ProfileLayoutError.invalidLegacyLayout("Desktop data is missing for \(profile.name)")
            }
            try writeMarker(profile.id, at: desktop)
            try ensureDirectory(store.cliDirectory(profile), permissions: 0o700)
        }

        let journal = OperationJournal(
            kind: .v1Migration,
            previousProfileID: active.id,
            targetProfileID: active.id)
        try writeJournal(journal)
        do {
            try fm.removeItem(at: canonicalDesktop)
            try fm.moveItem(at: expectedDesktop, to: canonicalDesktop)
            try fm.removeItem(at: canonicalCLI)
            try ensureDirectory(canonicalCLI, permissions: 0o700)
        } catch {
            throw ProfileLayoutError.pendingRecovery("v1 migration stopped: \(error.localizedDescription)")
        }
    }

    public func adoptCurrentLayout(active: Profile) throws {
        guard !isSymlink(canonicalDesktop), !isSymlink(canonicalCLI) else {
            throw ProfileLayoutError.invalidLegacyLayout("unexpected symlink while adopting the default layout")
        }
        try writeJournal(
            OperationJournal(
                kind: .v1Migration,
                previousProfileID: active.id,
                targetProfileID: active.id))
        if !itemExists(canonicalDesktop) {
            try ensureDirectory(canonicalDesktop, permissions: 0o700)
        }
        guard isDirectory(canonicalDesktop) else {
            throw ProfileLayoutError.invalidLegacyLayout("the Desktop path is not a directory")
        }

        let cliDestination = store.cliDirectory(active)
        guard !itemExists(cliDestination) else {
            throw ProfileLayoutError.invalidLegacyLayout("the default profile CLI destination already exists")
        }
        try ensureDirectory(cliDestination.deletingLastPathComponent(), permissions: 0o700)
        if itemExists(canonicalCLI) {
            guard isDirectory(canonicalCLI) else {
                throw ProfileLayoutError.invalidLegacyLayout("the CLI path is not a directory")
            }
            try fm.moveItem(at: canonicalCLI, to: cliDestination)
        } else {
            try ensureDirectory(cliDestination, permissions: 0o700)
        }
        try ensureDirectory(canonicalCLI, permissions: 0o700)
        try writeMarker(active.id, at: canonicalDesktop)
    }

    public func restoreDefaultLayout(active: Profile) throws {
        guard isDirectory(canonicalDesktop), !isSymlink(canonicalDesktop),
            marker(at: canonicalDesktop) == active.id
        else {
            throw ProfileLayoutError.profileMarkerMismatch(
                expected: active.id, actual: marker(at: canonicalDesktop))
        }
        let cliSource = store.cliDirectory(active)
        guard isDirectory(cliSource), !isSymlink(cliSource) else {
            throw ProfileLayoutError.invalidLegacyLayout("the active CLI profile directory is missing")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let restoreBackup =
            backupsDirectory
            .appendingPathComponent(
                "restore-v2-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        try ensureDirectory(restoreBackup, permissions: 0o700)
        let fallbackBackup = restoreBackup.appendingPathComponent("fallback-cli", isDirectory: true)

        try writeJournal(
            OperationJournal(
                kind: .defaultRestore,
                previousProfileID: active.id,
                targetProfileID: active.id,
                auxiliaryPath: fallbackBackup.path))

        var fallbackMoved = false
        do {
            if itemExists(canonicalCLI) {
                try fm.moveItem(at: canonicalCLI, to: fallbackBackup)
                fallbackMoved = true
            }
            try fm.moveItem(at: cliSource, to: canonicalCLI)
            let markerURL = canonicalDesktop.appendingPathComponent(Self.markerFilename)
            if itemExists(markerURL) { try fm.removeItem(at: markerURL) }
        } catch {
            if fallbackMoved, !itemExists(canonicalCLI), itemExists(fallbackBackup) {
                do {
                    try fm.moveItem(at: fallbackBackup, to: canonicalCLI)
                } catch let rollbackError {
                    throw ProfileLayoutError.ioFailure(
                        "Restore failed: \(error.localizedDescription). Restoring the fallback CLI directory also failed: \(rollbackError.localizedDescription)"
                    )
                }
            }
            throw ProfileLayoutError.ioFailure("Restore failed without overwriting data: \(error.localizedDescription)")
        }
    }

    public func reassignLocalProfileData(from old: Profile, to replacement: Profile, active: Bool) throws {
        let oldRoot = store.profileDirectory(old)
        let newRoot = store.profileDirectory(replacement)
        guard isDirectory(oldRoot), !isSymlink(oldRoot) else {
            throw ProfileLayoutError.ioFailure("Local profile data is missing at \(oldRoot.path).")
        }
        guard !itemExists(newRoot) else {
            throw ProfileLayoutError.ioFailure("Replacement profile data already exists at \(newRoot.path).")
        }
        if active {
            guard marker(at: canonicalDesktop) == old.id else {
                throw ProfileLayoutError.profileMarkerMismatch(
                    expected: old.id, actual: marker(at: canonicalDesktop))
            }
        } else {
            guard marker(at: store.desktopDirectory(old)) == old.id else {
                throw ProfileLayoutError.profileMarkerMismatch(
                    expected: old.id, actual: marker(at: store.desktopDirectory(old)))
            }
        }

        try fm.moveItem(at: oldRoot, to: newRoot)
        do {
            let desktop = active ? canonicalDesktop : store.desktopDirectory(replacement)
            try writeMarker(replacement.id, at: desktop)
        } catch {
            try fm.moveItem(at: newRoot, to: oldRoot)
            throw error
        }
    }

    // MARK: - Filesystem primitives

    public func marker(at directory: URL) -> UUID? {
        let url = directory.appendingPathComponent(Self.markerFilename)
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func writeMarker(_ id: UUID, at directory: URL) throws {
        try ensureDirectory(directory, permissions: 0o700)
        try atomicWrite(Data((id.uuidString + "\n").utf8), to: directory.appendingPathComponent(Self.markerFilename))
    }

    private func writeJournal(_ journal: OperationJournal) throws {
        try atomicWrite(try JSONEncoder.iso.encode(journal), to: journalURL)
    }

    private func finishPreV2Restore(_ journal: OperationJournal) throws {
        guard let recoveryPath = journal.recoveryPath else {
            throw ProfileLayoutError.pendingRecovery("the backup restore has no recovery path")
        }
        let stage = restoreStageDirectory(journal.id)
        let stageDesktop = stage.appendingPathComponent("canonical-desktop", isDirectory: true)
        let stageProfiles = stage.appendingPathComponent("profiles", isDirectory: true)
        let desktopMarker = canonicalDesktop.appendingPathComponent(".claude-profile-restore-set")
        let profilesMarker = store.profilesDirectory.appendingPathComponent(".restore-set-id")

        if markerValue(at: desktopMarker) != journal.id {
            guard markerValue(at: stageDesktop.appendingPathComponent(".claude-profile-restore-set")) == journal.id
            else {
                throw ProfileLayoutError.pendingRecovery("the staged Desktop backup could not be located")
            }
            try atomicSwap(canonicalDesktop, stageDesktop)
        }
        if markerValue(at: profilesMarker) != journal.id {
            guard markerValue(at: stageProfiles.appendingPathComponent(".restore-set-id")) == journal.id else {
                throw ProfileLayoutError.pendingRecovery("the staged profile backup could not be located")
            }
            try atomicSwap(store.profilesDirectory, stageProfiles)
        }

        let metadata = restoreMetadataURL(journal.id)
        guard itemExists(metadata) else {
            throw ProfileLayoutError.pendingRecovery("the staged profile metadata is missing")
        }
        try atomicWrite(Data(contentsOf: metadata), to: store.profilesFileURL)

        let recovery = URL(fileURLWithPath: recoveryPath, isDirectory: true)
        try ensureDirectory(recovery, permissions: 0o700)
        let oldDesktop = recovery.appendingPathComponent("canonical-desktop", isDirectory: true)
        if itemExists(stageDesktop), !itemExists(oldDesktop) {
            try fm.moveItem(at: stageDesktop, to: oldDesktop)
        }
        let oldProfiles = recovery.appendingPathComponent("profiles", isDirectory: true)
        if itemExists(stageProfiles), !itemExists(oldProfiles) {
            try fm.moveItem(at: stageProfiles, to: oldProfiles)
        }
    }

    private func restoreStageDirectory(_ id: UUID) -> URL {
        store.supportDirectory.appendingPathComponent(".restore-stage-\(id.uuidString)", isDirectory: true)
    }

    private func restoreMetadataURL(_ id: UUID) -> URL {
        store.supportDirectory.appendingPathComponent(".restore-metadata-\(id.uuidString).json")
    }

    private func storeCLI(in profilesRoot: URL, profile: Profile) -> URL {
        profilesRoot.appendingPathComponent(profile.id.uuidString).appendingPathComponent("cli")
    }

    private func storeDesktop(in profilesRoot: URL, profile: Profile) -> URL {
        profilesRoot.appendingPathComponent(profile.id.uuidString).appendingPathComponent("desktop")
    }

    private func markerValue(at url: URL) -> UUID? {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removeJournal() throws {
        guard itemExists(journalURL) else { return }
        try fm.removeItem(at: journalURL)
        try syncDirectory(journalURL.deletingLastPathComponent())
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).new-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic])
        chmod(temporary.path, S_IRUSR | S_IWUSR)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if itemExists(url) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw ProfileLayoutError.ioFailure("Could not open \(url.path) for synchronization")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ProfileLayoutError.ioFailure("Could not synchronize \(url.path)")
        }
    }

    private func atomicSwap(_ lhs: URL, _ rhs: URL) throws {
        let result = lhs.path.withCString { left in
            rhs.path.withCString { right in
                renameatx_np(AT_FDCWD, left, AT_FDCWD, right, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            throw ProfileLayoutError.ioFailure("Atomic Desktop swap failed: \(message)")
        }
    }

    private func cloneDirectory(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cRp", source.path, destination.path]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail =
                String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown cp error"
            throw ProfileLayoutError.backupFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func sha256(of url: URL) -> String? {
        guard itemExists(url), let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func inventory(roots: [String: URL]) throws -> BackupInventory {
        let names: Set<String> = [
            "settings.json", ".claude.json", "CLAUDE.md", "claude_desktop_config.json", "config.json",
        ]
        var lines: [String] = []
        var total: UInt64 = 0
        var critical: [String: String] = [:]
        var count = 0

        for (label, root) in roots.sorted(by: { $0.key < $1.key }) {
            var enumerationFailure: Error?
            guard
                let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [],
                    errorHandler: { url, error in
                        enumerationFailure = ProfileLayoutError.backupFailed(
                            "could not inventory \(url.path): \(error.localizedDescription)")
                        return false
                    })
            else { continue }
            for case let url as URL in enumerator {
                let prefixes = [root.path, "/private" + root.path]
                guard let prefix = prefixes.first(where: { url.path.hasPrefix($0 + "/") }) else {
                    throw ProfileLayoutError.backupFailed("could not relativize inventory path \(url.path)")
                }
                let relative = String(url.path.dropFirst(prefix.count)).trimmingCharacters(
                    in: CharacterSet(charactersIn: "/"))
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let type = values.isSymbolicLink == true ? "link" : (values.isDirectory == true ? "dir" : "file")
                let size = values.isRegularFile == true ? UInt64(values.fileSize ?? 0) : 0
                count += 1
                total += size
                lines.append(
                    "\(label)/\(relative)|\(type)|\(size)|\(try filesystemMetadataDescriptor(url))")
                if values.isRegularFile == true, names.contains(url.lastPathComponent), let hash = sha256(of: url) {
                    critical["\(label)/\(relative)"] = hash
                }
            }
            if let enumerationFailure { throw enumerationFailure }
        }
        let manifest = lines.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        return BackupInventory(
            entryCount: count,
            logicalBytes: total,
            manifestSHA256: digest,
            criticalFileHashes: critical)
    }

    private func filesystemMetadataDescriptor(_ url: URL) throws -> String {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw ProfileLayoutError.backupFailed("could not stat \(url.path): \(String(cString: strerror(errno)))")
        }
        // `com.apple.provenance` is rewritten by macOS when an item is copied,
        // including for APFS clones. It describes the copy operation rather
        // than profile content, so it cannot be compared byte-for-byte. All
        // other xattrs (including ACL-related metadata) remain verified.
        let attributes = try extendedAttributes(at: url)
            .filter { $0.key != "com.apple.provenance" }
        let xattrManifest = attributes.sorted(by: { $0.key < $1.key }).map { name, value in
            let digest = SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
            return "\(name)=\(digest)"
        }.joined(separator: ",")
        // A non-privileged APFS clone preserves content, mode, ACLs and xattrs,
        // but macOS normalizes a source group the current user does not belong
        // to (for example gid 0) to the user's primary group. Ownership is not
        // part of the documented backup acceptance criteria and rejecting that
        // safe normalization makes otherwise complete backups impossible.
        return "mode=\(info.st_mode);xattrs=\(xattrManifest)"
    }

    private func extendedAttributes(at url: URL) throws -> [String: Data] {
        let options = XATTR_NOFOLLOW
        let length = url.path.withCString { listxattr($0, nil, 0, options) }
        if length < 0 {
            if errno == ENOTSUP { return [:] }
            throw ProfileLayoutError.backupFailed(
                "could not list xattrs for \(url.path): \(String(cString: strerror(errno)))")
        }
        guard length > 0 else { return [:] }
        var nameBuffer = [CChar](repeating: 0, count: length)
        let readLength = url.path.withCString {
            listxattr($0, &nameBuffer, nameBuffer.count, options)
        }
        guard readLength >= 0 else {
            throw ProfileLayoutError.backupFailed(
                "could not read xattr names for \(url.path): \(String(cString: strerror(errno)))")
        }

        var result: [String: Data] = [:]
        var offset = 0
        while offset < readLength {
            let name = nameBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            let valueLength = url.path.withCString { path in
                name.withCString { getxattr(path, $0, nil, 0, 0, options) }
            }
            guard valueLength >= 0 else {
                throw ProfileLayoutError.backupFailed(
                    "could not size xattr \(name) for \(url.path): \(String(cString: strerror(errno)))")
            }
            var bytes = [UInt8](repeating: 0, count: valueLength)
            let actual = url.path.withCString { path in
                name.withCString { attribute in
                    getxattr(path, attribute, &bytes, bytes.count, 0, options)
                }
            }
            guard actual >= 0 else {
                throw ProfileLayoutError.backupFailed(
                    "could not read xattr \(name) for \(url.path): \(String(cString: strerror(errno)))")
            }
            result[name] = Data(bytes.prefix(actual))
        }
        return result
    }

    private func deviceID(_ url: URL) -> UInt64? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return UInt64(info.st_dev)
    }

    private func preflightBackupVolume() throws {
        try ensureDirectory(store.supportDirectory, permissions: 0o700)
        let values = try store.supportDirectory.resourceValues(forKeys: [
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsReadOnlyKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let format = values.volumeLocalizedFormatDescription?.lowercased() ?? "unknown"
        guard format.contains("apfs") else {
            throw ProfileLayoutError.unsupportedFilesystem(
                "Pre-v2 backup requires APFS copy-on-write cloning; found \(format).")
        }
        guard values.volumeIsReadOnly != true else {
            throw ProfileLayoutError.unsupportedFilesystem("The profile volume is read-only.")
        }
        let minimumFreeBytes: Int64 = 512 * 1_024 * 1_024
        if let available = values.volumeAvailableCapacityForImportantUsage,
            available < minimumFreeBytes
        {
            throw ProfileLayoutError.backupFailed(
                "Less than 512 MiB is available for clone metadata and migration journaling.")
        }
    }

    private func ensureDirectory(_ url: URL, permissions: mode_t) throws {
        if itemExists(url) {
            guard isDirectory(url), !isSymlink(url) else {
                throw ProfileLayoutError.ioFailure("\(url.path) is not a real directory")
            }
            return
        }
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)])
    }

    private func itemExists(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return true }
        return (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }

    private func symlinkDestination(_ url: URL) -> URL? {
        guard isSymlink(url), let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return url.deletingLastPathComponent().appendingPathComponent(target)
    }

    private func containsSymlinkComponent(_ url: URL) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let standardized = url.standardizedFileURL
        guard standardized.path == home.path || standardized.path.hasPrefix(home.path + "/") else {
            // Injected/test roots are already explicitly trusted by the caller.
            return false
        }
        var current = home
        for component in standardized.pathComponents.dropFirst(home.pathComponents.count) {
            current.appendPathComponent(component)
            if isSymlink(current) { return true }
        }
        return false
    }
}
