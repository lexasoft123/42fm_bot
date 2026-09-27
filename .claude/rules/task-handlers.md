---
paths:
  - "lib/task_runner.rb"
  - "lib/task_handlers/*.rb"
  - "lib/agent/error_reporter.rb"
  - "models/background_task.rb"
  - "lib/commands/task_queue.rb"
---

# Background tasks gotchas

Reference: `docs/architecture.md` § Background Task Queue.

- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance. Its forever-loop calls the testable `poll_cycle` boundary; that method catches dispatch/DB faults and reports them globally before the loop sleeps and continues.
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- `бот задачи` shows last 10 background tasks for the current chat
- **Never `sleep`/block in a handler** — TaskRunner has only 2 workers, and tool-path handlers run inside `bot.listen`'s single-threaded loop. Full war story: `.claude/rules/agent-runtime.md`.
- **Exceptions raised out of a handler are classified by message regex** (`TaskRunner::TRANSIENT_ERROR_RE` `\s5\d{2}[\s{]` → retried without spending an attempt; `PERMANENT_ERROR_RE` `\s4\d{2}[\s{]` → task failed immediately). Every terminal path is then passed to `Agent::ErrorReporter`: it keeps an existing tailored event for that parent task or creates a sanitized `runtime_error` event, so the failure reaches the agent instead of ending at the raw chat notice. A handler that wants a task-specific event/prompt should still fail and emit it itself (all Suno handlers do). A stray `" 4xx "` in a message makes it permanent — see `SunoClient#submit_error` for deliberate code rendering.
- `Agent::ErrorReporter` is the only generic failure bridge. Do not add new ad-hoc “print error to chat only” terminal paths. Generic task errors are deduplicated by `parent_task_id`; parentless errors coalesce by sanitized fingerprint for 5 minutes and use the 10/hour/chat cap; `agent_event` task failures are excluded to prevent recursive loops. Poller errors have no task chat, so `report_global` routes them to configured super-admin private chat IDs.
- **`params_hash`/`result_hash` are memoized and `reload` doesn't clear them** — in tests, assert persisted params via `BackgroundTask.find(id)`, not `task.reload.params_hash` (the latter reads the handler's in-memory mutation and passes even if the write was lost).
