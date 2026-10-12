# Shared Claude Code configuration

Canonical shared Claude Code configuration, bundled with Claude Profile
Switcher and installable per profile from the app. The scripts here remain the
developer path for deploying and verifying it from the repository.

## The idea

The main session (Opus by default, any model works) does small and medium work
itself and delegates when it pays: broad exploration, parallel research,
external documentation, large self-contained implementation, and independent
review of non-trivial changes. Judgment, synthesis and plan authorship stay in
the main session. Subagents run on Opus; a `PreToolUse` hook enforces that
deterministically, so the policy does not depend on the model remembering it.

The same flow applies beyond code: consulting deliverables, candidate
assessment, decision material, presentations and documents are first-class work,
with the same research → synthesis → production → verification flow.

## Coding principles

The Coding section of CLAUDE.md, and the working method of `implementer` and
the overreach check of `verifier`, adapt the four principles from
[forrestchang/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT), based on Andrej Karpathy's notes on LLM coding pitfalls: think before
coding, simplicity first, surgical changes, goal-driven execution.

## Handoff protocol

Subagents see nothing of the conversation, so context loss between agents is
the main failure mode. CLAUDE.md therefore requires:

- every brief states goal and why, context (decisions, paths, constraints),
  scope, deliverable, and done-when
- the main session writes longer briefs and specs to
  `<scratchpad>/handoffs/<task>.md`
- code-scout, doc-researcher and verifier are read-only and return condensed
  reports inline with `file:line` references; only implementer writes a
  handoff file (its change list)
- chained agents (scout → implementer → verifier) receive the spec path, the
  implementer's handoff path, and earlier findings copied verbatim into the
  next brief, not a paraphrase
- every agent reports with the same contract: status (done/partial/blocked),
  result, assumptions, open questions (plus the handoff file for implementer)

## Layout

```
install.sh                 deploy to profiles (idempotent)
verify.sh                  validate deployment + drift + hook behaviour
settings-fragment.json     the only settings keys this setup owns (model is seeded, not owned)
claude-shared/             the canonical configuration
├── CLAUDE.md              always-loaded operating model (kept short)
├── statusline.sh          status line: model, effort, dir, branch, context, cost
├── hooks/
│   └── pin-subagent-model.sh   PreToolUse (Agent|Task) model enforcement
├── agents/
│   ├── code-scout.md           maps existing code
│   ├── doc-researcher.md       external facts: docs, APIs, companies, markets
│   ├── implementer.md          large, self-contained implementation
│   └── verifier.md             independent review of non-trivial work
└── skills/
    ├── norwegian-business-writing/   professional Norwegian bokmål output
    ├── consultant-matching/          CV/candidate matching against requirements
    └── deliverable-production/       reports, decks, memos, spreadsheets
```

`claude-shared/` is mirrored to `~/.config/claude-shared/`, and each profile
links to it.

## Usage

```bash
./install.sh                  # all profiles
./install.sh "Work"   # one profile
./install.sh --with-plugins   # also install the document-skills plugin
./install.sh --yolo           # also bypass permission prompts (opt-in)
./verify.sh                   # validate all profiles (SKIP_PROBE=1 to skip the headless probe)
./verify.sh --yolo            # also require bypassed permission prompts
```

Requires `jq`. Safe to run repeatedly.

App users do not need the repository: Claude Profile Switcher bundles this
directory and installs it natively per profile (Manage Profiles → … → Install
Shared Claude Setup…, or the checkbox when creating a profile), with the same
yolo opt-in. The app writes `.version` into `~/.config/claude-shared` to detect
updates and local edits; `verify.sh` ignores it. A copy without `.version` that
differs from the bundle counts as edited: the app asks first and keeps it as
`~/.config/claude-shared.backup-<timestamp>`. One difference: the app
replaces only the shared `PreToolUse` entry and keeps every other hook, while
`install.sh`'s deep merge replaces the whole `PreToolUse` array.

## What is synchronized

Per profile, `install.sh`:

- symlinks `cli/CLAUDE.md` → `~/.config/claude-shared/CLAUDE.md`
- symlinks `cli/agents` → `~/.config/claude-shared/agents`
- symlinks **each** canonical skill into `cli/skills/<name>`, leaving every other
  entry in `cli/skills/` untouched — profile-local skills survive
- merges the owned keys into `settings.json` (`fallbackModel`, `statusLine`, `hooks`, and with `--yolo`
  `permissions.defaultMode` and `skipDangerousModePermissionPrompt`), backing the file up first; other `env`
  keys in a profile are preserved by the deep merge; the former
  `env.CLAUDE_CODE_EFFORT_LEVEL` lock is removed
- **seeds** `model: opus` only when the key is absent — a deliberate `/model`
  choice in a profile is never overwritten on reinstall

Because CLAUDE.md, agents, and skills are symlinks, they cannot drift: editing
the repo and running `install.sh` updates every profile at once.

## Permissions (yolo mode)

Opt-in: `./install.sh --yolo` or the app's "Bypass permission prompts (yolo)"
checkbox sets `permissions.defaultMode: "bypassPermissions"`, and
`skipDangerousModePermissionPrompt: true` removes the warning dialog at startup.
The main session and all subagents — subagents inherit the parent's permission
mode — then run without permission prompts. Without the opt-in neither key is
set or changed.

Plan mode is unaffected: `shift+tab` still enters it, CLAUDE.md requires
questions through `AskUserQuestion` before the plan is written, and the plan
itself is still presented with `ExitPlanMode` for approval. Bypassing
permissions bypasses prompts, not plan approval.

Undo it per profile with `/permissions` in a session, or by setting
`permissions.defaultMode` back to `"auto"` in that profile's `settings.json`.

## Effort

The user controls the main session's effort, and new shared subagents inherit
its current level. No effort override is set in the agent frontmatter.

- Run `/effort medium`, `/effort high`, or `/effort xhigh` in Claude Code.
  These choices are saved per model and apply to later sessions in that profile.
- Open `/effort` and confirm with `s` for a session-only change, or launch with
  `claude --effort medium` / `claude --effort high`.
- Run `/effort auto` to return to the model's default.
- `install.sh` removes the old `env.CLAUDE_CODE_EFFORT_LEVEL` lock and preserves
  `effortLevel`, `modelSettings`, and every other environment variable. Reinstalling
  never resets a saved effort choice. Without a saved choice, Claude uses the
  model's default effort.
- Restart existing Claude sessions after installing so the old environment
  override is no longer loaded. Then change effort in the main session before
  starting new subagents.

This covers the four shared agents and agents without their own effort override.
Plugin or project agents with explicit `effort` frontmatter can override inheritance.

See [Claude Code effort settings](https://code.claude.com/docs/en/model-config#set-the-effort-level)
and [subagent frontmatter](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields).

## Plugin policy

Plugins are profile-local state. The recommended policy:

| Plugin | State | Why |
|---|---|---|
| `superpowers` | disabled | conflicts with this operating model and re-injects a mandatory skill-check block on every session start, `/clear` and compaction |
| `andrej-karpathy-skills` | disabled | its four principles are built into CLAUDE.md (Coding), `implementer` and `verifier`; the plugin would load them twice |
| `code-review` | disabled | covered by the built-in `/code-review` and the `verifier` agent |
| `document-skills` | enabled | preferred tooling for docx, pptx, xlsx and pdf |

`verify.sh` fails if an enabled plugin does not load.

If a marketplace reports `cache-miss` or a "corrupted installLocation", its
entry in the profile's `plugins/known_marketplaces.json` points outside the
profile (typically `~/.claude/plugins/...`). Such a marketplace may still
appear to load from a stale cache, but `marketplace update` refuses to run, so
its plugins silently stop getting updates. Point `installLocation` at the
profile's own `plugins/marketplaces/<name>` copy, run `claude plugin
marketplace update <name>`, and reinstall the affected plugins — always with
the real binary and `CLAUDE_CONFIG_DIR` set to the profile. `verify.sh` fails
if any marketplace's `installLocation` is outside the profile's `plugins/`
directory or lacks a `marketplace.json`.

## What is deliberately NOT synchronized

- Everything else in `settings.json` — `permissions.allow`/`deny`, theme,
  `autoMode`, `enabledPlugins`, marketplaces. These are per-profile by design; one account
  has work-specific automation the other should not inherit.
- Plugins and their caches. `--with-plugins` installs the document skills per
  profile, but plugin state stays profile-local.
- Credentials, OAuth tokens, sessions, `history.jsonl`, `projects/`, memory,
  plans, telemetry, caches. Never copied, in either direction.

The canonical configuration contains no credentials; `verify.sh` scans for
credential patterns and fails if any appear.

## Document and office work

The official Anthropic document skills (docx, pptx, xlsx, pdf) are not in the
default marketplace. Install them per profile with `./install.sh --with-plugins`,
or manually:

```
/plugin marketplace add anthropics/skills
/plugin install document-skills@anthropic-agent-skills
```

They are the preferred tooling for producing documents, presentations, and
spreadsheets — `deliverable-production` hands over to them.

## The hook

`hooks/pin-subagent-model.sh`, matcher `Agent|Task`:

| Call | Result |
|---|---|
| model unspecified / `inherit` / `default` / `fable` | pinned to `opus` |
| model explicitly `opus`/`sonnet`/`haiku`/full ID | passed through untouched |
| `subagent_type: fork`, parent is Fable or unknown | denied |
| `subagent_type: Plan`, parent is Fable or unknown | denied |
| `fork` / `Plan`, any other parent | allowed (`Plan` is pinned to `opus`) |

`fork` always inherits the parent's model and ignores `model`, so denying is the
only available enforcement against Fable leaking into subagents. `Plan` authors
the plan, and authorship belongs in the main session; plan mode actively
instructs the model to dispatch it, so under Fable policy alone is not enough.
CLAUDE.md tells every main session not to dispatch `Plan`.

The parent model is read from the transcript: when `PreToolUse` fires, the
current assistant turn is not written yet, so the last completed assistant line
is the parent (`.message.model`). An unknown parent is treated as Fable.

## Pitfalls (verified, keep in mind)

- **`CLAUDE_CODE_SUBAGENT_MODEL` is deliberately not set.** Before Claude Code
  v2.1.251 it overrides the per-call parameter the hook sets; from v2.1.251 it is
  only a default. The semantics flip silently on upgrade — the hook behaves
  identically either way.
- **`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`** requires v2.1.257+ and blocks
  everything rather than pinning selectively.
- **`/agents` lists nothing** since v2.1.198 — the wizard was removed; it only
  prints where agent files live. Use the headless probe in `verify.sh` instead.
- **`claude plugin validate` gives false alarms through symlinks.** Validate
  `~/.config/claude-shared/agents` directly instead of the profile path.
- **The profile-switcher shim refuses recursive dispatch.** Running `claude`
  from inside a Claude Code session fails; `install.sh` and `verify.sh` resolve
  the real binary and skip the shim.
- **Profiles are selected via `CLAUDE_CONFIG_DIR`**, pointing at
  `~/Library/Application Support/ClaudeProfileSwitcher/profiles/<uuid>/cli/`.
- **`~/.claude` is a real directory in v2+, not a symlink** — global
  configuration written there is never read by a profile session.
- **A subagent's actual model** is only recorded in the subagent's own
  transcript, under `projects/<slug>/<session-id>/subagents/agent-*.jsonl`. The
  parent transcript shows the emitted call, i.e. before `updatedInput`.

## Drift checks

`verify.sh` fails on: missing shared files, wrong symlinks, wrong settings keys
(`model` unset, `fallbackModel` not `["sonnet"]`, effort env override
present, and with `--yolo` the two permission keys), a shared agent with an explicit `effort` override, an enabled plugin that fails to load
(`claude plugin list`), hook misbehaviour (six
synthetic cases, each under an Opus and a Fable parent), credential patterns in
the canonical config, and any difference between `claude-shared/` and the
deployed `~/.config/claude-shared/` (which would mean someone edited the
deployed copy directly). It reports, informationally: a `model` other than
`opus`, enabled-plugin differences between profiles, and whether the
document-skills plugin is installed per profile.
