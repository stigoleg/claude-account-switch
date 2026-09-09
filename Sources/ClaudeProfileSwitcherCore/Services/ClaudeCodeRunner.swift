import Darwin
import Foundation

public struct ClaudeCodeAuthStatus: Codable, Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?

    public init(loggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
    }
}

public enum ClaudeCodeRunnerError: LocalizedError, Equatable {
    case executableNotFound
    case timedOut
    case failed(Int32, String)
    case invalidStatus

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "The real Claude Code executable could not be found."
        case .timedOut: return "Claude Code did not respond before the operation timed out."
        case .failed(let status, let message):
            return message.isEmpty ? "Claude Code exited with status \(status)." : message
        case .invalidStatus: return "Claude Code returned an unreadable authentication status."
        }
    }
}

public protocol ClaudeCodeRunning: Sendable {
    func executableURL() -> URL?
    func authStatus(configDirectory: URL) async throws -> ClaudeCodeAuthStatus
    func logout(configDirectory: URL?) async throws
}

public struct ClaudeCodeRunner: ClaudeCodeRunning, Sendable {
    public let candidates: [URL]
    public let timeout: TimeInterval

    public init(candidates: [URL]? = nil, timeout: TimeInterval = 5) {
        self.candidates = candidates ?? SystemSurfaceLocator.defaultCandidatePaths()
        self.timeout = timeout
    }

    public func executableURL() -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func authStatus(configDirectory: URL) async throws -> ClaudeCodeAuthStatus {
        let data = try await run(
            arguments: ["auth", "status", "--json"], configDirectory: configDirectory)
        guard let value = try? JSONDecoder().decode(ClaudeCodeAuthStatus.self, from: data) else {
            throw ClaudeCodeRunnerError.invalidStatus
        }
        return value
    }

    public func logout(configDirectory: URL?) async throws {
        _ = try await run(arguments: ["auth", "logout"], configDirectory: configDirectory)
    }

    private func run(arguments: [String], configDirectory: URL?) async throws -> Data {
        guard let executable = executableURL() else { throw ClaudeCodeRunnerError.executableNotFound }
        let timeout = self.timeout
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            if let configDirectory {
                environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
            } else {
                environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            }
            environment["CLAUDE_PROFILE_SWITCHER_DISPATCHED"] = nil
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < terminationDeadline { usleep(25_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw ClaudeCodeRunnerError.timedOut
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message =
                    String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ClaudeCodeRunnerError.failed(process.terminationStatus, message)
            }
            return output
        }.value
    }
}
