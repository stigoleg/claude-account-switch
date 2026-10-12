#!/bin/bash
# Verifies that the shared Claude configuration is actually in place and works.
#
#   ./verify.sh                 -> all profiles in profiles.json
#   ./verify.sh "Work"  -> one named profile
#   ./verify.sh --yolo          -> also require bypassed permission prompts
#                                  (or set YOLO=1)
#
# Note: /agents does NOT list agents (the wizard was removed in v2.1.198).
# The last check therefore uses a headless probe against a fresh session.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$HOME/.config/claude-shared"
HOOK="$SHARED/hooks/pin-subagent-model.sh"
PROFILES_ROOT="$HOME/Library/Application Support/ClaudeProfileSwitcher"
PROFILES_JSON="$PROFILES_ROOT/profiles.json"
FAIL=0
YOLO="${YOLO:-0}"
ARGS=()
for a in "$@"; do
  case "$a" in
    --yolo) YOLO=1 ;;
    *)      ARGS+=("$a") ;;
  esac
done
ok(){   printf "  \033[32m✓\033[0m %s\n" "$1"; }
no(){   printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }
info(){ printf "  \033[2m·\033[0m %s\n" "$1"; }

echo "== Shared files =="
FILES=("$HOOK" "$SHARED/statusline.sh" "$SHARED/CLAUDE.md")
for f in "$SHARED"/agents/*.md; do [ -e "$f" ] && FILES+=("$f"); done
for d in "$SHARED"/skills/*/; do [ -d "$d" ] && FILES+=("${d}SKILL.md"); done
for f in "${FILES[@]}"; do
  [ -f "$f" ] && ok "${f#$SHARED/}" || no "missing: $f"
done
[ -x "$HOOK" ] && ok "hook is executable" || no "hook missing +x"
for f in "$SHARED"/agents/*.md; do
  [ -e "$f" ] || continue
  if awk '/^---$/ { block++; next } block == 1 && /^[[:space:]]*effort[[:space:]]*:/ { found=1 } END { exit !found }' "$f"; then
    no "$(basename "$f") overrides session effort"
  else
    ok "$(basename "$f") inherits session effort"
  fi
done

TF=$(mktemp /tmp/v.XXXX.jsonl)
h(){ jq -nc --arg t "$TF" --argjson ti "$1" '{tool_name:"Agent",transcript_path:$t,tool_input:$ti}' | bash "$HOOK"; }
chk(){ got=$(h "$2" | jq -rc 'if .hookSpecificOutput.permissionDecision=="deny" then "DENY" else .hookSpecificOutput.updatedInput.model // "PASS" end' 2>/dev/null); [ -z "$got" ] && got=PASS
       [ "$got" = "$3" ] && ok "$1 -> $got" || no "$1 -> $got (expected $3)"; }
# Columns: parent model, expected for Plan, expected for fork. Model pinning is
# the same for every parent; fork/Plan are only denied under a Fable parent
# (an Opus parent's Plan call falls through to ordinary pinning).
for row in "claude-opus-5-5 opus PASS" "claude-fable-5 DENY DENY"; do
  read -r PM EXP_PLAN EXP_FORK <<< "$row"
  echo "== Hook behaviour (parent: $PM) =="
  echo "{\"type\":\"assistant\",\"message\":{\"model\":\"$PM\"}}" > "$TF"
  chk "model unspecified"     '{"subagent_type":"general-purpose"}' opus
  chk "model: inherit"        '{"model":"inherit"}'                 opus
  chk "model: fable"          '{"model":"fable"}'                   opus
  chk "explicit haiku"        '{"model":"haiku"}'                   PASS
  chk "Plan (authorship)"     '{"subagent_type":"Plan"}'            "$EXP_PLAN"
  chk "fork (inherits model)" '{"subagent_type":"fork"}'            "$EXP_FORK"
done
rm -f "$TF"

echo "== Secret scan (canonical config) =="
if grep -rEIl "(sk-ant-|api[_-]?key[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9]|Bearer [A-Za-z0-9_.-]{20,}|BEGIN [A-Z ]+PRIVATE KEY)" "$REPO/claude-shared" >/dev/null 2>&1; then
  no "possible secret in claude-shared/:"
  grep -rEIl "(sk-ant-|api[_-]?key[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9]|Bearer [A-Za-z0-9_.-]{20,}|BEGIN [A-Z ]+PRIVATE KEY)" "$REPO/claude-shared" | sed 's/^/      /'
else
  ok "no credential patterns in canonical config"
fi

echo "== Drift: repo vs deployed shared copy =="
if [ -d "$SHARED" ]; then
  # .version is written by the app's installer and is not part of the repo.
  D=$(diff -rq -x .version -x .DS_Store "$REPO/claude-shared" "$SHARED" 2>&1)
  if [ -z "$D" ]; then ok "claude-shared/ == $SHARED"
  else no "drift between repo and deployed copy:"; printf '%s\n' "$D" | sed 's/^/      /'; fi
else
  no "$SHARED does not exist — run ./install.sh"
fi

# Claude Profile Switcher puts a dispatcher shim first on PATH, and it REFUSES
# to start recursively. If verify.sh runs inside a Claude Code session, `claude`
# fails with "refused to dispatch recursively". Find the real binary instead.
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
  c=$(ls -d /opt/homebrew/Caskroom/claude-code/*/claude 2>/dev/null | sort -V | tail -1)
  [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  return 1
}

# Which profiles?
NAMES=()
if [ ${#ARGS[@]} -gt 0 ]; then NAMES=("${ARGS[@]}")
else while IFS= read -r line; do NAMES+=("$line"); done < <(jq -r '.profiles[].name' "$PROFILES_JSON" 2>/dev/null); fi
[ ${#NAMES[@]} -gt 0 ] || { echo "Could not read profiles from $PROFILES_JSON"; exit 1; }

FIRST_ID=""
declare -a PLUGIN_SUMMARY
for NAME in "${NAMES[@]}"; do
  echo "== Profile: $NAME =="
  ID=$(jq -r --arg n "$NAME" '.profiles[]|select((.name|ascii_downcase)==($n|ascii_downcase))|.id' "$PROFILES_JSON" 2>/dev/null)
  if [ -z "$ID" ]; then no "no profile named \"$NAME\""; continue; fi
  [ -z "$FIRST_ID" ] && FIRST_ID="$ID"
  CLI="$PROFILES_ROOT/profiles/$ID/cli"
  S="$CLI/settings.json"

  jq -e . "$S" >/dev/null 2>&1 && ok "settings.json is valid JSON" || { no "settings.json invalid/missing"; continue; }
  # model is seeded, not owned — a deliberate /model choice is legitimate.
  M=$(jq -r '.model // "-"' "$S")
  if [ "$M" = "-" ]; then no "model unset (run ./install.sh to seed it)"
  elif [ "$M" = "opus" ]; then ok "model = opus"
  else info "model = $M (not opus — deliberate override, not reset by install)"; fi
  jq -e '.env // {} | has("CLAUDE_CODE_EFFORT_LEVEL") | not' "$S" >/dev/null \
    && ok "effort is user-controlled (no env override)" || no "CLAUDE_CODE_EFFORT_LEVEL locks effort"
  F=$(jq -c '.fallbackModel // "-"' "$S");         [ "$F" = '["sonnet"]' ] && ok "fallbackModel = [sonnet]" || no "fallbackModel = $F"
  DM=$(jq -r '.permissions.defaultMode // "-"' "$S")
  SD=$(jq -r '.skipDangerousModePermissionPrompt // false' "$S")
  if [ "$YOLO" = "1" ]; then
    [ "$DM" = "bypassPermissions" ] && ok "permissions.defaultMode = bypassPermissions" || no "permissions.defaultMode = $DM"
    [ "$SD" = "true" ] && ok "skipDangerousModePermissionPrompt = true" || no "skipDangerousModePermissionPrompt = $SD (startup dialog will appear)"
  else
    info "permissions.defaultMode = $DM, skipDangerousModePermissionPrompt = $SD (yolo is opt-in: --yolo)"
  fi
  SL=$(jq -r '.statusLine.command // "-"' "$S");   [ "$SL" = "$SHARED/statusline.sh" ] && ok "statusLine -> shared" || no "statusLine = $SL"
  jq -e '.hooks.PreToolUse[]|select(.matcher=="Agent|Task")' "$S" >/dev/null 2>&1 && ok "PreToolUse hook registered" || no "hook not registered"
  [ "$(readlink "$CLI/agents")"    = "$SHARED/agents" ]    && ok "agents -> shared"    || no "agents symlink wrong/missing"
  [ "$(readlink "$CLI/CLAUDE.md")" = "$SHARED/CLAUDE.md" ] && ok "CLAUDE.md -> shared" || no "CLAUDE.md symlink wrong/missing"

  for sdir in "$SHARED"/skills/*/; do
    [ -d "$sdir" ] || continue
    sn=$(basename "$sdir")
    [ "$(readlink "$CLI/skills/$sn")" = "$SHARED/skills/$sn" ] && ok "skills/$sn -> shared" || no "skills/$sn symlink wrong/missing"
  done
  LOCAL=$(ls "$CLI/skills" 2>/dev/null | wc -l | tr -d ' ')
  info "skills/ holds $LOCAL entr(ies) in total (canonical + profile-local)"

  # Informational: is the document-skills plugin present in this profile?
  IP="$CLI/plugins/installed_plugins.json"
  if [ -f "$IP" ] && jq -e '.. | strings | select(test("document-skills"))' "$IP" >/dev/null 2>&1; then
    info "drift: document-skills plugin installed"
  else
    info "drift: document-skills plugin NOT installed (./install.sh --with-plugins)"
  fi
  # Every marketplace must live inside this profile's plugins/ directory and be
  # complete. A location elsewhere (e.g. ~/.claude/plugins) loads as cache-miss
  # and makes `claude plugin marketplace update` refuse to run.
  KM="$CLI/plugins/known_marketplaces.json"
  if [ -f "$KM" ]; then
    while IFS=$'\t' read -r mn ml; do
      case "$ml" in
        "$CLI/plugins/"*) [ -f "$ml/.claude-plugin/marketplace.json" ] \
                            && ok "marketplace $mn inside profile" \
                            || no "marketplace $mn: no marketplace.json at $ml" ;;
        *) no "marketplace $mn points outside the profile: $ml" ;;
      esac
    done < <(jq -r 'to_entries[] | [.key, (.value.installLocation // "-")] | @tsv' "$KM")
  else
    info "no known_marketplaces.json"
  fi

  # Plugin load state as Claude Code sees it. A disabled plugin that fails is
  # informational; an enabled one that fails to load is a failure.
  if BIN=$(real_claude); then
    PL=$(CLAUDE_CONFIG_DIR="$CLI" "$BIN" plugin list 2>&1 \
      | awk '/❯/{n=$2} /Status:/{print n, ($0 ~ /failed to load/ ? "FAILED" : "ok")}')
    nfail=0
    while read -r pn st; do
      [ "$st" = "FAILED" ] || continue
      nfail=$((nfail+1))
      if [ "$(jq -r --arg p "$pn" '.enabledPlugins[$p] // false' "$S")" = "true" ]; then
        no "plugin $pn is enabled but failed to load"
      else
        info "plugin $pn failed to load (not enabled)"
      fi
    done <<< "$PL"
    [ "$nfail" -eq 0 ] && ok "no plugin failed to load"
  else
    info "plugin load check skipped: no claude binary outside the shim"
  fi
  PLUGIN_SUMMARY+=("$NAME:$(jq -r '[.enabledPlugins // {} | to_entries[] | select(.value) | .key] | sort | join(",")' "$S")")
done

echo "== Drift: enabled plugins across profiles =="
if [ ${#PLUGIN_SUMMARY[@]} -eq 0 ]; then
  info "no profile produced a plugin list"
elif [ ${#PLUGIN_SUMMARY[@]} -gt 1 ]; then
  BASE="${PLUGIN_SUMMARY[0]#*:}"
  same=1
  for row in "${PLUGIN_SUMMARY[@]}"; do
    [ "${row#*:}" = "$BASE" ] || same=0
  done
  if [ "$same" = "1" ]; then ok "identical enabled plugins in all profiles"
  else
    info "enabled plugins differ (informational, not a failure):"
    for row in "${PLUGIN_SUMMARY[@]}"; do info "  ${row%%:*}: ${row#*:}"; done
  fi
else
  for row in "${PLUGIN_SUMMARY[@]}"; do info "${row%%:*}: ${row#*:}"; done
fi

echo "== Agent discovery (fresh session, haiku — first profile only) =="
if [ "${SKIP_PROBE:-}" = "1" ]; then
  echo "  (skipped: SKIP_PROBE=1)"
elif [ -z "$FIRST_ID" ]; then
  echo "  (skipped: no profile resolved)"
elif ! BIN=$(real_claude); then
  no "no claude binary found outside the profile-switcher shim"
else
  OUT=$(CLAUDE_CONFIG_DIR="$PROFILES_ROOT/profiles/$FIRST_ID/cli" \
        "$BIN" -p --model haiku \
        "List EXACTLY the values you can pass as subagent_type to the Agent tool, one per line, nothing else." 2>&1)
  for a in code-scout doc-researcher implementer verifier; do
    printf '%s\n' "$OUT" | grep -qx "$a" && ok "$a found" || no "$a NOT found"
  done
fi

echo
[ $FAIL -eq 0 ] && echo "All OK." || { echo "Something failed — run ./install.sh"; exit 1; }
