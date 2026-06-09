# Claude Profile Switcher

**Use all your Claude accounts on one Mac — and switch between them in one click.**

A lightweight macOS menu-bar app for anyone juggling a personal and a work Claude account (or more). It works with both Claude Code (the CLI) and Claude Desktop, and neither of them needs to know it's there.

> Not affiliated with Anthropic. A personal tool, shared as-is.

[![build](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml/badge.svg)](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml)

## The problem

Claude only knows about one account at a time. Both apps read from fixed locations:

- `~/.claude` — Claude Code (CLI)
- `~/Library/Application Support/Claude/` — Claude Desktop

Sign in with a second account and it stomps the first. You end up logging in and out all day, or fiddling with the `CLAUDE_CONFIG_DIR` environment variable — which only helps the CLI; the Desktop app ignores it.

## The fix

Claude Profile Switcher gives every account its own **profile** — a private copy of both directories — and points the real paths at the active profile using symlinks:

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

Switching accounts just re-points the symlinks — atomic and instant. If Claude Desktop is running, the app asks first, quits it cleanly, flips the links, and relaunches it on the new account. Any terminal you open afterwards gets the right account automatically.

## Install

### Homebrew (recommended)

```bash
brew tap stigoleg/tap
brew install --cask claude-profile-switcher
```

**Then, one extra step on first launch.** The app is ad-hoc signed (no paid Apple Developer ID), so macOS quarantines the download and Gatekeeper blocks the first open. Either right-click the app in Finder and choose *Open* (once), or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"
```

Only do this for software you trust — you can verify any download against the `SHA256SUMS` file attached to each [GitHub release](https://github.com/stigoleg/claude-account-switch/releases). (Older guides suggest `brew install --no-quarantine`; Homebrew has removed that flag.)

### Manual download

Grab the `.dmg` (drag to Applications) or `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest), then clear quarantine as above.

### Requirements

macOS 14 (Sonoma) or newer. Building from source additionally needs the Swift 6 toolchain (Xcode 16+).

## Getting started

1. **First launch**: a one-time migration sheet appears. Quit Claude Desktop, then click **Run Migration**. Your existing Claude data moves into a profile called `default`; symlinks take its place. Nothing is lost — it's a move, not a copy.
2. **Add your second account**: open *Manage Profiles…*, type a name, click *Create + Sign In*. The app sequences both sign-ins for you: Claude Desktop opens first, and once its token lands, a Terminal window opens running `claude` for the CLI. Your claude.ai browser session is shared, so the second sign-in is usually one click. (On a machine with only one of the two apps installed, the sheet adapts automatically.)
3. **Switch any time**: click the menu-bar chip — a colored circle with the active profile's initial — and pick a profile.

## Everyday use

- **See where you're signed in.** Each profile card shows independent **Desktop** and **CLI** badges: green check = signed in, grey ✗ = not signed in, orange *Can't verify* = a shared CLI keychain login exists that can't be attributed to one profile (see *shell integration* below for the fix).
- **Sign in / sign out per surface.** Every card has a primary *Sign in* button plus a menu for Desktop-only or CLI-only. Signing out clears that profile's tokens and web session — it never touches the shared keychain entry other profiles may rely on.
- **Copy config between profiles.** New work account, empty config? Profile *⋯* menu → **Copy Config From…** brings over MCP servers, plugins, skills, commands, and settings from another profile. Choose **Merge** (conflicts are listed; you decide per item which side wins) or **Overwrite** (replaced items go to the Trash, so it's reversible). Credentials, sign-in state, cookies, and history are never copied.
- **Rename, recolor, delete** from each card. Deleted profile data goes to the Trash, not into the void.
- **⌘Q won't kill the app** while the *Manage Profiles…* window is focused — it stays in your menu bar. Quit from the menu-bar dropdown.

## Power features

### Per-project account binding (shell integration)

Want a repo to *always* use your work account, regardless of the menu-bar selection? Install **Shell integration** from *Manage Profiles…*, then drop a one-line file in the project:

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile
cd ~/repos/work-monorepo
claude   # runs as "work", no matter what's active globally
```

The installed zsh function finds the nearest `.claude-profile`, sets `CLAUDE_CONFIG_DIR` to that profile, and hands off to the real `claude`. Because `CLAUDE_CONFIG_DIR` is part of how Claude Code names its keychain entry, bound projects also get **per-profile keychain isolation** — the fix for the "Can't verify" badge. Optionally enable *Suggest Desktop switches* to get a notification when you enter a bound project whose profile differs from the active one.

zsh only (it's what macOS ships). The function file happens to be bash-compatible if you want to source it yourself.

### Multi-Mac sync (iCloud Drive)

Enable *Sync profiles via iCloud Drive* in the menu-bar dropdown to keep your profile **list** consistent across Macs: names, colors, and deletions sync; conflicts resolve last-writer-wins; deletions are tombstoned so they don't resurrect. **Credentials never leave the device** — you sign in once per Mac.

### A note on CLI MCP servers

Claude Code keeps user-scope MCP servers in `~/.claude.json`, a file in your home folder that sits **outside** the switched directories — it's shared by all profiles, along with your CLI identity. Per-profile CLI MCP config only exists inside projects bound via shell integration. Desktop MCP servers (`claude_desktop_config.json`) are fully per-profile and switch (and copy) cleanly.

## Stepping away

**Menu bar → Disable & Restore Default Layout…** undoes everything safely: quits Claude Desktop, removes the symlinks, and moves the active profile's data back to the original paths. Claude works exactly as before; other profiles stay on disk in case you come back.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar says *No profile active* | The symlinks broke (OS update, manual `rm`). Switch to any profile to recreate them. |
| Claude Desktop won't quit during a switch | The app force-quits after 8 s. If even that fails, quit it manually and retry. |
| An open terminal still shows the old account | Running processes keep the old directory open. New terminal tab = new account. |
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

Tip: Xcode's Run button launches the bare executable without `LSUIElement`, so you'll see a Dock icon. For the real menu-bar experience, use `make run`.

## CI & releases

- [`build.yml`](.github/workflows/build.yml) — every push/PR to `main`: lint, tests, and a build on a macOS 14 + 15 matrix; pushes upload the `.app` as a short-lived artifact.
- [`release.yml`](.github/workflows/release.yml) — on a `v*` tag: tests → version guard → `make dist` → GitHub Release (zip, dmg, SHA256SUMS, auto-generated notes) → Homebrew cask bump in [`stigoleg/homebrew-tap`](https://github.com/stigoleg/homebrew-tap).

Cutting a release is one command:

```bash
git tag v1.4.0 && git push origin v1.4.0
```

The **git tag is the single source of truth for the version**. `AppBundle/Info.plist` holds template values that `build-app.sh` stamps at build time (`CFBundleVersion` = commit count); untagged local builds are stamped `0.0.0-dev`. The cask bump needs the `TAP_GITHUB_TOKEN` repo secret — a fine-grained PAT with contents read/write scoped to only the tap repo; without it that job skips with a warning.

## Good to know

- **Unsigned, by choice.** Ad-hoc signed; no notarization. Hence the one-time Gatekeeper step. The release workflow has a ready slot for Developer ID signing if that ever changes.
- **Your data stays put.** Profile data lives unencrypted on disk with normal filesystem permissions — the same as Claude's own defaults. iCloud sync carries metadata only; tokens and conversations never leave the machine.
- **No sandbox.** Required, since the whole point is managing files outside the app's own container.

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
