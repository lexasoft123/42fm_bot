#!/usr/bin/env bash
# PreToolUse Bash hook: re-prompt the user for confirmation on every deploy/push
# command. Emits hookSpecificOutput.permissionDecision="ask" on match, routing
# the call through Claude Code's permission UI; silent passthrough otherwise.
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)
pattern='(^|[^[:alnum:]_])(make[[:space:]]+deploy|git[[:space:]]+push|docker[[:space:]]+compose[[:space:]]+up|ssh[[:space:]].+docker[[:space:]]+compose)($|[[:space:]])'
if echo "$cmd" | grep -qE "$pattern" \
   && ! echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+(--help|-h)($|[[:space:]])'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "deploy-guard: deploy/push commands always re-prompt — confirm only if the user has explicitly authorized this deploy in the current turn."
    }
  }'
fi
exit 0
