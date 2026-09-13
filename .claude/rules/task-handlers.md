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
- **Exceptions raised out of a handler are classified by message regex** (`TaskRunner::TRANSIENT_ERROR_RE` `\s5\d{2}[\s{]` → retried without spending an attempt; `PERMANENT_ERROR_RE` `\s4\d{2}[\s{]` → task failed immediately with a raw `"Ошибка: #{message}"` chat notice and NO agent_event). A handler that wants its own notice/agent_event for a permanent failure must check `TaskRunner.permanent_error?(e)` and fail the task itself instead of re-raising (all Suno handlers do). A stray `" 4xx "` in a message makes it permanent — see `SunoClient#submit_error` for deliberate code rendering.
- **`params_hash`/`result_hash` are memoized and `reload` doesn't clear them** — in tests, assert persisted params via `BackgroundTask.find(id)`, not `task.reload.params_hash` (the latter reads the handler's in-memory mutation and passes even if the write was lost).
