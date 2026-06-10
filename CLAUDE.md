# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md` | User-facing feature guide (RU): `docs/user/README.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Never deploy or push without explicit user permission in the current turn.** Includes `make deploy`, `git push`, and `ssh ... docker compose up`. Authorization does not carry over from a prior turn — re-confirm every time. `.claude/hooks/deploy_guard.sh` (PreToolUse Bash hook) emits `permissionDecision: "ask"` on every match, routing the call through Claude Code's permission prompt; the user must approve each invocation explicitly.
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

`make backup` (defaults to 5 retained snapshots; `BACKUP_KEEP=N` to override). Uses SQLite's online backup API so it's consistent under concurrent writes. Full procedure + restore playbook: `docs/architecture.md#operations`.

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
| Suno upload-cover (musical cover) | `lib/agent/tools/cover_audio.rb` → `suno_cover_audio` task (handled by `SunoTaskHandler`); 2 clip output. Lyrics/topic split + resolution chain: see `cover_audio` gotcha below. |
| Suno cover-art (album images) | `lib/agent/tools/cover_art.rb` → `suno_cover_art` task → `lib/task_handlers/suno_cover_art_handler.rb`; 2 PNG output via sendMediaGroup |
| Suno WAV-export (mp3 → wav) | `lib/agent/tools/convert_to_wav.rb` → `suno_wav_convert` task → `lib/task_handlers/suno_wav_convert_handler.rb`; sent as Telegram audio so user can play AND download. |
| Shared media download | `lib/media_download.rb` — `MediaDownload` module included by both Suno handlers (download URL → Tempfile) |
| Image generation (FLUX / Atlas Cloud / CloseRouter Nano Banana Pro) | `lib/image_gen/*.rb` + `lib/model_provider_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` (agent-only, no direct command). |
| Shared handler context | `lib/chat_context.rb` — `ChatContext` module (chat messages + knowledge for task handlers) |
| Agent views historical images | `lib/agent/tools/view_image.rb` (tool) + `lib/telegram_file.rb#download_image` (shared download) + `Agent::Runner#inject_pending_images` (vision injection + `agent_vision` upgrade) + `lib/message_responder.rb#photo_attachment_file_id` (persistence) |
| Agent scratchpad | `lib/agent/scratchpad.rb` + `models/chat_state.rb` + `lib/agent/tools/scratchpad.rb` (`remember`/`forget` tools); auto-rendered as `{SCRATCHPAD}` in agent_prompt template |
| Agent event handler | `lib/task_handlers/agent_event_handler.rb` + `lib/task_handlers/agent_event_emitter.rb` mixin. Reacts to image_gen/suno outcomes; rate-limited at 10/hour/chat. |
| Time-deferred intentions | `lib/cron_scheduler.rb` (60s tick) + `Agent::Scratchpad.due_intentions` / `mark_acted`. Started from `lib/bot.rb`. |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |
| Admin menu (super-admin only) | `lib/admin_menu/*.rb` + `lib/commands/admin_menu_open.rb` + `lib/bot_dispatcher.rb`. `/admin` or `бот меню` in private chat from a super-admin opens an inline-keyboard menu to manage authorized chats, per-chat rate limits, and global `users.role`. |
| Telegram reactions capture | `lib/bot.rb` (`ALLOWED_UPDATES`) + `lib/bot_dispatcher.rb` (`handle_reaction` / `handle_reaction_count` / `reaction_authorized?`) + `messages.reactions_count` + `Message.top_reacted(scope:)` |
| Rules-war game | `lib/agent/scratchpad.rb` (rules store API) + `lib/agent/tools/rules.rb` (`set_rule`/`repeal_rule`/`challenge_rule`/`court_rule`) + `lib/commands/rules.rb` (`бот правила` lister) + `lib/task_handlers/rule_obituary_handler.rb` + `lib/cron_scheduler.rb` (`maybe_announce_expired_rules`) |
| Auto-awards (🏆 images) | `lib/agent/tools/award.rb` (`make_award`) → `image_generate` task with `award: true`; caption via `ImageGenTaskHandler#caption_for` (shared by sync + async delivery) |
| Quote of the day | `lib/commands/quote.rb` (`бот цитата`) — random pick from `Message.top_reacted(scope: :user)`, 30-day window |
| Chat Wrapped (weekly + on-demand) | `lib/chat_wrapped.rb` + `lib/task_handlers/wrapped_digest_handler.rb` (`weekly_wrapped` task, F7 «Революция») + `lib/commands/wrapped.rb` (`бот итоги`) + `lib/cron_scheduler.rb` (`maybe_fire_digests`) + `digests:` settings block |

## Services

`Radio` (Liquidsoap TCP, lazy connect), `Song` (music library with FTS5 + Levenshtein fuzzy matching), `MusicScanner` (populates songs DB from file tags), `GptMaster` (Anthropic/OpenAI-compatible, `.chat`/`.ask`/`.call_raw`), `Agent::Runner` (agentic tool-use loop over GptMaster), `Agent::ToolRegistry` (tool definitions for agent mode), `TaskRunner` (generic DB-backed background task poller + handler registry), `SunoClient` (Suno AI song generation API, V5 model), `ImageGen::FluxAdapter` (FLUX 2 via api.bfl.ai), `ImageGen::AtlasAdapter` (Atlas Cloud, default model Wan 2.7), `ImageGen::CloseRouterImgAdapter` (CloseRouter Nano Banana Pro — synchronous), `ModelProviderClient` (generic Bearer+JSON HTTP client; used by Atlas + CloseRouter adapters, reusable for future Bearer-token model providers), `ChatContext` (shared module providing chat context + knowledge lookup for task handlers), `EmbeddingService` (OpenAI-compatible embeddings), `KnowledgeBase` (semantic RAG — store/search/auto-extract/compact facts), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope`, `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice`

## DB Tables

| Table | Columns |
|-------|---------|
| `chats` | `chat_id` (PK, bigint = Telegram chat id), `title`, `chat_type` (`group`/`supergroup`/`private`/`channel`), `authorized` (bool), `audio` (bool), `rate_limits` (JSON), `first_seen_at`, `last_seen_at`. Populated at startup from `Settings.auth['chats']` (`Chat.sync_from_config!`) and on every incoming message (`Chat.touch_seen`). `Chat` has_one :chat_state, has_many :messages/:background_tasks/:api_usages/:knowledge_facts. |
| `users` | `uid`, `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable), `chat_id`, `body`, `role` (`user`/`bot`), `message_id` (Telegram per-chat id, nullable for legacy rows), `reply_to_message_id` (nullable), `message_thread_id` (forum topic, nullable), `forwarded` (bool), `edited_at` (nullable), `bg_task_external_id` (nullable — populated for bot-delivered media so `cover_art` can resolve a reply-target back to its source song), `attachment_file_id` + `attachment_mime_type` + `attachment_title` + `attachment_performer` + `attachment_duration` (nullable — populated when an incoming user message has audio/voice/audio-MIME document; title falls back to `Document.file_name` minus extension when ID3 title is absent. Used by `Commands::GptChat#attached_audio` lookback and surfaced in `ChatContext.serialize_msg` as `audio: true` + `audio_meta: {title, performer, duration, mime}` so the agent names cover/add-vocals output after the actual track instead of inferring from prior chat context). Audio-only messages (no text caption) are persisted with body=`'[аудио]'` so they appear in chat context. `attachment_photo_file_id` (nullable — populated when an incoming message has a photo; the largest Telegram photo size ≤1280px is stored. Surfaced as `photo: true` in chat context; fetched on demand by the `view_image` agent tool. Photo-only messages are persisted with body=`'[фото]'`.) `reactions_count` (integer, default 0 — aggregate Telegram reaction count maintained by `BotDispatcher#handle_reaction` (per-user delta, best-effort) and `#handle_reaction_count` (authoritative overwrite); feeds `Message.top_reacted` → `бот цитата` + Wrapped "funniest"). |
| `phrases` | `user_id`, `content` |
| `knowledge` | `topic`, `content`, `embedding` (JSON), `source` (`manual`/`auto`), `chat_id` |
| `knowledge_compact_log` | `chat_id`, `merged`, `removed`, `kept`, `threshold`, `created_at` — one row per compaction run |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |
| `songs` | `title`, `artist`, `album`, `genre`, `year`, `filepath` (unique, relative to music root), `duration`, `category` |
| `songs_fts` | FTS5 virtual table indexing `title`, `artist`, `album`, `genre`, `category` — `content='songs'`, `content_rowid='id'`, `unicode61 remove_diacritics 1` tokenizer; auto-synced via triggers |
| `api_usage` | `chat_id`, `user_uid` (nullable — null for background extractions), `model`, `purpose` (`agent`/`main_chat`/`translate`/`knowledge_extract`/`knowledge_compact`/`suno_compose`/`suno_tags`/`image_prompt`), `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_cents` (decimal 10,4), `created_at` — one row per LLM API response; feeds `бот затраты` |
| `chat_states` | `chat_id` (PK), `scratchpad` (JSON), `updated_at` — agent's per-chat working memory (intentions/notes/expectations + the rules-war `rules` category + top-level `challenge_log`); read at every agent turn; written via `remember`/`forget` tools and the rules-game tools (`set_rule`/`court_rule`/`challenge_rule`). See ADR-003. |

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
- **Radio keepalive** — `Radio#start_keepalive` (called from `lib/bot.rb` at startup, alongside TaskRunner/CronScheduler) spawns a background thread that pings Liquidsoap every `KEEPALIVE_INTERVAL` (20s) with a harmless `request.alive`. Liquidsoap closes idle telnet connections; reusing a stale socket loses the first command's response, which made `!track` return `(нет данных)` *while a track was actually playing* (verified on prod: metadata was available via a fresh telnet probe, but every logged `!track` hit the stale-socket reconnect race). The keepalive pays the reconnect-on-idle penalty on the throwaway ping so real user commands always hit a warm socket. Idempotent (`@keepalive ||= …`), so safe across the bot's crash/retry loop. The interval must stay well under Liquidsoap's idle-close timeout. `Radio#command`'s reconnect rescue catches `Timeout::Error` (in addition to `Errno::EPIPE`/`ECONNRESET`/`IOError`) so a *hung* half-open socket also resets `@sock` and reconnects instead of timing out forever.
- **Radio metadata degradation** — `Radio#track` returns `"сейчас ничего не играет"` (not `"(нет данных), осталось …"`) when the playing source has no metadata. With the keepalive in place this should rarely trigger; it's a safety net.
- **`!queue` uses annotate tagging, not `request.queue`** — Liquidsoap's `request.queue(id="request")` operator **prefetches** the next request out of its visible queue, so `request.queue` reads empty within seconds of a `request.push` even while the track is queued/playing (verified on Liquidsoap 2.2.5; there is no `secondary_queue`/`primary_queue` in 2.x). So `Radio#request` pushes with the `annotate:` protocol — `request.push annotate:bot_req="1":<path>` (`REQUEST_TAG` constant) — and `Radio#queue` enumerates **`request.alive`** (all resolved-not-destroyed requests, rotation + user), fetches `request.metadata <id>` for each, and keeps only those tagged `bot_req="1"`. This covers both queued and now-playing user requests and self-prunes as they finish (played requests leave `request.alive`). The `source` metadata field can't be used to identify user requests — it's `"music_txt"` for library-file pushes (a file/playlist tag), inconsistent with the operator id. Empty result → `nil` → `RadioQueue` renders `"нихуя нет"`. The annotate round-trip was verified live on prod via a Ruby probe.
- In Docker, `restart: unless-stopped` handles crashes; the bot's own rescue/retry loop also retries within the process. The `daemons` gem is only used for local non-Docker runs via `./bin/bot`.
- `network_mode: host` is required so the container can reach Liquidsoap on `localhost:1234` (the radio telnet interface). Without it, `localhost` resolves to the container itself and the connection is refused. Since the bot exposes no inbound ports, host networking has no downside here.
- SOCKS proxy (if enabled) patches `Net::HTTP` globally via `socksify` — applies to all outbound HTTP
- **All** bot replies are stored in `messages` with `role: 'bot'`, `user_uid: nil` — not just GPT output. `MessageResponder#deliver` persists every successfully-sent output type after the Telegram call returns, capturing the `message_id` (+ originating `message_thread_id`): `:text` via a direct `Message.create` (using the `message_id` `MessageSender#send` returns), and `:sticker`/`:image`/`:voice` via `Message.persist_bot_reply(response:)` with a body marker (`[стикер]` / `[картинка]` / `[голос]`). This keeps the agent's chat context aware of the bot's own non-GPT replies and lets a later user reply resolve any bot message_id back to a row (fixes reply-chain blindness). `:image` persists only when the send actually succeeded — `MessageSender#send_image` returns `nil` from its rescue (a fallback text was sent, not an image). The `persist_as_bot_reply` flag was retired; persistence is now unconditional in `deliver`. Blank/whitespace `:text` payloads are skipped entirely (guards the Telegram "message text is empty" 400 from empty agent responses). Media sends (sticker/image/voice) thread the originating `message_thread_id` so forum-topic replies land in-thread. Background-task media (image_gen/suno/cover_art/wav handlers) self-persist (don't route through `deliver`), but their `persist_bot_media_row(s)` wrappers all delegate to `Message.persist_bot_reply` — the **single centralized write path** for bot-side rows (handles OpenStruct/Hash/`'result'`-enveloped responses, threads `reply_to`/`bg_task_external_id`, and captures `attachment_photo_file_id` from photo sends so the agent can re-view the bot's own generated images via `view_image`).
- Chat context JSON (`get_chat_context`) carries `id` (Telegram `message_id`), `role: 'bot'|'user'` (structural disambiguator — don't rely on name-string matching against the bot's display name), `who` (object: for users `{uid, username?, first_name?, last_name?}` — only present fields, or `{unknown:true}`; for the bot `{name:'Жзяцля'}`), `msg`, plus optional `reply_to`, `thread`, `fwd`, `edited`, `audio`, `audio_meta`, `photo` (`photo: true` = stored photo attachment, fetchable via the `view_image` tool; the file_id stays DB-internal). Two helpers in `ChatContext`: `identity_for_row` builds the `who` object; `display_name` produces the flat-string label used by `Agent::Runner#trigger_user_display` (shared so trigger line and history rows agree on every edge case). uid lets the agent mention users without a Telegram username via Markdown `[Name](tg://user?id=UID)`. When a reply target falls outside the 50-msg window, the helper fetches that one row from DB and prepends it. The `load_messages` agent tool lets the agent pull a wider window around any anchor `message_id`.
- Forum topics: if the triggering message has `message_thread_id`, the bot's reply is sent with the same `message_thread_id` (lands in the user's topic, not General), and context is scoped to same-thread messages.
- Edited messages: Telegram delivers edits via the same `Message` class with `edit_date` set. `save_message` updates the existing row in place (body + `edited_at`) and `respond` short-circuits dispatch — edits don't re-fire commands.
- `Settings` add-new-group note: top-level groups must be added to `REQUIRED_KEYS` in `lib/settings.rb` for the deep-merge validator to accept them. (Settings file roles are already documented in **Entry Points** above.)
- Knowledge auto-extraction runs in a background Thread every `knowledge.extract_every` messages per chat
- Embeddings deduplication threshold is 0.92 cosine similarity — near-duplicate facts are not stored
- Knowledge auto-compaction (`KnowledgeBase.compact!`) clusters near-dupes via stored embeddings (no API calls) and LLM-merges each cluster; triggered as a `knowledge_compact` background task when count >= adaptive threshold (`compact_at` × factor based on last run's avg cluster size); logs to `log/knowledge_compact.log`; history in `knowledge_compact_log` table
- Agent scratchpad (`Agent::Scratchpad`, `chat_states` table) — per-chat working memory (intentions/notes/expectations), distinct from knowledge base. Hard cap 6000 chars with FIFO eviction. Rendered as `{SCRATCHPAD}` in `agent_prompt`; managed via `remember`/`forget` tools. Detail: `docs/architecture.md#agent-scratchpad`, ADR-003.
- Agent event loop — `agent_event` task type, `AgentEventHandler`, `AgentEventEmitter` mixin. Emits on image_gen/suno failure-after-retries or success-after-retries; agent runs and decides whether to comment, retry, or `(skip)`. Per-chat cap 10/hour. Loop protection: only image_gen/suno emit; agent_event itself doesn't. Detail: `docs/architecture.md#agent-event-loop`, ADR-003 PR-2.
- **Agent tool ctx — `ctx[:api]`** — Tools read `ctx[:api]` for Telegram calls. Pass `api:` to `Agent::Runner.new`; Runner warns if nil. Detail: `docs/architecture.md#agent-event-loop`.
- **Suno error-detail propagation** — Suno's `errorCode`/`errorMessage` (e.g. `[413] "Uploaded audio matches existing work of art"`, `SENSITIVE_WORD_ERROR`, etc.) now reach the agent verbatim. `SunoClient#poll_once`, `poll_wav_once`, `poll_cover_art_once` return `{ failed: true, error: '<formatted detail>' }` (Hash) instead of bare `:failed` whenever Suno reported a specific reason. Handlers (`SunoTaskHandler` / `SunoCoverArtHandler` / `SunoWavConvertHandler`) `case Hash`-arm captures `result[:error]` and threads it to `mark_failed_and_notify(... error_detail:)`, which appends `| <detail>` to the `agent_event` summary. `bail_or_retry` also threads the failure reason through. Lets the agent distinguish copyright reject vs content flag vs worker hiccup vs delivery failure and pick a meaningful next move (rephrase / different source / retry later) instead of blind-retry. WAV-convert handler's `case Hash` is overloaded: discriminates `{ wav_url: ... }` (success), `{ failed: true, ... }` (failure), and unknown shapes (logged + `wav_unknown_response_shape` failure) by explicit key checks rather than fall-through. Bare `:failed` is reserved for paths with no detail. **SECURITY**: `SunoClient#format_suno_error` strips URLs (`%r{https?://\S+}` → `<url-redacted>`) before composing the detail string. Suno's errorMessage on some 4xx paths echoes the input URL back, and for `cover_audio`/`add_vocals` that URL is the Telegram file URL containing the bot token. The detail flows into agent_event summary (DB-persisted via `background_tasks.params`, forwarded to LLM context), so leaking the token there has DB + LLM blast radius beyond just chat-internal logs.
- `Agent::ToolResult` — tool handlers return either a String or `Agent::ToolResult.deferred(user_text:, intent:, retry_in_min:)` for rate-limited / retry-later outcomes. Runner auto-writes the intent to the scratchpad with `due_at`. New deferred-style tools just call `.deferred(...)` — no per-tool prompt scaffolding. Detail: `docs/architecture.md#agent-scratchpad`.
- `CronScheduler` (`lib/cron_scheduler.rb`) — 60s tick, fires `agent_event(cron_tick)` for chats with due scratchpad intentions; same 10/hr rate cap as agent_event. Started from `lib/bot.rb`. Detail: `docs/architecture.md#agent-scratchpad`.
- Scratchpad compaction is pure-Ruby (no LLM); runs inline on every `Scratchpad.add` for expiry-based pruning. Manual: `rake scratchpad:compact [MAX_AGE_DAYS=N] [CHAT_ID=...]`. Detail: `docs/architecture.md#agent-scratchpad`.
- `бот сожми знания` (admin only) triggers compaction immediately for the current chat
- All `бот <text>` requests — including search, images, gifs, horoscope — route through `GptChat` → `Agent::Runner`. The agent's `google_search` / `horoscope` / `generate_image` tools handle those intents and can compose multiple tools in one turn (e.g. "бот найди новости и нарисуй" → `google_search` then `generate_image`). There are no direct-dispatch commands for search or horoscope anymore.
- **`google_search` intent is explicit:** the agent passes `media_type: 'text'|'photo'|'gif'` on every call (JSON-Schema enum, all tool params are auto-required). No query-string regex sniffing; `Gogolmogol.new(query, media_type:)` uses the intent directly to set `searchType=image` + `fileType=gif`. `download_results` includes an SSRF guard — http(s) only, no loopback/private/link-local literal IPs (DNS-based + redirect-target rebinding are residual risks). Tool file holds Telegram coupling (`sendMediaGroup` / `sendAnimation`); Gogolmogol stays Telegram-unaware.
- Agent mode is the only mode: `GptChat` / `GptQuestion` always route through `Agent::Runner`, which lets GPT call bot tools (radio, weather, search, etc.) autonomously. Agent supports vision — replying to a photo with "бот ..." sends the image to the vision model for recognition.
- **`view_image` mid-loop vision upgrade** — the tool fetches a stored photo (by `message_id` of a `photo: true` context row) and returns `Agent::ToolResult.image`; Runner queues it in `@pending_images`, injects it AFTER all of the iteration's tool-result messages (openai contract: every tool_call answered before another role), then flips `@setting` to `agent_vision` for the rest of the turn. The upgrade only happens when `agent` and `agent_vision` share `api_type` (`ctx[:can_view_image]`, computed at Runner init) — accumulated messages are provider-shaped and can't be replayed cross-provider; on mismatch the tool degrades to text. DeepSeek's `reasoning_content` is stripped from accumulated assistant messages on upgrade (grok may reject the unknown field). `materialize_result` checks `image?` BEFORE the deferred guard — reordering would silently drop the image. `GptMaster#dump_gpt` redacts base64 image payloads from gpt.log. Photos persist at ≤1280px (`Message.pick_photo_file_id` — shared by incoming `save_message` and outgoing `persist_bot_reply`); the bot's own sent images (deliver `:image`, image_gen, Suno cover art) are captured too, so the agent can re-view its generation results. Only post-deploy photos are fetchable; document-images (`image/*` MIME files) aren't captured.
- `GptChat` must be last `бот`-prefixed command in registry — it matches `бот <anything>`
- `chat_gpt.providers` holds API credentials; `chat_gpt.settings` holds named configs (`agent`, `agent_vision`, `knowledge`, `lyrics`, `embedder`) referencing providers
- `GptMaster.new(messages, setting:, chat_id:, purpose:, system_prompt:)` resolves provider + model from settings; the `setting:` kwarg picks one of the named blocks under `chat_gpt.settings`. **Every consumer must pass `setting:` explicitly.** The kwarg default is still `'main'` but `main` is no longer defined — any forgotten caller fails loudly with `Unknown chat_gpt setting: main` rather than silently picking a model. Active settings: `agent` (Agent::Runner tool loop, image-gen prompt enrichment, suno tags/parsing — text only, no vision; default DeepSeek V4 Pro), `agent_vision` (Agent::Runner picks this automatically when an image is attached, also used by ImageGenTaskHandler for image-edit prompt enrichment — grok-4-fast-reasoning via xAI; chosen over Anthropic for less aggressive content filtering on named-people image descriptions, and over the non-reasoning Grok variant because reasoning follows tool-call instructions more reliably — the non-reasoning model frequently hallucinated `🎨 <caption>` image replies as text instead of invoking generate_image. Note: reasoning is *more* reliable, not perfect — even grok-4-fast-reasoning occasionally emits "Calling the image editor now..." as plain text with NO `tool_use` block (single iteration, `stop=stop`, 0 tool calls), so the user has to retry. Suspected soft-refusal pattern when the image edit involves sensitive content; no explicit policy error is logged, just a missing tool call), `knowledge` (KnowledgeBase extract + compact, background frequent), `lyrics` (suno_handler song lyrics generation — long-form creative text-out), `embedder` (text→vector, used by KnowledgeBase + EmbeddingService). `chat_id` + `purpose` feed the `api_usage` table (telemetry is fire-and-forget — errors logged, never propagated)
- **Prompt caching:** the `agent_prompt` template in `settings.common.yml` contains a `{CACHE_BREAK}` marker. Everything before it is sent as the Anthropic `system` param with `cache_control: { type: 'ephemeral' }`; everything after is the dynamic user message. Agent tools also get `cache_control` on the last tool in the array. Second+ calls within 5 min hit the cache (`cache_read_tokens > 0`, much cheaper input). OpenAI-compatible providers auto-cache; the split is harmless for them.
- `chat_gpt.pricing` (in `settings.common.yml`) maps exact model id → `input`/`output`/`cache_read`/`cache_write` in USD per 1M tokens. `ApiUsage.compute_cost(model, usage)` returns cents as `BigDecimal`. Unknown models → row with `cost_cents = 0` + warn log
- `бот затраты` / `бот расходы` / `бот cost` (admin-only) prints a Markdown digest of API costs broken down by purpose for today / 7d / 30d, plus top-5 spenders per window in the current chat, and global totals
- `TaskRunner` poller thread starts inside `Telegram::Bot::Client.run` block, reuses `bot.api` — no second bot instance
- Background tasks are generic: `TaskRunner.register('type', HandlerClass)` + `BackgroundTask.create!(task_type: 'type', ...)` — add new task types via handler files in `lib/task_handlers/`
- Suno song generation is agent-only — the `compose_song` agent tool creates a `suno_generate` background task (no direct `бот спой` command). Suno returns 2 clip variants; both are downloaded, named as `Performer_-_Song_Name.mp3`, and sent as a media group. Lyrics follow as a reply. For `compose_song` the lyrics are the locally-composed `params['lyrics']`; for `add_vocals` / `cover_audio` (which don't compose locally) the fallback is `clips.first[:lyrics]`, mapped from Suno's `response.sunoData[].prompt` field by `SunoClient#poll_once` (`SunoTaskHandler#resolve_delivery_lyrics` picks between them).
- Suno uses V5 model; lyrics + tags are produced **handler-side** in a SINGLE combined Sonnet 4.6 call (`compose_lyrics_and_tags`, `purpose: 'suno_compose'`, returns `<lyrics>…</lyrics><tags>…</tags>` XML blocks) on the common path where the user hasn't supplied verbatim lyrics. When the user DOES supply verbatim lyrics, the handler skips composition and runs the tags-only call (`resolve_tags`, `purpose: 'suno_tags'`). The `compose_song` agent tool does NOT take a `tags` arg (only intent: `artist`/`genre`/`theme`/`title`). Always-enrich is structural, not heuristic. Artist names are **never** included in tags (Suno blocks them). `TAGS_PROMPT` orders tags *genre → mood → instruments → vocals → mix*; negatives flow through the structured `negative_tags` param on `compose_song`/`add_vocals`/`cover_audio` (shared description: `SUNO_NEGATIVE_TAGS_DESC` in `_suno_language_rule.rb`), never inlined into `tags`. Detail: `docs/architecture.md#tag-ordering-convention-tags_prompt` + `#lyric-craft-directives-lyrics_prompt` + `#combined-compose-call`.
- **Genre-language rule** for Suno-bound lyrics/topic content (compose_song, add_vocals, cover_audio): the language of the SUNG text follows the GENRE'S native language, not the user's request language. Russian-origin genres (частушка, шансон, бардовская, советский рок/панк/эстрада) → Russian; everything else (rock, metal, pop, surf rock, blues, jazz, hip-hop, country, electronic, etc.) → English by default, even if the user asked in Russian. Section markers (`[Verse]`, `[Chorus]`...) and parenthetical stage directions inside blocks are ALWAYS English regardless of genre — Suno's style vocabulary is English-trained. User can override explicitly ("сделай рэп НА РУССКОМ"). Canonical rule wording: `SUNO_LANGUAGE_RULE_RU` constant in `lib/agent/tools/_suno_language_rule.rb`, interpolated into all three Suno tool descriptions; duplicated word-for-word in `Settings.suno['lyrics_prompt']` (the YAML side has no Ruby interpolation). New Suno tool? Reuse the constant.
- **Suno add-vocals / cover-audio / cover-art** — three additional agent tools layered on Suno: `add_vocals` (sing AI vocals over user-provided audio, 1 clip), `cover_audio` (musical cover/re-style of user-provided audio, 2 clips), `cover_art` (2 album-art PNGs for an existing Suno song). Audio inputs come from Telegram attachments (`message.audio` / `message.voice` / `message.document` with `audio/*` MIME — `attached_audio` helper in `lib/commands/gpt_chat.rb`) OR from agent-supplied URLs. `attached_audio` priority chain: (1) current message; (2) reply-target message; (3) most recent attachment within the last 20 messages of the chat (DB lookback via `messages.attachment_file_id`). The lookback covers the "user uploaded an audio earlier, then asked for a cover in a fresh message without using Telegram-reply" case. `ChatContext.serialize_msg` adds `audio: true` to context entries so the agent sees which past messages have an attachment. The Telegram file URL contains the bot token; sending it to Suno leaks the token to Suno's logs — pre-existing risk profile (the bot already exposes that URL to chat for voice messages); rotate via @BotFather if needed.
- **`cover_audio` lyrics-vs-topic split** — tool exposes two args: `lyrics` (verbatim → custom mode, ≤5000 chars) and `topic` (theme seed → auto mode, ≤500 chars). Reply to a prior bot song without `lyrics` → auto-fallback copies lyrics from the source task. Full resolution chain (`SunoTaskHandler#resolve_cover_prompt`), instrumental override, legacy `prompt` back-compat: `docs/architecture.md#cover-audio-mode-resolution`.
- **Combined "song + cover art" requests** — `compose_song` / `add_vocals` / `cover_audio` accept `with_cover_art: true`; chained `suno_cover_art` task fires after the song's `:done`. Charged against the `suno` rate-limit bucket; silently dropped if the bucket is exhausted. Detail: `docs/architecture.md#combined-song--cover-art-requests`.
- Suno cover-art uses a separate handler (`SunoCoverArtHandler`, output is images) and a different endpoint pair from compose/upload-cover. Failures emit `cover_art_failed` agent_event. Detail: `docs/architecture.md#cover-art-source-resolution`.
- Suno WAV export — `convert_to_wav` tool, `suno_wav_convert` task, `SunoWavConvertHandler`. Endpoint pair, `successFlag` enum, `taskId`+`audioId` requirement, clip_index → audioId mapping: `docs/architecture.md#suno-wav-export`.
- **`cover_art` source resolution** — chain: explicit `suno_task_id` → reply target's `bg_task_external_id` → most recent `done` Suno task. Full detail: `docs/architecture.md#cover-art-source-resolution`.
- Image generation is agent-only — the `generate_image` agent tool creates an `image_generate` background task (no direct `бот нарисуй` command). The handler's prompt-enrichment LLM step uses the active adapter's `prompt_template(:text_to_image|:edit)`.
- **Image-gen adapter dispatch** — `Settings.image_gen['provider']` selects the active backend (`'flux'` | `'atlas'` | `'closerouter'`). `ImageGen.current_adapter` is read on submit; the chosen `adapter.name` is snapshotted into `task.params['provider']`. `ImageGen.adapter_for(provider)` is read on poll, so a config flip (e.g. `docker compose up -d --build` mid-flight) doesn't reroute polling to a different prediction id space — old tasks continue against the original backend, new tasks go to the new one.
- **Synchronous image adapters** — `Adapter#synchronous?` predicate (defaults `false`). When `true`, `#submit` returns a terminal result Hash (`{url:, completed:true}`) instead of an external_id String; `ImageGenTaskHandler` short-circuits the poll cycle in `deliver_sync_result` and marks the task done in one call. `#poll_once` raises `NotImplementedError` if reached. Only `CloseRouterImgAdapter` is sync today (CloseRouter's `/v1/images/generations` returns the result in the same response). Flux + Atlas stay async.
- **`ModelProviderClient`** (`lib/model_provider_client.rb`) — generic Bearer+JSON HTTP client (formerly `AtlasClient`). `POST` raises on non-2xx; `GET` returns `[code, body]` and swallows transient SSL/timeout. Constructor takes a config dict + `tag:` for greppable logs (`'AtlasImg'` / `'CloseRouterImg'` / future `'CloseRouterVideo'`). Reusable by any future Bearer-token, JSON-body model provider.
- **Image-gen settings** in `config/settings.common.yml` under `image_gen:` block (`provider` + `providers.atlas` + `providers.flux` + `providers.closerouter`); api_keys in `config/settings.yml`. `FluxAdapter` has a one-release back-compat shim that reads top-level `Settings.flux` if `image_gen.providers.flux` is missing — removed once prod settings.yml is migrated. CloseRouter's `providers.closerouter` has `text_to_image_model: 'google/nano-banana-pro'` + `image_edit_model: 'google/nano-banana-pro-edit'` (separate model ids — edit is not a parameter on the base model).
- `бот задачи` shows last 10 background tasks for the current chat
- **Telegram reactions (S1)** — `lib/bot.rb` passes `allowed_updates: ALLOWED_UPDATES` to `Client.run` (NOT `bot.listen` — only `Client#initialize`'s options reach `getUpdates`; specifying the list REPLACES Telegram's default, so it must enumerate every consumed type). Two dispatcher branches: `MessageReactionCountUpdated` is **authoritative** (overwrites `reactions_count` with summed `total_count` — self-heals drift); `MessageReactionUpdated` is the per-user delta (`new_reaction.size - old_reaction.size` — Telegram coalesces a user's reactions, so swap=0/add=+1), best-effort only, needs bot group-admin to be delivered (confirmed admin in main chats). Reaction updates lack `from`/chat-type → dedicated `reaction_authorized?` gate (no super-admin shortcut).
- **Rules-war store** — scratchpad `rules` category is **exempt from `evict_until_under_cap` AND from generic `prune_expired`**: active rules must never vanish silently, and expired rules are deleted ONLY via `Scratchpad.pop_expired_rules` (CronScheduler) so each gets its obituary exactly once. `rules()`/`render` filter expired at read (≤60s pop lag is never *enforced*). Spam bounds: one-rule-per-citizen (new rule auto-repeals the author's old one — `add_rule` returns `{rule:, repealed:, evicted:}` so the agent announces the trade-in), `MAX_RULES = 20` backstop, 200-char content cap. `add_rule` is a separate method — generic `add` keeps returning a bare `"sp-NNN"` string (the Runner's deferred-intent write depends on it) and rejects `category: 'rules'`; `Scratchpad.remove` (the `forget` tool) can't delete rules. Court rules (`court_rule` tool, `set_by: 0`, rendered «суд») bypass one-rule-per-citizen but max 1 per chat, 12h.
- **Dice trials (`challenge_rule`)** — public `api.send_dice` roll (value is in the response immediately; the client animation runs ~4s). **NEVER `sleep` in a tool handler**: handlers run synchronously inside `bot.listen`'s single-threaded loop (a sleep freezes the whole bot) and, on the TaskRunner path, inside `with_connection` with only 2 workers. Outcome: 4–6 repeal / 2–3 survive +6h / 1 critical fail (+ court_rule instruction). Survival counter is surfaced **post-increment** (F5 awards trigger on `>= 3`). Throttle: 6 trials/chat/hour via scratchpad top-level `challenge_log` (pruned to the 1h window on write — `RateLimiter` doesn't fit, it counts BackgroundTask rows).
- **Rule obituaries** — CronScheduler pops expired rules per tick and enqueues at most ONE `rule_obituary` task (single or combined «братская могила»); max 3/chat/local-day, past the cap rules are popped silently. The handler renders only what task params carry.
- **`digests` settings block** — optional group (deliberately NOT in `Settings::REQUIRED_KEYS` — adding it would crash any settings.yml without it). `chat_id` is set on prod in place (never scp). Round 1 fires the **wrapped branch only**; `digests.news` is inert reserved config — enqueueing `daily_news` without a registered handler would mark-failed + error-notify the chat.
- **«Революция» (weekly Wrapped)** — 10% roll happens ONLY in `WrappedDigestHandler` (never `бот итоги`), is persisted into task params BEFORE any send, and retries re-read it — a transient send failure can't re-roll or double-wipe. `clear_rules` is idempotent.
- **`Message.top_reacted(scope:)`** — `:user` (Quote: humans only) vs `:all` (Wrapped funniest: includes bot rows — the dominant reacted content is the bot's own memes; don't silently exclude them).
- **Award captions** — `ImageGenTaskHandler#caption_for` is the single caption builder for BOTH delivery paths (sync CloseRouter + async Flux/Atlas); `award: true` params → `🏆` prefix.
- FLUX API settings: top-level `flux:` block in `settings.yml`/`settings.common.yml` is the legacy location read by FluxAdapter's back-compat shim. New canonical location is `image_gen.providers.flux.{api_url,api_key,model}`.
- Suno API settings in `config/settings.yml` under `suno` group: `api_key`; non-secret config (`api_url`, `model`) in `settings.common.yml`
- `ChatContext` module (`lib/chat_context.rb`) is the single source of truth for chat context and knowledge lookup — included by task handlers directly and by `GptHelpers` (which delegates via `super` with auto-passed `chat_id`)
- Admin-only commands use `return admin_denied unless admin?` from `Commands::Base`; agent tools check `@user.role` — both pull denial messages from `Settings.replies['admin_denied']` in `settings.common.yml`
- Radio search uses `Song.search` (multi-stage: FTS5 → Cyrillic→Latin transliteration with k/c variants → prefix truncation → LIKE → Levenshtein editdist); `radio.request` flow is unchanged
- `Song.search` uses FTS5 prefix matching (`word*`) with `unicode61 remove_diacritics 1` tokenizer; Cyrillic input triggers transliteration chain (Stages 1–4); Stage 1 variants include k/c, ts/c, kh/h, and w/v (в→w in translit but v in English proper nouns, e.g. "нирвана"→"nirwana"→"nirvana"); Stage 4 uses a custom `editdist` SQLite function registered by `DatabaseConnector.register_editdist` — catches e.g. "раммштайн"→Rammstein (distance 3)
- `MusicScanner` reads tags via `wahwah` (pure Ruby), falls back to parsing artist/title from filepath; run `bundle exec rake music:scan` to populate/refresh
- `Settings.radio['path']` (music directory root, used by MusicScanner inside the container) and `Settings.radio['source']` (Liquidsoap source name, e.g. `42fm_radio_station`) are in `settings.common.yml`; `Song#absolute_path` joins `host_path` (if set) or `path` + relative `filepath` — set `radio.host_path` in `settings.yml` when Liquidsoap sees a different path than the container (e.g. `/content/music` vs `/home/radio/content/music`)
- `wahwah` gem is pure Ruby — no native dependencies needed for audio tag reading
