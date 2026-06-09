import Foundation

public enum SymlinkError: LocalizedError {
    case targetIsDirectoryNotSymlink(URL)
    case ioFailure(URL, Error)
    case notASymlink(URL)

    public var errorDescription: String? {
        switch self {
        case .targetIsDirectoryNotSymlink(let url):
            return "\(url.path) exists as a directory, not a symlink. Refusing to overwrite."
        case .ioFailure(let url, let error):
            return "Failed to update \(url.path): \(error.localizedDescription)"
        case .notASymlink(let url):
            return "\(url.path) is not a symlink; refusing to remove it."
        }
    }
}

/// Seam over `SymlinkService` so callers can be exercised in tests with
/// fault-injecting wrappers (e.g. fail the Nth `replaceSymlink` to verify
/// rollback paths).
public protocol SymlinkServicing {
    func isSymlink(_ url: URL) -> Bool
    func symlinkDestination(_ url: URL) -> URL?
    func itemExists(_ url: URL) -> Bool
    func replaceSymlink(at path: URL, pointingTo destination: URL) throws
    func removeSymlink(at path: URL) throws
    func moveDirectory(from src: URL, to dst: URL) throws
    func ensureDirectory(_ url: URL) throws
    func trashProfileDirectory(_ url: URL) throws
    func sweepStaleTempLinks(siblingsOf url: URL)
}

/// Thin FileManager wrapper for the symlink swap.
///
/// All filesystem mutation that the app performs goes through here so we can
/// keep the rollback logic in one place.
public struct SymlinkService: SymlinkServicing {
    public let fm: FileManager

    public init(fm: FileManager = .default) { self.fm = fm }

    /// True if the given path is a symbolic link (does not follow it).
    public func isSymlink(_ url: URL) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }

    /// Returns the destination of a symlink, or nil.
    public func symlinkDestination(_ url: URL) -> URL? {
        guard isSymlink(url),
            let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
        else { return nil }
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return url.deletingLastPathComponent().appendingPathComponent(target)
    }

    /// True if the path exists at all (file, dir, or symlink — symlink not followed).
    public func itemExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) { return true }
        // fileExists follows symlinks; check the link itself too.
        return (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    /// Atomically replace a symlink (or absent path) with a new symlink to `destination`.
    ///
    /// If `path` exists as a real directory or file (not a symlink), throws — we never
    /// blow away real user data. Migration is responsible for moving real dirs into
    /// the profile store first; this method just flips pointers.
    public func replaceSymlink(at path: URL, pointingTo destination: URL) throws {
        // If something exists at `path`, it must be a symlink. Otherwise refuse.
        if itemExists(path), !isSymlink(path) {
            throw SymlinkError.targetIsDirectoryNotSymlink(path)
        }

        try ensureParentDirectory(of: path)

        // Build a new symlink at a sibling temp path then rename — that's the atomic dance.
        let temp = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).new-\(UUID().uuidString)")

        do {
            try fm.createSymbolicLink(at: temp, withDestinationURL: destination)
        } catch {
            throw SymlinkError.ioFailure(temp, error)
        }

        // rename(2) replaces atomically across symlinks.
        let result = temp.path.withCString { tempPtr in
            path.path.withCString { pathPtr in
                rename(tempPtr, pathPtr)
            }
        }
        if result != 0 {
            let err = errno
            try? fm.removeItem(at: temp)
            throw SymlinkError.ioFailure(
                path,
                NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(err))])
            )
        }
    }

    /// Remove a symlink at `path`. Refuses to operate on real files/directories so a
    /// mistaken call can't blow away real user data.
    public func removeSymlink(at path: URL) throws {
        guard itemExists(path) else { return }
        guard isSymlink(path) else { throw SymlinkError.notASymlink(path) }
        do {
            try fm.removeItem(at: path)
        } catch {
            throw SymlinkError.ioFailure(path, error)
        }
    }

    /// Move a real directory to a new location. Used during first-run migration.
    public func moveDirectory(from src: URL, to dst: URL) throws {
        try ensureParentDirectory(of: dst)
        if itemExists(dst) {
            // Make sure we don't clobber. Caller should have checked.
            throw SymlinkError.targetIsDirectoryNotSymlink(dst)
        }
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            throw SymlinkError.ioFailure(dst, error)
        }
    }

    /// Create an empty directory if it doesn't exist (for new profiles).
    public func ensureDirectory(_ url: URL) throws {
        if itemExists(url) { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SymlinkError.ioFailure(url, error)
        }
    }

    /// Move a profile's data to the Trash so it's recoverable.
    public func trashProfileDirectory(_ url: URL) throws {
        var resultURL: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resultURL)
    }

    /// Remove stale `.<name>.new-<uuid>` temp symlinks left behind if a
    /// `replaceSymlink` rename failed *and* its best-effort cleanup failed.
    /// Called at startup. Only entries whose suffix parses as a UUID and that
    /// are symlinks are touched, so unrelated dotfiles are never at risk.
    public func sweepStaleTempLinks(siblingsOf url: URL) {
        let parent = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent).new-"
        guard
            let entries = try? fm.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil,
                options: [])
        else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix),
                UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                isSymlink(entry)
            else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - private

    private func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw SymlinkError.ioFailure(parent, error)
            }
        }
    }
}
