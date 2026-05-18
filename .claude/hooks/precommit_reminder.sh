#!/usr/bin/env bash
# PreToolUse Bash hook: nudge Claude to run /review-code before committing.
# Non-blocking — emits hookSpecificOutput.additionalContext, the commit still proceeds.
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null || true)
if echo "$cmd" | grep -qE 'git[[:space:]]+commit($|[[:space:]])' \
   && ! echo "$cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+(--help|-h)\b'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: "Reminder: invoke /review-code (or the code-reviewer agent) before committing substantive changes. See CLAUDE.md ## Rules."
    }
  }'
fi
exit 0
