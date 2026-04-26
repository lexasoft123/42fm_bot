# 42FM Bot — Architecture

## Overview

42FM Bot is a Ruby Telegram bot for a private radio station community. It integrates with an Liquidsoap radio server via TCP, provides AI-generated responses via an OpenAI-compatible API, text-to-speech via AWS Polly, and various entertainment commands. The bot is chat-restricted: only messages from authorized `chat_ids` are processed.

---

## Startup Flow

```
bin/bot
  └── daemons gem (process manager, :monitor => false — bot handles its own restarts)
       └── lib/bot.rb
            ├── config/boot.rb (loads Settings, requires all modules)
            ├── AppConfigurator.configure (i18n, DB, SOCKS proxy)
            ├── Radio.new (lazy TCP connection to Liquidsoap — connects on first use)
            └── Telegram::Bot.run (long-polling loop)
                 └── MessageResponder.new(bot, message, radio).respond
                      ├── dispatch(ctx) → Commands::REGISTRY (first match wins)
                      └── deliver(result) → MessageSender / bot.api
```

`bin/console` provides a Pry REPL with the full environment loaded for debugging.

---

## Directory Structure

```
42fm_bot/
├── bin/
│   ├── bot              # Daemon entry point
│   └── console          # Pry debug console
├── config/
│   ├── boot.rb          # Bootstrap: loads all modules
│   ├── database.yml     # SQLite3 connection (db/bot.db)
│   ├── settings.yml     # Secrets (gitignored)
│   ├── bober.yml        # Bober command phrases
│   ├── initializers/
│   │   ├── 01_settings.rb        # Loads settings.yml
│   │   ├── string.rb             # String.truncate extension
│   │   └── telegram_stickers.rb  # Sticker ID constants
│   ├── replies/
│   │   ├── replies.yml  # General chat reply patterns
│   │   ├── jewish.yml   # Jewish-theme reply patterns
│   │   └── spider.yml   # Spider-theme reply patterns
│   └── lib/
│       └── dice.yml     # Dice game response templates
├── lib/
│   ├── bot.rb                 # Main loop + message dispatch
│   ├── message_responder.rb   # Builds CommandContext, runs dispatch/deliver
│   ├── message_sender.rb      # Telegram output wrapper
│   ├── command_context.rb     # Struct: per-message shared state
│   ├── command_result.rb      # Value object: response type + payload
│   ├── settings.rb            # Config singleton with required-key validation
│   ├── app_configurator.rb    # i18n, DB, SOCKS proxy init
│   ├── database_connector.rb  # ActiveRecord setup
│   ├── radio.rb               # Liquidsoap TCP client (lazy connect) + Song-backed search
│   ├── music_scanner.rb       # Reads audio file tags (wahwah), populates songs DB
│   ├── gpt_master.rb          # Anthropic/OpenAI-compatible API client (.chat / .ask / .call_raw)
│   ├── embedding_service.rb   # OpenAI-compatible embeddings API
│   ├── knowledge_base.rb      # Semantic RAG: add/search/extract_and_store facts
│   ├── polly.rb               # AWS Polly TTS + FFmpeg → OGG Opus
│   ├── tts_service.rb         # TTS facade: Polly + public URL builder
│   ├── gogolmogol.rb          # Google Custom Search
│   ├── horoscope.rb           # Horoscope scraper
│   ├── weather.rb             # OpenWeatherMap API
│   ├── dice.rb                # Dice game logic
│   ├── reply_master.rb        # YAML-driven reply engine
│   ├── reply_markup_formatter.rb  # Telegram keyboard builder
│   ├── holidays.rb            # Holiday announcer (dormant)
│   ├── giphy_master.rb        # Giphy API (disabled)
│   ├── commands/
│   │   ├── base.rb            # Base class: ctx accessors, helpers
│   │   ├── registry.rb        # Ordered array of command classes
│   │   ├── gpt_helpers.rb     # get_chat_context (thread-aware), get_relevant_knowledge
│   │   ├── tts_voice.rb
│   │   ├── bober_voice.rb
│   │   ├── order_block.rb
│   │   ├── order_request.rb
│   │   ├── radio_search.rb
│   │   ├── radio_track.rb
│   │   ├── stats.rb
│   │   ├── radio_queue.rb
│   │   ├── weather.rb
│   │   ├── listeners.rb
│   │   ├── remove_track.rb
│   │   ├── remaining.rb
│   │   ├── history.rb
│   │   ├── radio_top.rb
│   │   ├── meta.rb
│   │   ├── help.rb
│   │   ├── gpt_chat.rb
│   │   ├── news.rb
│   │   ├── translate.rb       # GPT-based translation (no Yandex)
│   │   ├── dice.rb
│   │   ├── phrase_top.rb
│   │   ├── knowledge_add.rb
│   │   ├── knowledge_list.rb
│   │   ├── knowledge_delete.rb
│   │   ├── task_queue.rb     # "бот задачи" — background task status
│   │   └── fallback_reply.rb
│   ├── agent/
│   │   ├── tool_registry.rb   # Tool definitions registry for agent mode
│   │   ├── runner.rb          # Agentic loop: GPT → tool call → execute → repeat
│   │   └── tools/
│   │       ├── radio.rb       # Radio tools (8): track, queue, search, request, etc.
│   │       ├── weather.rb     # Weather tool
│   │       ├── google_search.rb  # Google search tool
│   │       ├── knowledge.rb   # Knowledge search/add/delete tools
│   │       ├── horoscope.rb   # Horoscope tool
│   │       ├── suno.rb        # Suno song generation tool
│   │       ├── image_gen.rb   # FLUX image generation tool
│   │       └── scratchpad.rb  # remember / forget — agent working memory (ADR-003)
│   ├── chat_context.rb        # ChatContext module: shared chat context + knowledge lookup for handlers
│   ├── task_handlers/
│   │   ├── suno_handler.rb    # Suno background task: LLM parse → GPT lyrics → submit → poll → deliver
│   │   └── image_gen_handler.rb # FLUX background task: LLM prompt → submit → poll → deliver photo
│   ├── task_runner.rb         # Generic DB-backed task poller + handler registry
│   ├── suno_client.rb         # Suno AI API client (submit, poll, compose)
│   ├── flux_client.rb         # FLUX 2 image generation API client (submit, poll)
│   └── robot/
│       └── robocoder.rb       # Base64+XOR encode/decode util
├── models/
│   ├── user.rb       # ActiveRecord: users
│   ├── song.rb       # ActiveRecord: songs (FTS5 search, metadata from audio tags)
│   ├── message.rb    # ActiveRecord: messages (user optional for bot replies)
│   ├── phrase.rb     # ActiveRecord: phrases
│   ├── knowledge.rb              # ActiveRecord: knowledge facts (with embedding_vector serialization)
│   ├── knowledge_compact_log.rb  # ActiveRecord: compaction run history
│   └── background_task.rb # ActiveRecord: persistent background tasks
├── db/
│   ├── bot.db        # SQLite3 database
│   └── migrate/      # ActiveRecord migrations (012 files)
├── lib/samples/      # MP3 backing tracks for karaoke TTS
├── Gemfile
├── Rakefile          # db:migrate tasks
├── Dockerfile
└── docker-compose.yml
```

---

## Core Classes

### `MessageResponder` — `lib/message_responder.rb`

Receives every inbound message. Builds a `CommandContext`, runs `dispatch`, then `deliver`.

- `respond` — entry point: saves message, skips stale ones, processes voice, calls `dispatch`
- `dispatch(ctx)` — iterates `Commands::REGISTRY`; returns result from first matching command
- `deliver(result)` — sends the `CommandResult` payload via the appropriate Telegram API call

### `CommandContext` — `lib/command_context.rb`

Keyword-init struct passed to every command:
```ruby
CommandContext = Struct.new(:bot, :message, :user, :chat_id, :radio, :reply_master, :cmd, keyword_init: true)
```

### `CommandResult` — `lib/command_result.rb`

Value object returned by every command's `execute`:
```ruby
CommandResult.text("hello")    # :text
CommandResult.sticker(id)      # :sticker
CommandResult.image(url)       # :image
CommandResult.voice(url)       # :voice
CommandResult.none             # :none (handled but no reply)
```

### `Commands::Base` — `lib/commands/base.rb`

Base class for all commands. Exposes `ctx` members as delegated accessors (`bot`, `message`, `user`, `chat_id`, `radio`, `reply_master`, `cmd`). Provides shared helpers:
- `admin?` — checks if current user has `admin` role
- `admin_denied` — returns a `CommandResult.text` with a random denial message from `Settings.replies['admin_denied']`

### `Commands::REGISTRY` — `lib/commands/registry.rb`

Ordered array of command classes. `dispatch` tries each in order; first `match?` wins. **Order matters.**

### `MessageSender` — `lib/message_sender.rb`

Thin wrapper around the Telegram bot client:
- `send` (text), `send_sticker`, `send_image`, `send_voice`
- Shows typing indicator before responses

### `Settings` — `lib/settings.rb`

Singleton that loads `config/settings.yml`. Validates required top-level keys on load. Access via `method_missing`:
```ruby
Settings.telegram['token']
Settings.chat_gpt['api_key']
```
Required keys: `telegram`, `auth`, `proxy`, `chat_gpt`, `voice_messages`, `aws`, `translator`.

---

## Database Schema

**ORM:** ActiveRecord 7.2 with SQLite3 (`db/bot.db`)
**Run migrations:** `bundle exec rake db:migrate`

| Table | Key Columns |
|-------|-------------|
| `chats` | `chat_id` (PK, bigint = Telegram chat id), `title`, `chat_type` (`group`/`supergroup`/`private`/`channel`), `authorized` (bool), `audio` (bool), `rate_limits` (JSON, mirrors Settings.auth.chats[].rate_limits), `first_seen_at`, `last_seen_at`. Populated at startup via `Chat.sync_from_config!` from `Settings.auth.chats` and per-message via `Chat.touch_seen`. Associations: `has_one :chat_state`, `has_many :messages`/`:background_tasks`/`:api_usages`/`:knowledge_facts`. |
| `users` | `uid` (Telegram ID), `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable — nil for bot replies), `chat_id`, `body`, `role` (`user`/`bot`), `message_id` (Telegram per-chat id, nullable on legacy rows), `reply_to_message_id`, `message_thread_id` (forum topic), `forwarded` (bool, default false), `edited_at` |
| `phrases` | `user_id`, `content` (unique) — user-submitted catchphrases |
| `knowledge` | `topic`, `content`, `embedding` (JSON float array), `source` (`manual`/`auto`), `chat_id` (bigint, indexed) |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |
| `songs` | `title`, `artist`, `album`, `genre`, `year` (int), `filepath` (unique, relative to music root), `duration` (int, seconds), `category` (top-level dir) |
| `songs_fts` | FTS5 virtual table indexing `title`, `artist`, `album`, `genre`, `category` — content table mode (`content='songs'`, `content_rowid='id'`), `unicode61 remove_diacritics 1` tokenizer, auto-synced via INSERT/UPDATE/DELETE triggers |
| `api_usage` | `chat_id` (nullable), `user_uid` (nullable — null for knowledge extraction/compaction), `model`, `purpose` (`agent`/`main_chat`/`translate`/`knowledge_extract`/`knowledge_compact`/`suno_lyrics`/`suno_tags`/`suno_parse`/`image_prompt`), `input_tokens`/`output_tokens`/`cache_read_tokens`/`cache_write_tokens`, `cost_cents` (decimal 10,4), `created_at` — one row per API response; `ApiUsage.record` is fire-and-forget (rescues errors so telemetry never breaks replies) |
| `chat_states` | `chat_id` (PK, bigint), `scratchpad` (JSON: `intentions`/`notes`/`expectations` arrays of `{id, content, created_at}`), `updated_at`. Per-chat agent working memory; written via the `remember`/`forget` agent tools, read into `{SCRATCHPAD}` on every agent turn. Hard cap 6000 chars with FIFO eviction. See ADR-003. |

**Relationships:**
- `User` has_many `messages` (FK: `user_uid` → `users.uid`)
- `User` has_many `phrases`
- `Message` belongs_to `user`, `optional: true` (bot replies have no user)

---

## Service Modules

### Radio — `lib/radio.rb`
Communicates with Liquidsoap server over a raw TCP socket on `localhost:1234`. Connection is **lazy** — socket opens on first use, not at startup. Sends text commands, parses responses. Key operations: get current track, search, request, manage queue, fetch stats.

Search uses `Song.search` (FTS5) with fallback to legacy file-path matching (`music.txt`). `radio.request` picks a random match and pushes the absolute path to Liquidsoap.

### Song — `models/song.rb`
ActiveRecord model for the music library. Populated by `MusicScanner` from audio file tags.
- `Song.search(query, limit:)` — multi-stage search: (1) FTS5 MATCH with prefix matching (`word*`); (2) Cyrillic→Latin transliteration via `translit` gem with k/c, ts/c, kh/h variants; (3) prefix truncation on transliterated variants; (4) LIKE fallback; (5) Levenshtein edit-distance fuzzy match via `editdist` custom SQLite function (registered in `DatabaseConnector.register_editdist`)
- `Song#absolute_path` — joins `Settings.radio['path']` + `filepath` for Liquidsoap `request.push`
- `Song#display_name` — `"Artist — Title (Year)"` from metadata

### MusicScanner — `lib/music_scanner.rb`
Reads audio file tags via `wahwah` (pure Ruby, no native deps), populates the `songs` table. Idempotent: updates existing records, creates new ones, removes orphans (by `updated_at` timestamp). Falls back to parsing artist/title from filepath if tags are empty. Run via `bundle exec rake music:scan`.

### GptMaster — `lib/gpt_master.rb`
HTTP client (HTTParty) supporting both Anthropic and OpenAI-compatible APIs. Provider selected via `settings.yml` `chat_gpt.provider`. One class-method interface:

- `GptMaster.ask(text, prompt:, setting:, chat_id:, purpose:)` — caller supplies prompt template (`{REQUEST}` only). Used for one-off tasks like translation, knowledge extraction/compaction, suno lyrics/tags/parse, and image prompt generation. No context, no cache split.

Chat commands go through `Agent::Runner` directly (which instantiates `GptMaster` with `setting: 'agent'`, `system_prompt:`, and tools); there is no `GptMaster.chat` class method anymore.

**Anthropic specifics:** uses `x-api-key` + `anthropic-version` headers, requires `max_tokens`, optionally enables extended thinking via `thinking_budget`. Extracts the `text` block from the `content` array (skipping thinking blocks). When a `system_prompt:` is supplied, it is sent as a `system` array with `cache_control: { type: 'ephemeral' }` on its single text block. When `call_raw(tools:)` is invoked, `cache_control` is attached to the **last** tool definition — caching the entire tools array as one prefix segment.
**OpenAI/DeepSeek specifics:** uses `Authorization: Bearer`, passes `thinking: {type: 'enabled'}` for reasoning models. `system_prompt:` is converted into a leading `{role: 'system'}` message. No explicit cache markers (these providers auto-cache).

**Telemetry:** every successful response's `usage` block is extracted (Anthropic: `input_tokens`/`output_tokens`/`cache_creation_input_tokens`/`cache_read_input_tokens`; OpenAI: `prompt_tokens` minus `prompt_tokens_details.cached_tokens`, `completion_tokens`) and persisted as an `ApiUsage` row tagged with `chat_id` and `purpose`. A one-line log entry (`GptMaster usage [model]: in=N out=M cache_r=X cache_w=Y cost=$0.0042 purpose=agent chat=-100…`) is also emitted. Telemetry errors are swallowed (`LOGGER.warn`) — a broken `api_usage` table never blocks a reply.

**Pricing:** `Settings.chat_gpt['pricing']` is a hash keyed by exact model id with `input`/`output`/`cache_read`/`cache_write` prices in USD per 1M tokens. Unknown models are logged and persisted with `cost_cents = 0`.

### GptHelpers — `lib/commands/gpt_helpers.rb`
Mixed into GPT commands. Delegates to `ChatContext` module (via `include ChatContext` + `super`), auto-passing `chat_id` and the current `message_thread_id` from the command context:
- `get_chat_context` — delegates to `ChatContext#get_chat_context(chat_id, thread_id: message.message_thread_id)`
- `get_relevant_knowledge(query)` — delegates to `ChatContext#get_relevant_knowledge(query, chat_id)`

Bot-reply persistence is no longer a command-level concern. Commands signal with `CommandResult.text(..., persist_as_bot_reply: true)`; `MessageResponder#deliver` creates the `messages` row after `MessageSender#send` returns, capturing Telegram's `message_id` and the originating `message_thread_id`.

### EmbeddingService — `lib/embedding_service.rb`
Calls an OpenAI-compatible embeddings API (`embeddings.api_url`) to produce float vectors for text. Returns `nil` on failure. Used by `KnowledgeBase`.

### KnowledgeBase — `lib/knowledge_base.rb`
Semantic RAG store:
- `KnowledgeBase.add(topic:, content:, source:)` — embed + store a fact; deduplicates via cosine similarity threshold (0.92)
- `KnowledgeBase.search(query, top_k:)` — embed query, return top-K facts by cosine similarity
- `KnowledgeBase.extract_and_store(messages)` — uses `GptMaster.ask` with a structured prompt to extract 3–7 facts from recent chat messages, stores non-duplicate ones as `source: 'auto'`; calls `maybe_trigger_compact` after each batch
- `KnowledgeBase.compact!(chat_id:, threshold: 0.85)` — clusters all stored embeddings via pairwise cosine similarity + union-find (no API calls), then LLM-merges each cluster ≥ 2 into one comprehensive fact; logs all cluster before/after to `log/knowledge_compact.log`; writes result to `knowledge_compact_log` table

Auto-extraction is triggered by `MessageResponder#maybe_extract_knowledge` every `knowledge.extract_every` user messages per chat, runs in a background `Thread`.

Auto-compaction is triggered by `maybe_trigger_compact` after each extraction batch. Uses an adaptive threshold: if the last compaction found only small clusters (avg ≤ 2 entries), the effective threshold scales up to 3× `compact_at` before the next run. Threshold settings: `knowledge.compact_at` (entry count trigger, default 100), `knowledge.compact_threshold` (cosine similarity, default 0.85). Logs to `log/knowledge_compact.log`.

### Agent Mode — `lib/agent/`
`GptChat` and `GptQuestion` always route through `Agent::Runner`. The runner implements an agentic tool-use loop:

1. Send user message + tools definitions to LLM
2. If LLM returns tool calls → execute them, append results, repeat
3. If LLM returns text → return as final response
4. Safety cap: max 5 iterations, then force a text response

**Components:**
- `Agent::ToolRegistry` — central registry; tools register via `ToolRegistry.register(name:, description:, parameters:, handler:, admin_only:)`
- `Agent::Runner` — orchestrates the loop, handles provider differences (Anthropic vs OpenAI tool-calling formats), supports vision (multi-modal messages with images)
- `lib/agent/tools/*.rb` — tool definitions (radio×8, weather, google_search, knowledge×3, horoscope, compose_song, generate_image, load_messages)

**Tool-calling formats:**
- Anthropic: `tools: [{name, description, input_schema}]`, response `content: [{type: "tool_use"}]`, results as `{type: "tool_result"}`
- OpenAI: `tools: [{type: "function", function: {...}}]`, response `tool_calls: [...]`, results as `{role: "tool"}`

Admin-only tools are filtered from definitions AND checked at execution time (denial messages pulled from `Settings.replies['admin_denied']`). Tool results are truncated to 2000 chars.

**Vision support:** When a user replies to a photo with a bot-addressed message (e.g. "бот что тут?"), `GptChat` downloads the photo via Telegram API, base64-encodes it, and passes it to `Agent::Runner`. The runner builds a multi-modal message with an `image` content block for the Anthropic API. Falls back to text-only if the download fails or there's no photo.

### Background Task Queue — `lib/task_runner.rb` + `lib/task_handlers/`
Generic DB-backed persistent task system for long-running operations. A poller thread runs inside the bot process (started in `Telegram::Bot::Client.run`, reusing `bot.api`).

**Components:**
- `BackgroundTask` model — ActiveRecord wrapper for `background_tasks` table with status helpers (`mark_done!`, `mark_failed!`, `increment_attempts!`, `timed_out?`)
- `TaskRunner` — generic poller + handler registry. Polls pending tasks every 10s, dispatches to registered handlers by `task_type`
- Handler classes in `lib/task_handlers/` — each implements `def call(task, api)` returning `:pending`, `:done`, or `:failed`

**Adding a new task type:**
1. Create `lib/task_handlers/my_handler.rb` with `def call(task, api)` method
2. Register: `TaskRunner.register('my_type', MyHandler)`
3. Enqueue: `BackgroundTask.create!(task_type: 'my_type', chat_id: ..., params: {}.to_json)`

**Current handlers:**
- `SunoTaskHandler` (`suno_generate`) — LLM request parsing → GPT lyrics composition → LLM tag enrichment → Suno V5 API submit → poll → download both clip variants → send as media group with `Performer_-_Song_Name.mp3` filenames → send lyrics as reply. Uses `ChatContext` for context-aware lyrics. Triggered exclusively via the `compose_song` agent tool (no direct command).
- `ImageGenTaskHandler` (`image_generate`) — LLM English prompt generation (with chat context + knowledge) → FLUX 2 API submit → poll → send photo. Uses `ChatContext` for context-aware prompts. Triggered exclusively via the `generate_image` agent tool (no direct command).
- `KnowledgeCompactHandler` (`knowledge_compact`) — calls `KnowledgeBase.compact!` for the task's chat; logs to `log/knowledge_compact.log`; enqueued automatically by `maybe_trigger_compact` when entry count crosses the adaptive threshold.

### ChatContext — `lib/chat_context.rb`
Single source of truth for chat context and knowledge lookup. Included by task handlers (directly) and by `GptHelpers` (which delegates with auto-passed `chat_id` + current `message_thread_id`). Provides:
- `get_chat_context(chat_id, thread_id: nil)` — fetches the last N messages as a JSON array. Each entry is `{id, who, msg}` with optional `reply_to`, `thread`, `fwd`, `edited`. When `thread_id` is set, scopes the query to the same forum topic. When any in-window `reply_to` points to a `message_id` that isn't in the window, the helper fetches that one row from DB and prepends it (one-hop out-of-window backfill). Rescues to `''` on error.
- `get_relevant_knowledge(query, chat_id)` — embeds query, retrieves top-K knowledge facts as JSON; rescues to `''` on error
- `ChatContext.serialize_msg(row)` — module method shared by `get_chat_context` and the `load_messages` agent tool to produce the `{id, reply_to, thread, fwd, edited, who, msg}` hash from a row.

### SunoClient — `lib/suno_client.rb`
HTTP client for the Suno AI song generation API (`sunoapi.org`), using V5 model. Key methods:
- `submit(title:, lyrics:, tags:)` — POST to `/api/v1/generate`, returns `task_id`
- `poll_once(task_id)` — GET status, returns `:pending`, `:failed`, or `Array<{ audio_url:, title:, duration: }>` (all clip variants)
- `compose(...)` — blocking convenience (submit + poll loop)
- `SunoClient.resolve_genre(text)` — maps Russian genre names to English style tags (~50 genres)
- **Important:** Suno blocks artist names in tags — describe sound characteristics instead

### FluxClient — `lib/flux_client.rb`
HTTP client for the FLUX 2 image generation API (`api.bfl.ai`). Async: submit → poll.
- `submit(prompt:, width:, height:)` — POST to `/v1/{model}`, returns `task_id`
- `poll_once(task_id)` — GET `/v1/get_result`, returns `:pending`, `:failed`, or `{ url: "..." }`
- Uses `safety_tolerance: 5` (max without special auth) and `output_format: 'jpeg'`

### TtsService — `lib/tts_service.rb`
Facade over Polly. `TtsService.speak(text, voice:, speed:, minus:, track_id:)` generates OGG and returns the public URL.

### Polly — `lib/polly.rb`
AWS Polly TTS synthesis (region: `eu-west-1`). Voices: `Maxim` (Russian), `Hans` (German). Post-processes MP3 with FFmpeg to OGG Opus at 32 kbps. Supports karaoke mode: mixes speech over an MP3 backing track from `lib/samples/`.

### Gogolmogol — `lib/gogolmogol.rb`
Google Custom Search API. Supports image and GIF queries. Falls back across a pool of API key pairs when rate-limited.

### Horoscope — `lib/horoscope.rb`
Scrapes XML from `img.ignio.com` for zodiac horoscopes. Also scrapes `newsler.ru` for erotic horoscopes. Uses Nokogiri.

### Weather — `lib/weather.rb`
OpenWeatherMap JSON API. Returns temperature, wind speed, cloud cover for a given city.

### ReplyMaster — `lib/reply_master.rb`
Loads `config/replies/*.yml`. Each entry has a regex trigger and a list of response templates. Randomly selects responses. Also pulls user-saved `phrases` from the DB for personalized insult replies.

### Dice — `lib/dice.rb`
Rolls 2 dice for user and 2 for bot, determines winner, returns templated response from `config/lib/dice.yml`.

---

## External Services

| Service | Protocol | Auth |
|---------|----------|------|
| Telegram Bot API | HTTPS long-polling | Bot token |
| Liquidsoap Radio Server | Raw TCP socket | None (localhost) |
| Anthropic / OpenAI-compatible API | HTTPS/HTTParty | x-api-key / Bearer token |
| OpenAI Embeddings API | HTTPS/HTTParty | Bearer token |
| AWS Polly | AWS SDK | Access key + secret |
| Google Custom Search | REST | API key + CX key |
| OpenWeatherMap | REST | API key |
| img.ignio.com | HTTP scrape | None |
| newsler.ru | HTTP scrape | None |
| lenta.ru | RSS | None |
| Suno AI (sunoapi.org) | REST/HTTParty | Bearer token |
| FLUX 2 (api.bfl.ai) | REST/HTTParty | x-key header |

---

## Command Reference

### Radio commands (prefix `!`)
| Command | Description |
|---------|-------------|
| `!заказ / !request [track]` | Request a track (rate-limited for `new` users) |
| `!поиск / !search [query]` | Search track database |
| `!трек / !track` | Current playing track |
| `!queue / !очередь` | Request queue |
| `!слушатели / !listeners` | Listener count |
| `!убрать ID` | Remove from queue (admin only) |
| `!remaining / !осталось` | Time remaining on current track |
| `!история / !history` | Recently played |
| `!топ ID` | Move track to top of queue |
| `!мета / !meta` | Track metadata |
| `!статистика [день/неделя/месяц]` | Play statistics graph |
| `!новости / !news` | News from Lenta RSS |
| `!кости / !bones` | Dice game |
| `!погода city[,country]` | Weather |

### Task Queue
| Command | Description |
|---------|-------------|
| `бот задачи` | Show last 10 background tasks for the current chat |

### AI / Text
| Command | Description |
|---------|-------------|
| `бот <text>` | GPT response (default model, with chat context + knowledge) |
| `жпт <text>` / `балаболь <text>` | GPT response (alternative triggers) |
| `бот почему/как/зачем... <text>` | GPT question matcher |
| `бот запомни <content>` | Add fact to knowledge base (admin only) |
| `бот знания` | List all knowledge base entries with IDs |
| `бот забудь <id>` | Delete a knowledge base entry (admin only) |
| `бот сожми знания` | LLM-compact near-duplicate knowledge entries (admin only) |

### Voice TTS
| Command | Description |
|---------|-------------|
| `ублюдки / бот скажи [ганс] [минус] [track#] [text]` | Text-to-speech (Maxim or Hans voice, optional karaoke) |
| `бобёр [минус] [track#]` | Random phrase as TTS |

### Translation (GPT-powered)
| Command | Description |
|---------|-------------|
| `бот пиздани [text]` | Translate to Ukrainian |
| `бот бульбани [text]` | Translate to Belarusian |
| `бот шпрехни [text]` | Translate to German |
| `бот пшекни [text]` | Translate to Polish |
| `бот блгрни [text]` | Translate to Bulgarian |
| `бот татарни [text]` | Translate to Tatar |
| `бот казахни [text]` | Translate to Kazakh |
| `бот грекни [text]` | Translate to Greek |
| `бот сербни [text]` | Translate to Serbian |

### Info / Entertainment
| Command | Description |
|---------|-------------|
| `бот топ` | User phrase leaderboard |
| `бот чо нового / новости` | Latest news (RSS) |
| `!помощь / !help` | Command list |

Horoscopes, Google search, image search, gif search — no direct command.
The agent (via `бот <anything>` → `GptChat`) handles them through its
`horoscope`, `google_search`, and `generate_image` tools and can compose
multiple tools in a single turn (e.g. "бот найди новости и нарисуй" →
`google_search` then `generate_image`).

---

## Configuration

Settings are split into two files, deep-merged (`settings.yml` overrides `settings.common.yml`):
- `config/settings.common.yml` — non-secret defaults (prompts, models, URLs); committed to git
- `config/settings.yml` — secrets & overrides (API keys, chat IDs); gitignored

Key setting groups:

```yaml
telegram:
  token: ...
auth:
  chat_ids: [...]          # Whitelisted chat IDs
  audio_chat_ids: [...]    # Chats where voice messages are processed
proxy:
  enabled: true/false
  host: ...
  port: ...
  user: ...
  password: ...
chat_gpt:
  providers:
    anthropic:
      api_key: sk-ant-...
      api_type: anthropic         # 'anthropic' or 'openai'
      api_url: https://api.anthropic.com/v1/messages  # optional, has defaults
    openai:
      api_key: sk-...
      api_type: openai
    deepseek:
      api_key: sk-...
      api_type: openai
      api_url: https://api.deepseek.com/v1/chat/completions
  settings:
    main:                         # used for GptMaster.ask (translate, knowledge, suno, image prompt)
      provider: anthropic
      model: claude-sonnet-4-6
      max_tokens: 16000
      thinking_budget: 10000      # optional: Anthropic extended thinking
    agent:                        # used for Agent::Runner tool-calling loop
      provider: anthropic
      model: claude-haiku-4-5
      max_tokens: 4096
    embedder:                     # used for EmbeddingService
      provider: openai
      model: text-embedding-3-small
  pricing:                        # USD per 1M tokens; used by ApiUsage.compute_cost
    claude-sonnet-4-6:
      input: 3
      output: 15
      cache_read: 0.30
      cache_write: 3.75
    claude-opus-4-7:
      input: 15
      output: 75
      cache_read: 1.50
      cache_write: 18.75
  context_messages_size: 30
  agent_prompt: "...{CACHE_BREAK}...{KNOWLEDGE}...{CONTEXT}...{REQUEST}..."
knowledge:
  top_k: 3            # facts to inject per GPT call
  extract_every: 50   # auto-extract after every N user messages per chat
  compact_at: 100     # trigger background compaction when entry count reaches this
  compact_threshold: 0.85  # cosine similarity threshold for clustering near-dupes
suno:
  api_url: https://api.sunoapi.org
  api_key: ...
  model: V5
flux:
  api_url: https://api.bfl.ai
  api_key: ...
  model: flux-2-pro
replies:
  admin_denied:            # random denial messages for unauthorized admin commands
    - "а ты кто такой вообще?!"
    - "только для своих, брат"
    - ...
weather:
  api_url: ...
  api_key: ...
google:
  - api_key: ...
    cx_key: ...
aws:
  key_id: ...
  access_key: ...
translator:
  # legacy key — kept in settings but Yandex is no longer used
logging:
  path: log/bot.log   # relative to project root
  level: debug        # debug | info | warn | error
  max_size_mb: 100    # rotate when file exceeds this size
  keep_files: 5       # number of rotated files to keep
```

---

## Logging

All output is unified in a single log file configured via `settings.yml`:

| Source | Destination |
|--------|-------------|
| App logger (`LOGGER`) | `log/bot.log` |
| Telegram client | `log/bot.log` |
| ActiveRecord SQL | `log/bot.log` |
| Knowledge compaction (`COMPACT_LOGGER`) | `log/knowledge_compact.log` |

`AppConfigurator#setup_logging` runs first in `configure`, builds the loggers from settings, and passes the main logger to `DatabaseConnector`. The global `LOGGER` and `COMPACT_LOGGER` constants are assigned in `bot.rb` after `configure` returns.

**Chat-id prefix convention.** Every per-message / per-chat / per-task log line is prefixed with `[chat=<id>]` so one grep reconstructs the full timeline for a single chat (e.g. `grep 'chat=-1001273623296' log/bot.log`). Agent turns carry an additional `[AGENT]` tag. Generic / singleton services without chat context (radio socket, FluxClient, SunoClient, Gogolmogol, Polly, etc.) intentionally log without the prefix — their per-call context is already surrounded by chat-tagged lines from the caller.

Log rotation: size-based — rotates at `max_size_mb`, keeps `keep_files` old files (e.g. `bot.log.0`, `bot.log.1`). The `log/` directory is created automatically at startup.

---

## Deployment

- **Ruby:** 4.0
- **Docker:** `Dockerfile` + `docker-compose.yml`
- **Process management:** `daemons` gem — PID file in `pids/42fm_bot.pid`. `:monitor => false` — the bot's own `rescue/retry` loop handles restarts.
- **Starting/stopping:** always use `./bin/bot start|stop|restart|status`
- **SOCKS proxy:** configured in `settings.yml`, applied globally in `AppConfigurator#setup_proxy` via `socksify` (patches `Net::HTTP`)
