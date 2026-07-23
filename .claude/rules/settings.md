---
paths:
  - "lib/settings.rb"
  - "lib/rate_limiter.rb"
  - "config/settings.common.yml"
---

# Settings / rate limits gotchas

Reference: `docs/architecture.md` § Settings / § Configuration.

- `Settings` add-new-group note: top-level groups must be added to `REQUIRED_KEYS` in `lib/settings.rb` for the deep-merge validator to accept them. Settings file roles: `config/settings.common.yml` — non-secret defaults (prompts, models, URLs), committed; `config/settings.yml` — secrets & overrides, gitignored, deep-merged on top. Optional groups (e.g. `digests`) are deliberately NOT in `REQUIRED_KEYS` — see `.claude/rules/agent-games.md`. Nested keys under an existing group don't need a `REQUIRED_KEYS` entry either — e.g. `image_gen.models` / `image_gen.default_model` (the agent-selectable image-model catalog); adding or switching an image model is a config-only edit.
- **`telegram.rich_messages`** (default `true`, committed in `settings.common.yml`) — master switch for Bot API 10.1 Rich Messages in `MessageSender#send`. Non-secret default lives in common.yml and deep-merges under the `telegram.token` from the gitignored `settings.yml` (the `deep_merge` is recursive, so both coexist). Kill switch: set `telegram.rich_messages: false` in **prod** `settings.yml` — but note Settings load **once at boot**, so it only takes effect after a **restart**. No `REQUIRED_KEYS` change needed (nested key under the already-required `telegram` group). See `.claude/rules/messages-context.md` for the send-path behavior.
- **Per-role rate limits** — `Settings.auth['rate_limits']['admin'][service]` overrides the regular bucket when `RateLimiter.exceeded?(..., role: 'admin')` is called with `role: 'admin'`. Tools pass `ctx[:user]&.role`. Counters stay per-chat-shared (no per-user counter), so an admin's higher cap simply lets them keep acting after regular users have hit theirs. Priority: `auth.rate_limits.admin.<svc>` → `chat.rate_limits.<svc>` (per-chat menu edits) → `auth.rate_limits.<svc>` (default) → hard-coded `{max: 1, window: 20}`.
