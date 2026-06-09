# Claude Profile Switcher

A lightweight macOS menu-bar app for juggling multiple Claude accounts (personal, work, etc.) with **one click**. Works with both Claude Code (CLI) and Claude Desktop — they don't need to know it's there.

> Not affiliated with Anthropic. Personal tool.

[![build](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml/badge.svg)](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml)

## Why

Claude Code and Claude Desktop both read from fixed paths:
- `~/.claude` (CLI)
- `~/Library/Application Support/Claude/` (Desktop app)

Logging into a second account stomps the first. The well-known `CLAUDE_CONFIG_DIR` env-var trick only covers the CLI; the Desktop app ignores it.

This app keeps each account in its own profile directory and atomically flips the canonical paths to **symlinks** pointing at the active profile. Launching `claude` in any terminal or opening the Desktop app from anywhere "just works" with the currently-selected account.

## How it works

```
~/Library/Application Support/ClaudeProfileSwitcher/
└── profiles/
    ├── <uuid-default>/
    │   ├── cli/        ← ~/.claude is a symlink here
    │   └── desktop/    ← ~/Library/Application Support/Claude is a symlink here
    └── <uuid-work>/
        ├── cli/
        └── desktop/
```

Switching profiles = `unlink` + `symlink`. Atomic, instant. Quits Claude Desktop first if it's running and reopens it on the new profile.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15 / Swift 6 toolchain (you'll have it if Xcode 26 is installed) — only needed to build from source

## Install

### Homebrew (recommended)

```bash
brew tap stigoleg/tap
brew install --cask --no-quarantine claude-profile-switcher
```

The app is **ad-hoc signed** (no Apple Developer ID), so Gatekeeper blocks the first launch of a quarantined copy. `--no-quarantine` skips that check at install time — only use it for software you trust; you can verify the download against the `SHA256SUMS` file attached to each [GitHub release](https://github.com/stigoleg/claude-account-switch/releases).

### Manual download

Grab the `.dmg` (drag to Applications) or `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest), then clear quarantine once:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"
```

…or right-click the app in Finder and choose *Open*.

## Build & install from source

There's a Makefile for the common operations:

```bash
make           # show targets
make build     # produce ./build/Claude Profile Switcher.app
make run       # build + open the bundle
make install   # copy into /Applications (overwrites any prior install)
make test      # run unit tests
make lint      # swift format lint over Sources/Tests
make dist      # build .zip + .dmg + SHA256SUMS into ./dist
make icon      # regenerate AppBundle/AppIcon.{png,icns} from the source script
make clean     # remove .build, ./build and ./dist
make xcode     # open Package.swift in Xcode
```

## CI & releases

- [`build.yml`](.github/workflows/build.yml): `make test` + `make build` on every push/PR to main, on a macOS 14 + 15 matrix; pushes to main upload the built `.app` as a short-lived artifact.
- [`release.yml`](.github/workflows/release.yml): fires on a `v*` tag — tests → version guard (tag must match `Scripts/version.sh`) → `make dist` → GitHub Release with auto-generated notes, the `.zip`/`.dmg` and `SHA256SUMS` → Homebrew cask bump in `stigoleg/homebrew-tap`.

Cutting a release:

```bash
git tag v1.3.0 && git push origin v1.3.0
```

The version in `AppBundle/Info.plist` is a template (`0.0.0`) — the **git tag is the single source of truth**, stamped into the bundle at build time (`CFBundleVersion` = commit count). Untagged local builds are stamped `0.0.0-dev`. The cask bump job needs a `TAP_GITHUB_TOKEN` repo secret (fine-grained PAT, contents read/write, scoped to **only** the tap repo); without it the job skips with a warning.

For development you can also just open the package in Xcode:

```bash
make xcode
```

…but Xcode's Run button launches the SPM executable without `LSUIElement`, so a Dock icon will appear and the menu bar item will look slightly different. For the real experience, run `make build` and open the bundled `.app`.

## First run

1. The app opens a one-time migration sheet. **Quit Claude Desktop first.**
2. Click **Run Migration**. Your existing `~/.claude` and `~/Library/Application Support/Claude` are moved into a profile called `default`. Symlinks are created at the original paths.
3. The menu bar shows an avatar chip — a colored circle with the active profile's first letter inside. When no profile is active, you see a swap-arrows glyph instead.

## Daily use

- **Switch accounts**: click the menu bar item → click another profile. If Claude Desktop is running, you get a confirmation dialog first (so you don't lose an in-flight conversation). Claude Desktop is quit, the symlinks flip, and Claude Desktop relaunches on the new account.
- **Add an account**: *Manage Profiles…* → type a name → *Create + Sign In*. A sheet appears with **Sign in to both (Desktop + CLI)** as the primary option, plus *Desktop only* / *CLI only* as alternatives. The profile becomes active and Claude's own login screen opens.
- **About "sign in to both"**: Claude Desktop and Claude Code (CLI) use separate credential stores (`config.json`'s `oauth:tokenCache` and the macOS keychain) issued by different OAuth flows — no supported way to share them. The app sequences both sign-ins for you: Desktop launches first, the app polls until tokens land, then a Terminal window opens for `claude`. Your claude.ai browser session is shared, so the second flow is usually a one-click approval.
- **See where you're signed in**: each profile card shows badges for **Desktop** and **CLI** independently.
  - Desktop: green check = signed in (detected by reading the `oauth:tokenCache` field in `config.json`). This is the authoritative on-disk marker for Claude Desktop.
  - CLI: green check = local credential file present (older Claude Code versions); orange `?` = a `Claude Code-credentials*` entry exists in the macOS keychain but we can't attribute it to a specific profile *unless* you bind via shell integration (see below); grey x = no trace.
- **Sign in again / sign out**: each card has a primary *Sign in* button that hits both surfaces, plus a chevron menu for single-surface variants. Sign-out behaviour:
  - Desktop: clears `oauth:tokenCache` from `config.json` and removes the Electron `Cookies` file so the next launch shows the login screen.
  - CLI: deletes any legacy `.credentials.json` file. **Does not** touch the keychain entry, because it's shared across profiles when no `CLAUDE_CONFIG_DIR` is set.
- **Copy config between profiles**: per-profile *⋯* menu → **Copy Config From…**. Pick the source profile, tick what to bring over — MCP servers, plugins, skills/commands/agents, settings (CLI), MCP servers & extensions (Desktop) — and choose **Merge** or **Overwrite**. Merge shows a per-item conflict list when both profiles define the same thing (pick source or target per item, or "use source/target for all"). Overwrite mirrors the source for the selected categories; replaced items go to the **Trash** so they're recoverable. Credentials, sign-in state, cookies, and history are **never** copied (strict allow-list). Note: per-profile *CLI* MCP servers only exist under shell integration (`CLAUDE_CONFIG_DIR`) — without it the CLI reads the global `~/.claude.json`, which this app doesn't manage. Desktop MCP servers (`claude_desktop_config.json`) are always per-profile and copyable.
- **CMD+Q** while the *Manage Profiles…* window is focused **does not quit the app**. Use *Quit Claude Profile Switcher* in the menu bar dropdown instead. This keeps the menu bar app running when you reach for the usual shortcut to close a window.
- **Rename / delete**: per-profile *⋯* menu. Deleted profile data is moved to the Trash so it's recoverable.

## Multi-machine: iCloud Drive sync

Enable *Sync profiles via iCloud Drive* in the menu bar dropdown to keep the profile list in sync across Macs signed into the same iCloud account. The file lives at:

```
~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeProfileSwitcher/profiles.json
```

What syncs: profile IDs, names, colors, timestamps, deletion tombstones. **Credentials never leave the device** — you re-sign in on each Mac, and the keychain entries stay local. Conflicts between machines are resolved per-profile by `updatedAt` (last-writer-wins); deletions are tombstoned so a removed profile on Mac A doesn't get resurrected by stale state on Mac B.

If iCloud Drive isn't available the toggle shows an error and stays off.

## Per-project binding: shell integration

In *Manage Profiles…*, the **Shell integration** section installs a `claude` zsh function that walks up from `$PWD` looking for a `.claude-profile` file. If found, it reads the profile name on the first line, sets `CLAUDE_CONFIG_DIR` to that profile's `cli/` directory, and execs the real `claude`.

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile
cd ~/repos/work-monorepo
claude /status   # signs you in as the "work" profile, regardless of menu-bar selection
```

Because `CLAUDE_CONFIG_DIR` is part of how Claude Code hashes its keychain entry name, each profile gets its own keychain slot inside bound projects — **this is the supported fix for the v1.0 CLI-keychain-isolation limitation**. The globally-active profile (what the menu bar shows) keeps using the unsuffixed keychain entry.

Install / uninstall:
- **Install into ~/.zshrc** writes `~/.config/claude-profile-switcher/claude-profile.zsh` and appends a `source` line to `~/.zshrc` (idempotent).
- **Uninstall** removes the source line but leaves the function file in place.
- **Non-zsh shells**: install detects `$SHELL` and refuses if it isn't zsh. The function file format is plain zsh, but you can source the same file from bash if you want (the syntax happens to be compatible). To write the function file without touching any rc file, call `installFunctionFileOnly()` via the model, or just `swift run` your way through. Native bash/fish integration isn't on the roadmap.

Optional: tick **Suggest Desktop switches** to also get a macOS notification when you enter a bound project whose profile differs from the active Desktop profile. Clicking *Switch* on the notification goes through the regular "Claude Desktop is running" confirmation. The CLI binding works regardless of this checkbox.

## Disable & Restore

When you want to step away from the symlink layout (e.g. you're switching to a different multi-account approach, or troubleshooting), open the menu bar → **Disable & Restore Default Layout…** (also visible as a button in the *Manage Profiles…* header).

What it does:
1. Quits Claude Desktop.
2. Removes the symlinks at `~/.claude` and `~/Library/Application Support/Claude`.
3. Moves the **active profile's** `cli/` and `desktop/` directories back to the canonical paths.
4. Clears the active profile pointer. Other profiles stay on disk (so a re-migration later can pick them up) but become inactive.
5. Optionally quits the app.

After this, Claude reads/writes the real directories directly again — the app is "out of the way."

## Troubleshooting

**The menu bar says "No profile active"** — the symlinks at the canonical paths got broken (OS update, manual `rm`, etc.). Open *Manage Profiles…* and switch to any profile — that recreates the symlinks.

**Claude Desktop won't quit** — the app force-quits after 8 seconds. If that fails too, quit it manually and retry the switch.

**`claude` CLI still shows the old account in an open terminal** — running processes hold file descriptors to the old inode. Open a new terminal tab; it will see the new profile.

**Want to undo everything cleanly** — use **Disable & Restore** (see above) instead of the manual `rm`/`mv` recipe; it does the same thing safely.

## Caveats

- The app is unsigned (ad-hoc only). The first launch needs a right-click → *Open* to bypass Gatekeeper, or `xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"`.
- Profile data is not encrypted at rest beyond filesystem permissions (same as Claude's defaults).
- iCloud Drive sync only carries metadata. Tokens, conversation history, MCP configs etc. **never** leave the device.
- Sandbox is off — required to read/write outside the app's container.

## Repo layout

```
Sources/
├── ClaudeProfileSwitcher/         executable shim (@main only)
└── ClaudeProfileSwitcherCore/     library: Models, Services, UI
Tests/ClaudeProfileSwitcherCoreTests/    XCTest target
AppBundle/                         Info.plist + entitlements
.github/workflows/build.yml        CI: swift test + ./build-app.sh
Makefile                           build / run / test / install / clean / xcode
build-app.sh                       SPM binary → .app wrapper + ad-hoc codesign
```
