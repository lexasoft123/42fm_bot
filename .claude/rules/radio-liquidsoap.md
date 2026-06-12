---
paths:
  - "lib/radio.rb"
  - "lib/commands/radio_*.rb"
  - "lib/commands/order_*.rb"
  - "lib/commands/remove_track.rb"
  - "lib/commands/remaining.rb"
  - "lib/commands/history.rb"
  - "lib/commands/listeners.rb"
  - "lib/commands/meta.rb"
  - "lib/commands/stats.rb"
  - "lib/agent/tools/radio.rb"
---

# Radio / Liquidsoap gotchas

Prod-verified trap knowledge for the Liquidsoap TCP client and radio commands. Reference: `docs/architecture.md` § Radio.

- Radio TCP socket is lazy — connects on first use, not at startup
- **Radio keepalive** — `Radio#start_keepalive` (called from `lib/bot.rb` at startup, alongside TaskRunner/CronScheduler) spawns a background thread that pings Liquidsoap every `KEEPALIVE_INTERVAL` (20s) with a harmless `request.alive`. Liquidsoap closes idle telnet connections; reusing a stale socket loses the first command's response, which made `!track` return `(нет данных)` *while a track was actually playing* (verified on prod: metadata was available via a fresh telnet probe, but every logged `!track` hit the stale-socket reconnect race). The keepalive pays the reconnect-on-idle penalty on the throwaway ping so real user commands always hit a warm socket. Idempotent (`@keepalive ||= …`), so safe across the bot's crash/retry loop. The interval must stay well under Liquidsoap's idle-close timeout. `Radio#command`'s reconnect rescue catches `Timeout::Error` (in addition to `Errno::EPIPE`/`ECONNRESET`/`IOError`) so a *hung* half-open socket also resets `@sock` and reconnects instead of timing out forever.
- **Radio metadata degradation** — `Radio#track` returns `"сейчас ничего не играет"` (not `"(нет данных), осталось …"`) when the playing source has no metadata. With the keepalive in place this should rarely trigger; it's a safety net.
- **`!queue` uses annotate tagging, not `request.queue`** — Liquidsoap's `request.queue(id="request")` operator **prefetches** the next request out of its visible queue, so `request.queue` reads empty within seconds of a `request.push` even while the track is queued/playing (verified on Liquidsoap 2.2.5; there is no `secondary_queue`/`primary_queue` in 2.x). So `Radio#request` pushes with the `annotate:` protocol — `request.push annotate:bot_req="1":<path>` (`REQUEST_TAG` constant) — and `Radio#queue` enumerates **`request.alive`** (all resolved-not-destroyed requests, rotation + user), fetches `request.metadata <id>` for each, and keeps only those tagged `bot_req="1"`. This covers both queued and now-playing user requests and self-prunes as they finish (played requests leave `request.alive`). The `source` metadata field can't be used to identify user requests — it's `"music_txt"` for library-file pushes (a file/playlist tag), inconsistent with the operator id. Empty result → `nil` → `RadioQueue` renders `"нихуя нет"`. The annotate round-trip was verified live on prod via a Ruby probe.
- `new` role users are rate-limited on track requests (checks `user.last_order`)
- The container reaches Liquidsoap on `localhost:1234` only because of `network_mode: host` — see CLAUDE.md Docker Setup.
