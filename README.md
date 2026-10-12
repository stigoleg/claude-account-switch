# Claude Profile Switcher

A macOS menu bar app for using several Claude accounts on one Mac. Each account gets its own profile, and one click switches both Claude Desktop and Claude Code (the CLI).

> Not affiliated with Anthropic. A personal tool, shared as is.

[![build](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml/badge.svg)](https://github.com/stigoleg/claude-account-switch/actions/workflows/build.yml)

## Why

Claude assumes one account per Mac: Claude Code keeps its state in `~/.claude`, Claude Desktop in `~/Library/Application Support/Claude`. Signing in with a second account overwrites the first. `CLAUDE_CONFIG_DIR` only helps the CLI, and only where you remember to set it.

## How it works

```
~/Library/Application Support/ClaudeProfileSwitcher/profiles/
├── <personal>/
│   ├── cli/        ← used through CLAUDE_CONFIG_DIR
│   └── desktop/    ← parked here while the profile is inactive
└── <work>/
    ├── cli/
    └── desktop/
```

- **Desktop:** the active profile always lives at the real `~/Library/Application Support/Claude` (no symlink, so Cowork works). Switching swaps directories atomically on APFS, with a journal for crash recovery.
- **CLI:** a small dispatcher installed as `claude` sets the right `CLAUDE_CONFIG_DIR` and starts the real binary. Running sessions keep their account; new ones use the selected profile.

## Install

```bash
brew tap stigoleg/tap
brew install --cask claude-profile-switcher
```

Update with `brew update && brew upgrade --cask claude-profile-switcher`, then reopen the app. If Homebrew warns that the tap is untrusted, run `brew trust --cask stigoleg/tap/claude-profile-switcher`.

Or download the notarized `.dmg` or `.zip` from the [latest release](https://github.com/stigoleg/claude-account-switch/releases/latest). Requires macOS 14 (Sonoma) or newer.

## Getting started

1. **Migrate (once).** Existing v1 profiles are backed up first (verified APFS copy-on-write); the backup is never deleted automatically.
2. **Add an account.** Manage Profiles → name → Create + Sign In. Desktop signs in first, then a Terminal opens `claude` for the CLI login.
3. **Switch.** Click the colored circle in the menu bar and pick a profile.

## Features

**Profiles.** Each card shows Desktop and CLI sign-in status, with sign-in/out per app. Rename, recolor, or delete (to the Trash). Copy Config From brings MCP servers, plugins, skills and settings from another profile, never logins or history, and warns when secrets are detected.

**Pin a project to an account.** Install shell integration (zsh, bash, fish) from Manage Profiles, then:

```bash
echo "work" > ~/repos/work-monorepo/.claude-profile   # claude in this tree always runs as "work"
```

Optionally get a notification when you enter a pinned project that doesn't match the active Desktop profile. Open a new shell after installing.

**iCloud sync.** "Sync profiles via iCloud Drive" keeps names, colors and deletions consistent across your Macs. Credentials never sync, and a remote deletion never removes local data without asking.

**Shared Claude setup (optional).** A bundled Claude Code setup you can install per profile: a `CLAUDE.md` operating model, four subagents (`code-scout`, `doc-researcher`, `implementer`, `verifier`) with the Karpathy coding principles built in, three skills, a status line, and a hook that pins subagent models. Install it from a profile's … menu or when creating a profile.
- Your own skills, hooks and settings are kept, and `settings.json` is backed up first.
- "Bypass permission prompts" (yolo) is a separate opt-in that is off by default.
- The status line and the hook need [jq](https://jqlang.org) (`brew install jq`).
- Details and developer scripts are in [`SharedConfig/`](SharedConfig/README.md).

**Diagnose & Repair.** Menu bar → Diagnose & Repair… checks the profile layout, Claude Desktop's Cowork VM files, the shell integration and the shared setup. Checking changes nothing. Fixes are per item, and Copy Report gives text you can paste into a support request. The same report works without the UI:

```sh
"/Applications/Claude Profile Switcher.app/Contents/MacOS/ClaudeProfileSwitcher" --doctor [--json] [--fix]
```

`--fix` only runs safe repairs and refuses while the menu bar app or Claude Desktop is running.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Cowork: `failed to open SDK binary … too many levels of symbolic links` | Run Diagnose & Repair. Either the Desktop folder is still a v1 symlink (fix: migrate), or there is a symlink in `claude-code-vm`/`vm_bundles`. The fix moves that folder to `ClaudeProfileSwitcher/repairs/` and Desktop downloads a fresh one. Delete the moved copy once Desktop works, because `vm_bundles` can be many GB. |
| "Migration or recovery required" | Use the button in the Manage Profiles banner, or Diagnose & Repair. Switching stays disabled until the layout is safe. |
| An open terminal still uses the old account | Expected. Open a new terminal. |
| Claude Desktop won't quit during a switch | The app force quits after 8 seconds. If that fails, quit it manually and retry. |
| Restore the migration backup | Use Verify Backup or Restore Backup in the Manage Profiles banner. |
| Want everything back to stock | Menu bar → Disable & Restore Default Layout. It restores the selected profile to `~/.claude` and removes the shell hooks. Other profiles and backups stay on disk. Don't move profile folders by hand. |

## Privacy

Profile data stays on disk with normal permissions, as with Claude's own defaults. iCloud sync carries metadata only. The app isn't sandboxed, because managing files outside its own container is its job. Releases are Developer ID signed, hardened and notarized, with SHA-256 checksums and an SPDX SBOM.

## Development

Requires the Swift 6 toolchain (Xcode 16+).

```bash
make build    # ./build/Claude Profile Switcher.app
make run      # build and launch (use this, not Xcode's Run, to get the menu bar behaviour)
make test     # unit tests
make lint     # swift format lint
make          # all targets
```

**Releasing.** Signing and notarization run locally, so the Developer ID key never leaves the Mac. Put the signing values in `.env` (gitignored, see [SIGNING.md](SIGNING.md)), then run:

```bash
make release-check VERSION=2.1.0   # lint, tests, signed and notarized dist/; pushes nothing
make release VERSION=2.1.0         # the same, then tag, push and create the GitHub release
```

The published release triggers [`cask.yml`](.github/workflows/cask.yml), which updates [`stigoleg/homebrew-tap`](https://github.com/stigoleg/homebrew-tap) from `Packaging/homebrew/`. Versions such as `2.1.0-rc.1` become prereleases and leave the cask alone. [`build.yml`](.github/workflows/build.yml) runs lint, tests and builds on macOS 14, 15 and 26 for every push and PR. [`release.yml`](.github/workflows/release.yml) is a manual CI fallback that needs the signing secrets. The git tag is the version; untagged builds are `0.0.0-dev`.

```
Sources/ClaudeProfileSwitcher/       app entry point (+ --doctor)
Sources/ClaudeProfileDispatcher/     CLI profile dispatcher
Sources/ClaudeProfileSwitcherCore/   models, services, UI
Tests/                               XCTest suite
SharedConfig/                        optional shared Claude setup, bundled into the app
Packaging/homebrew/                  cask template
Scripts/, Makefile, build-app.sh     build, sign, package, release
```
