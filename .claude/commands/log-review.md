---
description: Audit prod bot state via bin/inspect. Delegates to the prod-log-reviewer agent.
argument-hint: "[topic or feature, e.g. 'ADR-003 cron loop' / 'last deploy' / '6h']"
---

Use the Task tool to launch the `prod-log-reviewer` agent.

Pass it this brief:

> Audit prod for: $ARGUMENTS
>
> Reference docs as needed: `docs/adr/`, `CLAUDE.md`, recent `git log --oneline -10`.
> If $ARGUMENTS is empty or just a number followed by `h`/`d`, default to a general health audit covering that window (or last 24h if no window given): `bot-status`, `errors-today`, `task-failures`, `cron-health`. Otherwise pick the probes that map to the named feature.
>
> Report under 250 words in the agent's standard ✓/✗ format with a one-line verdict.
