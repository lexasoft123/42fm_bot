# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Never run `ruby lib/bot.rb` directly.** Always use `./bin/bot start/stop/restart`.
- Always update all documents on changes.

---

## Running the Bot

**Always use the daemon script — never run `ruby lib/bot.rb` directly.**

```bash
./bin/bot start    # start daemon
./bin/bot stop     # stop daemon
./bin/bot restart  # restart daemon
./bin/bot status   # check if running
```

Logs: `log/bot.log` (app + SQL). PID file: `pids/42fm_bot.pid`.

---

## Keeping Docs Up to Date

**After every meaningful change — and before every commit — update `CLAUDE.md`, `docs/architecture.md`, and `docs/agents.md` when you:**
- Add, remove, or rename a command, service, or file
- Change how commands are dispatched or structured
- Add or modify DB schema (migrations, models)
- Change any settings structure or required keys
- Add new external service integrations
- Change any core pattern (how replies are built, how GPT is called, etc.)
- Change how the bot is started, stopped, or logged

---

## Entry Points

- `bin/bot` → `lib/bot.rb` — daemon loop, filters by authorized `chat_ids`, dispatches to `MessageResponder`
- `lib/message_responder.rb` — initializes `CommandContext`, runs `dispatch` → `deliver`
- `lib/commands/registry.rb` — ordered array of command classes; first match wins
- `config/boot.rb` — requires every lib file; add new requires here
- `config/settings.common.yml` — non-secret defaults (prompts, models, URLs); committed to git
- `config/settings.yml` — secrets & overrides (gitignored); deep-merged on top of common

## Command System

Commands live in `lib/commands/`. Each is a class inheriting `Commands::Base` with two methods:
- `match?` — returns truthy if this command handles the current message
- `execute` — runs the command, returns a `CommandResult`

`CommandContext` (struct) carries per-message state: `bot`, `message`, `user`, `chat_id`, `radio`, `reply_master`, `cmd`.
`CommandResult` (value object) wraps the response type (`:text`, `:sticker`, `:image`, `:voice`, `:audio`, `:none`) and payload.

## Key Files by Task

| Task | File |
|------|------|
| Add/change a command | New file in `lib/commands/` + require in `message_responder.rb` + entry in `lib/commands/registry.rb` |
| New service/API | `lib/new_service.rb` + require in `config/boot.rb` |
| Reply text templates | `config/replies/*.yml` |
| GPT prompt/model | `config/settings.yml` (`chat_gpt.settings.*` + `chat_gpt.providers.*`) + `lib/gpt_master.rb` |
| TTS / audio | `lib/polly.rb` (AWS Polly + FFmpeg → OGG Opus) + `lib/tts_service.rb` |
| Radio (Liquidsoap TCP) | `lib/radio.rb` |
| Agent mode tools | `lib/agent/tools/*.rb` + `lib/agent/tool_registry.rb` + `lib/agent/runner.rb` |
| Background tasks | `lib/task_runner.rb` + `lib/task_handlers/*.rb` + `models/background_task.rb` |
| Suno song generation | `lib/suno_client.rb` + `lib/task_handlers/suno_handler.rb` + `lib/commands/suno_sing.rb` |
| FLUX image generation | `lib/flux_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/commands/image_gen.rb` |
| Shared handler context | `lib/chat_context.rb` — `ChatContext` module (chat messages + knowledge for task handlers) |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |

## Services

`Radio` (Liquidsoap TCP socket, lazy connect), `GptMaster` (Anthropic/OpenAI-compatible, `.chat`/`.ask`/`.call_raw`), `Agent::Runner` (agentic tool-use loop over GptMaster), `Agent::ToolRegistry` (tool definitions for agent mode), `TaskRunner` (generic DB-backed background task poller + handler registry), `SunoClient` (Suno AI song generation API, V5 model), `FluxClient` (FLUX 2 image generation API via api.bfl.ai), `ChatContext` (shared module providing chat context + knowledge lookup for task handlers), `EmbeddingService` (OpenAI-compatible embeddings), `KnowledgeBase` (semantic RAG — store/search/auto-extract facts), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope` (scraper), `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice` (game)

## DB Tables

| Table | Columns |
|-------|---------|
| `users` | `uid`, `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable), `chat_id`, `body`, `role` (`user`/`bot`) |
| `phrases` | `user_id`, `content` |
| `knowledge` | `topic`, `content`, `embedding` (JSON), `source` (`manual`/`auto`), `chat_id` |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |

## Gotchas

- Messages from non-whitelisted `chat_ids` are silently dropped in `lib/bot.rb`
- Messages older than 30s are skipped
- Voice messages only go to `audio_chat_ids`
- `new` role users are rate-limited on track requests (checks `user.last_order`)
- Google API keys are a pool in settings — `gogolmogol.rb` cycles through them
- `ffmpeg` must be installed for TTS to work
- Radio TCP socket is lazy — connects on first use, not at startup
- Daemons runs with `:monitor => false` — the bot's own rescue/retry loop handles crashes
- SOCKS proxy (if enabled) patches `Net::HTTP` globally via `socksify` — applies to all outbound HTTP
- GPT bot replies are stored in `messages` with `role: 'bot'`, `user_uid: nil`
- `Settings` deep-merges `settings.common.yml` (defaults) + `settings.yml` (secrets/overrides); add new top-level groups to `REQUIRED_KEYS` in `lib/settings.rb`
- To change prompts, models, or non-secret config — edit `config/settings.common.yml` (committed). For API keys — edit `config/settings.yml` (gitignored)
- Knowledge auto-extraction runs in a background Thread every `knowledge.extract_every` messages per chat
- Embeddings deduplication threshold is 0.92 cosine similarity — near-duplicate facts are not stored
- `бот найди/ищи/пошукай` → Google search; bare `бот <text>` → GPT chat
- Agent mode (`chat_gpt.agent_mode: true`) lets GPT call bot tools (radio, weather, search, etc.) autonomously; toggle off to revert to simple GPT
- `GptQuestion`/`GptChat` must be last `бот`-prefixed commands in registry — they match `бот <anything>`
- `chat_gpt.providers` holds API credentials; `chat_gpt.settings` holds named configs (`main`, `agent`, `embedder`) referencing providers
- `GptMaster.new(messages, setting: 'main')` resolves provider + model from settings; class methods `.chat`/`.ask` default to `setting: 'main'`
- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- `бот спой/сочини/запиши/сыграй <request>` creates a background task for Suno song generation; freeform requests are parsed by LLM to extract genre, artist, topic, and tags; the `compose_song` agent tool does the same
- Suno uses V5 model; tags are enriched via LLM — artist names are **never** included in tags (Suno blocks them), instead describe the sound characteristics
- `бот нарисуй/рисуй/картинку <request>` creates a background task for FLUX image generation; LLM generates English prompt with chat context and knowledge; the `generate_image` agent tool does the same
- `бот задачи` shows last 10 background tasks for the current chat
- FLUX API settings in `config/settings.yml` under `flux` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- Suno API settings in `config/settings.yml` under `suno` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- `ChatContext` module (`lib/chat_context.rb`) provides `get_chat_context` and `get_relevant_knowledge` — included by both `SunoTaskHandler` and `ImageGenTaskHandler`
