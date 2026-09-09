import Foundation

private actor ClaudeCodeStatusCache {
    static let shared = ClaudeCodeStatusCache()
    private var values: [String: (date: Date, status: ClaudeCodeAuthStatus)] = [:]

    func status(
        for directory: URL,
        runner: any ClaudeCodeRunning,
        ttl: TimeInterval = 2
    ) async throws -> ClaudeCodeAuthStatus {
        let key = directory.standardizedFileURL.path
        if let cached = values[key], Date().timeIntervalSince(cached.date) < ttl {
            return cached.status
        }
        let status = try await runner.authStatus(configDirectory: directory)
        values[key] = (.now, status)
        return status
    }

    func invalidate(_ directory: URL) {
        values.removeValue(forKey: directory.standardizedFileURL.path)
    }
}

/// Sign-in state for one surface (CLI or Desktop) of a single profile.
public struct SurfaceStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case signedIn
        case signedOut
        /// The CLI or Desktop status command/file could not be read safely.
        case unknown
    }
    public let state: State
    /// File modification date of the credential marker, if present.
    public let lastUpdated: Date?
    /// Optional explanation surfaced as a tooltip / hint.
    public let note: String?

    public init(state: State, lastUpdated: Date?, note: String?) {
        self.state = state
        self.lastUpdated = lastUpdated
        self.note = note
    }

    public static let signedOut = SurfaceStatus(state: .signedOut, lastUpdated: nil, note: nil)

    public var isSignedIn: Bool { state == .signedIn }
    public var isUnknown: Bool { state == .unknown }
}

public struct ProfileLoginStatus: Equatable, Sendable {
    public var cli: SurfaceStatus
    public var desktop: SurfaceStatus

    public init(cli: SurfaceStatus, desktop: SurfaceStatus) {
        self.cli = cli
        self.desktop = desktop
    }

    public var anySignedIn: Bool { cli.isSignedIn || desktop.isSignedIn }
    public var bothSignedIn: Bool { cli.isSignedIn && desktop.isSignedIn }
}

/// Inspects on-disk credential markers to determine sign-in state.
///
/// **Desktop** keeps its OAuth token encrypted inside the `"oauth:tokenCache"`
/// field of `config.json` — that's the authoritative on-disk marker.
///
/// **CLI** status is authoritative from `claude auth status --json`, invoked
/// with that profile's `CLAUDE_CONFIG_DIR`. Legacy credential files are only a
/// fast-path for older Claude Code versions.
///
/// The struct is **not** main-actor isolated. Synchronous methods do file I/O
/// only and can run from any thread. The async methods use `KeychainProbe`
/// (its own actor) so the subprocess never blocks the caller.
///
/// `@unchecked Sendable` because `FileManager.default` is documented thread-safe
/// but the type itself isn't `Sendable`; we hold an immutable reference and
/// only read.
public struct CredentialsInspector: @unchecked Sendable {
    public let fm: FileManager
    public let store: ProfileStore
    /// Set to `false` from tests so the keychain probe doesn't run (it would
    /// behave inconsistently across machines and isn't relevant to fixture-based
    /// tests). Production callers should leave it on.
    public let keychainProbeEnabled: Bool
    /// Injection seam for tests; defaults to the shared keychain probe.
    public let keychainProbe: KeychainProbe
    public let canonicalDesktopPath: URL
    public let claudeCodeRunner: any ClaudeCodeRunning

    public init(
        fm: FileManager = .default,
        store: ProfileStore,
        keychainProbeEnabled: Bool = true,
        keychainProbe: KeychainProbe = .shared,
        canonicalDesktopPath: URL = ProfileStore.claudeDesktopPath,
        claudeCodeRunner: any ClaudeCodeRunning = ClaudeCodeRunner()
    ) {
        self.fm = fm
        self.store = store
        self.keychainProbeEnabled = keychainProbeEnabled
        self.keychainProbe = keychainProbe
        self.canonicalDesktopPath = canonicalDesktopPath
        self.claudeCodeRunner = claudeCodeRunner
    }

    /// Candidate credential filenames for the CLI (older Claude Code versions
    /// kept tokens in a file before the keychain migration).
    private static let cliCredentialFilenames = [".credentials.json", "credentials.json"]

    /// Authoritative Desktop config file.
    private static let desktopConfigFilename = "config.json"

    /// Synchronous, file-only status. Used by the sign-in polling loop which
    /// only cares whether the *file* credential marker has landed yet.
    public func status(for profile: Profile, activeProfileID: UUID? = nil) -> ProfileLoginStatus {
        ProfileLoginStatus(
            cli: inspectCLI(directory: store.cliDirectory(profile)),
            desktop: inspectDesktop(
                directory: activeProfileID == profile.id ? canonicalDesktopPath : store.desktopDirectory(profile))
        )
    }

    /// Async status that asks Claude Code using the profile-specific config
    /// directory. Used by the UI badges.
    public func statusWithKeychain(
        for profile: Profile,
        activeProfileID: UUID? = nil
    ) async -> ProfileLoginStatus {
        async let cli = inspectCLIWithKeychain(directory: store.cliDirectory(profile))
        let desktop = inspectDesktop(
            directory: activeProfileID == profile.id ? canonicalDesktopPath : store.desktopDirectory(profile))
        return ProfileLoginStatus(cli: await cli, desktop: desktop)
    }

    /// Returns the credential file paths to delete on sign-out for a given profile.
    public func credentialFiles(for profile: Profile, surface: Surface) -> [URL] {
        let dir: URL
        let names: [String]
        switch surface {
        case .cli:
            dir = store.cliDirectory(profile)
            names = Self.cliCredentialFilenames
        case .desktop:
            dir = store.desktopDirectory(profile)
            // We don't delete config.json wholesale — too much state lives there.
            // Sign-out for Desktop is handled by clearing the oauth:tokenCache
            // key (see ProfileManager.signOut), plus optionally Cookies / Storage.
            names = []
        }
        return
            names
            .map { dir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Desktop

    /// Inspects the given Desktop support directory for an `oauth:tokenCache`
    /// marker. Public so tests can drive it against fixture JSON directly.
    public func inspectDesktop(directory: URL) -> SurfaceStatus {
        let configURL = directory.appendingPathComponent(Self.desktopConfigFilename)
        guard fm.fileExists(atPath: configURL.path),
            let data = try? Data(contentsOf: configURL)
        else {
            return .signedOut
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SurfaceStatus(
                state: .unknown,
                lastUpdated: nil,
                note: "config.json was unreadable as JSON; couldn't determine sign-in state.")
        }

        // Token is an encrypted blob under "oauth:tokenCache". When the user
        // signs out via Claude Desktop, the field gets removed or set to "".
        if let token = json["oauth:tokenCache"] as? String, !token.isEmpty {
            let modified = (try? fm.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
            return SurfaceStatus(state: .signedIn, lastUpdated: modified, note: nil)
        }
        return .signedOut
    }

    // MARK: - CLI

    /// File-only CLI inspection. Returns `.signedIn` or `.signedOut` based on
    /// the per-profile credential file. Never touches the keychain — call
    /// `inspectCLIWithKeychain` if you want that fallback.
    public func inspectCLI(directory: URL) -> SurfaceStatus {
        for name in Self.cliCredentialFilenames {
            let file = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path),
                let attrs = try? fm.attributesOfItem(atPath: file.path),
                let size = attrs[.size] as? NSNumber, size.intValue > 0
            {
                return SurfaceStatus(
                    state: .signedIn,
                    lastUpdated: attrs[.modificationDate] as? Date,
                    note: nil)
            }
        }
        return .signedOut
    }

    /// File-first, then the authoritative profile-scoped Claude Code command.
    public func inspectCLIWithKeychain(directory: URL) async -> SurfaceStatus {
        let fileStatus = inspectCLI(directory: directory)
        if fileStatus.isSignedIn { return fileStatus }

        guard keychainProbeEnabled else { return fileStatus }

        do {
            let status = try await ClaudeCodeStatusCache.shared.status(
                for: directory, runner: claudeCodeRunner)
            if status.loggedIn {
                return SurfaceStatus(state: .signedIn, lastUpdated: nil, note: nil)
            }
            return .signedOut
        } catch {
            return SurfaceStatus(
                state: .unknown,
                lastUpdated: nil,
                note: "Could not verify this profile with `claude auth status`: \(error.localizedDescription)"
            )
        }
    }

    public func invalidateCLIStatus(for profile: Profile) async {
        await ClaudeCodeStatusCache.shared.invalidate(store.cliDirectory(profile))
    }
}

public enum Surface: Sendable, Equatable, Hashable {
    case cli
    case desktop
}
