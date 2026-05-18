#!/usr/bin/env bash
# PreToolUse Bash hook: block deploy/push commands until user explicitly re-confirms.
# Emits hookSpecificOutput.permissionDecision="deny" on match; silent passthrough otherwise.
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)
pattern='(^|[^[:alnum:]_])(make[[:space:]]+deploy|git[[:space:]]+push|docker[[:space:]]+compose[[:space:]]+up|ssh[[:space:]].+docker[[:space:]]+compose)($|[[:space:]])'
if echo "$cmd" | grep -qE "$pattern" \
   && ! echo "$cmd" | grep -qE 'git[[:space:]]+push[[:space:]]+(--help|-h)($|[[:space:]])'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Blocked by deploy-guard hook. The user must explicitly authorize deploys/pushes in the current turn before this command can run. Ask the user to re-confirm."
    }
  }'
fi
exit 0
