---
paths:
  - "lib/agent/runner.rb"
  - "lib/agent/tool_registry.rb"
  - "lib/agent/tool_result.rb"
  - "lib/agent/scratchpad.rb"
  - "lib/agent/tools/*.rb"
  - "lib/cron_scheduler.rb"
  - "lib/task_handlers/agent_event_handler.rb"
  - "lib/task_handlers/agent_event_emitter.rb"
  - "lib/commands/gpt_chat.rb"
  - "lib/commands/gpt_question.rb"
---

# Agent runtime gotchas

Trap knowledge for the agent loop, tools, scratchpad, event loop, and cron. Reference: `docs/architecture.md` § Agent Mode / § Agent Scratchpad / § Agent Event Loop.

| Task | File |
|------|------|
| Agent mode tools | `lib/agent/tools/*.rb` + `lib/agent/tool_registry.rb` + `lib/agent/runner.rb` |
| Agent scratchpad | `lib/agent/scratchpad.rb` + `models/chat_state.rb` + `lib/agent/tools/scratchpad.rb` (`remember`/`forget` tools); auto-rendered as `{SCRATCHPAD}` in agent_prompt template |
| Agent event handler | `lib/task_handlers/agent_event_handler.rb` + `lib/task_handlers/agent_event_emitter.rb` mixin. Reacts to image_gen/suno outcomes; rate-limited at 10/hour/chat. |
| Time-deferred intentions | `lib/cron_scheduler.rb` (60s tick) + `Agent::Scratchpad.due_intentions` / `mark_acted`. Started from `lib/bot.rb`. |
| Agent views historical images | `lib/agent/tools/view_image.rb` (tool) + `lib/telegram_file.rb#download_image` (shared download) + `Agent::Runner#inject_pending_images` (vision injection + `agent_vision` upgrade) + `lib/message_responder.rb#photo_attachment_file_id` (persistence) |

- **NEVER `sleep` (or otherwise block) in a tool handler.** Handlers run synchronously inside `bot.listen`'s single-threaded loop — a sleep freezes the whole bot for every chat — and, on the TaskRunner path, inside `with_connection` with only 2 workers. This killed the "wait for the dice animation" idea in `challenge_rule`: `api.send_dice`'s response carries the rolled value immediately (the client animation runs ~4s), so the verdict returns at once instead of sleeping through the animation.
- Agent mode is the only mode: `GptChat` / `GptQuestion` always route through `Agent::Runner`, which lets GPT call bot tools (radio, weather, search, etc.) autonomously. Agent supports vision — replying to a photo with "бот ..." sends the image to the vision model for recognition.
- All `бот <text>` requests — including search, images, gifs, horoscope — route through `GptChat` → `Agent::Runner`. The agent's `google_search` / `horoscope` / `generate_image` tools handle those intents and can compose multiple tools in one turn (e.g. "бот найди новости и нарисуй" → `google_search` then `generate_image`). There are no direct-dispatch commands for search or horoscope anymore.
- Agent scratchpad (`Agent::Scratchpad`, `chat_states` table) — per-chat working memory (intentions/notes/expectations), distinct from knowledge base. Hard cap 6000 chars with FIFO eviction. Rendered as `{SCRATCHPAD}` in `agent_prompt`; managed via `remember`/`forget` tools. Detail: `docs/architecture.md#agent-scratchpad`, ADR-003. **Rules-war `rules` category invariants constrain scratchpad edits — see `.claude/rules/agent-games.md`.**
- Agent event loop — `agent_event` task type, `AgentEventHandler`, `AgentEventEmitter` mixin. Emits on image_gen/suno failure-after-retries or success-after-retries; agent runs and decides whether to comment, retry, or `(skip)`. Per-chat cap 10/hour. Loop protection: only image_gen/suno emit; agent_event itself doesn't. Detail: `docs/architecture.md#agent-event-loop`, ADR-003 PR-2.
- **Agent tool ctx — `ctx[:api]`** — Tools read `ctx[:api]` for Telegram calls. Pass `api:` to `Agent::Runner.new`; Runner warns if nil. Detail: `docs/architecture.md#agent-event-loop`.
- `Agent::ToolResult` — tool handlers return either a String or `Agent::ToolResult.deferred(user_text:, intent:, retry_in_min:)` for rate-limited / retry-later outcomes. Runner auto-writes the intent to the scratchpad with `due_at`. New deferred-style tools just call `.deferred(...)` — no per-tool prompt scaffolding. Detail: `docs/architecture.md#agent-scratchpad`.
- `CronScheduler` (`lib/cron_scheduler.rb`) — 60s tick, fires `agent_event(cron_tick)` for chats with due scratchpad intentions; same 10/hr rate cap as agent_event. Started from `lib/bot.rb`. Detail: `docs/architecture.md#agent-scratchpad`.
- Scratchpad compaction is pure-Ruby (no LLM); runs inline on every `Scratchpad.add` for expiry-based pruning. Manual: `rake scratchpad:compact [MAX_AGE_DAYS=N] [CHAT_ID=...]`. Detail: `docs/architecture.md#agent-scratchpad`.
- **`view_image` mid-loop vision upgrade** — the tool fetches a stored photo (by `message_id` of a `photo: true` context row) and returns `Agent::ToolResult.image`; Runner queues it in `@pending_images`, injects it AFTER all of the iteration's tool-result messages (openai contract: every tool_call answered before another role), then flips `@setting` to `agent_vision` for the rest of the turn. The upgrade only happens when `agent` and `agent_vision` share `api_type` (`ctx[:can_view_image]`, computed at Runner init) — accumulated messages are provider-shaped and can't be replayed cross-provider; on mismatch the tool degrades to text. DeepSeek's `reasoning_content` is stripped from accumulated assistant messages on upgrade (grok may reject the unknown field). `materialize_result` checks `image?` BEFORE the deferred guard — reordering would silently drop the image. `GptMaster#dump_gpt` redacts base64 image payloads from gpt.log. Photos persist at ≤1280px (`Message.pick_photo_file_id` — shared by incoming `save_message` and outgoing `persist_bot_reply`); the bot's own sent images (deliver `:image`, image_gen, Suno cover art) are captured too, so the agent can re-view its generation results. Only post-deploy photos are fetchable; document-images (`image/*` MIME files) aren't captured.
  - **Same resolution reused for edit sourcing:** `generate_image`'s `source_message_ids` lets the agent pick history photos as *edit inputs* (combine), resolved the same way (`message_id` → `attachment_photo_file_id` → `TelegramFile.download_image`) — but the download happens in `ImageGenTaskHandler` (TaskRunner), NOT the tool, because the tool runs in the bot's listen loop (no blocking I/O). See `.claude/rules/image-gen.md`.
