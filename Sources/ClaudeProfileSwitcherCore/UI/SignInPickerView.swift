import SwiftUI

public struct SignInPickerView: View {
    public let profile: Profile
    public let surfaces: SurfaceAvailability
    public let onPick: (ProfileManager.SignInMethod?) -> Void

    public init(
        profile: Profile,
        surfaces: SurfaceAvailability,
        onPick: @escaping (ProfileManager.SignInMethod?) -> Void
    ) {
        self.profile = profile
        self.surfaces = surfaces
        self.onPick = onPick
    }

    // `.unknown` counts as available so a slow probe never hides options;
    // the sign-in preflight still catches a genuinely missing surface.
    private var desktopAvailable: Bool { surfaces.desktop != .notInstalled }
    private var cliAvailable: Bool { surfaces.cli != .notInstalled }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(profile.name)").font(.title2).bold()

            explainer

            if desktopAvailable || cliAvailable {
                methodButtons
            } else {
                nothingInstalled
            }

            HStack {
                if !desktopAvailable || !cliAvailable {
                    Button {
                        surfaces.refreshSoon(force: true)
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Later") { onPick(nil) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { surfaces.refreshSoon() }
    }

    @ViewBuilder
    private var explainer: some View {
        if desktopAvailable && cliAvailable {
            Text(
                "Claude Desktop and Claude Code use separate credential stores, so each needs its own sign-in. We'll launch Desktop first; once that's done, a Terminal will open to run `claude`. Your claude.ai browser session is shared, so the second flow is usually one click."
            )
            .foregroundStyle(.secondary)
        } else if desktopAvailable {
            Text(
                "The `claude` CLI wasn't found on this Mac, so only the Desktop sign-in is available. Install Claude Code later and re-open this sheet to add the CLI."
            )
            .foregroundStyle(.secondary)
        } else if cliAvailable {
            Text(
                "Claude Desktop isn't installed on this Mac, so only the CLI sign-in is available. A Terminal window will open running `claude`, which prompts for /login."
            )
            .foregroundStyle(.secondary)
        } else {
            Text(
                "Neither Claude Desktop nor the `claude` CLI was found on this Mac. Install at least one of them, then come back — the profile is created and ready."
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var methodButtons: some View {
        VStack(spacing: 8) {
            if desktopAvailable && cliAvailable {
                Button {
                    onPick(.both)
                } label: {
                    Label("Sign in to both (Desktop + CLI)", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 8) {
                    Button {
                        onPick(.desktop)
                    } label: {
                        Label("Desktop only", systemImage: "app.fill")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        onPick(.cli)
                    } label: {
                        Label("CLI only", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else if desktopAvailable {
                Button {
                    onPick(.desktop)
                } label: {
                    Label("Sign in with Claude Desktop", systemImage: "app.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    onPick(.cli)
                } label: {
                    Label("Sign in with the CLI", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var nothingInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: URL(string: "https://claude.ai/download")!) {
                Label("Download Claude Desktop", systemImage: "arrow.down.circle")
            }
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text("Install Claude Code:")
                Text(verbatim: "npm install -g @anthropic-ai/claude-code")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
        }
    }
}
