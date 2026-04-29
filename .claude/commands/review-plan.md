---
description: Audit a plan file from a chief-architect perspective. Delegates to the plan-reviewer agent.
argument-hint: "[path/to/plan.md — defaults to most recent in ~/.claude/plans/]"
---

Use the Task tool to launch the `plan-reviewer` agent.

Resolve the plan path:
- If `$ARGUMENTS` is non-empty, use it verbatim.
- Otherwise, run `ls -t ~/.claude/plans/*.md 2>/dev/null | head -1` and use the result. If that's empty, tell the user there's no plan to review and stop.

Pass the agent this brief:

> Audit the plan at `<resolved path>`. Read it end-to-end, cross-check claims against the codebase where possible, and produce findings in the standard format (numbered list of categorized findings with concrete plan-section / file:line references, then a one-line verdict).
>
> Be blunt and substantive. If the plan is genuinely good, ship a brief approval — don't manufacture concerns to pad the review.
