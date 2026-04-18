# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Always run `make test` before committing.** All tests must pass before creating a commit.
- **Never run `ruby lib/bot.rb` directly.** Use Docker in production; use `./bin/bot start/stop/restart` only for local non-Docker development.
- **Back up `db/bot.db` on prod only when the deploy includes a new migration.** Run `make backup` — code-only deploys don't need it. See `Backing up the prod DB` below for details.
- Always update all documents on changes.

---

## Running the Bot (Docker — production)

The bot runs as a Docker container managed by `docker compose`. The entrypoint runs DB migrations automatically on every start.

```bash
docker compose up -d --build   # build image and start (or restart after code changes)
docker compose logs -f         # tail logs
docker compose down            # stop
```

Logs are bind-mounted to `./log/bot.log` on the host — everything app-level goes in this single file. Per-chat lines are prefixed `[chat=<id>]` (agent turns add `[AGENT]`), so a single chat's timeline is greppable with `grep 'chat=-1001273...' log/bot.log`.

## Running the Bot (local, non-Docker)

```bash
./bin/bot start    # start daemon
./bin/bot stop     # stop daemon
./bin/bot restart  # restart daemon
./bin/bot status   # check if running
```

PID file: `pids/42fm_bot.pid`.

## Docker Setup

| File | Purpose |
|------|---------|
| `Dockerfile` | `ruby:4.0-slim` + `ffmpeg` + `opus-tools` + sqlite3/libxml2; installs gems, runs entrypoint |
| `docker-entrypoint.sh` | Runs `rake db:migrate` then execs `bundle exec ruby lib/bot.rb` as PID 1 |
| `docker-compose.yml` | `network_mode: host` + bind mounts for `db/`, `config/settings.yml` (ro), `log/`, and music library |
| `.env` | Gitignored host-local config: `DEPLOY_HOST` and `MUSIC_PATH` (see `.env.example`) |
| `.env.example` | Committed template documenting required `.env` variables |

**Volumes:**
- `./db` → `/app/db` — SQLite DB lives in the repo directory on the host; easy to back up and copy
- `./config/settings.yml` → `/app/config/settings.yml` (read-only bind mount — secrets)
- `./log` → `/app/log` — logs readable on host
- `${MUSIC_PATH:-/home/radio/content/music}` → `/home/radio/content/music` (read-only) — music library
- `web/` — ephemeral TTS scratch dir (created in image, not mounted; files deleted after each voice send)

## Deploying to Production

```bash
# From local machine (requires .env with DEPLOY_HOST set):
make deploy
# Equivalent to: ssh $DEPLOY_HOST 'cd ~/bot && git pull && docker compose up -d --build'
```

**First-time setup on a new server:**
```bash
git clone <repo> && cd 42fm_bot
cp /path/to/settings.yml config/settings.yml
cp .env.example .env   # edit DEPLOY_HOST and MUSIC_PATH as needed
docker compose up -d --build
docker compose logs -f
```

## Backing up the prod DB

```bash
make backup                    # keeps 5 newest snapshots on prod host (default)
make backup BACKUP_KEEP=10     # keep 10 newest
```

Runs [bin/backup.sh](bin/backup.sh) remotely via `ssh bash -exs`. Uses SQLite's online backup API (`sqlite3 db/bot.db ".backup db/bot.db.bak-<utc_ts>"`), so the snapshot is consistent **even in WAL mode under concurrent writes** — a plain `cp` would miss writes still sitting in the `-wal` file. The resulting `.bak` is a standalone SQLite DB; no `-wal` or `-shm` sidecars needed. After writing, it prunes older snapshots so only the most recent N remain.

**When to run:** before a deploy that includes a new migration under `db/migrate/`. Code-only deploys don't touch schema or data, so no backup.

**Restoring** (if a migration or deploy goes bad):
```bash
ssh $DEPLOY_HOST 'cd ~/bot && docker compose down && \
  cp db/bot.db.bak-<ts> db/bot.db && \
  git reset --hard <previous-sha> && docker compose up -d --build'
```

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
| Music search / song DB | `models/song.rb` + `lib/music_scanner.rb` + `rake music:scan` |
| Agent mode tools | `lib/agent/tools/*.rb` + `lib/agent/tool_registry.rb` + `lib/agent/runner.rb` |
| Background tasks | `lib/task_runner.rb` + `lib/task_handlers/*.rb` + `models/background_task.rb` |
| Suno song generation | `lib/suno_client.rb` + `lib/task_handlers/suno_handler.rb` + `lib/agent/tools/suno.rb` (agent-only, no direct command) |
| FLUX image generation | `lib/flux_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` (agent-only, no direct command) |
| Shared handler context | `lib/chat_context.rb` — `ChatContext` module (chat messages + knowledge for task handlers) |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |

## Services

`Radio` (Liquidsoap TCP socket, lazy connect), `Song` (music library with FTS5 search + Levenshtein fuzzy matching, populated by `MusicScanner`), `MusicScanner` (reads audio file tags via wahwah, populates songs DB), `GptMaster` (Anthropic/OpenAI-compatible, `.chat`/`.ask`/`.call_raw`), `Agent::Runner` (agentic tool-use loop over GptMaster), `Agent::ToolRegistry` (tool definitions for agent mode), `TaskRunner` (generic DB-backed background task poller + handler registry), `SunoClient` (Suno AI song generation API, V5 model), `FluxClient` (FLUX 2 image generation API via api.bfl.ai), `ChatContext` (shared module providing chat context + knowledge lookup for task handlers), `EmbeddingService` (OpenAI-compatible embeddings), `KnowledgeBase` (semantic RAG — store/search/auto-extract/compact facts), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope` (scraper), `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice` (game)

## DB Tables

| Table | Columns |
|-------|---------|
| `users` | `uid`, `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable), `chat_id`, `body`, `role` (`user`/`bot`), `message_id` (Telegram per-chat id, nullable for legacy rows), `reply_to_message_id` (nullable), `message_thread_id` (forum topic, nullable), `forwarded` (bool), `edited_at` (nullable) |
| `phrases` | `user_id`, `content` |
| `knowledge` | `topic`, `content`, `embedding` (JSON), `source` (`manual`/`auto`), `chat_id` |
| `knowledge_compact_log` | `chat_id`, `merged`, `removed`, `kept`, `threshold`, `created_at` — one row per compaction run |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |
| `songs` | `title`, `artist`, `album`, `genre`, `year`, `filepath` (unique, relative to music root), `duration`, `category` |
| `songs_fts` | FTS5 virtual table indexing `title`, `artist`, `album`, `genre`, `category` — `content='songs'`, `content_rowid='id'`, `unicode61 remove_diacritics 1` tokenizer; auto-synced via triggers |
| `api_usage` | `chat_id`, `user_uid` (nullable — null for background extractions), `model`, `purpose` (`agent`/`main_chat`/`translate`/`knowledge_extract`/`knowledge_compact`/`suno_lyrics`/`suno_tags`/`suno_parse`/`image_prompt`), `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_cents` (decimal 10,4), `created_at` — one row per LLM API response; feeds `бот затраты` |

## Gotchas

- Messages from non-whitelisted `chat_ids` are silently dropped in `lib/bot.rb`
- Messages older than 30s are skipped
- Voice messages only go to `audio_chat_ids`
- `new` role users are rate-limited on track requests (checks `user.last_order`)
- Google API keys are a pool in settings — `gogolmogol.rb` cycles through them
- `ffmpeg` and `opusenc` (from `opus-tools`) must be installed for TTS to work — both are included in the Docker image
- Radio TCP socket is lazy — connects on first use, not at startup
- In Docker, `restart: unless-stopped` handles crashes; the bot's own rescue/retry loop also retries within the process. The `daemons` gem is only used for local non-Docker runs via `./bin/bot`.
- `network_mode: host` is required so the container can reach Liquidsoap on `localhost:1234` (the radio telnet interface). Without it, `localhost` resolves to the container itself and the connection is refused. Since the bot exposes no inbound ports, host networking has no downside here.
- SOCKS proxy (if enabled) patches `Net::HTTP` globally via `socksify` — applies to all outbound HTTP
- GPT bot replies are stored in `messages` with `role: 'bot'`, `user_uid: nil`. Persistence happens in `MessageResponder#deliver` **after** `MessageSender#send` returns, so Telegram's `message_id` is captured for the row. Commands opt in via `CommandResult.text(..., persist_as_bot_reply: true)`.
- Chat context JSON (`get_chat_context`) carries `id` (Telegram `message_id`), optional `reply_to`, `thread`, `fwd`, `edited`. When a reply target falls outside the 50-msg window, the helper fetches that one row from DB and prepends it. The `load_messages` agent tool lets the agent pull a wider window around any anchor `message_id`.
- Forum topics: if the triggering message has `message_thread_id`, the bot's reply is sent with the same `message_thread_id` (lands in the user's topic, not General), and context is scoped to same-thread messages.
- Edited messages: Telegram delivers edits via the same `Message` class with `edit_date` set. `save_message` updates the existing row in place (body + `edited_at`) and `respond` short-circuits dispatch — edits don't re-fire commands.
- `Settings` deep-merges `settings.common.yml` (defaults) + `settings.yml` (secrets/overrides); add new top-level groups to `REQUIRED_KEYS` in `lib/settings.rb`
- To change prompts, models, or non-secret config — edit `config/settings.common.yml` (committed). For API keys — edit `config/settings.yml` (gitignored)
- Knowledge auto-extraction runs in a background Thread every `knowledge.extract_every` messages per chat
- Embeddings deduplication threshold is 0.92 cosine similarity — near-duplicate facts are not stored
- Knowledge auto-compaction (`KnowledgeBase.compact!`) clusters near-dupes via stored embeddings (no API calls) and LLM-merges each cluster; triggered as a `knowledge_compact` background task when count >= adaptive threshold (`compact_at` × factor based on last run's avg cluster size); logs to `log/knowledge_compact.log`; history in `knowledge_compact_log` table
- `бот сожми знания` (admin only) triggers compaction immediately for the current chat
- `бот найди/ищи/пошукай` → Google search; bare `бот <text>` → GPT chat
- Agent mode is the only mode: `GptChat` / `GptQuestion` always route through `Agent::Runner`, which lets GPT call bot tools (radio, weather, search, etc.) autonomously. Agent supports vision — replying to a photo with "бот ..." sends the image to Claude for recognition.
- `GptChat` must be last `бот`-prefixed command in registry — it matches `бот <anything>`
- `chat_gpt.providers` holds API credentials; `chat_gpt.settings` holds named configs (`main`, `agent`, `embedder`) referencing providers
- `GptMaster.new(messages, setting: 'main', chat_id:, purpose:, system_prompt:)` resolves provider + model from settings; class method `.ask` defaults to `setting: 'main'` (used by translate, knowledge, suno lyrics, image prompt); `chat_id` + `purpose` feed the `api_usage` table (telemetry is fire-and-forget — errors logged, never propagated)
- **Prompt caching:** the `agent_prompt` template in `settings.common.yml` contains a `{CACHE_BREAK}` marker. Everything before it is sent as the Anthropic `system` param with `cache_control: { type: 'ephemeral' }`; everything after is the dynamic user message. Agent tools also get `cache_control` on the last tool in the array. Second+ calls within 5 min hit the cache (`cache_read_tokens > 0`, much cheaper input). OpenAI-compatible providers auto-cache; the split is harmless for them.
- `chat_gpt.pricing` (in `settings.common.yml`) maps exact model id → `input`/`output`/`cache_read`/`cache_write` in USD per 1M tokens. `ApiUsage.compute_cost(model, usage)` returns cents as `BigDecimal`. Unknown models → row with `cost_cents = 0` + warn log
- `бот затраты` / `бот расходы` / `бот cost` (admin-only) prints a Markdown digest of API costs broken down by purpose for today / 7d / 30d, plus top-5 spenders per window in the current chat, and global totals
- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- Suno song generation is agent-only — the `compose_song` agent tool creates a `suno_generate` background task (no direct `бот спой` command). Suno returns 2 clip variants; both are downloaded, named as `Performer_-_Song_Name.mp3`, and sent as a media group. Lyrics follow as a reply.
- Suno uses V5 model; tags are enriched via LLM — artist names are **never** included in tags (Suno blocks them), instead describe the sound characteristics
- FLUX image generation is agent-only — the `generate_image` agent tool creates an `image_generate` background task (no direct `бот нарисуй` command). LLM generates English prompt with chat context and knowledge.
- `бот задачи` shows last 10 background tasks for the current chat
- FLUX API settings in `config/settings.yml` under `flux` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- Suno API settings in `config/settings.yml` under `suno` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- `ChatContext` module (`lib/chat_context.rb`) is the single source of truth for chat context and knowledge lookup — included by task handlers directly and by `GptHelpers` (which delegates via `super` with auto-passed `chat_id`)
- Admin-only commands use `return admin_denied unless admin?` from `Commands::Base`; agent tools check `@user.role` — both pull denial messages from `Settings.replies['admin_denied']` in `settings.common.yml`
- Radio search uses `Song.search` (multi-stage: FTS5 → Cyrillic→Latin transliteration with k/c variants → prefix truncation → LIKE → Levenshtein editdist); `radio.request` flow is unchanged
- `Song.search` uses FTS5 prefix matching (`word*`) with `unicode61 remove_diacritics 1` tokenizer; Cyrillic input triggers transliteration chain (Stages 1–4); Stage 1 variants include k/c, ts/c, kh/h, and w/v (в→w in translit but v in English proper nouns, e.g. "нирвана"→"nirwana"→"nirvana"); Stage 4 uses a custom `editdist` SQLite function registered by `DatabaseConnector.register_editdist` — catches e.g. "раммштайн"→Rammstein (distance 3)
- `MusicScanner` reads tags via `wahwah` (pure Ruby), falls back to parsing artist/title from filepath; run `bundle exec rake music:scan` to populate/refresh
- `Settings.radio['path']` (music directory root, used by MusicScanner inside the container) and `Settings.radio['source']` (Liquidsoap source name, e.g. `42fm_radio_station`) are in `settings.common.yml`; `Song#absolute_path` joins `host_path` (if set) or `path` + relative `filepath` — set `radio.host_path` in `settings.yml` when Liquidsoap sees a different path than the container (e.g. `/content/music` vs `/home/radio/content/music`)
- `wahwah` gem is pure Ruby — no native dependencies needed for audio tag reading
