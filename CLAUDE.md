# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Always run `make test` before committing.** All tests must pass before creating a commit.
- **Never run `ruby lib/bot.rb` directly.** Use Docker in production; use `./bin/bot start/stop/restart` only for local non-Docker development.
- **Back up `db/bot.db` on prod only when the deploy includes a new migration.** Run `make backup` — code-only deploys don't need it. See `Backing up the prod DB` below for details.
- **Never `scp config/settings.yml` to prod.** Local and prod copies intentionally diverge (e.g. `proxy` is enabled only on prod). To change prod settings, ssh in and edit in place, or hand the user the exact diff to apply.
- **In plan mode, run the `plan-reviewer` agent (via the Task tool) on the plan file before calling ExitPlanMode.** Then **report the reviewer's findings to the user verbatim** before applying any patches. Wait for the user to decide which findings to act on — do not auto-apply. Only after the user has seen the findings (and you've patched what they agreed to) should you call ExitPlanMode. Manual ad-hoc reviews of older plans: `/review-plan <path>`.
- **For substantive code changes (new features, multi-file refactors), invoke the `code-reviewer` agent before commit.** Same workflow as `plan-reviewer`: report findings to the user verbatim, wait for their call, then patch and commit. Skip for trivial edits (typos, single-line fixes). Manual ad-hoc reviews: `/review-code [path]` (defaults to staged or branch diff). The reviewer uses Ruby LSP for symbol/caller resolution.
- Always update all documents on changes.

---

## Running the Bot (Docker — production)

The bot runs as a Docker container managed by `docker compose`. The entrypoint runs DB migrations automatically on every start.

```bash
docker compose up -d --build   # build image and start (or restart after code changes)
docker compose logs -f         # tail logs
docker compose down            # stop
```

Logs are bind-mounted to `./log/` on the host. Three files:
- **`bot.log`** — app output, one line per event. Per-chat lines are prefixed `[chat=<id>]` (agent turns add `[AGENT]`). A single chat's timeline is greppable with `grep 'chat=-1001273...' log/bot.log`.
- **`gpt.log`** — NDJSON dump of every LLM request+response (system prompt, messages, tools, raw response, stop_reason, usage). One JSON object per line, rotation 5×50MB. Useful for reconstructing exactly what the model saw and said when debugging odd replies. Query with `jq`, e.g. `jq 'select(.chat==-1001273623296 and .purpose=="agent")' log/gpt.log`. Disable via `Settings.chat_gpt['debug_log'] = false`.
- **`knowledge_compact.log`** — per-run knowledge-compaction traces.

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
| Suno add-vocals (sing along user audio) | `lib/agent/tools/add_vocals.rb` → `suno_add_vocals` task (handled by `SunoTaskHandler`); 1 clip output |
| Suno upload-cover (musical cover) | `lib/agent/tools/cover_audio.rb` → `suno_cover_audio` task (handled by `SunoTaskHandler`); 2 clip output. Tool exposes `lyrics` (verbatim → custom-mode) + `topic` (auto-gen seed → non-custom-mode). `SunoTaskHandler#resolve_cover_prompt` maps them onto Suno's `customMode`+`prompt` pair; fallback chain: lyrics → topic → title. Split exists because Suno sings `prompt` verbatim under custom-mode and the agent was putting style descriptions there. |
| Suno cover-art (album images) | `lib/agent/tools/cover_art.rb` → `suno_cover_art` task → `lib/task_handlers/suno_cover_art_handler.rb`; 2 PNG output via sendMediaGroup |
| Suno WAV-export (mp3 → wav) | `lib/agent/tools/convert_to_wav.rb` → `suno_wav_convert` task → `lib/task_handlers/suno_wav_convert_handler.rb`; uses `/api/v1/wav/{generate,record-info}`. Re-fetches the source's `record-info` to map clip_index → audioId (we don't persist clip ids in `result`). Sent as Telegram audio so the user can play AND download. |
| Shared media download | `lib/media_download.rb` — `MediaDownload` module included by both Suno handlers (download URL → Tempfile) |
| Image generation (FLUX / Atlas Cloud) | `lib/image_gen/*.rb` + `lib/atlas_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` (agent-only, no direct command). `ImageGen.current_adapter` picks `FluxAdapter` or `AtlasAdapter` based on `Settings.image_gen['provider']`. |
| Shared handler context | `lib/chat_context.rb` — `ChatContext` module (chat messages + knowledge for task handlers) |
| Agent scratchpad | `lib/agent/scratchpad.rb` + `models/chat_state.rb` + `lib/agent/tools/scratchpad.rb` (`remember`/`forget` tools); auto-rendered as `{SCRATCHPAD}` in agent_prompt template |
| Agent event handler | `lib/task_handlers/agent_event_handler.rb` + `lib/task_handlers/agent_event_emitter.rb` mixin. Reacts to image_gen/suno outcomes; rate-limited at 10/hour/chat. |
| Time-deferred intentions | `lib/cron_scheduler.rb` (60s tick) + `Agent::Scratchpad.due_intentions` / `mark_acted`. Started from `lib/bot.rb`. |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |
| Admin menu (super-admin only) | `lib/admin_menu/*.rb` + `lib/commands/admin_menu_open.rb` + `lib/bot_dispatcher.rb`. `/admin` or `бот меню` in private chat from a super-admin opens an inline-keyboard menu to manage authorized chats, per-chat rate limits, and global `users.role`. |

## Services

`Radio` (Liquidsoap TCP socket, lazy connect), `Song` (music library with FTS5 search + Levenshtein fuzzy matching, populated by `MusicScanner`), `MusicScanner` (reads audio file tags via wahwah, populates songs DB), `GptMaster` (Anthropic/OpenAI-compatible, `.chat`/`.ask`/`.call_raw`), `Agent::Runner` (agentic tool-use loop over GptMaster), `Agent::ToolRegistry` (tool definitions for agent mode), `TaskRunner` (generic DB-backed background task poller + handler registry), `SunoClient` (Suno AI song generation API, V5 model), `ImageGen::FluxAdapter` (FLUX 2 image generation via api.bfl.ai), `ImageGen::AtlasAdapter` (Atlas Cloud image generation, default model Wan 2.7), `AtlasClient` (generic Atlas Cloud HTTP client; reusable for future Atlas-backed services like LLM/embeddings/video), `ChatContext` (shared module providing chat context + knowledge lookup for task handlers), `EmbeddingService` (OpenAI-compatible embeddings), `KnowledgeBase` (semantic RAG — store/search/auto-extract/compact facts), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope` (scraper), `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice` (game)

## DB Tables

| Table | Columns |
|-------|---------|
| `chats` | `chat_id` (PK, bigint = Telegram chat id), `title`, `chat_type` (`group`/`supergroup`/`private`/`channel`), `authorized` (bool), `audio` (bool), `rate_limits` (JSON), `first_seen_at`, `last_seen_at`. Populated at startup from `Settings.auth['chats']` (`Chat.sync_from_config!`) and on every incoming message (`Chat.touch_seen`). `Chat` has_one :chat_state, has_many :messages/:background_tasks/:api_usages/:knowledge_facts. |
| `users` | `uid`, `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable), `chat_id`, `body`, `role` (`user`/`bot`), `message_id` (Telegram per-chat id, nullable for legacy rows), `reply_to_message_id` (nullable), `message_thread_id` (forum topic, nullable), `forwarded` (bool), `edited_at` (nullable), `bg_task_external_id` (nullable — populated for bot-delivered media so `cover_art` can resolve a reply-target back to its source song), `attachment_file_id` + `attachment_mime_type` + `attachment_title` + `attachment_performer` + `attachment_duration` (nullable — populated when an incoming user message has audio/voice/audio-MIME document; title falls back to `Document.file_name` minus extension when ID3 title is absent. Used by `Commands::GptChat#attached_audio` lookback and surfaced in `ChatContext.serialize_msg` as `audio: true` + `audio_meta: {title, performer, duration, mime}` so the agent names cover/add-vocals output after the actual track instead of inferring from prior chat context). Audio-only messages (no text caption) are persisted with body=`'[аудио]'` so they appear in chat context. |
| `phrases` | `user_id`, `content` |
| `knowledge` | `topic`, `content`, `embedding` (JSON), `source` (`manual`/`auto`), `chat_id` |
| `knowledge_compact_log` | `chat_id`, `merged`, `removed`, `kept`, `threshold`, `created_at` — one row per compaction run |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |
| `songs` | `title`, `artist`, `album`, `genre`, `year`, `filepath` (unique, relative to music root), `duration`, `category` |
| `songs_fts` | FTS5 virtual table indexing `title`, `artist`, `album`, `genre`, `category` — `content='songs'`, `content_rowid='id'`, `unicode61 remove_diacritics 1` tokenizer; auto-synced via triggers |
| `api_usage` | `chat_id`, `user_uid` (nullable — null for background extractions), `model`, `purpose` (`agent`/`main_chat`/`translate`/`knowledge_extract`/`knowledge_compact`/`suno_lyrics`/`suno_tags`/`suno_parse`/`image_prompt`), `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_cents` (decimal 10,4), `created_at` — one row per LLM API response; feeds `бот затраты` |
| `chat_states` | `chat_id` (PK), `scratchpad` (JSON), `updated_at` — agent's per-chat working memory (intentions/notes/expectations); read at every agent turn; written via `remember`/`forget` tools. See ADR-003. |

## Gotchas

- **Per-role rate limits** — `Settings.auth['rate_limits']['admin'][service]` overrides the regular bucket when `RateLimiter.exceeded?(..., role: 'admin')` is called with `role: 'admin'`. Tools pass `ctx[:user]&.role`. Counters stay per-chat-shared (no per-user counter), so an admin's higher cap simply lets them keep acting after regular users have hit theirs. Priority: `auth.rate_limits.admin.<svc>` → `chat.rate_limits.<svc>` (per-chat menu edits) → `auth.rate_limits.<svc>` (default) → hard-coded `{max: 1, window: 20}`.
- **Telegram update dispatch** — `bot.listen` (gem 2.7.0) yields `update.current_message` directly (the inner `Message` / `CallbackQuery` / `EditedMessage` / etc.), NOT the wrapper `Update`. `BotDispatcher.dispatch` (`lib/bot_dispatcher.rb`) does `case update when Message ... when CallbackQuery ... else log` — anything else is silently logged as ignored. Add new `when` branches there to handle additional update types.
- **Super-admin (`Settings.auth['super_admin_uids']`)** — list of Telegram UIDs that get `/admin` menu access. Set in `config/settings.yml` (gitignored), NOT `settings.common.yml`. Empty list = no super-admins (fail-closed). Distinct from `users.role == 'admin'`: super-admin is the menu-gating list (settings-driven, almost-never-changes), `admin` role is the per-command gate (DB-driven, mutable via menu). At startup `AdminMenu.register_commands` calls `setMyCommands` scoped per super-admin uid so `/admin` shows in their Telegram menu button (the "/" icon next to the input field) — no need to remember the slash command.
- **Super-admin private-chat implicit authorization** — `BotDispatcher#authorized?` short-circuits the `Chat.where(authorized: true)` allowlist for super-admins in private chat. This makes `/admin` work on first deploy without pre-seeding a `chats` row, AND prevents the menu from creating an unrecoverable lock-out. Two further guards in `AdminMenu::CallbackHandler#perform_mutation`: refuse to deauthorize a chat whose `chat_id == any super_admin_uid`; refuse to demote a super-admin's `users.role`.
- **Admin menu `awaiting_input` early-exit** — `MessageResponder#maybe_handle_admin_input` intercepts plain-text from super-admin in private chat ONLY when `AdminMenu::Session.awaiting_input?(uid)` is true. `Session.awaiting_input?` has a built-in 5-min TTL — stale sessions auto-clear on access. `TextInputHandler` itself bypasses on `/cancel` keyword, on any `/`-prefixed slash command, and on `бот`/`жпт`/`балаболь`-prefixed agent triggers — so normal bot use is never locked out by a dangling session.
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
- Agent scratchpad (`Agent::Scratchpad`, `chat_states` table) is per-chat working memory distinct from the knowledge base — knowledge = facts about the world, scratchpad = agent's own intentions/expectations/notes. Three categories: `intentions`, `notes`, `expectations`. Hard cap 6000 chars (~1500 tokens) with FIFO eviction from the largest category. Rendered as `{SCRATCHPAD}` placeholder in `agent_prompt`. Agent manages it via `remember`/`forget` tools. See ADR-003 for the full architecture rationale.
- Agent event loop (`agent_event` task type, `AgentEventHandler`, `AgentEventEmitter` mixin): when image_gen / suno tasks hit interesting outcomes (failure after retries, success after retries), the handler emits an `agent_event` BackgroundTask. Handler runs `Agent::Runner` with synthetic `[СЛУЖЕБНОЕ СОБЫТИЕ]` text describing what happened, agent decides whether to comment, retry via tools, or `(skip)`. Per-chat rate limit: 10 emits per rolling hour. Loop protection: only image_gen/suno emit; agent_event itself doesn't (single-hop). See ADR-003 PR-2.
- `Agent::ToolResult` — structured tool-result protocol. Tool handlers may return either a String (passthrough) or `Agent::ToolResult.deferred(user_text:, intent:, retry_in_min:)` for rate-limited / retry-later outcomes. `Agent::Runner` auto-writes the intent to the chat's scratchpad on `:deferred` (with `due_at = now + retry_in_min`) and forwards a `[deferred retry_in=Nmin, intent saved to scratchpad] <user_text>` prefix to the LLM. New deferred-style tools just call `Agent::ToolResult.deferred(...)` — no per-tool prompt scaffolding required.
- `CronScheduler` (`lib/cron_scheduler.rb`) — thread that wakes every 60s, finds chats with scratchpad intentions whose `due_at` has passed, emits one `agent_event(cron_tick)` per chat carrying the due intent ids. Marks them `acted: true` so the next tick doesn't re-dispatch. Subject to the same per-chat 10/hour `agent_event` rate cap. Lets the agent act on time-deferred intentions (e.g. retry a rate-limited image after the cooldown). Started from `lib/bot.rb` alongside `TaskRunner.start`.
- Scratchpad compaction (`Agent::Scratchpad.compact(chat_id, max_age_days:)`): pure-Ruby pruning of entries past `expires_at` plus entries older than `max_age_days` (default 30). Also runs inline on every `Scratchpad.add` for expiry-based pruning. Manual run: `rake scratchpad:compact [MAX_AGE_DAYS=N] [CHAT_ID=...]`. No LLM calls — at the 6000-char cap, semantic compaction isn't worth the cost.
- `бот сожми знания` (admin only) triggers compaction immediately for the current chat
- All `бот <text>` requests — including search, images, gifs, horoscope — route through `GptChat` → `Agent::Runner`. The agent's `google_search` / `horoscope` / `generate_image` tools handle those intents and can compose multiple tools in one turn (e.g. "бот найди новости и нарисуй" → `google_search` then `generate_image`). There are no direct-dispatch commands for search or horoscope anymore.
- Agent mode is the only mode: `GptChat` / `GptQuestion` always route through `Agent::Runner`, which lets GPT call bot tools (radio, weather, search, etc.) autonomously. Agent supports vision — replying to a photo with "бот ..." sends the image to Claude for recognition.
- `GptChat` must be last `бот`-prefixed command in registry — it matches `бот <anything>`
- `chat_gpt.providers` holds API credentials; `chat_gpt.settings` holds named configs (`agent`, `agent_vision`, `knowledge`, `lyrics`, `embedder`) referencing providers
- `GptMaster.new(messages, setting:, chat_id:, purpose:, system_prompt:)` resolves provider + model from settings; the `setting:` kwarg picks one of the named blocks under `chat_gpt.settings`. **Every consumer must pass `setting:` explicitly.** The kwarg default is still `'main'` but `main` is no longer defined — any forgotten caller fails loudly with `Unknown chat_gpt setting: main` rather than silently picking a model. Active settings: `agent` (Agent::Runner tool loop, image-gen prompt enrichment, suno tags/parsing — text only, no vision; default DeepSeek V4 Pro), `agent_vision` (Agent::Runner picks this automatically when an image is attached, also used by ImageGenTaskHandler for image-edit prompt enrichment — grok-4-fast-reasoning via xAI; chosen over Anthropic for less aggressive content filtering on named-people image descriptions, and over the non-reasoning Grok variant because reasoning follows tool-call instructions more reliably — the non-reasoning model occasionally hallucinated `🎨 <caption>` image replies as text instead of invoking generate_image), `knowledge` (KnowledgeBase extract + compact, background frequent), `lyrics` (suno_handler song lyrics generation — long-form creative text-out), `embedder` (text→vector, used by KnowledgeBase + EmbeddingService). `chat_id` + `purpose` feed the `api_usage` table (telemetry is fire-and-forget — errors logged, never propagated)
- **Prompt caching:** the `agent_prompt` template in `settings.common.yml` contains a `{CACHE_BREAK}` marker. Everything before it is sent as the Anthropic `system` param with `cache_control: { type: 'ephemeral' }`; everything after is the dynamic user message. Agent tools also get `cache_control` on the last tool in the array. Second+ calls within 5 min hit the cache (`cache_read_tokens > 0`, much cheaper input). OpenAI-compatible providers auto-cache; the split is harmless for them.
- `chat_gpt.pricing` (in `settings.common.yml`) maps exact model id → `input`/`output`/`cache_read`/`cache_write` in USD per 1M tokens. `ApiUsage.compute_cost(model, usage)` returns cents as `BigDecimal`. Unknown models → row with `cost_cents = 0` + warn log
- `бот затраты` / `бот расходы` / `бот cost` (admin-only) prints a Markdown digest of API costs broken down by purpose for today / 7d / 30d, plus top-5 spenders per window in the current chat, and global totals
- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- Suno song generation is agent-only — the `compose_song` agent tool creates a `suno_generate` background task (no direct `бот спой` command). Suno returns 2 clip variants; both are downloaded, named as `Performer_-_Song_Name.mp3`, and sent as a media group. Lyrics follow as a reply. For `compose_song` the lyrics are the locally-composed `params['lyrics']`; for `add_vocals` / `cover_audio` (which don't compose locally) the fallback is `clips.first[:lyrics]`, mapped from Suno's `response.sunoData[].prompt` field by `SunoClient#poll_once` (`SunoTaskHandler#resolve_delivery_lyrics` picks between them).
- Suno uses V5 model; tags are enriched via LLM — artist names are **never** included in tags (Suno blocks them), instead describe the sound characteristics
- **Suno add-vocals / cover-audio / cover-art** — three additional agent tools layered on Suno: `add_vocals` (sing AI vocals over user-provided audio, 1 clip), `cover_audio` (musical cover/re-style of user-provided audio, 2 clips), `cover_art` (2 album-art PNGs for an existing Suno song). Audio inputs come from Telegram attachments (`message.audio` / `message.voice` / `message.document` with `audio/*` MIME — `attached_audio` helper in `lib/commands/gpt_chat.rb`) OR from agent-supplied URLs. `attached_audio` priority chain: (1) current message; (2) reply-target message; (3) most recent attachment within the last 20 messages of the chat (DB lookback via `messages.attachment_file_id`). The lookback covers the "user uploaded an audio earlier, then asked for a cover in a fresh message without using Telegram-reply" case. `ChatContext.serialize_msg` adds `audio: true` to context entries so the agent sees which past messages have an attachment. The Telegram file URL contains the bot token; sending it to Suno leaks the token to Suno's logs — pre-existing risk profile (the bot already exposes that URL to chat for voice messages); rotate via @BotFather if needed.
- **`cover_audio` lyrics-vs-topic split** (replaces former single `prompt` arg): the `/api/v1/generate/upload-cover` endpoint takes a `customMode` flag + a `prompt` field whose meaning depends on mode — `customMode: true` sings `prompt` verbatim as lyrics (≤5000 chars on V5); `customMode: false` treats `prompt` as a "core idea" theme and Suno auto-generates fresh lyrics from it (≤500 chars). Suno does NOT preserve the original mp3's lyrics in either mode. The previous schema hardcoded `customMode: true` and exposed one `prompt` arg, so the agent — guided by a "тема/настроение/текст" description — would put style descriptions ("Hungarian prog-rock 80s") in `prompt` and Suno literally sang those words. Tool now exposes two explicit args: `lyrics` (verbatim user-provided text → custom mode) and `topic` (short Russian theme phrase → auto mode). When the source audio is a previously-bot-generated Suno song, the agent is instructed to copy the original lyrics from chat context (the `[песня: ...]` row + the bot's lyrics reply right after) into `lyrics`, applying any user-requested edits — letting "сделай этот трек в стиле джаза" reuse lyrics rather than auto-gen new ones. `SunoTaskHandler#resolve_cover_prompt` resolves the `[lyrics, topic, title]` chain into Suno's `(customMode, prompt)` pair (with topic truncated to 500 chars). Legacy in-flight tasks with only `prompt` get treated as topic for back-compat.
- **Combined "song + cover art" requests** — all three song-producing tools (`compose_song`, `add_vocals`, `cover_audio`) accept `with_cover_art: true`. After the song's `:done` polling, `SunoTaskHandler#maybe_chain_cover_art` enqueues a chained `suno_cover_art` task pointing at the just-completed song's `external_id`. Dedup via `json_extract(params, '$.source_task_id')` lookup. Charged against the `'suno'` rate-limit bucket (RateLimiter now counts all `suno_*` task types); silently dropped at chain time if the bucket is exhausted.
- Suno cover-art uses a separate handler (`SunoCoverArtHandler`) since its output is images, not audio; polls via `SunoClient#poll_cover_art_once` against a **different endpoint** (`/api/v1/suno/cover/record-info`, not `/api/v1/generate/record-info` — they're separate ID spaces) with a different response shape (`successFlag`, `response.images`, `errorCode`/`errorMessage`). Failures emit `cover_art_failed` agent_event so the agent can comment.
- Suno WAV export (`convert_to_wav` agent tool, `suno_wav_convert` task type, `SunoWavConvertHandler`) uses yet another endpoint pair: `POST /api/v1/wav/generate` (requires both `taskId` AND `audioId` — the per-clip id from `response.sunoData[].id`, NOT the song's task id) + `GET /api/v1/wav/record-info`. `successFlag` enum: `PENDING` / `SUCCESS` / `CREATE_TASK_FAILED` / `GENERATE_WAV_FAILED` / `CALLBACK_EXCEPTION`. Source resolution mirrors `cover_art` (explicit `suno_task_id` → reply target's `bg_task_external_id` → most recent done song). `clip_index` (1 or 2, default 1) picks which of the two Suno clips to convert; the handler re-fetches the source's `record-info` via `SunoClient#fetch_audio_ids` to map clip_index → audioId since we don't persist clip ids in `BackgroundTask.result`. Output sent as Telegram audio (`sendAudio`) named `Performer_-_Title.wav`.
- **`cover_art` source resolution** — chain: (1) explicit `args['suno_task_id']`; (2) `ctx[:reply_to_message_id]` → `Message.bg_task_external_id` (populated by both Suno handlers when persisting bot media rows); (3) most recent `done` task in chat across `suno_generate` / `suno_add_vocals` / `suno_cover_audio`. The reply-target resolution is what makes "бот, нарисуй обложку" work correctly when the user replies to a specific bot song instead of the latest one.
- Image generation is agent-only — the `generate_image` agent tool creates an `image_generate` background task (no direct `бот нарисуй` command). The handler's prompt-enrichment LLM step uses the active adapter's `prompt_template(:text_to_image|:edit)`.
- **Image-gen adapter dispatch** — `Settings.image_gen['provider']` selects the active backend (`'flux'` | `'atlas'`). `ImageGen.current_adapter` is read on submit; the chosen `adapter.name` is snapshotted into `task.params['provider']`. `ImageGen.adapter_for(provider)` is read on poll, so a config flip (e.g. `docker compose up -d --build` mid-flight) doesn't reroute polling to a different prediction id space — old tasks continue against the original backend, new tasks go to the new one.
- **`AtlasClient`** (`lib/atlas_client.rb`) — generic Atlas Cloud HTTP client (`POST` raises on non-2xx; `GET` returns `[code, body]` and swallows transient SSL/timeout). Constructor takes a config dict + `tag:` for greppable logs (`AtlasLLM`/`AtlasEmbed`/etc.). Reusable by future Atlas-backed services beyond image gen.
- **Image-gen settings** in `config/settings.common.yml` under `image_gen:` block (`provider` + `providers.atlas` + `providers.flux`); api_keys in `config/settings.yml`. `FluxAdapter` has a one-release back-compat shim that reads top-level `Settings.flux` if `image_gen.providers.flux` is missing — removed once prod settings.yml is migrated.
- `бот задачи` shows last 10 background tasks for the current chat
- FLUX API settings: top-level `flux:` block in `settings.yml`/`settings.common.yml` is the legacy location read by FluxAdapter's back-compat shim. New canonical location is `image_gen.providers.flux.{api_url,api_key,model}`.
- Suno API settings in `config/settings.yml` under `suno` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- `ChatContext` module (`lib/chat_context.rb`) is the single source of truth for chat context and knowledge lookup — included by task handlers directly and by `GptHelpers` (which delegates via `super` with auto-passed `chat_id`)
- Admin-only commands use `return admin_denied unless admin?` from `Commands::Base`; agent tools check `@user.role` — both pull denial messages from `Settings.replies['admin_denied']` in `settings.common.yml`
- Radio search uses `Song.search` (multi-stage: FTS5 → Cyrillic→Latin transliteration with k/c variants → prefix truncation → LIKE → Levenshtein editdist); `radio.request` flow is unchanged
- `Song.search` uses FTS5 prefix matching (`word*`) with `unicode61 remove_diacritics 1` tokenizer; Cyrillic input triggers transliteration chain (Stages 1–4); Stage 1 variants include k/c, ts/c, kh/h, and w/v (в→w in translit but v in English proper nouns, e.g. "нирвана"→"nirwana"→"nirvana"); Stage 4 uses a custom `editdist` SQLite function registered by `DatabaseConnector.register_editdist` — catches e.g. "раммштайн"→Rammstein (distance 3)
- `MusicScanner` reads tags via `wahwah` (pure Ruby), falls back to parsing artist/title from filepath; run `bundle exec rake music:scan` to populate/refresh
- `Settings.radio['path']` (music directory root, used by MusicScanner inside the container) and `Settings.radio['source']` (Liquidsoap source name, e.g. `42fm_radio_station`) are in `settings.common.yml`; `Song#absolute_path` joins `host_path` (if set) or `path` + relative `filepath` — set `radio.host_path` in `settings.yml` when Liquidsoap sees a different path than the container (e.g. `/content/music` vs `/home/radio/content/music`)
- `wahwah` gem is pure Ruby — no native dependencies needed for audio tag reading
