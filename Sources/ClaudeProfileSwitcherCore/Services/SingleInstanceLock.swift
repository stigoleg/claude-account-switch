import Darwin
import Foundation

public final class SingleInstanceLock: @unchecked Sendable {
    private let descriptor: Int32
    public let lockFileURL: URL

    public init(lockFileURL: URL = ProfileStore.supportDirectory.appendingPathComponent("app.lock")) throws {
        self.lockFileURL = lockFileURL
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SingleInstanceError.cannotOpen }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SingleInstanceError.alreadyRunning
        }
        self.descriptor = descriptor
        let pidText = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = pidText.withCString { write(descriptor, $0, strlen($0)) }
        _ = fsync(descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum SingleInstanceError: LocalizedError {
    case cannotOpen
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .cannotOpen: return "Claude Profile Switcher could not create its process lock."
        case .alreadyRunning: return "Claude Profile Switcher is already running."
        }
    }
}
