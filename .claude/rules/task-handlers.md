---
paths:
  - "lib/task_runner.rb"
  - "lib/task_handlers/*.rb"
  - "models/background_task.rb"
  - "lib/commands/task_queue.rb"
---

# Background tasks gotchas

Reference: `docs/architecture.md` § Background Task Queue.

- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- `бот задачи` shows last 10 background tasks for the current chat
- **Never `sleep`/block in a handler** — TaskRunner has only 2 workers, and tool-path handlers run inside `bot.listen`'s single-threaded loop. Full war story: `.claude/rules/agent-runtime.md`.
