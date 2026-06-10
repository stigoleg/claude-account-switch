# Claude Profile Switcher

A macOS menu bar app for people who use more than one Claude account on the same Mac. It keeps each account in its own profile and switches between them with a single click. One switch covers both Claude Desktop and Claude Code (the CLI), and you keep using both apps exactly as you always have.

> Not affiliated with Anthropic. A personal tool, shared as is.

[![build](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml/badge.svg)](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml)

## Why this exists

Claude assumes you have one account per Mac. Both apps keep their settings and login state at fixed locations:

- `~/.claude` for Claude Code
- `~/Library/Application Support/Claude/` for Claude Desktop

When you sign in with a second account, it overwrites the first. So you end up signing out and back in several times a day, losing your place each time. The usual workaround is the `CLAUDE_CONFIG_DIR` environment variable, but it only affects the CLI, and only in terminals where you remember to set it. Claude Desktop ignores it completely.

## How it works

Every account gets a private copy of both directories, kept together in one place:

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

The real paths become symlinks that point at whichever profile is active. A switch simply repoints them. The operation is atomic, takes no time, and is invisible to Claude. If Claude Desktop is running, the app asks for confirmation first, quits it cleanly, flips the links, and starts it again on the other account. Any terminal you open afterwards picks up the right account on its own.

## Install

### Homebrew (recommended)

```bash
brew tap stigoleg/tap
brew install --cask claude-profile-switcher
```

Newer Homebrew versions warn that taps outside Homebrew's own are untrusted. The install still works, and you can silence the warning for this cask with a one time:

```bash
brew trust --cask stigoleg/tap/claude-profile-switcher
```

There is one extra step before the first launch. The app is ad hoc signed (no paid Apple Developer ID), so macOS quarantines the download and Gatekeeper refuses to open it. Either right click the app in Finder and choose Open, which you only need to do once, or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine "/Applications/Claude Profile Switcher.app"
```

Only do this for software you trust. You can check every download against the `SHA256SUMS` file attached to its [GitHub release](https://github.com/stigoleg/claude-account-switch/releases).

### Manual download

Get the `.dmg` (drag it to Applications) or the `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest), then clear the quarantine flag the same way.

### Requirements

macOS 14 (Sonoma) or newer. Building from source also requires the Swift 6 toolchain (Xcode 16 or later).

## Getting started

1. Run the one time migration. On first launch the app offers to move your existing Claude data into a profile named `default`. Quit Claude Desktop, click Run Migration, and you are done. The data is moved, not copied, so nothing is duplicated or lost.
2. Add your second account. Open Manage Profiles, give the profile a name, and click Create + Sign In. The app walks you through both logins: Claude Desktop opens first, and once it has signed in, a Terminal window opens running `claude` for the CLI. Your claude.ai browser session carries over, so the second login is usually a single click. If only one of the two apps is installed, the sheet adapts.
3. Switch whenever you like. Click the menu bar chip, the colored circle showing the active profile's initial, and pick a profile.

## Everyday use

Each profile card shows separate badges for Desktop and the CLI, so you can always see where you are signed in. A green check means signed in, a grey cross means signed out. An orange "Can't verify" means there is a shared CLI keychain login that cannot be pinned to one profile; the shell integration described below fixes that.

Every card has a primary Sign in button plus a menu for Desktop only or CLI only. Signing out clears that profile's tokens and web session. It never touches the shared keychain entry that other profiles may depend on.

Starting a fresh account with an empty config? Open the profile's "..." menu and choose Copy Config From to bring over MCP servers, plugins, skills, commands and settings from another profile. Merge mode lists any conflicts and lets you pick a winner for each item. Overwrite mode mirrors the source and moves whatever it replaced to the Trash, so you can take it back. Credentials, login state, cookies and history are never copied.

You can rename, recolor and delete profiles from each card. Deleted profiles go to the Trash, not into the void. And pressing Cmd+Q while the Manage Profiles window is focused will not kill the app; it keeps running in your menu bar, and you quit it from the menu bar dropdown.

## Power features

### Pin a project to an account

Some repos should always use the work account, no matter what the menu bar says. Install shell integration from Manage Profiles, then drop a one line file into the project:

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile
cd ~/repos/work-monorepo
claude   # runs as "work", regardless of the active profile
```

A small zsh function finds the nearest `.claude-profile` file, points `CLAUDE_CONFIG_DIR` at that profile, and hands off to the real `claude`. As a welcome side effect, pinned projects get their own keychain entry per profile, which is exactly what clears up the "Can't verify" badge. You can also enable Suggest Desktop switches to get a notification when you enter a pinned project that does not match the active Desktop profile.

This is zsh only, since that is what macOS ships. The function file happens to be bash compatible if you want to source it yourself.

### Keep your profile list in sync across Macs

Enable "Sync profiles via iCloud Drive" in the menu bar dropdown and your profile list stays consistent on every Mac signed into your iCloud account. Names, colors and deletions all sync. Conflicts resolve in favor of the newest change, and deletions are remembered so a removed profile cannot reappear from a stale machine. Credentials never sync; you sign in once per Mac.

### A caveat about CLI MCP servers

Claude Code keeps user level MCP servers in `~/.claude.json`, a file in your home folder that sits outside the switched directories. All profiles share it, along with your CLI identity. Per profile CLI MCP config exists only inside projects pinned via shell integration. Desktop MCP servers (`claude_desktop_config.json`) are fully per profile and switch and copy cleanly.

## Stepping away

Menu bar → Disable & Restore Default Layout undoes everything safely. It quits Claude Desktop, removes the symlinks, and moves the active profile's data back to the original paths. Claude then behaves exactly as it did before the app existed. Other profiles stay on disk in case you return.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar says "No profile active" | The symlinks broke (OS update, manual `rm`). Switch to any profile to recreate them. |
| Claude Desktop will not quit during a switch | The app force quits after 8 seconds. If even that fails, quit it manually and retry. |
| An open terminal still shows the old account | Running processes hold on to the old directory. A new terminal tab gets the new account. |
| Want everything back to stock | Use Disable & Restore. Do not delete the symlinks by hand. |

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

A tip: Xcode's Run button launches the bare executable without `LSUIElement`, so a Dock icon appears. For the real menu bar experience, use `make run`.

## CI & releases

[`build.yml`](.github/workflows/build.yml) runs on every push and PR to `main`: lint, tests, and a build on a macOS 14 + 15 matrix. Pushes upload the built `.app` as a short lived artifact.

[`release.yml`](.github/workflows/release.yml) runs on a `v*` tag: tests, a version guard, `make dist`, a GitHub Release with the zip, dmg, SHA256SUMS and generated notes, and finally a Homebrew cask bump in [`stigoleg/homebrew-tap`](https://github.com/stigoleg/homebrew-tap).

Cutting a release is one command:

```bash
git tag v1.4.0 && git push origin v1.4.0
```

The git tag is the single source of truth for the version. `AppBundle/Info.plist` holds template values that `build-app.sh` stamps at build time (`CFBundleVersion` is the commit count), and untagged local builds are stamped `0.0.0-dev`. The cask bump needs the `TAP_GITHUB_TOKEN` repo secret, a fine grained PAT with contents read and write access scoped to the tap repo only. Without it, that job skips with a warning.

## Good to know

The app is unsigned by choice: ad hoc signed, not notarized, hence the one time Gatekeeper step. The release workflow has a ready slot for Developer ID signing if that ever changes.

Your data stays put. Profile data lives unencrypted on disk with normal filesystem permissions, the same as Claude's own defaults. iCloud sync carries metadata only; tokens and conversations never leave the machine.

There is no sandbox, and that is deliberate. The whole point of the app is managing files outside its own container.

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
