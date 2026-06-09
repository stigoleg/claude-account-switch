# Claude Profile Switcher

**One Mac. All your Claude accounts. Switch in a click.**

If you use Claude with more than one account — personal and work, say — you know the dance: sign out, sign back in, lose your place, repeat tomorrow. Claude Profile Switcher ends it. Each account lives in its own self-contained profile, and a small menu-bar app flips between them instantly. One switch covers both Claude Desktop and Claude Code (the CLI), with no changes to how you use either app.

> Not affiliated with Anthropic. A personal tool, shared as-is.

[![build](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml/badge.svg)](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml)

## Why this exists

Claude assumes one account per Mac. Both apps store their settings and sign-in state at fixed locations:

- `~/.claude` for Claude Code
- `~/Library/Application Support/Claude/` for Claude Desktop

Sign in with a second account, and it overwrites the first. The usual workaround — the `CLAUDE_CONFIG_DIR` environment variable — only helps the CLI, and only in terminals where you remember to set it. Claude Desktop ignores it entirely.

## How it works

Every account gets a private copy of both directories, kept under one roof:

```
~/Library/Application Support/ClaudeProfileSwitcher/
└── profiles/
    ├── <personal>/
    │   ├── cli/        ← ~/.claude points here
    │   └── desktop/    ← ~/Library/Application Support/Claude points here
    └── <work>/
        ├── cli/
        └── desktop/
```

The real paths become symlinks that point at whichever profile is active. Switching accounts just re-points them — atomic, instant, and invisible to Claude. If Claude Desktop is running, the app asks first, quits it cleanly, flips the links, and relaunches it signed in to the other account. Every terminal you open afterwards picks up the right account automatically.

## Install

### Homebrew (recommended)

```bash
brew tap stigoleg/tap
brew install --cask claude-profile-switcher
```

Then one extra step before the first launch. The app is ad-hoc signed (no paid Apple Developer ID), so macOS quarantines the download and Gatekeeper blocks it from opening. Either right-click the app in Finder and choose *Open* — once is enough — or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"
```

Only do this for software you trust. Every download can be verified against the `SHA256SUMS` file attached to its [GitHub release](https://github.com/stigoleg/claude-account-switch/releases).

### Manual download

Grab the `.dmg` (drag to Applications) or the `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest), then clear quarantine the same way.

### Requirements

macOS 14 (Sonoma) or newer. Building from source also needs the Swift 6 toolchain (Xcode 16 or later).

## Getting started

1. **Run the one-time migration.** On first launch, the app offers to move your existing Claude data into a profile named `default`. Quit Claude Desktop, click **Run Migration**, and you're done. It's a move, not a copy — nothing is duplicated or lost.
2. **Add your second account.** Open *Manage Profiles…*, give the profile a name, and click *Create + Sign In*. The app walks you through both sign-ins: Claude Desktop opens first, and once it's signed in, a Terminal window opens running `claude` for the CLI. Your claude.ai browser session carries over, so the second sign-in is usually a single click. If only one of the two apps is installed, the sheet adapts.
3. **Switch whenever you like.** Click the menu-bar chip — a colored circle with the active profile's initial — and pick a profile.

## Everyday use

- **See where you're signed in.** Each profile card shows separate badges for Desktop and CLI. Green check: signed in. Grey ✗: not signed in. Orange *Can't verify*: a shared CLI keychain login exists that can't be pinned to one profile — shell integration below fixes that.
- **Sign in and out per app.** Every card has a primary *Sign in* button plus a menu for Desktop-only or CLI-only. Signing out clears that profile's tokens and web session, and never touches the shared keychain entry other profiles may depend on.
- **Copy your setup to a new account.** Fresh work account, empty config? Open the profile's *⋯* menu and choose **Copy Config From…** to bring over MCP servers, plugins, skills, commands and settings from another profile. *Merge* lists any conflicts and lets you pick a winner per item; *Overwrite* mirrors the source and moves whatever it replaced to the Trash, so it's reversible. Credentials, sign-in state, cookies and history never come along.
- **Rename, recolor, delete** from each card. Deleted profiles go to the Trash, not into the void.
- **⌘Q won't kill the app** while the *Manage Profiles…* window is focused — it keeps running in your menu bar. Quit it from the menu-bar dropdown instead.

## Power features

### Pin a project to an account

Some repos should always use the work account, no matter what the menu bar says. Install **Shell integration** from *Manage Profiles…*, then drop a one-line file into the project:

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile
cd ~/repos/work-monorepo
claude   # runs as "work", regardless of the active profile
```

A small zsh function finds the nearest `.claude-profile`, points `CLAUDE_CONFIG_DIR` at that profile, and hands off to the real `claude`. As a welcome side effect, pinned projects get their own keychain entry per profile — which is exactly what clears up the *Can't verify* badge. Optionally enable *Suggest Desktop switches* to get a notification when you enter a pinned project that doesn't match the active Desktop profile.

zsh only, since that's what macOS ships. The function file happens to be bash-compatible if you want to source it yourself.

### Keep your profile list in sync across Macs

Enable *Sync profiles via iCloud Drive* in the menu-bar dropdown and your profile list — names, colors, deletions — stays consistent on every Mac signed into your iCloud account. Conflicts resolve newest-wins, and deletions are remembered so a removed profile can't reappear from a stale machine. Credentials never sync; you sign in once per Mac.

### One honest caveat: CLI MCP servers

Claude Code keeps user-level MCP servers in `~/.claude.json`, a file in your home folder that sits *outside* the switched directories — all profiles share it, along with your CLI identity. Per-profile CLI MCP config exists only inside projects pinned via shell integration. Desktop MCP servers (`claude_desktop_config.json`) are fully per-profile and switch — and copy — cleanly.

## Stepping away

**Menu bar → Disable & Restore Default Layout…** undoes everything safely: it quits Claude Desktop, removes the symlinks, and moves the active profile's data back to the original paths. Claude behaves exactly as it did before the app existed. Other profiles stay on disk in case you return.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar says *No profile active* | The symlinks broke (OS update, manual `rm`). Switch to any profile to recreate them. |
| Claude Desktop won't quit during a switch | The app force-quits after 8 seconds. If even that fails, quit it manually and retry. |
| An open terminal still shows the old account | Running processes hold on to the old directory. A new terminal tab gets the new account. |
| Want everything back to stock | Use **Disable & Restore** — don't hand-delete the symlinks. |

## Building from source

```bash
make            # list all targets
make build      # ./build/Claude Profile Switcher.app
make run        # build + launch
make test       # unit tests
make lint       # swift format lint
make install    # copy into /Applications
make dist       # release artifacts (.zip, .dmg, SHA256SUMS) in ./dist
make clean      # remove .build, ./build, ./dist
make xcode      # open the package in Xcode
```

Tip: Xcode's Run button launches the bare executable without `LSUIElement`, so a Dock icon appears. For the real menu-bar experience, use `make run`.

## CI & releases

- [`build.yml`](.github/workflows/build.yml) — every push and PR to `main`: lint, tests, and a build on a macOS 14 + 15 matrix. Pushes upload the built `.app` as a short-lived artifact.
- [`release.yml`](.github/workflows/release.yml) — on a `v*` tag: tests → version guard → `make dist` → GitHub Release (zip, dmg, SHA256SUMS, auto-generated notes) → Homebrew cask bump in [`stigoleg/homebrew-tap`](https://github.com/stigoleg/homebrew-tap).

Cutting a release is one command:

```bash
git tag v1.4.0 && git push origin v1.4.0
```

The git tag is the single source of truth for the version. `AppBundle/Info.plist` holds template values that `build-app.sh` stamps at build time (`CFBundleVersion` = commit count); untagged local builds are stamped `0.0.0-dev`. The cask bump needs the `TAP_GITHUB_TOKEN` repo secret — a fine-grained PAT with contents read/write, scoped to the tap repo only. Without it, that job skips with a warning.

## Good to know

- **Unsigned, by choice.** Ad-hoc signed, not notarized — hence the one-time Gatekeeper step. The release workflow has a ready slot for Developer ID signing if that ever changes.
- **Your data stays put.** Profile data lives unencrypted on disk with normal filesystem permissions, same as Claude's own defaults. iCloud sync carries metadata only; tokens and conversations never leave the machine.
- **No sandbox.** Required — the whole point is managing files outside the app's own container.

## Repo layout

```
Sources/
├── ClaudeProfileSwitcher/         executable shim (@main only)
└── ClaudeProfileSwitcherCore/     library: Models, Services, UI
Tests/ClaudeProfileSwitcherCoreTests/   XCTest suite (80 tests)
AppBundle/                         Info.plist + entitlements + icon
Packaging/homebrew/                cask template for the tap
Scripts/                           version stamping, dmg, icon generation
.github/workflows/                 build.yml + release.yml
Makefile, build-app.sh             build / test / package
```
