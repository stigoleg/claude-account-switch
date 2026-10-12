#!/bin/bash
# Status line: active model (and effort level, when reported) first, then
# directory, branch, context usage and cost.
# Input fields verified against code.claude.com/docs/en/statusline.

set -uo pipefail
input=$(cat)
command -v jq >/dev/null 2>&1 || { echo ""; exit 0; }

MODEL=$(printf '%s' "$input" | jq -r '.model.display_name // "?"')
DIR=$(printf '%s' "$input"   | jq -r '.workspace.current_dir // .cwd // ""')
PCT=$(printf '%s' "$input"   | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)
COST=$(printf '%s' "$input"  | jq -r '.cost.total_cost_usd // empty')
EFFORT=$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)

DIM=$'\033[2m'; RESET=$'\033[0m'
BOLD=$'\033[1m'; ORANGE=$'\033[38;5;209m'; BLUE=$'\033[38;5;75m'

parts="${BOLD}${BLUE}${MODEL}${RESET}"
[ -n "${EFFORT:-}" ] && parts="$parts ${DIM}${EFFORT}${RESET}"

if [ -n "$DIR" ]; then
  parts="$parts ${DIM}·${RESET} $(basename "$DIR")"
  BRANCH=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$BRANCH" ] && parts="$parts ${DIM}(${BRANCH})${RESET}"
fi

# Context usage is only shown once it starts to matter. Thresholds are tuned
# for a 1M window: 25% is already ~250k tokens, which is where occupancy starts
# to cost both quality (attention dilution) and money (resent every turn).
if [ -n "${PCT:-}" ] && [ "$PCT" -ge 25 ] 2>/dev/null; then
  if [ "$PCT" -ge 50 ]; then parts="$parts ${DIM}·${RESET} ${ORANGE}${PCT}% ctx${RESET}"
  else parts="$parts ${DIM}· ${PCT}% ctx${RESET}"; fi
fi

if [ -n "${COST:-}" ]; then
  C=$(printf '%.2f' "$COST" 2>/dev/null) && [ "$C" != "0.00" ] && parts="$parts ${DIM}· \$${C}${RESET}"
fi

printf '%b\n' "$parts"
