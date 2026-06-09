import Foundation

/// Sign-in state for one surface (CLI or Desktop) of a single profile.
public struct SurfaceStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case signedIn
        case signedOut
        /// We can't tell from local files; the source of truth is elsewhere
        /// (e.g. the macOS keychain, which is shared across profiles).
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
/// **CLI** (Claude Code) stores credentials in the macOS keychain in
/// `Claude Code-credentials*`. Without `CLAUDE_CONFIG_DIR` isolation the
/// keychain entry is shared across profiles, so we can't tell *which* profile
/// owns the credentials — we report `.unknown` when the file marker is missing
/// but a global keychain entry exists.
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

    public init(
        fm: FileManager = .default,
        store: ProfileStore,
        keychainProbeEnabled: Bool = true,
        keychainProbe: KeychainProbe = .shared
    ) {
        self.fm = fm
        self.store = store
        self.keychainProbeEnabled = keychainProbeEnabled
        self.keychainProbe = keychainProbe
    }

    /// Candidate credential filenames for the CLI (older Claude Code versions
    /// kept tokens in a file before the keychain migration).
    private static let cliCredentialFilenames = [".credentials.json", "credentials.json"]

    /// Authoritative Desktop config file.
    private static let desktopConfigFilename = "config.json"

    /// Synchronous, file-only status. Used by the sign-in polling loop which
    /// only cares whether the *file* credential marker has landed yet.
    public func status(for profile: Profile) -> ProfileLoginStatus {
        ProfileLoginStatus(
            cli: inspectCLI(directory: store.cliDirectory(profile)),
            desktop: inspectDesktop(directory: store.desktopDirectory(profile))
        )
    }

    /// Async status that also probes the macOS keychain (off-main, cached).
    /// Used by the UI badges.
    public func statusWithKeychain(for profile: Profile) async -> ProfileLoginStatus {
        async let cli = inspectCLIWithKeychain(directory: store.cliDirectory(profile))
        let desktop = inspectDesktop(directory: store.desktopDirectory(profile))
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

    /// File-first, then async keychain fallback. Returns `.unknown` with a
    /// note when the per-profile file is absent but a global keychain entry
    /// exists.
    public func inspectCLIWithKeychain(directory: URL) async -> SurfaceStatus {
        let fileStatus = inspectCLI(directory: directory)
        if fileStatus.isSignedIn { return fileStatus }

        guard keychainProbeEnabled else { return fileStatus }

        if await keychainProbe.hasGenericPassword(service: "Claude Code-credentials") {
            return SurfaceStatus(
                state: .unknown,
                lastUpdated: nil,
                note:
                    "A shared Claude Code keychain login exists — it may belong to another profile. The macOS keychain is shared across profiles unless CLAUDE_CONFIG_DIR is set; install Shell integration and bind projects with a .claude-profile file to give each profile its own keychain slot."
            )
        }
        return .signedOut
    }
}

public enum Surface: Sendable, Equatable, Hashable {
    case cli
    case desktop
}
