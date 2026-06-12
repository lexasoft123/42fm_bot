---
paths:
  - "lib/settings.rb"
  - "lib/rate_limiter.rb"
  - "config/settings.common.yml"
---

# Settings / rate limits gotchas

Reference: `docs/architecture.md` § Settings / § Configuration.

- `Settings` add-new-group note: top-level groups must be added to `REQUIRED_KEYS` in `lib/settings.rb` for the deep-merge validator to accept them. Settings file roles: `config/settings.common.yml` — non-secret defaults (prompts, models, URLs), committed; `config/settings.yml` — secrets & overrides, gitignored, deep-merged on top. Optional groups (e.g. `digests`) are deliberately NOT in `REQUIRED_KEYS` — see `.claude/rules/agent-games.md`.
- **Per-role rate limits** — `Settings.auth['rate_limits']['admin'][service]` overrides the regular bucket when `RateLimiter.exceeded?(..., role: 'admin')` is called with `role: 'admin'`. Tools pass `ctx[:user]&.role`. Counters stay per-chat-shared (no per-user counter), so an admin's higher cap simply lets them keep acting after regular users have hit theirs. Priority: `auth.rate_limits.admin.<svc>` → `chat.rate_limits.<svc>` (per-chat menu edits) → `auth.rate_limits.<svc>` (default) → hard-coded `{max: 1, window: 20}`.
