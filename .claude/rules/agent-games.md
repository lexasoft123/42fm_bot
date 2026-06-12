---
paths:
  - "lib/agent/tools/rules.rb"
  - "lib/agent/scratchpad.rb"
  - "lib/commands/rules.rb"
  - "lib/commands/quote.rb"
  - "lib/commands/wrapped.rb"
  - "lib/chat_wrapped.rb"
  - "lib/task_handlers/rule_obituary_handler.rb"
  - "lib/task_handlers/wrapped_digest_handler.rb"
---

# Community games gotchas (rules-war, quote, wrapped, awards)

Reference: `docs/architecture.md` § Rules-war game / § Chat Wrapped / § Quote of the day. `lib/agent/scratchpad.rb` is deliberately listed here AND in `agent-runtime.md` — the rules-store invariants constrain scratchpad edits.

| Task | File |
|------|------|
| Rules-war game | `lib/agent/scratchpad.rb` (rules store API) + `lib/agent/tools/rules.rb` (`set_rule`/`repeal_rule`/`challenge_rule`/`court_rule`) + `lib/commands/rules.rb` (`бот правила` lister) + `lib/task_handlers/rule_obituary_handler.rb` + `lib/cron_scheduler.rb` (`maybe_announce_expired_rules`) |
| Quote of the day | `lib/commands/quote.rb` (`бот цитата`) — random pick from `Message.top_reacted(scope: :user)`, 30-day window |
| Chat Wrapped (weekly + on-demand) | `lib/chat_wrapped.rb` + `lib/task_handlers/wrapped_digest_handler.rb` (`weekly_wrapped` task, F7 «Революция») + `lib/commands/wrapped.rb` (`бот итоги`) + `lib/cron_scheduler.rb` (`maybe_fire_digests`) + `digests:` settings block |

- **Rules-war store** — scratchpad `rules` category is **exempt from `evict_until_under_cap` AND from generic `prune_expired`**: active rules must never vanish silently, and expired rules are deleted ONLY via `Scratchpad.pop_expired_rules` (CronScheduler) so each gets its obituary exactly once. `rules()`/`render` filter expired at read (≤60s pop lag is never *enforced*). Spam bounds: one-rule-per-citizen (new rule auto-repeals the author's old one — `add_rule` returns `{rule:, repealed:, evicted:}` so the agent announces the trade-in), `MAX_RULES = 20` backstop, 200-char content cap. `add_rule` is a separate method — generic `add` keeps returning a bare `"sp-NNN"` string (the Runner's deferred-intent write depends on it) and rejects `category: 'rules'`; `Scratchpad.remove` (the `forget` tool) can't delete rules. Court rules (`court_rule` tool, `set_by: 0`, rendered «суд») bypass one-rule-per-citizen but max 1 per chat, 12h.
- **Dice trials (`challenge_rule`)** — public `api.send_dice` roll (value is in the response immediately; the client animation runs ~4s). **NEVER `sleep` in a tool handler**: handlers run synchronously inside `bot.listen`'s single-threaded loop (a sleep freezes the whole bot) and, on the TaskRunner path, inside `with_connection` with only 2 workers. Outcome: 4–6 repeal / 2–3 survive +6h / 1 critical fail (+ court_rule instruction). Survival counter is surfaced **post-increment** (F5 awards trigger on `>= 3`). Throttle: 6 trials/chat/hour via scratchpad top-level `challenge_log` (pruned to the 1h window on write — `RateLimiter` doesn't fit, it counts BackgroundTask rows).
- **Rule obituaries** — CronScheduler pops expired rules per tick and enqueues at most ONE `rule_obituary` task (single or combined «братская могила»); max 3/chat/local-day, past the cap rules are popped silently. The handler renders only what task params carry.
- **`digests` settings block** — optional group (deliberately NOT in `Settings::REQUIRED_KEYS` — adding it would crash any settings.yml without it). `chat_id` is set on prod in place (never scp). Round 1 fires the **wrapped branch only**; `digests.news` is inert reserved config — enqueueing `daily_news` without a registered handler would mark-failed + error-notify the chat.
- **«Революция» (weekly Wrapped)** — 10% roll happens ONLY in `WrappedDigestHandler` (never `бот итоги`), is persisted into task params BEFORE any send, and retries re-read it — a transient send failure can't re-roll or double-wipe. `clear_rules` is idempotent.
- **`Message.top_reacted(scope:)`** — `:user` (Quote: humans only) vs `:all` (Wrapped funniest: includes bot rows — the dominant reacted content is the bot's own memes; don't silently exclude them).
