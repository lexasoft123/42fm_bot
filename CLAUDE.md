# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full reference: `docs/architecture.md` (design, schema, services, development guide) | Area gotchas: `.claude/rules/*.md` (auto-loaded when working with matching files) | User-facing feature guide (RU): `docs/user/README.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Never deploy or push without explicit user permission in the current turn.** Includes `make deploy`, `git push`, and `ssh ... docker compose up`. Authorization does not carry over from a prior turn — re-confirm every time. `.claude/hooks/deploy_guard.sh` (PreToolUse Bash hook) emits `permissionDecision: "ask"` on every match, routing the call through Claude Code's permission prompt; the user must approve each invocation explicitly.
- **Always run `make test` before committing.** All tests must pass before creating a commit.
- **Never run `ruby lib/bot.rb` directly.** Use Docker in production; use `./bin/bot start/stop/restart` only for local non-Docker development.
- **Back up `db/bot.db` on prod only when the deploy includes a new migration.** Run `make backup` — code-only deploys don't need it. See `Backing up the prod DB` below for details.
- **Never `scp config/settings.yml` to prod.** Local and prod copies intentionally diverge (e.g. `proxy` is enabled only on prod). To change prod settings, ssh in and edit in place, or hand the user the exact diff to apply.
- **In plan mode, run the `plan-reviewer` agent (via the Task tool) on the plan file before calling ExitPlanMode.** Then **report the reviewer's findings to the user verbatim** before applying any patches. Wait for the user to decide which findings to act on — do not auto-apply. Only after the user has seen the findings (and you've patched what they agreed to) should you call ExitPlanMode. Manual ad-hoc reviews of older plans: `/review-plan <path>`.
- **For substantive code changes (new features, multi-file refactors), invoke the `code-reviewer` agent before commit.** Same workflow as `plan-reviewer`: report findings to the user verbatim, wait for their call, then patch and commit. Skip for trivial edits (typos, single-line fixes). Manual ad-hoc reviews: `/review-code [path]` (defaults to staged or branch diff). The reviewer uses Ruby LSP for symbol/caller resolution.
- **Keep docs in sync — before every commit:** update `docs/architecture.md` (behavior/design reference) for any new/renamed command, service, file, schema, settings group, or core pattern; update the matching `.claude/rules/*.md` when you learn a new trap or change a documented invariant in that area (new area → new rule file with `paths:` frontmatter); update CLAUDE.md only for entry points, run/deploy procedure, orientation tables, or cross-cutting rules.

---

## Running the Bot (Docker — production)

The bot runs as a Docker container managed by `docker compose`. The entrypoint runs DB migrations automatically on every start. `restart: unless-stopped` handles crashes; the `daemons` gem is only used for local non-Docker runs.

```bash
docker compose up -d --build   # build image and start (or restart after code changes)
docker compose logs -f         # tail logs
docker compose down            # stop
```

Logs are bind-mounted to `./log/` on the host. Three files (detail: `docs/architecture.md#logging`):
- **`bot.log`** — app output; per-chat lines prefixed `[chat=<id>]` (agent turns add `[AGENT]`)
- **`gpt.log`** — NDJSON dump of every LLM request+response; query with `jq`
- **`knowledge_compact.log`** — per-run knowledge-compaction traces

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
| `Dockerfile` | `ruby:4.0-slim` + `ffmpeg` + `opus-tools` (both required for TTS) + sqlite3/libxml2; installs gems, runs entrypoint |
| `docker-entrypoint.sh` | Runs `rake db:migrate` then execs `bundle exec ruby lib/bot.rb` as PID 1 |
| `docker-compose.yml` | `network_mode: host` + bind mounts for `db/`, `config/settings.yml` (ro), `log/`, and music library |
| `.env` | Gitignored host-local config: `DEPLOY_HOST` and `MUSIC_PATH` (see `.env.example`) |
| `.env.example` | Committed template documenting required `.env` variables |

`network_mode: host` is required so the container can reach Liquidsoap on `localhost:1234` (the radio telnet interface) — without it, `localhost` resolves to the container itself. The bot exposes no inbound ports, so host networking has no downside.

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

How-to recipes (add a command, patterns, settings, migrations): `docs/architecture.md` § Development Guide.

## Key Files by Task

| Task | File |
|------|------|
| Add/change a command | New file in `lib/commands/` + require in `message_responder.rb` + entry in `lib/commands/registry.rb` |
| New service/API | `lib/new_service.rb` + require in `config/boot.rb` |
| Reply text templates | `config/replies/*.yml` |
| Bot text send path / rich formatting | `lib/message_sender.rb` (rich-first + classic fallback) + `lib/telegram_rich_client.rb` (Bot API 10.1 `sendRichMessage`) — see `.claude/rules/messages-context.md` |
| GPT prompt/model | `config/settings.yml` (`chat_gpt.settings.*` + `chat_gpt.providers.*`) + `lib/gpt_master.rb` |
| TTS / audio | `lib/polly.rb` (AWS Polly + FFmpeg → OGG Opus) + `lib/tts_service.rb` |
| Radio (Liquidsoap TCP) | `lib/radio.rb` |
| Music search / song DB | `models/song.rb` + `lib/music_scanner.rb` + `rake music:scan` |
| Agent mode tools | `lib/agent/tools/*.rb` + `lib/agent/tool_registry.rb` + `lib/agent/runner.rb` |
| Background tasks | `lib/task_runner.rb` + `lib/task_handlers/*.rb` + `models/background_task.rb` |
| Suno (compose / add-vocals / cover / cover-art / WAV) | `lib/suno_client.rb` + `lib/task_handlers/suno_*.rb` + `lib/agent/tools/{suno,add_vocals,cover_audio,cover_art,convert_to_wav}.rb` — see `.claude/rules/suno.md` |
| Image generation (FLUX / Atlas / CloseRouter; agent picks model per request) | `lib/image_gen/*.rb` (incl. `catalog.rb`) + `lib/model_provider_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` — see `.claude/rules/image-gen.md` |
| Knowledge base / embeddings / dedup | `lib/knowledge_base.rb` + `lib/knowledge_base/{cluster,review}.rb` + `lib/embedding_cache.rb` + `models/knowledge{,_subject}.rb` + `rake knowledge:*` — see `.claude/rules/knowledge.md` |
| Shared handler context | `lib/chat_context.rb` — `ChatContext` module (chat messages + knowledge for task handlers) |
| Agent scratchpad / events / cron | `lib/agent/scratchpad.rb` + `lib/cron_scheduler.rb` + `lib/task_handlers/agent_event_*.rb` — see `.claude/rules/agent-runtime.md` |
| Admin menu / access requests / chat labels | `lib/admin_menu/*.rb` + `lib/access_request.rb` + `models/chat.rb` — see `.claude/rules/admin-menu.md` |
| Community games (rules-war, awards, quote, wrapped) | `lib/agent/tools/{rules,award}.rb` + `lib/chat_wrapped.rb` + `lib/commands/{rules,quote,wrapped}.rb` — see `.claude/rules/agent-games.md` |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |

## Services

`Radio` (Liquidsoap TCP, lazy connect), `Song` (music library with FTS5 + Levenshtein fuzzy matching), `MusicScanner` (populates songs DB from file tags), `GptMaster` (Anthropic/OpenAI-compatible, `.chat`/`.ask`/`.call_raw`), `Agent::Runner` (agentic tool-use loop over GptMaster), `Agent::ToolRegistry` (tool definitions for agent mode), `TaskRunner` (generic DB-backed background task poller + handler registry), `SunoClient` (Suno AI song generation API, V5 model), `ImageGen::FluxAdapter` (FLUX 2 via api.bfl.ai), `ImageGen::AtlasAdapter` (Atlas Cloud, default model Wan 2.7), `ImageGen::CloseRouterImgAdapter` (CloseRouter Nano Banana Pro — synchronous), `ModelProviderClient` (generic Bearer+JSON HTTP client), `ChatContext` (shared chat context + knowledge lookup for task handlers), `EmbeddingService` (OpenAI-compatible embeddings), `EmbeddingCache` (per-chat normalized float32 matrix; keeps the knowledge read path off the DB), `KnowledgeBase` (semantic RAG — store/search/auto-extract), `KnowledgeBase::Cluster` + `KnowledgeBase::Review` (dedup: candidate generation over two similarity spaces, then an LLM judge — the only path that deletes facts), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope`, `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice`

Details on each: `docs/architecture.md` § Service Modules.

## DB Tables

Columns and semantics: `docs/architecture.md#database-schema`.

| Table | Purpose |
|-------|---------|
| `chats` | Known chats: authorization, type, title, per-chat rate limits, seen timestamps |
| `users` | Telegram users: name, role (`new`/`member`/`admin`), last track order |
| `messages` | Full chat history (user + bot rows), reply/thread/attachment/reaction metadata |
| `phrases` | User-submitted catchphrases |
| `knowledge` | Semantic RAG facts with embeddings, per chat (soft-deleted via `deleted_at`) |
| `knowledge_subjects` | Many-to-many: which participants each fact is about |
| `knowledge_compact_log` | One row per knowledge-compaction run |
| `background_tasks` | Generic async task queue (suno/image_gen/agent_event/...) |
| `songs` | Music library metadata from file tags |
| `songs_fts` | FTS5 index over songs, trigger-synced |
| `api_usage` | Per-LLM-call token/cost telemetry; feeds `бот затраты` |
| `chat_states` | Agent's per-chat scratchpad JSON (intentions/notes/rules) |

## Gotchas (cross-cutting)

Area-specific gotchas live in `.claude/rules/*.md` (see index below). These apply everywhere:

- **Never `sleep`/block in any command, agent tool, or task handler** — handlers run synchronously inside `bot.listen`'s single-threaded loop (a sleep freezes the whole bot for every chat); TaskRunner has only 2 workers. Full war story: `.claude/rules/agent-runtime.md`.
- SOCKS proxy (if enabled) patches `Net::HTTP` globally via `socksify` — applies to ALL outbound HTTP.
- Every bot send must persist a `messages` row via the centralized `Message.persist_bot_reply` path — detail: `.claude/rules/messages-context.md`.

## Area gotchas index

Path-scoped rule files under `.claude/rules/` — each auto-loads when working with files matching its `paths:` frontmatter. Consult them explicitly when reasoning about an area without opening its files:

| Area | Rule file |
|------|-----------|
| Radio / Liquidsoap (keepalive, queue annotate tagging) | `radio-liquidsoap.md` |
| Music search (FTS5, transliteration, editdist) | `music-search.md` |
| Suno (compose, covers, WAV, error propagation, language rule) | `suno.md` |
| Image generation (adapters, sync vs async, awards) | `image-gen.md` |
| Agent runtime (scratchpad, events, vision, ToolResult) | `agent-runtime.md` |
| Community games (rules-war, dice trials, wrapped, quote) | `agent-games.md` |
| Admin menu / authorization / access requests | `admin-menu.md` |
| Knowledge base / embeddings / compaction | `knowledge.md` |
| Message pipeline (dispatch, persistence, context JSON, reactions) | `messages-context.md` |
| GPT providers / settings / caching / cost telemetry | `gpt-providers.md` |
| Settings validation / rate limits | `settings.md` |
| Command registry order / DM no-prefix / TTS deps | `commands-registry.md` |
| Background tasks (TaskRunner contract) | `task-handlers.md` |
| Google search (key pool, SSRF guard) | `google-search.md` |
