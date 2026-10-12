import Darwin
import Foundation

public enum DiagnosticSeverity: String, Codable, Comparable, Sendable {
    case ok
    case warning
    case error

    private var rank: Int {
        switch self {
        case .ok: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum RepairAction: Codable, Equatable, Hashable, Sendable {
    /// The one-time v2 layout migration. GUI-only: it has its own sheet.
    case runMigration
    case recoverLayout
    /// Rename a Desktop VM folder into `<support>/repairs/…`. Never deletes.
    case moveAside(URL, profileID: UUID?)
    case reinstallShellIntegration
    case sweepTempLinks
    /// Redeploy the shared Claude setup and relink one profile, leaving its
    /// permission keys alone. Rewrites settings.json, so never unattended.
    case installSharedConfig(profileID: UUID, overwriteLocalEdits: Bool)
    /// Replace an edited deployed shared setup (the edited copy is kept as a
    /// backup), then relink every profile that has it installed.
    case overwriteSharedConfig

    /// Repairs that can run unattended ("Fix all", `--doctor --fix`).
    public var isSafe: Bool {
        switch self {
        case .moveAside, .reinstallShellIntegration, .sweepTempLinks: return true
        case .runMigration, .recoverLayout, .installSharedConfig, .overwriteSharedConfig: return false
        }
    }

    /// Repairs that need the menu bar app (Manage Profiles or Diagnose & Repair).
    public var needsApp: Bool {
        switch self {
        case .runMigration, .installSharedConfig, .overwriteSharedConfig: return true
        case .moveAside, .reinstallShellIntegration, .sweepTempLinks, .recoverLayout: return false
        }
    }

    public var title: String {
        switch self {
        case .runMigration: return "Migrate…"
        case .recoverLayout: return "Recover Layout"
        case .moveAside: return "Move Aside…"
        case .reinstallShellIntegration: return "Reinstall Shell Integration"
        case .sweepTempLinks: return "Remove Stale Links"
        case .installSharedConfig(_, let overwriteLocalEdits):
            return overwriteLocalEdits ? "Overwrite Edits and Reinstall…" : "Reinstall Shared Setup…"
        case .overwriteSharedConfig: return "Overwrite Local Edits…"
        }
    }
}

public struct DiagnosticFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let title: String
    public let detail: String
    public let repair: RepairAction?

    public init(
        id: String, severity: DiagnosticSeverity, title: String, detail: String, repair: RepairAction? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.repair = repair
    }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let generatedAt: Date
    public let findings: [DiagnosticFinding]
}

public enum DiagnosticsError: LocalizedError, Equatable {
    case desktopRunning
    case migrationIsInteractive
    case notMovable(String)
    case moveFailed(String)
    case sharedConfigUnavailable

    public var errorDescription: String? {
        switch self {
        case .desktopRunning:
            return "Quit Claude Desktop before moving its VM files aside. Nothing was changed."
        case .migrationIsInteractive:
            return "The layout migration runs from Manage Profiles in the menu bar app."
        case .notMovable(let path):
            return "Refusing to move \(path): only Claude Desktop's claude-code-vm and vm_bundles folders can be moved."
        case .moveFailed(let message):
            return "Could not move the folder aside: \(message)"
        case .sharedConfigUnavailable:
            return "The shared Claude setup is not bundled with this build of the app."
        }
    }
}

/// Read-only health checks for the profile layout and the files Claude
/// Desktop's Cowork VM opens, plus the repairs the UI and `--doctor --fix` run.
///
/// Cowork's Linux VM reads the Mac's files through virtiofs and refuses
/// symlinks anywhere in the path (ELOOP, "too many levels of symbolic links"),
/// so every check here uses lstat and never follows a link.
@MainActor
public final class DiagnosticsService {
    /// Desktop subfolders the Cowork VM opens. Both may be re-downloaded by
    /// Claude Desktop, which is what makes moving them aside a safe repair.
    public static let vmFolderNames = ["claude-code-vm", "vm_bundles"]
    /// Electron's single-instance links, present whenever Claude Desktop runs.
    static let electronRuntimeLinks: Set<String> = ["SingletonLock", "SingletonSocket", "SingletonCookie"]

    public let manager: ProfileManager
    public let shellIntegration: ShellIntegrationService
    public let home: URL
    public let sharedConfig: SharedConfigService?
    private let fm = FileManager.default

    public init(
        manager: ProfileManager, shellIntegration: ShellIntegrationService, home: URL,
        sharedConfig: SharedConfigService? = nil
    ) {
        self.manager = manager
        self.shellIntegration = shellIntegration
        self.home = home
        self.sharedConfig = sharedConfig
    }

    /// Standalone wiring for `--doctor`, matching `AppViewModel`: with
    /// CPS_TEST_ROOT set, every path and the Desktop controller are fakes.
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> DiagnosticsService
    {
        let testRoot = environment["CPS_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let store = ProfileStore(supportRoot: testRoot?.appendingPathComponent("support", isDirectory: true))
        store.load()
        guard let testRoot else {
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            return DiagnosticsService(
                manager: ProfileManager(store: store),
                shellIntegration: ShellIntegrationService(store: store),
                home: home,
                sharedConfig: SharedConfigService(
                    bundleURL: SharedConfigService.bundledResourceURL,
                    deployedURL: SharedConfigService.deployedURL(home: home),
                    profilesDirectory: store.profilesDirectory,
                    runner: ClaudeCodeRunner(timeout: 300)))
        }
        let home = testRoot.appendingPathComponent("home", isDirectory: true)
        let manager = ProfileManager(
            store: store,
            claudeApp: TestModeClaudeAppController(),
            surfaceLocator: TestModeSurfaceLocator(),
            cliCanonicalPath: home.appendingPathComponent(".claude", isDirectory: true),
            desktopCanonicalPath: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            claudeCodeRunner: TestModeClaudeCodeRunner())
        let shell = ShellIntegrationService(
            store: store,
            configDirectoryOverride: testRoot.appendingPathComponent("config"),
            zshrcOverride: home.appendingPathComponent(".zshrc"),
            shellIsZshOverride: true,
            bashrcOverride: home.appendingPathComponent(".bashrc"),
            bashProfileOverride: home.appendingPathComponent(".bash_profile"),
            fishConfigOverride: home.appendingPathComponent(".config/fish/conf.d/claude-profile-switcher.fish"))
        return DiagnosticsService(
            manager: manager, shellIntegration: shell, home: home,
            sharedConfig: SharedConfigService(
                bundleURL: SharedConfigService.bundledResourceURL,
                deployedURL: SharedConfigService.deployedURL(home: home),
                profilesDirectory: store.profilesDirectory,
                runner: TestModeClaudeCodeRunner()))
    }

    private var store: ProfileStore { manager.store }

    public var repairsDirectory: URL {
        store.supportDirectory.appendingPathComponent("repairs", isDirectory: true)
    }

    // MARK: - Run

    /// Every check, in report order. Add new checks here.
    private var checks: [() -> [DiagnosticFinding]] {
        [checkPathChain, checkLayoutHealth, checkVMTrees, checkShellIntegration, checkTempLinks, checkSharedConfig]
    }

    /// Strictly read-only.
    public func run() -> [DiagnosticFinding] {
        checks.flatMap { $0() }
    }

    // MARK: - Path chain

    private func checkPathChain() -> [DiagnosticFinding] {
        let desktop = manager.desktopCanonicalPath.standardizedFileURL
        let root = home.standardizedFileURL
        var chain = [root]
        if desktop.path.hasPrefix(root.path + "/") {
            var current = root
            for component in desktop.pathComponents.dropFirst(root.pathComponents.count) {
                current.appendPathComponent(component)
                chain.append(current)
            }
        } else {
            chain.append(desktop)
        }

        var findings: [DiagnosticFinding] = []
        for url in chain where lstatKind(url) == .symlink {
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
            if url.path == desktop.path {
                findings.append(
                    DiagnosticFinding(
                        id: "path.desktop",
                        severity: .error,
                        title: "Claude Desktop's folder is a symlink",
                        detail: """
                            \(url.path) → \(target)
                            This is the legacy v1 layout. Cowork's VM cannot open files through symlinks and fails \
                            with "too many levels of symbolic links". Run the v2 migration to make it a real folder.
                            """,
                        repair: .runMigration))
            } else {
                findings.append(
                    DiagnosticFinding(
                        id: "path.ancestor.\(url.lastPathComponent)",
                        severity: .error,
                        title: "\(url.lastPathComponent) is a symlink",
                        detail: """
                            \(url.path) → \(target)
                            Cowork's VM cannot open files through symlinks, so Claude Desktop's VM features fail \
                            on this Mac. The app cannot repair this: move the folder back to its standard location.
                            """))
            }
        }
        if findings.isEmpty {
            findings.append(
                DiagnosticFinding(
                    id: "path.ok",
                    severity: .ok,
                    title: "No symlinks in Claude Desktop's path",
                    detail: desktop.path))
        }
        return findings
    }

    // MARK: - Layout

    private func checkLayoutHealth() -> [DiagnosticFinding] {
        let health = manager.layout.health(activeProfileID: store.activeProfileID, profiles: store.profiles)
        switch health {
        case .healthy:
            return [
                DiagnosticFinding(
                    id: "layout.ok",
                    severity: .ok,
                    title: "Profile layout healthy",
                    detail: "Claude Desktop uses a real folder for the active profile.")
            ]
        case .migrationRequired:
            // A symlinked Desktop folder is already reported by the path check.
            if lstatKind(manager.desktopCanonicalPath) == .symlink { return [] }
            let legacyCLI = lstatKind(manager.cliCanonicalPath) == .symlink
            return [
                DiagnosticFinding(
                    id: "layout.migration",
                    severity: legacyCLI ? .error : .warning,
                    title: legacyCLI ? "Legacy symlink layout for Claude Code" : "Profiles are not set up yet",
                    detail: legacyCLI
                        ? "\(manager.cliCanonicalPath.path) is a symlink. Run the v2 migration."
                        : "Run the one-time migration from Manage Profiles to start using profiles.",
                    repair: .runMigration)
            ]
        case .recoveryRequired(let detail):
            let journal = (manager.layout as? ProfileLayoutService)?.journalURL
            let interrupted = journal.map { fm.fileExists(atPath: $0.path) } ?? false
            return [
                DiagnosticFinding(
                    id: "layout.recovery",
                    severity: .error,
                    title: interrupted ? "A profile switch was interrupted" : "Profile layout needs recovery",
                    detail: interrupted
                        ? "\(detail). Recovery finishes or rolls back the interrupted operation."
                        : "\(detail). Use Restore Backup or Disable & Restore in Manage Profiles.",
                    repair: interrupted ? .recoverLayout : nil)
            ]
        case .unsupportedFilesystem(let detail):
            // Symlinked ancestors are reported individually by the path check.
            if checkPathChain().contains(where: { $0.severity == .error }) { return [] }
            return [
                DiagnosticFinding(
                    id: "layout.filesystem", severity: .error, title: "Unsupported filesystem", detail: detail)
            ]
        }
    }

    // MARK: - Cowork VM files

    private struct DesktopRoot {
        let url: URL
        let profileID: UUID?
        let label: String
    }

    /// The active canonical Desktop folder plus every inactive profile's
    /// stored Desktop folder. With a legacy symlinked canonical folder the
    /// active profile's data lives in its stored folder, so scan that instead.
    private func desktopRoots() -> [DesktopRoot] {
        var roots: [DesktopRoot] = []
        let canonicalIsReal = lstatKind(manager.desktopCanonicalPath) == .directory
        let active = store.activeProfile
        if canonicalIsReal {
            roots.append(
                DesktopRoot(
                    url: manager.desktopCanonicalPath,
                    profileID: nil,
                    label: active.map { "active profile “\($0.name)”" } ?? "Claude Desktop"))
        }
        for profile in store.profiles where !canonicalIsReal || profile.id != store.activeProfileID {
            let url = store.desktopDirectory(profile)
            guard lstatKind(url) == .directory else { continue }
            roots.append(DesktopRoot(url: url, profileID: profile.id, label: "profile “\(profile.name)”"))
        }
        return roots
    }

    private func checkVMTrees() -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        for root in desktopRoots() {
            let key = root.profileID?.uuidString ?? "active"
            for name in Self.vmFolderNames {
                let folder = root.url.appendingPathComponent(name, isDirectory: true)
                let problems = linkProblems(in: folder)
                if !problems.isEmpty {
                    let shown = problems.prefix(10).map { "  • \($0)" }.joined(separator: "\n")
                    let more = problems.count > 10 ? "\n  • … and \(problems.count - 10) more" : ""
                    findings.append(
                        DiagnosticFinding(
                            id: "vm.\(key).\(name)",
                            severity: .error,
                            title: "Symlink in \(name) (\(root.label))",
                            detail: """
                                Cowork's VM cannot open files through symlinks ("too many levels of symbolic \
                                links"). Found in \(folder.path):
                                \(shown)\(more)
                                Moving the folder aside keeps it under \(repairsDirectory.path) (it can be \
                                large); Claude Desktop downloads a fresh copy. Delete the moved folder once Claude \
                                Desktop works again.
                                """,
                            repair: .moveAside(folder, profileID: root.profileID)))
                }
                if name == "claude-code-vm", let finding = sdkVersionFinding(folder, root: root, key: key) {
                    findings.append(finding)
                }
            }
            findings += desktopLevelLinks(root, key: key)
        }
        if !findings.contains(where: { $0.severity != .ok }) {
            findings.append(
                DiagnosticFinding(
                    id: "vm.ok",
                    severity: .ok,
                    title: "Cowork VM files contain no symlinks",
                    detail: "Checked claude-code-vm and vm_bundles in \(desktopRoots().count) Desktop folder(s)."))
        }
        return findings
    }

    /// Walk `folder` with lstat, never descending into symlinks, and describe
    /// every link found. Only metadata is read: vm_bundles holds disk images.
    private func linkProblems(in folder: URL) -> [String] {
        var problems: [String] = []
        func visit(_ url: URL, relative: String, depth: Int) {
            switch lstatKind(url) {
            case .symlink:
                problems.append("\(relative): \(describeLink(url))")
            case .error(ELOOP):
                problems.append("\(relative): symlink loop (too many levels of symbolic links)")
            case .directory:
                guard depth < 32, let children = try? fm.contentsOfDirectory(atPath: url.path) else { return }
                for child in children.sorted() {
                    visit(
                        url.appendingPathComponent(child),
                        relative: relative + "/" + child,
                        depth: depth + 1)
                }
            default:
                return
            }
        }
        visit(folder, relative: folder.lastPathComponent, depth: 0)
        return problems
    }

    private func describeLink(_ url: URL) -> String {
        let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
        var info = stat()
        if stat(url.path, &info) == 0 { return "symlink → \(target)" }
        switch errno {
        case ELOOP: return "symlink loop → \(target) (too many levels of symbolic links)"
        case ENOENT: return "dangling symlink → \(target)"
        default: return "symlink → \(target) (\(String(cString: strerror(errno))))"
        }
    }

    /// `.sdk-version` names the Claude Code build Desktop hands to the VM;
    /// its `<version>/claude` must be a regular file.
    private func sdkVersionFinding(_ folder: URL, root: DesktopRoot, key: String) -> DiagnosticFinding? {
        guard lstatKind(folder) == .directory else { return nil }
        let versionFile = folder.appendingPathComponent(".sdk-version")
        guard lstatKind(versionFile) == .regular,
            let raw = try? String(contentsOf: versionFile, encoding: .utf8)
        else { return nil }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !version.contains("/"), version != "..", version.count < 64 else { return nil }
        let binary = folder.appendingPathComponent("\(version)/claude")
        let kind = lstatKind(binary)
        let state: String
        switch kind {
        case .regular, .symlink:
            // Symlinks are reported as errors by the tree walk.
            return nil
        case .missing:
            state = "is missing"
        default:
            state = "is not a regular file"
        }
        return DiagnosticFinding(
            id: "vm.\(key).sdk-binary",
            severity: .warning,
            title: "Claude Code \(version) for Cowork \(state) (\(root.label))",
            detail: """
                .sdk-version names \(version), but \(binary.path) \(state). Claude Desktop normally downloads \
                it again on next launch; if Cowork keeps failing, move claude-code-vm aside.
                """,
            repair: kind == .missing ? nil : .moveAside(folder, profileID: root.profileID))
    }

    private func desktopLevelLinks(_ root: DesktopRoot, key: String) -> [DiagnosticFinding] {
        guard let children = try? fm.contentsOfDirectory(atPath: root.url.path) else { return [] }
        let links = children.sorted().filter {
            !Self.vmFolderNames.contains($0) && !Self.electronRuntimeLinks.contains($0)
                && lstatKind(root.url.appendingPathComponent($0)) == .symlink
        }
        guard !links.isEmpty else { return [] }
        let listed = links.map { "  • \($0): \(describeLink(root.url.appendingPathComponent($0)))" }
        return [
            DiagnosticFinding(
                id: "desktop.\(key).symlinks",
                severity: .warning,
                title: "Symlinks inside Claude Desktop's folder (\(root.label))",
                detail: """
                    \(root.url.path) contains symlinks. Cowork's VM cannot follow them if it needs these files:
                    \(listed.joined(separator: "\n"))
                    """)
        ]
    }

    // MARK: - Shell integration

    private func checkShellIntegration() -> [DiagnosticFinding] {
        let installed =
            shellIntegration.integrationStatuses().contains(where: \.installed)
            || lstatKind(shellIntegration.dispatcherURL) != .missing
        guard installed else {
            return [
                DiagnosticFinding(
                    id: "shell.none",
                    severity: .ok,
                    title: "Shell integration not installed",
                    detail: "New terminals use Claude Code's default configuration.")
            ]
        }
        var problems: [String] = []
        if !shellIntegration.dispatcherSignatureValid() {
            problems.append(
                "The dispatcher at \(shellIntegration.dispatcherURL.path) is missing, not executable, "
                    + "or fails code-signature verification.")
        }
        let manifestURL = shellIntegration.dispatcherManifestURL
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder.iso.decode(CLIProfileDispatcherManifest.self, from: data)
        {
            let real = URL(fileURLWithPath: manifest.realClaudePath)
            let shim = shellIntegration.dispatcherURL.resolvingSymlinksInPath().standardizedFileURL
            if manifest.realClaudePath.isEmpty {
                problems.append("dispatcher.json does not name a real claude binary. Install Claude Code.")
            } else if !fm.isExecutableFile(atPath: real.path) {
                problems.append("dispatcher.json points at \(real.path), which is missing or not executable.")
            } else if real.resolvingSymlinksInPath().standardizedFileURL == shim {
                problems.append("dispatcher.json points back at the dispatcher itself (\(real.path)).")
            }
        } else {
            problems.append("\(manifestURL.path) is missing or unreadable.")
        }
        guard !problems.isEmpty else {
            return [
                DiagnosticFinding(
                    id: "shell.ok",
                    severity: .ok,
                    title: "Shell integration healthy",
                    detail: "Dispatcher signature and real claude path verified.")
            ]
        }
        return [
            DiagnosticFinding(
                id: "shell.dispatcher",
                severity: .error,
                title: "Claude Code shell integration is broken",
                detail: problems.joined(separator: "\n"),
                repair: .reinstallShellIntegration)
        ]
    }

    // MARK: - Temp links

    /// Mirrors `SymlinkService.sweepStaleTempLinks` without removing anything.
    private func checkTempLinks() -> [DiagnosticFinding] {
        var stale: [String] = []
        for url in [manager.cliCanonicalPath, manager.desktopCanonicalPath] {
            let parent = url.deletingLastPathComponent()
            let prefix = ".\(url.lastPathComponent).new-"
            let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names
            where name.hasPrefix(prefix)
                && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                && lstatKind(parent.appendingPathComponent(name)) == .symlink
            {
                stale.append(parent.appendingPathComponent(name).path)
            }
        }
        guard !stale.isEmpty else { return [] }
        return [
            DiagnosticFinding(
                id: "links.stale",
                severity: .warning,
                title: "Stale temporary symlinks",
                detail: "Left behind by an interrupted swap:\n" + stale.map { "  • \($0)" }.joined(separator: "\n"),
                repair: .sweepTempLinks)
        ]
    }

    // MARK: - Shared Claude setup

    private func checkSharedConfig() -> [DiagnosticFinding] {
        guard let shared = sharedConfig else { return [] }
        var findings: [DiagnosticFinding] = []
        let drift = shared.deployedHasLocalEdits()
        if drift {
            findings.append(
                DiagnosticFinding(
                    id: "shared.drift",
                    severity: .warning,
                    title: "The shared Claude setup was edited locally",
                    detail: """
                        \(shared.deployedURL.path) differs from what the app installed (or, for a copy made by \
                        install.sh or by hand, from the bundled setup). Updating replaces it; the edited copy is \
                        kept as \(shared.deployedURL.lastPathComponent).backup-<timestamp> next to it.
                        """,
                    repair: shared.isAvailable ? .overwriteSharedConfig : nil))
        }
        var healthy = 0
        for profile in store.profiles {
            let repair: RepairAction? =
                shared.isAvailable
                ? .installSharedConfig(profileID: profile.id, overwriteLocalEdits: drift)
                : nil
            switch shared.status(profileID: profile.id) {
            case .notInstalled:
                continue
            case .installed:
                healthy += 1
            case .outdated:
                findings.append(
                    DiagnosticFinding(
                        id: "shared.\(profile.id.uuidString).outdated",
                        severity: .warning,
                        title: "Shared Claude setup update available (profile “\(profile.name)”)",
                        detail:
                            "\(shared.deployedURL.path) differs from the shared setup bundled with this version of the app.",
                        repair: repair))
            case .broken(let problems):
                findings.append(
                    DiagnosticFinding(
                        id: "shared.\(profile.id.uuidString).broken",
                        severity: .error,
                        title: "Shared Claude setup is broken (profile “\(profile.name)”)",
                        detail: problems.map { "  • \($0)" }.joined(separator: "\n"),
                        repair: repair))
            }
        }
        if healthy > 0, findings.isEmpty {
            findings.append(
                DiagnosticFinding(
                    id: "shared.ok",
                    severity: .ok,
                    title: "Shared Claude setup healthy",
                    detail: "Installed and current in \(healthy) profile(s)."))
        }
        let anyInstalled = store.profiles.contains { shared.status(profileID: $0.id) != .notInstalled }
        if anyInstalled, shared.jqURL() == nil {
            findings.append(
                DiagnosticFinding(
                    id: "shared.jq",
                    severity: .warning,
                    title: "jq is not installed",
                    detail: """
                        The shared setup's status line and subagent model hook need jq and silently do nothing \
                        without it. Install it with `brew install jq`.
                        """))
        }
        return findings
    }

    // MARK: - Repair

    /// Apply one repair. `.moveAside` refuses while Claude Desktop runs; the
    /// caller quits it first when the user agreed to that.
    public func apply(_ action: RepairAction) throws {
        switch action {
        case .runMigration:
            throw DiagnosticsError.migrationIsInteractive
        case .recoverLayout:
            try manager.recoverLayoutIfNeeded()
        case .moveAside(let url, let profileID):
            try moveAside(url, profileID: profileID)
        case .reinstallShellIntegration:
            try shellIntegration.installAllSupportedShells()
        case .sweepTempLinks:
            manager.symlinks.sweepStaleTempLinks(siblingsOf: manager.cliCanonicalPath)
            manager.symlinks.sweepStaleTempLinks(siblingsOf: manager.desktopCanonicalPath)
        case .installSharedConfig(let profileID, let overwriteLocalEdits):
            guard let sharedConfig else { throw DiagnosticsError.sharedConfigUnavailable }
            let outcome = try sharedConfig.install(
                profileID: profileID, yolo: nil, overwriteLocalEdits: overwriteLocalEdits)
            logKeptCopy(outcome)
            store.appendLog("doctor: reinstalled the shared Claude setup in \(profileID)")
        case .overwriteSharedConfig:
            guard let sharedConfig else { throw DiagnosticsError.sharedConfigUnavailable }
            logKeptCopy(try sharedConfig.deploy(overwriteLocalEdits: true))
            for profile in store.profiles where sharedConfig.status(profileID: profile.id) != .notInstalled {
                try sharedConfig.install(profileID: profile.id, yolo: nil)
            }
        }
    }

    private func logKeptCopy(_ outcome: SharedConfigDeployOutcome) {
        if case .deployed(let kept?) = outcome {
            store.appendLog("doctor: kept the edited shared Claude setup at \(kept.path)")
        }
    }

    private func moveAside(_ url: URL, profileID: UUID?) throws {
        let source = url.standardizedFileURL
        let allowed = desktopRoots().contains { root in
            root.profileID == profileID
                && root.url.standardizedFileURL.path == source.deletingLastPathComponent().path
        }
        guard allowed, Self.vmFolderNames.contains(source.lastPathComponent), lstatKind(source) != .missing
        else { throw DiagnosticsError.notMovable(source.path) }
        guard !manager.claudeApp.isClaudeRunning else { throw DiagnosticsError.desktopRunning }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination =
            repairsDirectory
            .appendingPathComponent(formatter.string(from: .now), isDirectory: true)
            .appendingPathComponent(profileID?.uuidString ?? "active", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        guard lstatKind(destination) == .missing else {
            throw DiagnosticsError.moveFailed("\(destination.path) already exists")
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // rename(2) only: same volume, the link itself moves, nothing is copied or deleted.
        guard rename(source.path, destination.path) == 0 else {
            throw DiagnosticsError.moveFailed(String(cString: strerror(errno)))
        }
        store.appendLog("doctor: moved \(source.path) to \(destination.path)")
    }

    // MARK: - Reports

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    public static func makeReport(_ findings: [DiagnosticFinding]) -> DiagnosticReport {
        DiagnosticReport(
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: .now,
            findings: findings)
    }

    /// Plain text suitable for pasting into a support conversation.
    public static func textReport(_ findings: [DiagnosticFinding]) -> String {
        let report = makeReport(findings)
        var lines = [
            "Claude Profile Switcher \(report.appVersion) — Diagnose & Repair",
            "macOS \(report.macOSVersion)",
            "Generated \(ISO8601DateFormatter().string(from: report.generatedAt))",
            "",
        ]
        for finding in findings.sorted(by: { $0.severity > $1.severity }) {
            lines.append("[\(finding.severity.rawValue.uppercased())] \(finding.title)")
            for line in finding.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
            if let repair = finding.repair {
                lines.append("    Fix: \(repair.title)")
            }
        }
        let errors = findings.filter { $0.severity == .error }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        lines.append("")
        lines.append("\(errors) error(s), \(warnings) warning(s)")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func jsonReport(_ findings: [DiagnosticFinding]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeReport(findings))
    }

    // MARK: - Filesystem

    private enum EntryKind: Equatable {
        case missing
        case directory
        case regular
        case symlink
        case other
        case error(Int32)
    }

    private func lstatKind(_ url: URL) -> EntryKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .error(errno)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        case S_IFREG: return .regular
        default: return .other
        }
    }
}
