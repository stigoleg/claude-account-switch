import Foundation

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

    public init(
        store: ProfileStore,
        configDirectoryOverride: URL? = nil,
        zshrcOverride: URL? = nil,
        shellIsZshOverride: Bool? = nil
    ) {
        self.store = store
        self.configDirectoryOverride = configDirectoryOverride
        self.zshrcOverride = zshrcOverride
        self.shellIsZshOverride = shellIsZshOverride
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

    /// Persist the name → CLI directory mapping the shell function reads.
    /// Returns an error message on failure (caller surfaces it via lastError).
    @discardableResult
    public func writeProfilePathsManifest() -> String? {
        do {
            try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
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
            "profiles": dict,
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: profilePathsURL, options: .atomic)
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

        let existing = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
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

    /// Write the function file without touching any rc file. Useful for non-zsh
    /// users who want to source it manually from their own shell config.
    public func installFunctionFileOnly() throws {
        try writeFunctionFile()
        _ = writeProfilePathsManifest()
    }

    /// Remove the sourcing block from `~/.zshrc`. Leaves the function file in
    /// place so the user can reinstall without losing customizations.
    public func uninstall() throws {
        guard let existing = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == Self.zshrcMarker || trimmed == Self.zshrcSourceLine
        }
        let combined = lines.joined(separator: "\n")
        guard let data = combined.data(using: .utf8) else { throw IntegrationError.encoding }
        try data.write(to: zshrcURL, options: .atomic)
    }

    /// The literal contents of the zsh function file. Kept on Swift's side so
    /// we can update it via the Manage Profiles window's Install button.
    public static let shellFunctionContents: String = #"""
        # Claude Profile Switcher integration — sourced from ~/.zshrc
        # Walks up from $PWD looking for a `.claude-profile` file. If found,
        # binds CLAUDE_CONFIG_DIR (which gives each profile its own keychain
        # entry suffix) and writes a hint the menu-bar app picks up.

        _cps_paths="$HOME/.config/claude-profile-switcher/profile-paths.json"
        _cps_hint="$HOME/.config/claude-profile-switcher/desktop-hint"

        claude() {
          local dir="$PWD"
          local profile=""
          while [[ "$dir" != "/" && -n "$dir" ]]; do
            if [[ -f "$dir/.claude-profile" ]]; then
              profile=$(head -n1 "$dir/.claude-profile" | tr -d '[:space:]')
              break
            fi
            dir="${dir:h}"
          done

          if [[ -n "$profile" && -f "$_cps_paths" ]]; then
            local cli_dir
            cli_dir=$(/usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('profiles',{}).get(sys.argv[2].lower(),{}).get('cli',''))" "$_cps_paths" "$profile" 2>/dev/null)

            if [[ -n "$cli_dir" && -d "$cli_dir" ]]; then
              # Emit a hint the menu-bar app watches (used by the optional
              # "Suggest Desktop switches" feature).
              mkdir -p "${_cps_hint:h}"
              printf '%s\n%s\n' "$profile" "$(date +%s)" > "$_cps_hint" 2>/dev/null
              CLAUDE_CONFIG_DIR="$cli_dir" command claude "$@"
              return $?
            fi
          fi
          command claude "$@"
        }
        """#

    public enum IntegrationError: LocalizedError {
        case encoding
        case notZsh
        public var errorDescription: String? {
            switch self {
            case .encoding: return "Failed to encode shell integration file."
            case .notZsh:
                return
                    "Your $SHELL isn't zsh. The function file can still be written via \"Install function file only\" and sourced manually from your shell's rc file."
            }
        }
    }
}
