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

Every account gets isolated Desktop and CLI data, kept together in one place:

```
~/Library/Application Support/ClaudeProfileSwitcher/
└── profiles/
    ├── <personal>/
    │   ├── cli/        ← selected with CLAUDE_CONFIG_DIR
    │   └── desktop/    ← stored here while this profile is inactive
    └── <work>/
        ├── cli/
        └── desktop/
```

The active Desktop profile always lives at the real `~/Library/Application Support/Claude` directory, so Cowork can mount paths beneath it without crossing a symlink. Switching uses a journaled atomic APFS directory swap. Claude Code runs through a compiled dispatcher that sets a profile-specific `CLAUDE_CONFIG_DIR`; existing CLI sessions keep their account and new sessions use the selected profile.

## Install

### Homebrew (recommended)

```bash
brew tap stigoleg/tap
brew install --cask claude-profile-switcher
```

Update with `brew update && brew upgrade --cask claude-profile-switcher`, then quit and reopen the app from the menu bar.

Newer Homebrew versions warn that taps outside Homebrew's own are untrusted. The install still works, and you can trust this cask with:

```bash
brew trust --cask stigoleg/tap/claude-profile-switcher
```

Version 2 releases are Developer ID signed, hardened and notarized. Release assets include SHA-256 checksums and an SPDX software bill of materials.

### Manual download

Get the notarized `.dmg` (drag it to Applications) or `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest).

### Requirements

macOS 14 (Sonoma) or newer. Building from source also requires the Swift 6 toolchain (Xcode 16 or later).

## Getting started

1. Run the one-time migration. Version 1 profiles are first protected by a verified APFS copy-on-write backup. The active Desktop data is then moved to the real canonical directory without copying its contents. The backup is never deleted automatically.
2. Add your second account. Open Manage Profiles, give the profile a name, and click Create + Sign In. The app walks you through both logins: Claude Desktop opens first, and once it has signed in, a Terminal window opens running `claude` for the CLI. Your claude.ai browser session carries over, so the second login is usually a single click. If only one of the two apps is installed, the sheet adapts.
3. Switch whenever you like. Click the menu bar chip, the colored circle showing the active profile's initial, and pick a profile.

## Everyday use

Each profile card shows separate badges for Desktop and the CLI. CLI status is verified by running `claude auth status` with that profile's own `CLAUDE_CONFIG_DIR`.

Every card has a primary Sign in button plus a menu for Desktop only or CLI only. CLI sign-in and sign-out use Claude Code's own `auth` commands inside the selected profile.

Starting a fresh account with an empty config? Open the profile's "..." menu and choose Copy Config From to bring over MCP servers, plugins, skills, commands and settings from another profile. Claude login state, cookies and history are excluded. Settings and MCP entries can contain their own API keys, so the review step requires an explicit warning acknowledgement when secret-shaped fields are detected.

You can rename, recolor and delete profiles from each card. Deleted profiles go to the Trash, not into the void. And pressing Cmd+Q while the Manage Profiles window is focused will not kill the app; it keeps running in your menu bar, and you quit it from the menu bar dropdown.

## Power features

### Pin a project to an account

Some repos should always use the work account, no matter what the menu bar says. Install shell integration from Manage Profiles, then drop a one line file into the project:

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile
cd ~/repos/work-monorepo
claude   # runs as "work", regardless of the active profile
```

A compiled dispatcher for zsh, bash and fish finds the nearest `.claude-profile` file, points `CLAUDE_CONFIG_DIR` at that profile, and hands off to the real `claude`. Use the profile UUID for new binding files; names and previous names remain supported. You can also enable Suggest Desktop switches to get a notification when you enter a pinned project that does not match the active Desktop profile.

Open a new shell after installing or repairing CLI integration. Directly invoking an absolute Claude binary path bypasses profile selection and is unsupported.

### Keep your profile list in sync across Macs

Enable "Sync profiles via iCloud Drive" in the menu bar dropdown and your profile list stays consistent on every Mac signed into your iCloud account. Names, colors and deletion requests sync using deterministic logical revisions rather than device clocks. A remote deletion never removes local bytes automatically: accept it to move an inactive profile to the Trash, or choose Keep on This Mac to retain the data under a new profile ID. Credentials never sync; you sign in once per Mac.

### CLI isolation

Every CLI launch through the dispatcher uses its profile directory for settings, plugins, history and authentication. The v2 migration logs out the unsafe legacy global keychain context and guides you through one new CLI login per profile.

### Shared Claude setup (optional)

The app bundles a curated Claude Code setup: a `CLAUDE.md` operating model, four subagents (`code-scout`, `doc-researcher`, `implementer`, `verifier`), three skills, a status line, and a hook that pins subagents to an explicit model. The coding agents have the four Karpathy coding principles built in (think before coding, simplicity first, surgical changes, goal-driven execution). It is opt-in per profile: Manage Profiles → a profile's … menu → Install Shared Claude Setup…, or the checkbox when you create a profile.

- The files are copied to `~/.config/claude-shared` and the profile's `cli/` links `CLAUDE.md`, `agents` and each shared skill there. Profile-local skills, other hooks and other settings stay. `settings.json` is backed up before it changes; an existing `model` choice is kept.
- **Bypass permission prompts (yolo)** is a separate checkbox, off by default. It sets `permissions.defaultMode: "bypassPermissions"` and `skipDangerousModePermissionPrompt: true`, so Claude Code runs tools, edits files and executes commands without asking. Only enable it where you accept that.
- The card shows "Shared setup", plus "yolo" and "update available" when they apply. Diagnose & Repair reports broken links and available updates; its reinstall asks before it changes anything and never touches the permission settings. If `~/.config/claude-shared` was edited by hand (or, for a copy made by `install.sh`, differs from the bundled setup), the app asks before replacing it and keeps the old copy as `~/.config/claude-shared.backup-<timestamp>`.
- The status line and the subagent model hook need [jq](https://jqlang.org) (`brew install jq`); without it they silently do nothing. macOS 14 ships no jq, so the install sheet and Diagnose & Repair warn when it is missing.
- Remove it with Remove Shared Claude Setup in the same menu. That removes the links and the settings values the setup wrote; your `model` and everything else stay.

The canonical copy and the developer scripts (`install.sh`, `verify.sh`) live in [`SharedConfig/`](SharedConfig/README.md).

## Stepping away

Menu bar → Disable & Restore Default Layout keeps the real active Desktop directory in place, backs up the fallback CLI directory, restores the selected profile to `~/.claude`, and removes the managed shell hooks. Other profiles and migration backups remain on disk.

## Diagnose & Repair

Menu bar → Diagnose & Repair… (also under More in Manage Profiles) checks the profile layout, every Desktop profile's Cowork VM files, and the Claude Code shell integration. Checking never changes anything. Each problem has a Fix button where the app can repair it, and Copy Report puts a plain-text report on the clipboard for support. Reveal Repairs Folder appears once a repair has moved something aside.

Without opening the app, the same report is available from Terminal:

```sh
"/Applications/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --doctor          # text report
"/Applications/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --doctor --json   # JSON report
"/Applications/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --doctor --fix    # safe repairs, then report
```

`--doctor` exits 1 when it finds errors or warnings. `--fix` only runs safe repairs: it moves broken Cowork VM folders aside, removes stale temporary links and reinstalls the shell integration. It refuses while the menu bar app is running (use the window instead), never runs the layout migration, and never reinstalls the shared Claude setup; it prints which findings need the app.

**"failed to open SDK binary … claude-code-vm/<version>/claude: too many levels of symbolic links".** Cowork's Linux VM opens Claude Desktop's files through virtiofs and refuses symlinks anywhere in the path. Either `~/Library/Application Support/Claude` is still a legacy v1 symlink (run the migration from Manage Profiles), or a symlink sits inside `claude-code-vm` or `vm_bundles`. In the Diagnose & Repair window the repair quits Claude Desktop first (after asking); `--doctor --fix` instead refuses to move the folder while Claude Desktop runs, so quit it and run again. The folder is moved to `~/Library/Application Support/ClaudeProfileSwitcher/repairs/<timestamp>/`; nothing is deleted, and Claude Desktop downloads a fresh copy the next time Cowork starts. The moved folder keeps using disk space (`vm_bundles` can be many GB): delete it from the repairs folder once Claude Desktop works again. A symlinked `~/Library` or home folder is reported but must be fixed by hand.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Migration or recovery is required | Open Manage Profiles and use the health banner, or Diagnose & Repair. Switching stays disabled until the layout is unambiguous. |
| Claude Desktop will not quit during a switch | The app force quits after 8 seconds. If even that fails, quit it manually and retry. |
| An open terminal still shows the old account | Expected: existing CLI processes keep their account. Open a new terminal for the newly selected default. |
| Need to verify or restore the migration backup | Use Verify Backup or Restore Backup in the green health banner. Restore first preserves the current v2 data under `Backups/pre-restore-v2-*`. |
| Want everything back to stock | Use Disable & Restore. Do not move profile directories by hand. |

## Building from source

```bash
make            # list all targets
make build      # ./build/Claude Profile Switcher.app
make run        # build + launch
make test       # unit tests
make lint       # swift format lint
make signing-check   # validate Developer ID + provisioning prerequisites
make notarized-dist  # signed, notarized and stapled production artifacts
make install    # copy into /Applications
make dist       # release artifacts (.zip, .dmg, SHA256SUMS) in ./dist
make clean      # remove .build, ./build, ./dist
make xcode      # open the package in Xcode
```

A tip: Xcode's Run button launches the bare executable without `LSUIElement`, so a Dock icon appears. For the real menu bar experience, use `make run`.

Public releases require Developer ID, the iCloud provisioning profile and notarization. See [SIGNING.md](SIGNING.md) for the complete local and GitHub Actions setup.

## CI & releases

[`build.yml`](.github/workflows/build.yml) runs on every push and PR to `main`: lint, tests, signature verification and builds on macOS 14, 15 and 26. Pushes upload the newest-runner `.app` as a short-lived artifact.

[`release.yml`](.github/workflows/release.yml) runs on a `v*` tag: tests, a version guard, `make dist`, a GitHub Release with the zip, dmg, SHA256SUMS and generated notes, and finally a Homebrew cask bump in [`stigoleg/homebrew-tap`](https://github.com/stigoleg/homebrew-tap).

Cutting a release is one command:

```bash
git tag v2.0.0-rc.1 && git push origin v2.0.0-rc.1
```

The git tag is the single source of truth for the version. `AppBundle/Info.plist` holds template values that `build-app.sh` stamps at build time (`CFBundleVersion` is the commit count), and untagged local builds are stamped `0.0.0-dev`. The cask bump needs the `TAP_GITHUB_TOKEN` repo secret, a fine grained PAT with contents read and write access scoped to the tap repo only. Without it, that job skips with a warning.

## Good to know

Production releases are Developer ID signed with hardened runtime and notarized. The embedded CLI dispatcher is signed separately before the app bundle is sealed.

Your data stays put. Profile data lives unencrypted on disk with normal filesystem permissions, the same as Claude's own defaults. iCloud sync carries metadata only; tokens and conversations never leave the machine.

There is no sandbox, and that is deliberate. The whole point of the app is managing files outside its own container.

## Repo layout

```
Sources/
├── ClaudeProfileSwitcher/         menu-bar executable (@main only)
├── ClaudeProfileDispatcher/       compiled CLI profile dispatcher
└── ClaudeProfileSwitcherCore/     library: Models, Services, UI
Tests/ClaudeProfileSwitcherCoreTests/   XCTest and dispatcher integration suite
AppBundle/                         Info.plist + entitlements + icon
Packaging/homebrew/                cask template for the tap
SharedConfig/                      optional shared Claude setup, bundled into the app
Scripts/                           version stamping, dmg, icon generation
.github/workflows/                 build.yml + release.yml
Makefile, build-app.sh             build / test / package
```
