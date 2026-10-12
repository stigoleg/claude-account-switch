import CryptoKit
import Darwin
import Foundation

public enum SharedConfigStatus: Equatable, Sendable {
    case notInstalled
    case installed(yolo: Bool)
    /// The deployed copy is older than the copy bundled with the app.
    case outdated
    case broken([String])
}

public enum SharedConfigDeployOutcome: Equatable, Sendable {
    case unchanged
    /// `keptPrevious` is where a replaced copy with local edits was moved.
    case deployed(keptPrevious: URL?)
}

public struct SharedConfigContents: Equatable, Sendable {
    public let agents: [String]
    public let skills: [String]
}

public enum SharedConfigError: LocalizedError, Equatable {
    case unavailable
    case localEdits(String)
    case profileNotSetUp(String)
    case invalidSettings(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The shared Claude setup is not bundled with this build of the app."
        case .localEdits(let path):
            return
                "\(path) was edited after it was installed. Nothing was changed; confirm overwriting the edits to update it."
        case .profileNotSetUp(let path):
            return
                "The profile's Claude Code folder does not exist yet (\(path)). Set the profile up on this Mac first."
        case .invalidSettings(let path):
            return "\(path) is not valid JSON. Nothing was changed; fix or remove the file and try again."
        case .ioFailure(let message):
            return "Could not install the shared Claude setup: \(message)"
        }
    }
}

/// Installs the curated Claude Code setup bundled under `SharedConfig/` (the
/// native port of `SharedConfig/install.sh`). The bundle is mirrored to
/// `~/.config/claude-shared`, and each opted-in profile's `cli/` links
/// CLAUDE.md, agents and every shared skill there; settings.json gets only the
/// keys the setup owns.
public struct SharedConfigService: Sendable {
    public static let claudeMDFile = "CLAUDE.md"
    public static let agentsDirectory = "agents"
    public static let skillsDirectory = "skills"
    public static let settingsFile = "settings.json"
    public static let versionFile = ".version"
    static let ignoredNames: Set<String> = [".DS_Store"]
    static let yoloMode = "bypassPermissions"
    static let skipPromptKey = "skipDangerousModePermissionPrompt"

    /// The bundle root, holding `claude-shared/` and `settings-fragment.json`.
    public let bundleURL: URL?
    /// Where the bundle is mirrored. The hook command embeds this path, so it
    /// must not contain spaces.
    public let deployedURL: URL
    public let profilesDirectory: URL
    public let runner: any ClaudeCodeRunning
    /// Candidate jq paths, in order. The hook and status line do nothing without jq.
    public let jqSearchPaths: [String]

    public init(
        bundleURL: URL?, deployedURL: URL, profilesDirectory: URL, runner: any ClaudeCodeRunning,
        jqSearchPaths: [String] = SharedConfigService.defaultJQSearchPaths()
    ) {
        self.bundleURL = bundleURL
        self.deployedURL = deployedURL
        self.profilesDirectory = profilesDirectory
        self.runner = runner
        self.jqSearchPaths = jqSearchPaths
    }

    /// The usual install locations first (macOS 14 ships no jq), then PATH.
    public static func defaultJQSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/jq" }
        return ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"] + path
    }

    public func jqURL() -> URL? {
        jqSearchPaths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `<App>.app/Contents/Resources/SharedConfig`, copied there by build-app.sh.
    public static var bundledResourceURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("SharedConfig", isDirectory: true)
    }

    public static func deployedURL(home: URL) -> URL {
        home.appendingPathComponent(".config/claude-shared", isDirectory: true)
    }

    private var fm: FileManager { .default }

    private var bundledSharedURL: URL? {
        bundleURL?.appendingPathComponent("claude-shared", isDirectory: true)
    }

    private var fragmentURL: URL? {
        bundleURL?.appendingPathComponent("settings-fragment.json")
    }

    public var isAvailable: Bool {
        guard let shared = bundledSharedURL, let fragment = fragmentURL else { return false }
        return kind(shared) == .directory && kind(fragment) == .regular
    }

    /// SHA-256 over the bundled `claude-shared/` tree and the settings fragment.
    public var bundledVersion: String? {
        guard isAvailable, let shared = bundledSharedURL, let fragment = fragmentURL,
            let tree = treeHash(shared), let fragmentData = fm.contents(atPath: fragment.path)
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data(tree.utf8))
        hasher.update(data: fragmentData)
        return hex(hasher.finalize())
    }

    public func bundledContents() -> SharedConfigContents {
        guard let shared = bundledSharedURL else { return SharedConfigContents(agents: [], skills: []) }
        let agents = entries(in: shared.appendingPathComponent(Self.agentsDirectory))
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
        return SharedConfigContents(agents: agents, skills: skillNames(in: shared))
    }

    public func cliDirectory(_ profileID: UUID) -> URL {
        profilesDirectory.appendingPathComponent("\(profileID.uuidString)/cli", isDirectory: true)
    }

    // MARK: - Deploy

    /// True when the deployed copy cannot be proven unedited: its content no
    /// longer matches what `.version` recorded, or, without a `.version`
    /// (a copy from install.sh or made by hand), it differs from the bundle.
    public func deployedHasLocalEdits() -> Bool {
        guard kind(deployedURL) != .missing else { return false }
        if let recorded = readVersionFile() {
            return treeHash(deployedURL) != recorded.contentHash
        }
        guard let source = bundledSharedURL, let bundled = treeHash(source) else { return true }
        return treeHash(deployedURL) != bundled
    }

    /// Mirror the bundle to `deployedURL` (like `rsync -a --delete`), staged
    /// in a sibling directory and swapped in atomically. Throws `.localEdits`
    /// instead of silently overwriting edits; with `overwriteLocalEdits` an
    /// edited copy is kept as `<deployed>.backup-<stamp>`, never deleted.
    @discardableResult
    public func deploy(overwriteLocalEdits: Bool = false) throws -> SharedConfigDeployOutcome {
        guard let source = bundledSharedURL, let version = bundledVersion else { throw SharedConfigError.unavailable }
        let hasLocalEdits = deployedHasLocalEdits()
        if !overwriteLocalEdits, hasLocalEdits { throw SharedConfigError.localEdits(deployedURL.path) }
        if !hasLocalEdits, readVersionFile()?.version == version {
            return .unchanged
        }

        let parent = deployedURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(deployedURL.lastPathComponent).new-\(UUID().uuidString)")
        var keptPrevious: URL?
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            removeIgnored(in: staging)
            var executables = [staging.appendingPathComponent("statusline.sh")]
            let hooks = staging.appendingPathComponent("hooks", isDirectory: true)
            executables += entries(in: hooks).filter { $0.hasSuffix(".sh") }.map { hooks.appendingPathComponent($0) }
            for url in executables where kind(url) == .regular {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            guard let contentHash = treeHash(staging) else {
                throw SharedConfigError.ioFailure("could not read \(staging.path)")
            }
            try Data("\(version)\n\(contentHash)\n".utf8)
                .write(to: staging.appendingPathComponent(Self.versionFile), options: .atomic)

            if kind(deployedURL) == .missing {
                try fm.moveItem(at: staging, to: deployedURL)
            } else {
                try atomicSwap(staging, deployedURL)
                // `staging` now holds the previous copy. Delete it only when
                // it provably held nothing but shipped content.
                if hasLocalEdits {
                    let backup = unique(
                        parent.appendingPathComponent("\(deployedURL.lastPathComponent).backup-\(Self.timestamp())"))
                    try fm.moveItem(at: staging, to: backup)
                    keptPrevious = backup
                } else {
                    try fm.removeItem(at: staging)
                }
            }
        } catch {
            try? fm.removeItem(at: staging)
            if let error = error as? SharedConfigError { throw error }
            throw SharedConfigError.ioFailure(error.localizedDescription)
        }
        return .deployed(keptPrevious: keptPrevious)
    }

    // MARK: - Install

    /// Deploy if needed, link the profile to the deployed copy and merge the
    /// owned settings keys. `yolo`: true sets both permission keys, false
    /// removes them while they hold the yolo values, nil leaves them alone.
    /// Idempotent. Returns the deploy outcome (where an edited copy was kept).
    @discardableResult
    public func install(profileID: UUID, yolo: Bool?, overwriteLocalEdits: Bool = false) throws
        -> SharedConfigDeployOutcome
    {
        let cli = cliDirectory(profileID)
        guard kind(cli) == .directory else { throw SharedConfigError.profileNotSetUp(cli.path) }
        let settingsURL = cli.appendingPathComponent(Self.settingsFile)
        // Validate everything that can fail before changing anything.
        let original = try readSettings(settingsURL)
        let fragment = try loadFragment()
        let outcome = try deploy(overwriteLocalEdits: overwriteLocalEdits)

        let stamp = Self.timestamp()
        do {
            try link(cli.appendingPathComponent(Self.claudeMDFile), to: deployed(Self.claudeMDFile), stamp: stamp)
            try link(
                cli.appendingPathComponent(Self.agentsDirectory), to: deployed(Self.agentsDirectory), stamp: stamp)
            let skills = cli.appendingPathComponent(Self.skillsDirectory, isDirectory: true)
            try fm.createDirectory(at: skills, withIntermediateDirectories: true)
            for name in skillNames(in: deployedURL) {
                try link(
                    skills.appendingPathComponent(name),
                    to: deployed("\(Self.skillsDirectory)/\(name)"),
                    stamp: stamp)
            }
            // Links left behind by skills removed from the shared set.
            for name in entries(in: skills) {
                let url = skills.appendingPathComponent(name)
                if pointsIntoDeployed(url, under: Self.skillsDirectory + "/"), !targetExists(url) {
                    try fm.removeItem(at: url)
                }
            }
        } catch {
            throw SharedConfigError.ioFailure(error.localizedDescription)
        }

        var settings = original ?? [:]
        for (key, value) in fragment where key != "hooks" {
            settings[key] = value
        }
        if let fragmentHooks = fragment["hooks"] as? [String: Any] {
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for (event, owned) in fragmentHooks {
                hooks[event] = mergeHookGroups(hooks[event] as? [Any] ?? [], owned: owned as? [Any] ?? [])
            }
            settings["hooks"] = hooks
        }
        // Retire the old effort lock; keep every other env key.
        if var env = settings["env"] as? [String: Any], env["CLAUDE_CODE_EFFORT_LEVEL"] != nil {
            env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
            settings["env"] = env.isEmpty ? nil : env
        }
        // Seeded, not owned: a deliberate /model choice survives reinstalls.
        if settings["model"] == nil { settings["model"] = "opus" }
        switch yolo {
        case true?:
            var permissions = settings["permissions"] as? [String: Any] ?? [:]
            permissions["defaultMode"] = Self.yoloMode
            settings["permissions"] = permissions
            settings[Self.skipPromptKey] = true
        case false?:
            removeYolo(&settings)
        case nil:
            break
        }
        try writeSettings(settings, original: original, to: settingsURL, stamp: stamp)
        return outcome
    }

    /// True only when both permission keys hold the yolo values.
    public func isYoloEnabled(profileID: UUID) -> Bool {
        let settingsURL = cliDirectory(profileID).appendingPathComponent(Self.settingsFile)
        return isYolo((try? readSettings(settingsURL)) ?? nil)
    }

    // MARK: - Uninstall

    /// Remove the links into the deployed copy and every settings value that
    /// still equals what install wrote. `model` and the deployed copy stay.
    public func uninstall(profileID: UUID) throws {
        let cli = cliDirectory(profileID)
        guard kind(cli) == .directory else { throw SharedConfigError.profileNotSetUp(cli.path) }
        let settingsURL = cli.appendingPathComponent(Self.settingsFile)
        let original = try readSettings(settingsURL)
        let fragment = try loadFragment()

        do {
            for name in [Self.claudeMDFile, Self.agentsDirectory] {
                let url = cli.appendingPathComponent(name)
                if pointsIntoDeployed(url, under: name) { try fm.removeItem(at: url) }
            }
            let skills = cli.appendingPathComponent(Self.skillsDirectory, isDirectory: true)
            for name in entries(in: skills) {
                let url = skills.appendingPathComponent(name)
                if pointsIntoDeployed(url, under: Self.skillsDirectory + "/") { try fm.removeItem(at: url) }
            }
        } catch {
            throw SharedConfigError.ioFailure(error.localizedDescription)
        }

        guard let original else { return }
        var settings = original
        for (key, value) in fragment where key != "hooks" && jsonEqual(settings[key], value) {
            settings.removeValue(forKey: key)
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                // Remove only the shared hook commands; a group goes when it is empty.
                let kept = groups.compactMap { group -> Any? in
                    guard var dict = group as? [String: Any], let list = dict["hooks"] as? [Any] else { return group }
                    let remaining = list.filter { !isSharedHook($0) }
                    if remaining.count == list.count { return group }
                    if remaining.isEmpty { return nil }
                    dict["hooks"] = remaining
                    return dict
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        removeYolo(&settings)
        try writeSettings(settings, original: original, to: settingsURL, stamp: Self.timestamp())
    }

    // MARK: - Status

    public func status(profileID: UUID) -> SharedConfigStatus {
        let cli = cliDirectory(profileID)
        guard kind(cli) == .directory else { return .notInstalled }
        var problems: [String] = []
        var installedParts = 0

        for name in [Self.claudeMDFile, Self.agentsDirectory] {
            let url = cli.appendingPathComponent(name)
            if pointsIntoDeployed(url, under: name) {
                installedParts += 1
                if !targetExists(url) { problems.append("\(name) is a dangling link to \(deployed(name).path)") }
            } else {
                problems.append("\(name) is not linked to \(deployed(name).path)")
            }
        }
        let skills = cli.appendingPathComponent(Self.skillsDirectory, isDirectory: true)
        for name in entries(in: skills) {
            let url = skills.appendingPathComponent(name)
            guard pointsIntoDeployed(url, under: Self.skillsDirectory + "/") else { continue }
            installedParts += 1
            if !targetExists(url) { problems.append("skills/\(name) is a dangling link") }
        }
        for name in skillNames(in: deployedURL) {
            let url = skills.appendingPathComponent(name)
            if linkDestination(url) != deployed("\(Self.skillsDirectory)/\(name)").path {
                problems.append("skills/\(name) is not linked to the shared copy")
            }
        }

        var settings: [String: Any]?
        do {
            settings = try readSettings(cli.appendingPathComponent(Self.settingsFile))
        } catch {
            problems.append("settings.json is not valid JSON")
        }
        let hooks = (settings?["hooks"] as? [String: Any])?["PreToolUse"] as? [Any] ?? []
        if hooks.contains(where: isSharedHookEntry) {
            installedParts += 1
        } else {
            problems.append("The PreToolUse hook that pins subagent models is not registered in settings.json")
        }

        guard installedParts > 0 else { return .notInstalled }
        if kind(deployedURL) != .directory {
            problems.insert("\(deployedURL.path) is missing", at: 0)
        }
        if !problems.isEmpty { return .broken(problems) }
        if let bundled = bundledVersion, readVersionFile()?.version != bundled { return .outdated }
        return .installed(yolo: isYolo(settings))
    }

    // MARK: - Plugins

    /// Best effort: install the Anthropic document skills plugin into one
    /// profile. Returns failure messages; an empty array means success.
    public func installDocumentSkills(profileID: UUID) async -> [String] {
        let cli = cliDirectory(profileID)
        var failures: [String] = []
        do {
            try await runner.runCommand(
                ["plugin", "marketplace", "add", "anthropics/skills"], configDirectory: cli, timeout: 300)
        } catch {
            // Already-added marketplaces fail here too; only the install result counts.
            failures.append("marketplace add: \(error.localizedDescription)")
        }
        do {
            try await runner.runCommand(
                ["plugin", "install", "document-skills@anthropic-agent-skills", "--scope", "user"],
                configDirectory: cli, timeout: 300)
            return []
        } catch {
            failures.append("plugin install: \(error.localizedDescription)")
            return failures
        }
    }

    // MARK: - Settings

    /// nil when the file does not exist; throws when it is not a JSON object.
    private func readSettings(_ url: URL) throws -> [String: Any]? {
        guard kind(url) != .missing else { return nil }
        guard let data = fm.contents(atPath: url.path),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SharedConfigError.invalidSettings(url.path) }
        return dict
    }

    /// Back up and atomically replace settings.json, only when the content changed.
    private func writeSettings(_ settings: [String: Any], original: [String: Any]?, to url: URL, stamp: String)
        throws
    {
        if let original, jsonEqual(original, settings) { return }
        let target = url.resolvingSymlinksInPath()
        do {
            if original != nil {
                try fm.copyItem(at: target, to: unique(url.appendingPathExtension("bak-\(stamp)")))
            }
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: target, options: .atomic)
        } catch {
            throw SharedConfigError.ioFailure(error.localizedDescription)
        }
    }

    /// The fragment with `__SHARED__` replaced by the deployed path.
    private func loadFragment() throws -> [String: Any] {
        guard isAvailable, let url = fragmentURL else { throw SharedConfigError.unavailable }
        guard let data = fm.contents(atPath: url.path),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SharedConfigError.invalidSettings(url.path) }
        return substitute(dict) as? [String: Any] ?? [:]
    }

    private func substitute(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string.replacingOccurrences(of: "__SHARED__", with: deployedURL.path)
        case let array as [Any]:
            return array.map(substitute)
        case let dict as [String: Any]:
            return dict.mapValues(substitute)
        default:
            return value
        }
    }

    /// A matcher group that contains at least one shared hook command.
    private func isSharedHookEntry(_ entry: Any) -> Bool {
        let hooks = (entry as? [String: Any])?["hooks"] as? [Any] ?? []
        return hooks.contains { isSharedHook($0) }
    }

    /// A single hook whose command runs a script from the deployed hooks dir.
    private func isSharedHook(_ hook: Any, script: String? = nil) -> Bool {
        guard let command = (hook as? [String: Any])?["command"] as? String else { return false }
        return command.contains(script ?? deployed("hooks").path + "/")
    }

    /// The deployed script a fragment hook runs, e.g. `<deployed>/hooks/x.sh`.
    private func hookScript(_ hook: Any) -> String? {
        guard let command = (hook as? [String: Any])?["command"] as? String,
            let range = command.range(of: deployed("hooks").path + "/")
        else { return nil }
        return String(command[range.lowerBound...].prefix { !$0.isWhitespace })
    }

    /// Replace each shared hook where it already sits (inside whatever group
    /// holds it, next to foreign hooks); append a group only for shared hooks
    /// not present yet.
    private func mergeHookGroups(_ existing: [Any], owned: [Any]) -> [Any] {
        var groups = existing
        for case let ownedGroup as [String: Any] in owned {
            var missing: [Any] = []
            for hook in ownedGroup["hooks"] as? [Any] ?? [] {
                guard let script = hookScript(hook) else {
                    missing.append(hook)
                    continue
                }
                var found = false
                for index in groups.indices {
                    guard var group = groups[index] as? [String: Any], var list = group["hooks"] as? [Any] else {
                        continue
                    }
                    for position in list.indices where isSharedHook(list[position], script: script) {
                        list[position] = hook
                        found = true
                    }
                    group["hooks"] = list
                    groups[index] = group
                }
                if !found { missing.append(hook) }
            }
            if !missing.isEmpty {
                var group = ownedGroup
                group["hooks"] = missing
                groups.append(group)
            }
        }
        return groups
    }

    private func isYolo(_ settings: [String: Any]?) -> Bool {
        (settings?["permissions"] as? [String: Any])?["defaultMode"] as? String == Self.yoloMode
            && jsonEqual(settings?[Self.skipPromptKey], true)
    }

    private func removeYolo(_ settings: inout [String: Any]) {
        if var permissions = settings["permissions"] as? [String: Any],
            permissions["defaultMode"] as? String == Self.yoloMode
        {
            permissions.removeValue(forKey: "defaultMode")
            settings["permissions"] = permissions.isEmpty ? nil : permissions
        }
        if jsonEqual(settings[Self.skipPromptKey], true) {
            settings.removeValue(forKey: Self.skipPromptKey)
        }
    }

    private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject).isEqual(rhs as AnyObject)
    }

    // MARK: - Links

    private func deployed(_ relative: String) -> URL {
        deployedURL.appendingPathComponent(relative)
    }

    /// Point `url` at `target`. A different link is replaced; a real file or
    /// directory is renamed to `<name>.backup-<stamp>` first.
    private func link(_ url: URL, to target: URL, stamp: String) throws {
        switch kind(url) {
        case .missing:
            break
        case .symlink:
            if linkDestination(url) == target.path { return }
            try fm.removeItem(at: url)
        default:
            try fm.moveItem(at: url, to: unique(url.appendingPathExtension("backup-\(stamp)")))
        }
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
    }

    private func pointsIntoDeployed(_ url: URL, under relative: String) -> Bool {
        guard let destination = linkDestination(url) else { return false }
        let base = deployed(relative).path
        return relative.hasSuffix("/") ? destination.hasPrefix(deployedURL.path + "/" + relative) : destination == base
    }

    private func linkDestination(_ url: URL) -> String? {
        guard kind(url) == .symlink else { return nil }
        return try? fm.destinationOfSymbolicLink(atPath: url.path)
    }

    private func targetExists(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0
    }

    private func unique(_ url: URL) -> URL {
        var candidate = url
        var counter = 1
        while kind(candidate) != .missing {
            candidate = URL(fileURLWithPath: "\(url.path)-\(counter)")
            counter += 1
        }
        return candidate
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    // MARK: - Filesystem

    private func entries(in directory: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !Self.ignoredNames.contains($0) }
            .sorted()
    }

    private func skillNames(in shared: URL) -> [String] {
        let skills = shared.appendingPathComponent(Self.skillsDirectory, isDirectory: true)
        return entries(in: skills).filter { kind(skills.appendingPathComponent($0)) == .directory }
    }

    private func removeIgnored(in root: URL) {
        guard let enumerator = fm.enumerator(atPath: root.path) else { return }
        for case let relative as String in enumerator
        where Self.ignoredNames.contains((relative as NSString).lastPathComponent) {
            try? fm.removeItem(at: root.appendingPathComponent(relative))
        }
    }

    private func readVersionFile() -> (version: String, contentHash: String)? {
        guard kind(deployedURL) == .directory,
            let text = try? String(contentsOf: deployed(Self.versionFile), encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        return (lines[0], lines[1])
    }

    /// SHA-256 over sorted relative paths and contents; symlink destinations
    /// are hashed, not followed. `.version` and `.DS_Store` are ignored.
    private func treeHash(_ root: URL) -> String? {
        guard kind(root) == .directory else { return nil }
        var hasher = SHA256()
        func visit(_ url: URL, relative: String) -> Bool {
            hasher.update(data: Data("\(relative)\0".utf8))
            switch kind(url) {
            case .symlink:
                hasher.update(data: Data("link:\(linkDestination(url) ?? "")\0".utf8))
            case .directory:
                hasher.update(data: Data("dir\0".utf8))
                for name in entries(in: url) where !(relative.isEmpty && name == Self.versionFile) {
                    guard
                        visit(
                            url.appendingPathComponent(name), relative: relative.isEmpty ? name : "\(relative)/\(name)")
                    else { return false }
                }
            case .regular:
                guard let data = fm.contents(atPath: url.path) else { return false }
                hasher.update(data: data)
            default:
                return false
            }
            return true
        }
        guard visit(root, relative: "") else { return nil }
        return hex(hasher.finalize())
    }

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private enum EntryKind: Equatable {
        case missing
        case directory
        case regular
        case symlink
        case other
    }

    private func kind(_ url: URL) -> EntryKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .other }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        default: return .other
        }
    }

    private func atomicSwap(_ lhs: URL, _ rhs: URL) throws {
        let result = lhs.path.withCString { left in
            rhs.path.withCString { right in
                renameatx_np(AT_FDCWD, left, AT_FDCWD, right, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw SharedConfigError.ioFailure("atomic swap of \(rhs.path) failed: \(String(cString: strerror(errno)))")
        }
    }
}
