import Darwin
import Foundation

public struct CLIProfileDispatcherManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let aliases: [String]
        public let cliPath: String

        public init(id: UUID, name: String, aliases: [String], cliPath: String) {
            self.id = id
            self.name = name
            self.aliases = aliases
            self.cliPath = cliPath
        }
    }

    public let schemaVersion: Int
    public let activeProfileID: UUID?
    public let realClaudePath: String
    public let profiles: [Entry]

    public init(
        schemaVersion: Int = 2,
        activeProfileID: UUID?,
        realClaudePath: String,
        profiles: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.realClaudePath = realClaudePath
        self.profiles = profiles
    }

    public func profile(matching rawValue: String) -> Entry? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: value) {
            return profiles.first { $0.id == id }
        }
        let matches = profiles.filter { entry in
            entry.name.caseInsensitiveCompare(value) == .orderedSame
                || entry.aliases.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct CLIIntegrationStatus: Equatable, Sendable {
    public enum Shell: String, CaseIterable, Sendable, Hashable {
        case zsh
        case bash
        case fish
    }

    public let shell: Shell
    public let installed: Bool

    public init(shell: Shell, installed: Bool) {
        self.shell = shell
        self.installed = installed
    }
}

/// Per-project CLI binding via a zsh shell function.
///
/// The shell function walks up from `$PWD` looking for a `.claude-profile`
/// file. If found, it reads the profile name, looks up the matching CLI
/// directory from the manifest we write, sets `CLAUDE_CONFIG_DIR`, and execs
/// the real `claude`. Because `CLAUDE_CONFIG_DIR` changes the suffix on
/// Claude Code's macOS keychain entry name, this is *also* the mechanism
/// that lets per-project sign-ins use a different account than the
/// globally-active profile — solving the keychain-isolation limitation we
/// documented in v1.0.
@MainActor
public final class ShellIntegrationService {
    private let store: ProfileStore
    private let fm = FileManager.default

    /// Optional overrides for tests so install/uninstall can target a tmp dir
    /// instead of the real `~/.config/...` and `~/.zshrc`.
    private let configDirectoryOverride: URL?
    private let zshrcOverride: URL?
    private let shellIsZshOverride: Bool?
    private let bashrcOverride: URL?
    private let bashProfileOverride: URL?
    private let fishConfigOverride: URL?
    private let dispatcherSourceOverride: URL?

    public init(
        store: ProfileStore,
        configDirectoryOverride: URL? = nil,
        zshrcOverride: URL? = nil,
        shellIsZshOverride: Bool? = nil,
        bashrcOverride: URL? = nil,
        bashProfileOverride: URL? = nil,
        fishConfigOverride: URL? = nil,
        dispatcherSourceOverride: URL? = nil
    ) {
        self.store = store
        self.configDirectoryOverride = configDirectoryOverride
        self.zshrcOverride = zshrcOverride
        self.shellIsZshOverride = shellIsZshOverride
        self.bashrcOverride = bashrcOverride
        self.bashProfileOverride = bashProfileOverride
        self.fishConfigOverride = fishConfigOverride
        self.dispatcherSourceOverride = dispatcherSourceOverride
    }

    /// `~/.config/claude-profile-switcher/`
    public var configDirectory: URL {
        configDirectoryOverride
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("claude-profile-switcher", isDirectory: true)
    }

    /// `~/.config/claude-profile-switcher/profile-paths.json`
    public var profilePathsURL: URL {
        configDirectory.appendingPathComponent("profile-paths.json")
    }

    public var dispatcherManifestURL: URL {
        configDirectory.appendingPathComponent("dispatcher.json")
    }

    public var dispatcherDirectory: URL {
        configDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public var dispatcherURL: URL {
        dispatcherDirectory.appendingPathComponent("claude")
    }

    /// `~/.config/claude-profile-switcher/claude-profile.zsh`
    public var functionFileURL: URL {
        configDirectory.appendingPathComponent("claude-profile.zsh")
    }

    /// `~/.config/claude-profile-switcher/desktop-hint`
    public var desktopHintURL: URL {
        configDirectory.appendingPathComponent("desktop-hint")
    }

    /// `~/.zshrc`
    public var zshrcURL: URL {
        zshrcOverride ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zshrc")
    }

    /// The marker line we add to `~/.zshrc` so it's idempotent and easy to detect.
    public static let zshrcMarker = "# Added by Claude Profile Switcher"
    public static let zshrcSourceLine = "source \"$HOME/.config/claude-profile-switcher/claude-profile.zsh\""
    public static let pathLine = "export PATH=\"$HOME/.config/claude-profile-switcher/bin:$PATH\""
    public static let fishPathLine = "fish_add_path --prepend $HOME/.config/claude-profile-switcher/bin"

    /// Persist the name → CLI directory mapping the shell function reads.
    /// Returns an error message on failure (caller surfaces it via lastError).
    @discardableResult
    public func writeProfilePathsManifest() -> String? {
        do {
            try fm.createDirectory(
                at: configDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return "Couldn't create shell config dir: \(error.localizedDescription)"
        }

        var dict: [String: [String: String]] = [:]
        for profile in store.profiles {
            dict[profile.name.lowercased()] = [
                "id": profile.id.uuidString,
                "cli": store.cliDirectory(profile).path,
                "desktop": store.desktopDirectory(profile).path,
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "activeProfileID": store.activeProfileID?.uuidString as Any,
            "profiles": dict,
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try writeAtomicallyAndSynchronize(data, to: profilePathsURL)
            let manifest = CLIProfileDispatcherManifest(
                activeProfileID: store.activeProfileID,
                realClaudePath: resolveRealClaudePath()?.path ?? "",
                profiles: store.profiles.map {
                    CLIProfileDispatcherManifest.Entry(
                        id: $0.id,
                        name: $0.name,
                        aliases: $0.aliases,
                        cliPath: store.cliDirectory($0).path)
                })
            try writeAtomicallyAndSynchronize(
                try JSONEncoder.iso.encode(manifest), to: dispatcherManifestURL)
            return nil
        } catch {
            return "Couldn't write profile-paths.json: \(error.localizedDescription)"
        }
    }

    /// True if `$SHELL` points at zsh. Used to short-circuit the install flow
    /// for bash/fish users who'd otherwise see "Installed" without anything
    /// taking effect.
    public var currentShellIsZsh: Bool {
        if let override = shellIsZshOverride { return override }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.hasSuffix("/zsh") || shell == "zsh"
    }

    /// Write the shell-function file. Idempotent — overwrites with the latest
    /// canonical contents on every call.
    public func writeFunctionFile() throws {
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        guard let data = Self.shellFunctionContents.data(using: .utf8) else {
            throw IntegrationError.encoding
        }
        try data.write(to: functionFileURL, options: .atomic)
    }

    public func installDispatcher() throws {
        try fm.createDirectory(at: dispatcherDirectory, withIntermediateDirectories: true)
        guard let source = dispatcherSourceOverride ?? bundledDispatcherURL(),
            fm.isExecutableFile(atPath: source.path)
        else { throw IntegrationError.dispatcherMissing }
        let temporary = dispatcherDirectory.appendingPathComponent(".claude.new-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: dispatcherURL.path) {
            _ = try fm.replaceItemAt(dispatcherURL, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: dispatcherURL)
        }
    }

    /// True if `~/.zshrc` already sources our function file.
    public func isInstalledInZshrc() -> Bool {
        guard let contents = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return contents.contains(Self.zshrcSourceLine)
    }

    /// Write the function file and append a sourcing block to `~/.zshrc` if it
    /// isn't already there. No-op if already installed.
    ///
    /// Throws `IntegrationError.notZsh` when `$SHELL` isn't zsh. Use
    /// `installFunctionFileOnly()` if the user is on bash/fish and wants the
    /// function file written for manual sourcing anyway.
    public func install() throws {
        guard currentShellIsZsh else { throw IntegrationError.notZsh }
        try writeFunctionFile()
        _ = writeProfilePathsManifest()

        let existing = try existingContents(of: zshrcURL)
        if existing.contains(Self.zshrcSourceLine) { return }

        // Only prefix a newline when we have to — avoids stacking blank lines
        // on top of clean zshrc files.
        var prefix = ""
        if !existing.isEmpty, !existing.hasSuffix("\n") {
            prefix = "\n"
        } else if !existing.isEmpty {
            prefix = ""
        }
        let block = "\(prefix)\(Self.zshrcMarker)\n\(Self.zshrcSourceLine)\n"

        let combined = existing + block
        guard let data = combined.data(using: .utf8) else { throw IntegrationError.encoding }
        try data.write(to: zshrcURL, options: .atomic)
    }

    /// Production installation for all supported shells. The legacy `install`
    /// method remains zsh-only for API compatibility and focused unit tests.
    public func installAllSupportedShells() throws {
        try installDispatcher()
        try writeFunctionFile()
        if let error = writeProfilePathsManifest() { throw IntegrationError.manifest(error) }

        try installBlock(
            in: zshrcURL,
            marker: Self.zshrcMarker,
            line: Self.zshrcSourceLine)
        try installBlock(
            in: bashrcURL,
            marker: Self.zshrcMarker,
            line: Self.zshrcSourceLine)
        try installBlock(
            in: bashProfileURL,
            marker: Self.zshrcMarker,
            line: Self.zshrcSourceLine)

        let fish = fishConfigURL
        try fm.createDirectory(at: fish.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fishContents = "# Added by Claude Profile Switcher\n\(Self.fishPathLine)\n"
        try fishContents.write(to: fish, atomically: true, encoding: .utf8)
    }

    /// Write the function file without touching any rc file. Useful for non-zsh
    /// users who want to source it manually from their own shell config.
    public func installFunctionFileOnly() throws {
        try writeFunctionFile()
        _ = writeProfilePathsManifest()
    }

    /// Remove the sourcing block from `~/.zshrc`. Leaves the function file in
    /// place so the user can reinstall without losing customizations.
    public func uninstall() throws {
        guard fm.fileExists(atPath: zshrcURL.path) else { return }
        let existing = try String(contentsOf: zshrcURL, encoding: .utf8)
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == Self.zshrcMarker || trimmed == Self.zshrcSourceLine
        }
        let combined = lines.joined(separator: "\n")
        guard let data = combined.data(using: .utf8) else { throw IntegrationError.encoding }
        try data.write(to: zshrcURL, options: .atomic)
    }

    public func uninstallAllSupportedShells() throws {
        try removeManagedBlock(from: zshrcURL)
        try removeManagedBlock(from: bashrcURL)
        try removeManagedBlock(from: bashProfileURL)
        if fm.fileExists(atPath: fishConfigURL.path) {
            try fm.removeItem(at: fishConfigURL)
        }
    }

    public func integrationStatuses() -> [CLIIntegrationStatus] {
        [
            CLIIntegrationStatus(shell: .zsh, installed: file(zshrcURL, contains: Self.zshrcSourceLine)),
            CLIIntegrationStatus(
                shell: .bash,
                installed: file(bashrcURL, contains: Self.zshrcSourceLine)
                    || file(bashProfileURL, contains: Self.zshrcSourceLine)),
            CLIIntegrationStatus(shell: .fish, installed: file(fishConfigURL, contains: Self.fishPathLine)),
        ]
    }

    public func dispatcherSignatureValid() -> Bool {
        guard fm.isExecutableFile(atPath: dispatcherURL.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", dispatcherURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Shared zsh/bash fragment that prepends the compiled dispatcher.
    public static let shellFunctionContents: String = #"""
        # Claude Profile Switcher integration — sourced by zsh/bash.
        # The compiled dispatcher selects the active or project-bound profile.
        export PATH="$HOME/.config/claude-profile-switcher/bin:$PATH"
        """#

    public enum IntegrationError: LocalizedError {
        case encoding
        case notZsh
        case dispatcherMissing
        case manifest(String)
        public var errorDescription: String? {
            switch self {
            case .encoding: return "Failed to encode shell integration file."
            case .notZsh:
                return
                    "Your $SHELL isn't zsh. The function file can still be written via \"Install function file only\" and sourced manually from your shell's rc file."
            case .dispatcherMissing:
                return "The signed Claude dispatcher is missing from the app bundle. Reinstall the application."
            case .manifest(let message):
                return message
            }
        }
    }

    private var bashrcURL: URL {
        bashrcOverride ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bashrc")
    }

    private var bashProfileURL: URL {
        bashProfileOverride ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bash_profile")
    }

    private var fishConfigURL: URL {
        fishConfigOverride
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/fish/conf.d/claude-profile-switcher.fish")
    }

    private func bundledDispatcherURL() -> URL? {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClaudeProfileDispatcher")
    }

    private func resolveRealClaudePath() -> URL? {
        let own = dispatcherURL.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let profileCandidates = store.profiles.map {
            store.cliDirectory($0).appendingPathComponent("local/claude")
        }
        let candidates =
            profileCandidates + [
                home.appendingPathComponent(".claude/local/claude"),
                home.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
                home.appendingPathComponent("bin/claude"),
                home.appendingPathComponent(".npm-global/bin/claude"),
            ]
        return candidates.lazy.map { $0.resolvingSymlinksInPath() }.first {
            $0.standardizedFileURL.path != own && fm.isExecutableFile(atPath: $0.path)
        }
    }

    private func installBlock(in url: URL, marker: String, line: String) throws {
        let existing = try existingContents(of: url)
        if existing.contains(line) { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).claude-profile-switcher-backup")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: url, to: backup)
            }
        }
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + prefix + marker + "\n" + line + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeManagedBlock(from url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filtered = lines.filter {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return value != Self.zshrcMarker && value != Self.zshrcSourceLine && value != Self.pathLine
        }
        try filtered.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func file(_ url: URL, contains value: String) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8).contains(value)) ?? false
    }

    private func existingContents(of url: URL) throws -> String {
        guard fm.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func writeAtomicallyAndSynchronize(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).new-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw IntegrationError.manifest("Could not synchronize CLI metadata.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw IntegrationError.manifest("Could not synchronize CLI metadata.")
        }
    }
}
