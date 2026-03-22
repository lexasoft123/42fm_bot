# ADR-002: DB-Backed Background Task Queue

**Status:** Accepted
**Date:** 2026-03-22

## Context

Long-running operations like Suno AI song generation (60–120s) were handled with ad-hoc `Thread.new` calls. These threads are lost on bot restart — if the bot crashes or restarts mid-generation, the user never gets their result and there's no way to recover.

We need persistent background tasks that:
- Survive bot restarts
- Don't require external infrastructure (Redis, RabbitMQ)
- Are generic enough to support future task types (image generation, video, etc.)

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Sidekiq + Redis** | Mature, battle-tested, rich features | Requires Redis server, separate process, overkill for this scale |
| **Active Job + Solid Queue** | Rails-native, DB-backed | Requires Rails — this is a plain Ruby app |
| **delayed_job_active_record** | Works with AR, no Redis | Separate worker process, limited maintenance |
| **Custom DB table + poller** | Zero deps, uses existing SQLite, single process | Less features, manual implementation |

## Decision

Custom `background_tasks` table with a generic `TaskRunner` poller thread. The bot is a single-process daemon serving a private community (~20 users) — throughput requirements are minimal. Adding Redis or a job framework would be over-engineering.

## Architecture

- `background_tasks` table stores task state in SQLite (same DB as everything else)
- `TaskRunner` is a generic poller thread started inside `Telegram::Bot::Client.run`, reusing the existing `bot.api` for Telegram calls
- Task handlers are registered via `TaskRunner.register('type', HandlerClass)` — adding a new task type requires only a handler class and a register call
- Handler's `call(task, api)` returns `:pending`, `:done`, or `:failed`
- `TaskRunner` manages attempts, timeouts, and error handling generically

## Handler Registry Pattern

```ruby
# Registration (in handler file):
TaskRunner.register('suno_generate', SunoTaskHandler)

# Handler contract:
class SunoTaskHandler
  def call(task, api)
    # Do work, return :pending / :done / :failed
  end
end
```

## Trade-offs

- **No concurrency control** — tasks are processed sequentially. Fine for current scale (<5 concurrent tasks)
- **10s polling interval** — not real-time, but song generation takes 60-120s anyway
- **SQLite write contention** — poller and main thread both write to DB. SQLite handles this with WAL mode, acceptable at this scale
- **No retry backoff** — fixed interval polling. If needed, handler can implement its own delay logic

## Consequences

- Song generation survives restarts — the poller picks up pending tasks on boot
- Any command or agent tool can enqueue async work with `BackgroundTask.create!`
- Future task types (image gen, video, etc.) require only a new handler file
- No new external dependencies or processes to manage
