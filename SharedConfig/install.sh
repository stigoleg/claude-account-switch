#!/bin/bash
# Deploys the canonical shared Claude configuration to Claude Profile Switcher
# profiles.
#
#   ./install.sh                   -> all profiles in profiles.json
#   ./install.sh "Work"    -> one named profile
#   ./install.sh --all             -> explicit form of the default
#   ./install.sh --with-plugins    -> also install the document-skills plugin
#   ./install.sh --yolo            -> also bypass permission prompts
#
# Safe to run repeatedly. Touches only the settings keys this setup owns (model,
# fallbackModel, statusLine, hooks, and with --yolo permissions.defaultMode and
# skipDangerousModePermissionPrompt); everything else in settings.json — including
# permissions.allow — is preserved. settings.json is backed up before every
# change. Without --yolo the two permission keys are never set or changed.
#
# Claude Profile Switcher installs the same setup natively (Manage Profiles →
# … → Install Shared Claude Setup); this script is the developer path.
#
# Run this after migrating Claude Profile Switcher, or when a profile has lost
# its links.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$HOME/.config/claude-shared"
PROFILES_ROOT="$HOME/Library/Application Support/ClaudeProfileSwitcher"
PROFILES_JSON="$PROFILES_ROOT/profiles.json"
TS=$(date +%Y%m%d-%H%M%S)

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

# Claude Profile Switcher puts a dispatcher shim first on PATH, and that shim
# REFUSES to start recursively. Find the real binary and skip the shim.
real_claude() {
  local c rp
  # The dispatcher records the real binary; the native installer uses ~/.local/bin.
  local disp="$HOME/.config/claude-profile-switcher/dispatcher.json"
  local recorded=""
  [ -f "$disp" ] && command -v jq >/dev/null && recorded=$(jq -r '.realClaudePath // empty' "$disp" 2>/dev/null)
  for c in "$recorded" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude $(which -a claude 2>/dev/null); do
    [ -n "$c" ] && [ -x "$c" ] || continue
    rp=$(readlink "$c" 2>/dev/null || echo "$c")
    case "$rp" in *claude-profile-switcher*|*claude-account-switch*) continue ;; esac
    echo "$c"; return 0
  done
  # Fallback: newest Homebrew cask version.
  c=$(ls -d /opt/homebrew/Caskroom/claude-code/*/claude 2>/dev/null | sort -V | tail -1)
  [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  return 1
}

# --- 0. Arguments ----------------------------------------------------------
WITH_PLUGINS=0
YOLO=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --with-plugins) WITH_PLUGINS=1 ;;
    --yolo)         YOLO=1 ;;
    --all)          ;;   # the default; accepted for clarity
    *)              ARGS+=("$a") ;;
  esac
done

# --- 1. Shared directory ---------------------------------------------------
echo "==> Shared configuration -> $SHARED"
mkdir -p "$SHARED"
# Mirror, so files deleted from the repo also disappear from the deployed copy.
rsync -a --delete "$REPO/claude-shared/" "$SHARED/"
chmod +x "$SHARED/hooks/pin-subagent-model.sh" "$SHARED/statusline.sh"
bash -n "$SHARED/hooks/pin-subagent-model.sh"
bash -n "$SHARED/statusline.sh"
echo "    agents: $(ls "$SHARED/agents" | tr '\n' ' ')"
if [ -d "$SHARED/skills" ]; then
  echo "    skills: $(ls "$SHARED/skills" | tr '\n' ' ')"
fi

# --- 2. Which profiles? ----------------------------------------------------
[ -f "$PROFILES_JSON" ] || { echo "Could not find $PROFILES_JSON"; exit 1; }

# (macOS ships bash 3.2 — no mapfile, hence while-read.)
NAMES=()
if [ ${#ARGS[@]} -eq 0 ]; then
  while IFS= read -r line; do NAMES+=("$line"); done < <(jq -r '.profiles[].name' "$PROFILES_JSON")
else
  NAMES=("${ARGS[@]}")
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "No profiles found in $PROFILES_JSON"; exit 1; }

# --- 3. Link each profile --------------------------------------------------
for NAME in "${NAMES[@]}"; do
  ID=$(jq -r --arg n "$NAME" '.profiles[] | select((.name|ascii_downcase)==($n|ascii_downcase)) | .id' "$PROFILES_JSON")
  if [ -z "$ID" ]; then
    echo "!! No profile named \"$NAME\" — skipping."
    echo "   Available: $(jq -r '[.profiles[].name]|join(", ")' "$PROFILES_JSON")"
    continue
  fi

  CLI="$PROFILES_ROOT/profiles/$ID/cli"
  mkdir -p "$CLI"
  echo "==> $NAME ($ID)"

  # Symlinks: agents/ and CLAUDE.md point into the shared directory.
  for pair in "agents:agents" "CLAUDE.md:CLAUDE.md"; do
    dst="$CLI/${pair%%:*}"; src="$SHARED/${pair##*:}"
    if [ -L "$dst" ]; then rm "$dst"
    elif [ -e "$dst" ]; then mv "$dst" "$dst.backup-$TS"; echo "    moved existing ${pair%%:*} -> ${pair%%:*}.backup-$TS"; fi
    ln -s "$src" "$dst"
  done
  echo "    agents/ and CLAUDE.md symlinked"

  # Skills are linked per skill, so profile-local skills survive untouched.
  if [ -d "$SHARED/skills" ]; then
    mkdir -p "$CLI/skills"
    linked=0
    for sdir in "$SHARED/skills"/*/; do
      [ -d "$sdir" ] || continue
      sname=$(basename "$sdir")
      dst="$CLI/skills/$sname"
      if [ -L "$dst" ]; then rm "$dst"
      elif [ -e "$dst" ]; then mv "$dst" "$dst.backup-$TS"; echo "    moved existing skills/$sname -> $sname.backup-$TS"; fi
      ln -s "$SHARED/skills/$sname" "$dst"
      linked=$((linked+1))
    done
    # Remove dangling links left behind by skills deleted from the canonical set.
    for l in "$CLI/skills"/*; do
      [ -L "$l" ] || continue
      tgt=$(readlink "$l")
      case "$tgt" in
        "$SHARED/skills/"*) [ -e "$l" ] || { rm "$l"; echo "    removed stale link skills/$(basename "$l")"; } ;;
      esac
    done
    echo "    skills: $linked canonical skill(s) linked (profile-local skills untouched)"
  fi

  # settings.json: merge the fragment in, preserve everything else.
  [ -f "$CLI/settings.json" ] || echo '{}' > "$CLI/settings.json"
  cp "$CLI/settings.json" "$CLI/settings.json.bak-$TS"
  sed "s|__SHARED__|$SHARED|g" "$REPO/settings-fragment.json" > "$CLI/.fragment.tmp"
  # Retire the old effort lock; preserve saved /effort choices and other env keys.
  jq -s '(.[0] * .[1]) | del(.env.CLAUDE_CODE_EFFORT_LEVEL)' "$CLI/settings.json" "$CLI/.fragment.tmp" > "$CLI/.settings.tmp"
  jq -e . "$CLI/.settings.tmp" >/dev/null
  mv "$CLI/.settings.tmp" "$CLI/settings.json"
  rm -f "$CLI/.fragment.tmp"

  # Opt-in: run without permission prompts (same keys the app's yolo toggle sets).
  if [ "$YOLO" = "1" ]; then
    jq '.permissions.defaultMode = "bypassPermissions" | .skipDangerousModePermissionPrompt = true' \
      "$CLI/settings.json" > "$CLI/.settings.tmp"
    mv "$CLI/.settings.tmp" "$CLI/settings.json"
    echo "    yolo: permission prompts bypassed"
  fi

  # `model` is seeded, not owned: a new profile gets the opus main-session
  # default, but a deliberate /model choice is never overwritten on reinstall.
  if [ "$(jq -r 'has("model")' "$CLI/settings.json")" != "true" ]; then
    jq '.model = "opus"' "$CLI/settings.json" > "$CLI/.settings.tmp"
    mv "$CLI/.settings.tmp" "$CLI/settings.json"
    echo "    model seeded to opus (was unset)"
  fi
  echo "    settings.json merged (backup: settings.json.bak-$TS)"
  jq -c '{model, effortLevel, modelSettings, fallbackModel, defaultMode: .permissions.defaultMode, hook: .hooks.PreToolUse[0].hooks[0].command}' "$CLI/settings.json" | sed 's/^/    /'

  # Optional: the official Anthropic document skills (docx, pptx, xlsx, pdf).
  # Best effort — network or CLI syntax changes must never abort the install.
  if [ "$WITH_PLUGINS" = "1" ]; then
    if BIN=$(real_claude); then
      echo "    installing document-skills plugin..."
      CLAUDE_CONFIG_DIR="$CLI" "$BIN" plugin marketplace add anthropics/skills >/dev/null 2>&1 \
        || echo "    !! marketplace add failed (already added, offline, or syntax changed)"
      CLAUDE_CONFIG_DIR="$CLI" "$BIN" plugin install document-skills@anthropic-agent-skills --scope user >/dev/null 2>&1 \
        && echo "    document-skills installed" \
        || echo "    !! document-skills install failed — run /plugin install document-skills@anthropic-agent-skills manually"
    else
      echo "    !! no real claude binary found — skipping plugin install"
    fi
  fi
done

echo
echo "==> Done. Verify in a FRESH session:"
echo "    ./verify.sh"
