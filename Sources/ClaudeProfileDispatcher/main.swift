import ClaudeProfileSwitcherCore
import Darwin
import Foundation

enum DispatcherError: LocalizedError {
    case manifestMissing(String)
    case manifestUnreadable(String)
    case noActiveProfile
    case unknownProfile(String)
    case profileDirectoryMissing(String)
    case unsupportedManifest(Int)
    case claudeBinaryMissing
    case recursion
    case execFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing(let path):
            return "Claude Profile Switcher manifest is missing at \(path). Open the app and repair CLI integration."
        case .manifestUnreadable(let reason): return "Claude Profile Switcher manifest is invalid: \(reason)"
        case .noActiveProfile: return "No Claude profile is active. Select one in Claude Profile Switcher."
        case .unknownProfile(let value):
            return "The .claude-profile value “\(value)” does not match a configured profile."
        case .profileDirectoryMissing(let path):
            return "The selected Claude profile directory is missing or unsafe at \(path). Open the app to repair it."
        case .unsupportedManifest(let schema):
            return "Claude Profile Switcher manifest schema \(schema) is not supported by this dispatcher."
        case .claudeBinaryMissing:
            return
                "The real claude executable could not be found. Open Claude Profile Switcher and repair CLI integration."
        case .recursion: return "Claude Profile Switcher refused to dispatch recursively."
        case .execFailed(let reason): return "Could not start Claude Code: \(reason)"
        }
    }
}

struct Dispatcher {
    let fm: FileManager
    let environment: [String: String]
    let arguments: [String]
    let currentDirectory: URL

    init(
        fm: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.fm = fm
        self.environment = environment
        self.arguments = arguments
        self.currentDirectory = currentDirectory
    }

    func run() throws -> Never {
        let manifestURL = Self.manifestURL(environment: environment)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw DispatcherError.manifestMissing(manifestURL.path)
        }
        let manifest: CLIProfileDispatcherManifest
        do {
            manifest = try JSONDecoder().decode(
                CLIProfileDispatcherManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw DispatcherError.manifestUnreadable(error.localizedDescription)
        }
        guard manifest.schemaVersion == 2 else {
            throw DispatcherError.unsupportedManifest(manifest.schemaVersion)
        }

        let requested = try nearestBinding()
        let entry: CLIProfileDispatcherManifest.Entry
        if let requested {
            guard let match = manifest.profile(matching: requested) else {
                throw DispatcherError.unknownProfile(requested)
            }
            entry = match
        } else {
            guard let activeID = manifest.activeProfileID,
                let match = manifest.profiles.first(where: { $0.id == activeID })
            else { throw DispatcherError.noActiveProfile }
            entry = match
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: entry.cliPath, isDirectory: &isDirectory),
            isDirectory.boolValue,
            !isSymbolicLink(entry.cliPath)
        else { throw DispatcherError.profileDirectoryMissing(entry.cliPath) }

        let executable = try resolveClaudeBinary(manifest: manifest)
        writeDesktopHint(profileID: entry.id)

        var nextEnvironment = environment
        nextEnvironment["CLAUDE_CONFIG_DIR"] = entry.cliPath
        nextEnvironment["CLAUDE_PROFILE_SWITCHER_DISPATCHED"] = "1"
        let argv = [executable] + Array(arguments.dropFirst())
        let result = argv.withCStringArray { argvPointer in
            nextEnvironment.map { "\($0.key)=\($0.value)" }.withCStringArray { environmentPointer in
                execve(executable, argvPointer, environmentPointer)
            }
        }
        throw DispatcherError.execFailed("\(String(cString: strerror(errno))) (\(result))")
    }

    func nearestBinding() throws -> String? {
        var directory = currentDirectory.standardizedFileURL
        while true {
            let candidate = directory.appendingPathComponent(".claude-profile")
            if fm.fileExists(atPath: candidate.path) {
                let contents = try String(contentsOf: candidate, encoding: .utf8)
                let firstLine =
                    contents.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let value = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if directory.path == "/" { break }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private func resolveClaudeBinary(manifest: CLIProfileDispatcherManifest) throws -> String {
        guard environment["CLAUDE_PROFILE_SWITCHER_DISPATCHED"] != "1" else {
            throw DispatcherError.recursion
        }
        let selfPath = URL(fileURLWithPath: arguments[0]).standardizedFileURL.path
        let candidates =
            [manifest.realClaudePath]
            + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for candidate in candidates {
            guard !candidate.isEmpty else { continue }
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            if standardized == selfPath { continue }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: standardized, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fm.isExecutableFile(atPath: standardized)
            {
                return standardized
            }
        }
        throw DispatcherError.claudeBinaryMissing
    }

    private func writeDesktopHint(profileID: UUID) {
        let url = Self.configDirectory(environment: environment).appendingPathComponent("desktop-hint")
        let value = "\(profileID.uuidString)\n\(Int(Date().timeIntervalSince1970))\n"
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        guard let type = try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    static func configDirectory(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/claude-profile-switcher")
    }

    static func manifestURL(environment: [String: String]) -> URL {
        configDirectory(environment: environment).appendingPathComponent("dispatcher.json")
    }
}

extension Array where Element == String {
    fileprivate func withCStringArray<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = map { strdup($0) }
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        defer {
            for pointer in pointers { free(pointer) }
            buffer.deallocate()
        }
        for (index, pointer) in pointers.enumerated() { buffer[index] = pointer }
        buffer[count] = nil
        return body(buffer)
    }
}

do {
    try Dispatcher().run()
} catch {
    FileHandle.standardError.write(Data(("claude: \(error.localizedDescription)\n").utf8))
    exit(78)
}
