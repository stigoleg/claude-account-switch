#!/bin/bash
# PreToolUse hook (matcher: Agent|Task). Pins subagents to an explicit model
# and keeps Fable out of them, whatever the main session runs on.
#
# Rules:
#   model unspecified | inherit | default | *fable*   -> pinned to opus
#   model explicitly opus/sonnet/haiku/full ID        -> passed through untouched
#   subagent_type == fork, parent is Fable/unknown    -> denied
#     (a fork always inherits the parent model; `model` is ignored, so pinning
#      is impossible — the only enforcement available is to deny the call)
#   subagent_type == Plan, parent is Fable/unknown    -> denied
#     (the Plan agent authors the plan, and authorship stays in the main
#      session, where the full context lives. Plan mode actively instructs the
#      model to dispatch this agent, so policy alone is not enough. From a
#      non-Fable parent, Plan falls through to ordinary pinning.)
#
# The parent model is read from the transcript: the current assistant turn has
# not been written yet when PreToolUse fires, so the last fully written
# assistant line IS the parent. Verified field: .message.model.
# An unknown parent (fresh session, no completed turn) is treated as Fable.
#
# Note: CLAUDE_CODE_SUBAGENT_MODEL is deliberately NOT set in settings.json.
# Before Claude Code v2.1.251 it overrides the per-call parameter this hook
# sets; from v2.1.251 it is only a default. The semantics flip silently on
# upgrade. This hook behaves identically on both.

set -uo pipefail

INPUT=$(cat)

# Without jq: do not block the workflow, let the call through.
command -v jq >/dev/null 2>&1 || exit 0

REQ=$(printf '%s' "$INPUT" | jq -r '.tool_input.model // ""' | tr '[:upper:]' '[:lower:]')
KIND=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""')
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')

PARENT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  PARENT=$(tail -n 400 "$TRANSCRIPT" \
    | jq -r 'select(.type=="assistant") | .message.model // empty' 2>/dev/null \
    | tail -n 1)
fi
[ -z "$PARENT" ] && PARENT="unknown"

parent_is_fable() {
  case "$PARENT" in *fable*|unknown) return 0 ;; *) return 1 ;; esac
}

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{
    hookEventName:"PreToolUse",
    permissionDecision:"deny",
    permissionDecisionReason:$r}}'
}

if [ "$KIND" = "fork" ]; then
  parent_is_fable && deny "fork inherits the parent model ($PARENT) and cannot \
be pinned; it is denied when the parent model is Fable or undetectable. Start \
a fresh agent with explicit context and model: opus|sonnet|haiku instead."
  exit 0
fi

case "$KIND" in
  Plan|plan)
    # From a non-Fable parent there is no leak; Plan then falls through to the
    # ordinary pinning below instead of being denied.
    if parent_is_fable; then
      deny "The Plan agent authors the plan, and authorship belongs in the main \
session; it is denied when the parent model is Fable or undetectable (parent: \
$PARENT). Delegate fact-finding instead — code-scout for code, \
doc-researcher for documentation, Explore for coarse search — and do the \
judgement, the synthesis and the plan writing yourself, where you have the full \
context."
      exit 0
    fi
    ;;
esac

# An explicit non-Fable choice is respected (e.g. haiku for cheap fan-out).
case "$REQ" in
  ""|inherit|default|*fable*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | jq -c --arg was "${REQ:-unset}" --arg p "$PARENT" '{hookSpecificOutput:{
  hookEventName:"PreToolUse",
  permissionDecision:"allow",
  permissionDecisionReason:("Subagent pinned to opus (asked for: " + $was +
    ", parent: " + $p + "). Unset, inherit and Fable requests are pinned to opus; pass " +
    "model: opus|sonnet|haiku explicitly to choose the level."),
  updatedInput:(.tool_input + {model:"opus"})}}'
exit 0
