---
description: Review recent code changes for correctness, security, performance, maintainability, and project conventions. Delegates to the code-reviewer agent.
argument-hint: "[file path or scope description — defaults to staged diff, falling back to branch diff vs main]"
---

Use the Task tool to launch the `code-reviewer` agent.

Resolve the review scope:
- If `$ARGUMENTS` is non-empty, treat it as the focus (a file path, a directory, or a free-form description like "the Suno chain logic").
- Otherwise, run `git diff --cached --stat` and use the staged diff if non-empty.
- Otherwise, run `git diff main...HEAD --stat` (or `master` if `main` doesn't exist) and use the branch diff.
- Otherwise, tell the user there's nothing to review and stop.

Pass the agent this brief:

> Review scope: $ARGUMENTS (or staged/branch diff if no arg).
>
> Conduct a comprehensive code review per your standard categories. Cross-check against [CLAUDE.md](CLAUDE.md) — project conventions matter. Report findings in the standard format (numbered list of categorized findings with concrete file:line references, then a one-line verdict).
>
> Be blunt and substantive. If the code is genuinely good, ship a brief approval — don't manufacture concerns to pad the review.
