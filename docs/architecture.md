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
│   │       ├── image_gen.rb   # Image generation tool (agent picks model per request from the catalog)
│   │       └── scratchpad.rb  # remember / forget — agent working memory (ADR-003)
│   ├── chat_context.rb        # ChatContext module: shared chat context + knowledge lookup for handlers
│   ├── task_handlers/
│   │   ├── suno_handler.rb    # Suno background task: LLM parse → GPT lyrics → submit → poll → deliver
│   │   └── image_gen_handler.rb # Image-gen background task: LLM prompt → adapter.submit → poll → deliver photo (provider-agnostic)
│   ├── task_runner.rb         # Generic DB-backed task poller + handler registry
│   ├── suno_client.rb         # Suno AI API client (submit, poll, compose)
│   ├── model_provider_client.rb # Generic Bearer+JSON HTTP client (formerly AtlasClient); used by Atlas + CloseRouter adapters
│   ├── image_gen.rb           # Top-level facade: ADAPTERS registry + current_adapter / adapter_for(snapshot)
│   ├── image_gen/
│   │   ├── adapter.rb         # Base class: submit(...,model:) / poll_once / prompt_template(:t2i|:edit) / name / synchronous?
│   │   ├── catalog.rb         # ImageGen::Catalog: agent-selectable model catalog (config image_gen.models), lazy + memoized
│   │   ├── flux_adapter.rb    # FLUX 2 via api.bfl.ai (absorbs former FluxClient + FLUX-tuned templates)
│   │   ├── atlas_adapter.rb   # Atlas Cloud (multi-model: nano-banana-2 default / Wan / ...) via ModelProviderClient
│   │   └── closerouter_adapter.rb # CloseRouter Nano Banana Pro (synchronous /v1/images/generations; no polling)
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
- `process_voice_message` — audio passthrough for `audio:`-enabled chats: posts the voice file's direct (token-bearing, deliberate) URL to the chat. Resolves getFile through `TelegramFile.public_url`, which handles both the gem-2.x typed `Types::File` and legacy Hash shapes — inline `file['result']` access raises `Dry::Struct::MissingAttributeError` on the typed object and aborts dispatch (prod bug, fixed Jun 2026)
- `dispatch(ctx)` — iterates `Commands::REGISTRY`; returns result from first matching command
- `deliver(result)` — sends the `CommandResult` payload via the appropriate Telegram API call, then persists a `role: 'bot'` `messages` row for every successfully-sent type (see *Bot-reply persistence* below)

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

**Private chats need no prefix.** `GptChat#private_no_prefix?` matches any non-slash text when `message.chat.type == 'private'`, so a bare DM goes straight to the agent (slash commands fall through to `FallbackReply`). Deliberate consequences:
- `FallbackReply` (ReplyMaster Easter eggs) is shadowed in DMs for plain text.
- `BoberVoice`/`TtsVoice` still win in DMs — their unprefixed PATTERNs (`боб(е|ё)р` — unanchored, matches mid-sentence; `ублюдки …` — start-anchored) sit above `GptChat` in the registry. Pinned by registry-level tests in `test/gpt_chat_test.rb`.
- The Phrase egg (`maybe_save_phrase`) stays gated on explicit addressing (prefix or reply-to-bot) — bare DM «ты …»/«вы …» is not harvested.
- A super-admin with an armed admin-menu `awaiting_input` session has plain DM text consumed by the menu first (escape: `/cancel`, any `/`-command, or a `бот`/`жпт` prefix).
- Cost: every plain-text DM runs the full agent path (LLM call + knowledge embedding lookup). Bare DM text reaches the agent downcased, same as the reply-to-bot path.

### `MessageSender` — `lib/message_sender.rb`

Thin wrapper around the Telegram bot client:
- `send` (text), `send_sticker`, `send_image`, `send_voice`
- Shows typing indicator before responses

**Rich Messages (Bot API 10.1).** `send` prefers Telegram **Rich Messages** (`sendRichMessage`, Rich Markdown = GitHub-Flavored Markdown, which the LLM already emits) and falls back to the classic `sendMessage` path. The classic path is unchanged (`split_text` at 4096 → `send_chunk` with legacy `parse_mode:'Markdown'` + `sanitize_markdown` + plain-text retry). One log line per branch: `rich=ok id=…` / `rich=fallback reason=…` / `rich=ambiguous no-fallback …` (grep to watch the fallback rate). Key details:
- **Fallback is failure-classified (no duplicates)**: `TelegramRichClient` raises `Rejected` (definitely-not-delivered: over-length, `ok:false`, connect/write failure, non-JSON body) → classic fallback runs; or `Ambiguous` (request sent, no confirmation — e.g. `Net::ReadTimeout` after the 4s cutoff, which is realistic behind the SOCKS proxy) → fallback is **suppressed** because Telegram may already have posted it. `ok:true` with no `message_id` is likewise treated as *sent* (no re-send, just no DB row). `send` returns an Integer id, or nil (either fell back, or sent-but-id-unknown). Length limit is counted in **characters** (`String#length`), not bytes — a Cyrillic bot would otherwise sideline ~16k-char messages under Telegram's 32768-*char* rich limit.
- **Why a custom client** (`lib/telegram_rich_client.rb`): the gem's `Api#method_missing` has an `ENDPOINTS` whitelist (`return super unless ENDPOINTS.key?(endpoint)`) so `bot.api.sendRichMessage` raises `NoMethodError`. The gem's public `Api#call` would work but uses the global 20s timeout; `TelegramRichClient` is a plain Net::HTTP JSON POST with a **short 4s timeout** so a stalled rich call can't freeze the single-threaded `bot.listen` loop (rides the socksify proxy on prod like any Net::HTTP call).
- **`*` semantics flip**: legacy Markdown `*x*` = bold, but Rich Markdown/GFM `*x*` = *italic* (`**x**` = bold). The agent system prompt (`settings.common.yml`) was updated to teach GFM (`**bold**`), and hand-authored `*bold*` headers in `cost_report`/`task_queue`/`knowledge_list` were converted to `**bold**` so they don't render italic.
- **Classic fallback cleans GFM-only markers**: `sanitize_markdown` now also strips `||spoiler||`/`~~strike~~`/leading `#` heading markers (outside code spans, via `strip_gfm_only`) so a rich→classic fallback (or the rich-off kill-switch state) isn't littered with literal markup — and a spoiler doesn't reveal as bare `||…||`. Pipes/`#` inside code spans are preserved.
- **Kill switch**: `telegram.rich_messages` (default **true** in `settings.common.yml`; set `false` in prod `settings.yml` + restart to disable). Guarded so tests with a minimal Settings stub take the classic path.
- **Scope**: only text through `MessageSender#send`. Background-task senders (`task_runner`, `suno_handler`, `image_gen_handler`, `agent_event_handler`, `wrapped_digest_handler`, …) call `bot.api.sendMessage` directly and stay on legacy Markdown — unaffected.
- **Cadence**: rich sends up to 32768 chars as ONE message (classic split only above that); replies that were previously chunked at 4096 now arrive as a single message. Rich limits: 32768 chars, 500 blocks, 16 nest levels, 50 media, 20 table cols.
- **Deferred (Phase 2)**: `sendRichMessageDraft` streaming (private-chat-only; needs GptMaster SSE + background-thread offload off the single-threaded loop), media blocks, `editMessageText` rich edits.

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
| `messages` | `user_uid` (nullable — nil for bot replies), `chat_id`, `body`, `role` (`user`/`bot`), `message_id` (Telegram per-chat id, nullable on legacy rows), `reply_to_message_id`, `message_thread_id` (forum topic), `forwarded` (bool, default false), `edited_at`, `bg_task_external_id` (nullable — populated for bot-delivered media so `cover_art` can resolve a reply-target back to its source song), `attachment_file_id` + `attachment_mime_type` + `attachment_title` + `attachment_performer` + `attachment_duration` (nullable — populated when an incoming user message has audio/voice/audio-MIME document; title falls back to `Document.file_name` minus extension when ID3 title is absent. Used by `Commands::GptChat#attached_audio` lookback and surfaced in `ChatContext.serialize_msg` as `audio: true` + `audio_meta: {title, performer, duration, mime}` so the agent names cover/add-vocals output after the actual track instead of inferring from prior chat context. Audio-only messages (no text caption) are persisted with body=`'[аудио]'` so they appear in chat context), `attachment_photo_file_id` (photo attachments, largest size ≤1280px — fetched on demand by the `view_image` agent tool; photo-only rows get body `[фото]`), `reactions_count` (int, default 0 — aggregate Telegram reaction count maintained by `BotDispatcher#handle_reaction` (per-user delta, best-effort) and `#handle_reaction_count` (authoritative overwrite); feeds `Message.top_reacted` → `бот цитата` + Wrapped "funniest"; see "Telegram reactions capture") |
| `phrases` | `user_id`, `content` (unique) — user-submitted catchphrases |
| `knowledge` | `topic`, `content`, `embedding` (JSON float array), `source` (`manual`/`auto`), `chat_id` (bigint, indexed) |
| `knowledge_compact_log` | `chat_id`, `merged`, `removed`, `kept`, `threshold`, `created_at` — one row per compaction run |
| `background_tasks` | `task_type`, `status` (`pending`/`done`/`failed`), `chat_id`, `external_id`, `params` (JSON), `result` (JSON), `attempts`, `max_attempts` |
| `songs` | `title`, `artist`, `album`, `genre`, `year` (int), `filepath` (unique, relative to music root), `duration` (int, seconds), `category` (top-level dir) |
| `songs_fts` | FTS5 virtual table indexing `title`, `artist`, `album`, `genre`, `category` — content table mode (`content='songs'`, `content_rowid='id'`), `unicode61 remove_diacritics 1` tokenizer, auto-synced via INSERT/UPDATE/DELETE triggers |
| `api_usage` | `chat_id` (nullable), `user_uid` (nullable — null for knowledge extraction/compaction), `model`, `purpose` (`agent`/`main_chat`/`translate`/`knowledge_extract`/`knowledge_compact`/`suno_compose`/`suno_tags`/`image_prompt`), `input_tokens`/`output_tokens`/`cache_read_tokens`/`cache_write_tokens`, `cost_cents` (decimal 10,4), `created_at` — one row per API response; `ApiUsage.record` is fire-and-forget (rescues errors so telemetry never breaks replies) |
| `chat_states` | `chat_id` (PK, bigint), `scratchpad` (JSON: `intentions`/`notes`/`expectations` arrays of `{id, content, created_at}` + the rules-war `rules` array `{id: r-NNN, content, set_by, set_by_name, target, expires_at, challenges_survived, court?}` + top-level `challenge_log` timestamps), `updated_at`. Per-chat agent working memory; written via the `remember`/`forget` agent tools and the rules-game tools, read into `{SCRATCHPAD}` on every agent turn. Hard cap 6000 chars with FIFO eviction (rules exempt — see "Rules-war game"). See ADR-003. |

**Relationships:**
- `User` has_many `messages` (FK: `user_uid` → `users.uid`)
- `User` has_many `phrases`
- `Message` belongs_to `user`, `optional: true` (bot replies have no user)

---

## Service Modules

### Radio — `lib/radio.rb`
Communicates with Liquidsoap server over a raw TCP socket on `localhost:1234`. Connection is **lazy** — socket opens on first use, not at startup. Sends text commands, parses responses. Key operations: get current track, search, request, manage queue, fetch stats.

**Keepalive.** `Radio#start_keepalive` (called from `lib/bot.rb` at startup) runs a background thread that pings Liquidsoap every 20s with a harmless `request.alive`. Liquidsoap closes idle telnet connections, and reusing a stale socket loses the first command's response — this made `!track` return `(нет данных)` while a track was actually playing. The keepalive absorbs that reconnect-on-idle cost on the throwaway ping so user commands always hit a warm socket. Idempotent. `Radio#command`'s reconnect rescue also catches `Timeout::Error` so a hung half-open socket self-heals. `Radio#track` degrades to `"сейчас ничего не играет"` when the source has no metadata.

**Request queue (`!queue`).** The user-request queue is `request.queue(id="request")`. That operator **prefetches** the next request out of its visible queue, so the `request.queue` telnet command reads empty within seconds of a `request.push` (verified on Liquidsoap 2.2.5; no `secondary_queue` in 2.x). So `Radio#request` tags each push with the `annotate:` protocol (`request.push annotate:bot_req="1":<path>`, `Radio::REQUEST_TAG`), and `Radio#queue` enumerates `request.alive` (all live requests, rotation + user) and keeps only those whose `request.metadata` carries `bot_req="1"`. This reliably lists the user's queued + now-playing requests and self-prunes as they finish. The `source` metadata field is unreliable for this (it's a file/playlist tag, `"music_txt"` for library pushes).

Search uses `Song.search` (FTS5) with fallback to legacy file-path matching (`music.txt`). `radio.request` picks a random match and pushes the absolute path to Liquidsoap.

### Song — `models/song.rb`
ActiveRecord model for the music library. Populated by `MusicScanner` from audio file tags.
- `Song.search(query, limit:)` — multi-stage search: (1) FTS5 MATCH with prefix matching (`word*`), `unicode61 remove_diacritics 1` tokenizer; (2) Cyrillic→Latin transliteration via `translit` gem with k/c, ts/c, kh/h, and w/v variants (в→w in translit but v in English proper nouns, e.g. "нирвана"→"nirwana"→"nirvana"); (3) prefix truncation on transliterated variants; (4) LIKE fallback; (5) Levenshtein edit-distance fuzzy match via `editdist` custom SQLite function (registered in `DatabaseConnector.register_editdist`) — catches e.g. "раммштайн"→Rammstein (distance 3)
- `Song#absolute_path` — joins `Settings.radio['path']` + `filepath` for Liquidsoap `request.push`
- `Song#display_name` — `"Artist — Title (Year)"` from metadata

### MusicScanner — `lib/music_scanner.rb`
Reads audio file tags via `wahwah` (pure Ruby, no native deps), populates the `songs` table. Idempotent: updates existing records, creates new ones, removes orphans (by `updated_at` timestamp). Falls back to parsing artist/title from filepath if tags are empty. Run via `bundle exec rake music:scan`.

### RateLimiter — `lib/rate_limiter.rb`
Per-chat, per-service rate limiting (counts `BackgroundTask` rows in a rolling window). Per-role overrides: `Settings.auth['rate_limits']['admin'][service]` overrides the regular bucket when `RateLimiter.exceeded?(..., role: 'admin')` is called with `role: 'admin'`. Agent tools pass `ctx[:user]&.role`. Counters stay per-chat-shared (no per-user counter). For **admins** the effective limit is the **more permissive** (higher max-per-minute) of the per-chat bucket and `auth.rate_limits.admin.<svc>` — so a super-admin *raising* their own cap via the /admin menu applies, but a *restrictive* per-chat/config-seeded value can't drop an admin below the admin override. Non-admins use the per-chat bucket directly. (Menu edits and config seeds share the `chat.rate_limits` column via `Chat.sync_from_config!`, so they're indistinguishable — hence "more permissive", not "menu edit wins".) Order — non-admin: `chat.rate_limits.<svc>` → `auth.rate_limits.<svc>` → hard-coded `{max:1,window:20}`; admin: `more_permissive(per-chat, admin-override)` → default → hard-coded.

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

**Bot-reply persistence.** `MessageResponder#deliver` persists a `role: 'bot'` `messages` row for **every** successfully-sent output type — not just GPT replies — so the agent's chat context sees the bot's own non-GPT output and any bot message a user replies to can be resolved back to a row. After the Telegram send returns:
- `:text` → direct `Message.create` using the `message_id` `MessageSender#send` returns (`reply_to_message_id` from the result meta, `message_thread_id` from the inbound message). Blank/whitespace payloads are skipped (avoids the Telegram "message text is empty" 400).
- `:sticker` / `:image` / `:voice` → `Message.persist_bot_reply(response:)` (extracts `message_id` + `message_thread_id` from the raw Telegram response) with a body marker `[стикер]` / `[картинка]` / `[голос]`. `:image` persists only when `MessageSender#send_image` returns a non-nil response — its rescue path returns `nil` because it sent a fallback text, not an image.

Media sends (sticker/image/voice) thread the originating `message_thread_id` so forum-topic replies land in-thread. The old `persist_as_bot_reply` opt-in flag was retired — persistence is unconditional. Background-task media (image_gen/suno/cover_art/wav handlers) self-persist (never route through `deliver`), but their `persist_bot_media_row(s)` wrappers are thin delegations to `Message.persist_bot_reply` — the **single centralized write path** for all bot-side rows. It handles every response shape (Telegram OpenStruct/typed object, raw Hash, `'result'`-enveloped Hash, single media-group element), threads `reply_to:` and `bg_task_external_id:`, and captures `attachment_photo_file_id` from photo sends (via `Message.photo_file_id_from` / `pick_photo_file_id`, ≤1280px) so the agent can re-view the bot's own generated images — image_gen output, Suno cover art, `deliver :image` — through the `view_image` tool.

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

### Agent Scratchpad — `lib/agent/scratchpad.rb` + `models/chat_state.rb`
Per-chat working memory distinct from the knowledge base — knowledge = facts about the world, scratchpad = agent's own intentions/expectations/notes. Stored in `chat_states.scratchpad` (JSON), one row per chat. Three categories: `intentions`, `notes`, `expectations`. Hard cap 6000 chars (~1500 tokens) with FIFO eviction from the largest category. Rendered as `{SCRATCHPAD}` placeholder in `agent_prompt`. Agent manages it via `remember`/`forget` tools (`lib/agent/tools/scratchpad.rb`). See ADR-003 for the full architecture rationale.

**Compaction** (`Agent::Scratchpad.compact(chat_id, max_age_days:)`): pure-Ruby pruning of entries past `expires_at` plus entries older than `max_age_days` (default 30). Runs inline on every `Scratchpad.add` for expiry-based pruning. Manual run: `rake scratchpad:compact [MAX_AGE_DAYS=N] [CHAT_ID=...]`. No LLM calls — at the 6000-char cap, semantic compaction isn't worth the cost. The `бот сожми знания` (admin only) command triggers compaction immediately for the current chat.

**Time-deferred intentions — `CronScheduler` (`lib/cron_scheduler.rb`)**: thread that wakes every 60s, finds chats with scratchpad intentions whose `due_at` has passed, and emits one `agent_event(cron_tick)` per chat carrying the due intent ids. Marks them `acted: true` so the next tick doesn't re-dispatch. Subject to the same per-chat 10/hour `agent_event` rate cap. Lets the agent act on time-deferred intentions (e.g. retry a rate-limited image after the cooldown). Started from `lib/bot.rb` alongside `TaskRunner.start`. The tick also runs `maybe_fire_digests` (weekly Wrapped auto-post — own `weekly_wrapped` task type, bypasses the agent_event cap) and `maybe_announce_expired_rules` (rules-war obituaries — see "Rules-war game").

**`Agent::ToolResult`** — structured tool-result protocol. Tool handlers may return either a String (passthrough) or `Agent::ToolResult.deferred(user_text:, intent:, retry_in_min:)` for rate-limited / retry-later outcomes. `Agent::Runner` auto-writes the intent to the chat's scratchpad on `:deferred` (with `due_at = now + retry_in_min`) and forwards a `[deferred retry_in=Nmin, intent saved to scratchpad] <user_text>` prefix to the LLM. New deferred-style tools just call `Agent::ToolResult.deferred(...)` — no per-tool prompt scaffolding required.

### Agent Mode — `lib/agent/`
`GptChat` and `GptQuestion` always route through `Agent::Runner`. The runner implements an agentic tool-use loop:

1. Send user message + tools definitions to LLM
2. If LLM returns tool calls → execute them, append results, repeat
3. If LLM returns text → return as final response
4. Safety cap: max 5 iterations, then force a text response

**Components:**
- `Agent::ToolRegistry` — central registry; tools register via `ToolRegistry.register(name:, description:, parameters:, handler:, admin_only:)`
- `Agent::Runner` — orchestrates the loop, handles provider differences (Anthropic vs OpenAI tool-calling formats), supports vision (multi-modal messages with images)
- `lib/agent/tools/*.rb` — tool definitions (radio×8, weather, google_search, knowledge×3, horoscope, compose_song, generate_image, load_messages, view_image)

**Tool-calling formats:**
- Anthropic: `tools: [{name, description, input_schema}]`, response `content: [{type: "tool_use"}]`, results as `{type: "tool_result"}`
- OpenAI: `tools: [{type: "function", function: {...}}]`, response `tool_calls: [...]`, results as `{role: "tool"}`

Admin-only tools are filtered from definitions AND checked at execution time (denial messages pulled from `Settings.replies['admin_denied']`). Tool results are truncated to 2000 chars.

**Vision support:** When a user attaches or replies to a photo with a bot-addressed message (e.g. "бот что тут?"), `GptChat` downloads the photo via `TelegramFile.download_image` (getFile → token URL → base64), and passes it to `Agent::Runner`, which routes the turn to the `agent_vision` setting and builds a multi-modal message with an `image` content block (Anthropic shape; `GptMaster` converts to OpenAI `image_url` data-URI at the wire for openai-compat providers). Falls back to text-only if the download fails or there's no photo.

**Historical images — `view_image` tool:** incoming photos are persisted by `MessageResponder#save_message` as `messages.attachment_photo_file_id` (largest photo size ≤1280px; photo-only messages get body `[фото]`), and the bot's **own sent images** (deliver `:image`, image_gen output, Suno cover art) are captured the same way by `Message.persist_bot_reply` from the sendPhoto/sendMediaGroup response — so the agent can re-view its generation results. `ChatContext.serialize_msg` flags such rows with `photo: true` (the file_id itself never enters the LLM context). When the agent wants to see one of those images, it calls `view_image(message_id:)`; the handler resolves the file_id from DB, downloads via `TelegramFile.download_image`, and returns `Agent::ToolResult.image`. `Agent::Runner` then:
1. Queues the payload in `@pending_images` (`materialize_result` checks `image?` *before* the deferred guard — an image result that fell through would be silently dropped).
2. After **all** of the iteration's tool-result messages are appended (openai requires every `tool_call` answered before another role appears), injects the image: for openai providers as a fresh `user` turn carrying the image block(s); for Anthropic merged into the last `tool_result` user message (Anthropic forbids consecutive user turns; one user turn may hold `tool_result` + `image` blocks together).
3. Upgrades `@setting` to `agent_vision` for the rest of the turn — guarded by `can_view_image?` (computed at init, exposed as `ctx[:can_view_image]`): true only when already on `agent_vision` or when `agent_vision` exists **and shares `api_type`** with the active setting, because the switch replays provider-shaped accumulated messages. On upgrade, DeepSeek's `reasoning_content` field is stripped from accumulated assistant messages (another openai-compat endpoint may reject the unknown field on replay). When `can_view_image` is false (e.g. cross-api_type config), the tool degrades to a polite text reply instead of corrupting the request.

Cost note: an injected base64 image rides every subsequent iteration of the agent loop. The persisted photo size is capped at ≤1280px, and `GptMaster#dump_gpt` redacts base64 image payloads (both Anthropic `image` and OpenAI `image_url` shapes) from `gpt.log` to keep log volume sane. Limitations: only photos received **after** this feature deployed have a stored file_id (no backfill possible); images sent as uncompressed documents (`message.document` with `image/*` MIME) are not captured — matches the existing `extract_image` behavior.

### Agent Event Loop — `lib/task_handlers/agent_event_handler.rb`
When image_gen / suno tasks hit interesting outcomes (failure after retries, success after retries), the handler emits an `agent_event` BackgroundTask via the `lib/task_handlers/agent_event_emitter.rb` mixin. `AgentEventHandler` runs `Agent::Runner` with a synthetic `[СЛУЖЕБНОЕ СОБЫТИЕ]` text describing what happened; the agent decides whether to comment, retry via tools, or `(skip)`.

One special case: `song_delivery_failed` fires from `SunoTaskHandler#send_audio` when the song generated fine but the Telegram send conclusively failed (no clips downloaded, or sendMediaGroup retries exhausted). The task is already DB-`done` at that point (`mark_done!` runs before delivery so the clip URLs persist), so this event — plus a chat notification — is the only signal that the song never arrived; the agent should offer re-generation since Suno's CDN URLs expire.

Per-chat rate limit: 10 emits per rolling hour. Loop protection: only image_gen/suno emit; agent_event itself doesn't (single-hop). See ADR-003 PR-2.

`AgentEventHandler#call` receives `(task, api)` from `TaskRunner` (no full `bot` object — `TaskRunner` only ever has `bot.api`), and forwards `api:` to `Agent::Runner.new`. The Runner stores it as `@tool_ctx[:api]` so tools that need to call Telegram (e.g. `google_search` sending image media groups) work in this code path. Runner logs a warning at initialization if `api:` is nil — a future caller who forgets will see a greppable `Agent::Runner initialized without Telegram api` in logs instead of a masked `NoMethodError` deep in a tool's `rescue`. All callers (`GptChat`, `GptQuestion`, `AgentEventHandler`) pass `api:` directly; `bot:` is no longer accepted.

### Telegram reactions capture — `lib/bot.rb` + `lib/bot_dispatcher.rb`
Powers Quote-of-the-day and Wrapped "funniest". `lib/bot.rb` opts into reaction updates via `Client.run(..., allowed_updates: ALLOWED_UPDATES)` — the list **replaces** Telegram's server default (which omits reaction types), so it enumerates every consumed update type; passing it to `bot.listen` would be a no-op (only `Client#initialize`'s options reach `getUpdates`). `BotDispatcher` gains two branches:

- `MessageReactionCountUpdated` → **authoritative**: `reactions_count = Σ total_count` (overwrite, never increment — self-heals any drift).
- `MessageReactionUpdated` → per-user delta `new_reaction.size − old_reaction.size` (Telegram coalesces a user's reactions into full before/after sets: swap = 0, add = +1), clamped at 0 via `MAX(0, …)`. Best-effort only; needs the bot to be a **group admin** to be delivered at all (confirmed for the main prod chats). `user` can be nil (anonymous `actor_chat`) — irrelevant, only the delta is used.

Reaction updates carry no `from`/chat-type, so a dedicated `reaction_authorized?` gates on the `chats` allowlist only (no super-admin private-chat shortcut). Rows are matched by `(chat_id, message_id)` (existing index); unknown messages are silently skipped. Write traffic: one UPDATE per reaction event + one per count event (~3–5× message write volume on a reaction-heavy chat) — statement-level pool checkouts, no contention with the 2-worker TaskRunner.

`Message.top_reacted(chat_id, since:, limit:, scope:)` is the single query surface: `scope: :user` → human rows only (Quote), `scope: :all` → bot rows included (Wrapped "funniest" — the dominant reacted content is the bot's own memes).

### Rules-war game — `lib/agent/scratchpad.rb` + `lib/agent/tools/rules.rb` + `lib/commands/rules.rb`
Gamifies the chat's emergent habit of setting "rules" through the bot. The store is the scratchpad's `rules` category — rules render into `{SCRATCHPAD}` on every agent turn, so the agent sees and honours them with zero extra plumbing.

**Store invariants** (all in `Agent::Scratchpad`):
- Rules are **exempt from `evict_until_under_cap`** (an active rule must never vanish silently) **and from generic `prune_expired`** — expired rules are deleted *only* by `pop_expired_rules` (CronScheduler) so each gets its obituary exactly once. `rules()`/`render` filter expired at read, so a dead rule is never *enforced* during the ≤60s pop window.
- Spam bounds: **one-rule-per-citizen** (a new rule auto-repeals the author's previous one; `add_rule` returns `{rule:, repealed:, evicted:}` so the agent announces the trade-in publicly), `MAX_RULES = 20` backstop (oldest evicted), content truncated to 200 chars.
- `add_rule` is a **separate method** — the generic `add` keeps its bare-`"sp-NNN"`-string contract (the Runner's deferred-intent writer depends on it) and rejects `category: 'rules'`; `Scratchpad.remove` (the `forget` tool) cannot delete rules. Rule ids are a separate monotonic `r-NNN` sequence (never reused).
- Court rules (`set_by: 0`, rendered «суд», `court: true`) bypass one-rule-per-citizen but cap at 1 per chat, 12h expiry.

**Agent tools** (`lib/agent/tools/rules.rb`): `set_rule(content)` (author = `ctx[:user]`), `repeal_rule(id)` (author/admin only; court rules admin-only), `challenge_rule(id)` — the **public dice trial**: `api.send_dice` rolls Telegram's animated 🎲 in the chat (value is in the API response immediately; **no sleep in the handler** — it runs synchronously inside `bot.listen`'s single-threaded loop). Outcome: 4–6 rule repealed; 2–3 survives +6h «за неуважение к суду»; 1 critical fail — survives, +6h, and the tool result instructs the agent to compose a counter-rule via `court_rule(content, target)`. Survival increments `challenges_survived` (surfaced **post-increment**; ≥3 triggers the «Конституционный статус» award suggestion). `sendDice` failure falls back to internal `rand(1..6)` (flagged in the narration). Throttle: 6 trials/chat/hour via the scratchpad top-level `challenge_log` (pruned to the trailing hour on write).

**Lister**: `бот правила` (`Commands::Rules`) renders the constitution («📜 УСТАВ ЧАТА», ст. r-NNN per rule) deterministically — no LLM.

**Obituaries**: each CronScheduler tick pops expired rules per chat and enqueues at most **one** `rule_obituary` task (single obituary, or a combined «братская могила» listing several); cap 3/chat/local-day — past it, rules are popped silently. `RuleObituaryHandler` renders only what task params carry.

### Auto-awards — `lib/agent/tools/award.rb`
`make_award(recipient, reason)` composes a ceremonial award request and enqueues a normal `image_generate` task with `award: true` — the full enrichment + delivery pipeline is reused. `ImageGenTaskHandler#caption_for` (shared by the sync CloseRouter path AND the async Flux/Atlas path) prefixes `🏆` instead of `🎨`. Rides the `image` rate-limit bucket with the standard deferred pattern. The agent also hands out awards on dice-trial outcomes (challenge_rule's result text suggests them — prompt-level wiring, no extra plumbing).

### Chat Wrapped — `lib/chat_wrapped.rb` + `lib/task_handlers/wrapped_digest_handler.rb` + `lib/commands/wrapped.rb`
`ChatWrapped.generate(chat_id)` — deterministic 7-day stats (messages, top poster, images + top commissioner, songs, active rules, funniest via `top_reacted(scope: :all)`); plain text, no LLM. Two surfaces: `бот итоги` (on-demand, **read-only**) and the weekly `weekly_wrapped` task auto-posted by `CronScheduler#maybe_fire_digests` per the `digests:` settings block (fire-once-per-day guard keyed on local-midnight-in-UTC; no-ops while `digests.chat_id` is nil, so dev/test stay silent; the `digests.news` key is inert config reserved for the future news-digest feature — enqueueing `daily_news` without a handler would mark-failed + error-notify).

**«Революция»** (10% per weekly post, never on-demand): wipes all rules (`Scratchpad.clear_rules`) and appends a banner line. Retry-safe: the roll happens once and is persisted into task params *before* any send; a handler retry re-reads it (no re-roll, no double-wipe — `clear_rules` is idempotent).

### Quote of the day — `lib/commands/quote.rb`
`бот цитата` — random pick from the top-10 most-reacted *human* messages of the last 30 days (`top_reacted(scope: :user)`), formatted with a `tg://user?id=` author mention. Graceful fallback while reactions accrue post-deploy.

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
- `WrappedDigestHandler` (`weekly_wrapped`) — weekly Chat Wrapped auto-post with the retry-safe «Революция» roll (see "Chat Wrapped"). Enqueued by `CronScheduler#maybe_fire_digests`.
- `RuleObituaryHandler` (`rule_obituary`) — template obituary post for expired rules-war rules (no LLM); batching/caps owned by the cron tick (see "Rules-war game").

### ChatContext — `lib/chat_context.rb`
Single source of truth for chat context and knowledge lookup. Included by task handlers (directly) and by `GptHelpers` (which delegates with auto-passed `chat_id` + current `message_thread_id`). Provides:
- `get_chat_context(chat_id, thread_id: nil)` — fetches the last N messages as a JSON array. Each entry is `{id, role: 'bot'|'user', who, msg}` with optional `reply_to`, `thread`, `fwd`, `edited`, `audio`, `audio_meta`, `photo` (`photo: true` marks a stored photo attachment the agent can fetch via the `view_image` tool; the underlying `attachment_photo_file_id` stays DB-internal). `role` is the structural disambiguator between user input and the bot's own prior outputs (replaces name-string matching against the bot's display name). `who` is a structured object — for users `{uid, username?, first_name?, last_name?}` (only present fields, or `{unknown:true}` when nothing is known); for the bot `{name: 'Жзяцля'}`. `uid` is included so the agent can mention users without a Telegram username via Markdown `[Name](tg://user?id=UID)`. When `thread_id` is set, scopes the query to the same forum topic. When any in-window `reply_to` points to a `message_id` that isn't in the window, the helper fetches that one row from DB and prepends it (one-hop out-of-window backfill). Rescues to `''` on error.
- `get_relevant_knowledge(query, chat_id)` — embeds query, retrieves top-K knowledge facts as JSON; rescues to `''` on error
- `ChatContext.serialize_msg(row)` — module method shared by `get_chat_context` and the `load_messages` agent tool to produce the hash described above.
- `ChatContext.identity_for_row(row)` — module helper: builds the `who` object (only includes non-blank fields; falls back to `{unknown:true}`).
- `ChatContext.display_name(name:, first_name:, last_name:)` — module helper: flat-string label used by `Agent::Runner#trigger_user_display`. Shared with `serialize_msg` so the trigger line and history rows agree on every formatting edge case.

### SunoClient — `lib/suno_client.rb`
HTTP client for the Suno AI song generation API (`sunoapi.org`), using V5 model. Key methods:
- `submit(title:, lyrics:, tags:, negative_tags: '')` — POST to `/api/v1/generate`, returns `task_id`. `negative_tags` maps to Suno's `negativeTags` field (exclusions applied after positives); the key is **dropped from the POST body** when the value is empty (mirrors `vocal_gender` conditional in `add_vocals`/`cover_audio`).
- `poll_once(task_id)` — GET status, returns `:pending`, `:failed`, or `Array<{ audio_url:, title:, duration: }>` (all clip variants)
- `compose(...)` — blocking convenience (submit + poll loop)
- `SunoClient.resolve_genre(text)` — maps Russian genre names to English style tags (~50 genres)
- **Important:** Suno blocks artist names in tags — describe sound characteristics instead

#### Combined compose call
On the common path (user did NOT supply verbatim lyrics), `SunoTaskHandler#compose_lyrics_and_tags` makes ONE Sonnet 4.6 call (`setting: 'lyrics'`, `purpose: 'suno_compose'`) producing both lyrics and style tags in a single response. Format pinned to two XML blocks:

```
<lyrics>
[Intro]
...full lyrics with section markers and stage directions...
[Outro]
</lyrics>

<tags>
industrial metal, Tanz-Metall, mid-tempo grinding stomp, ...
</tags>
```

Parser is a trivial regex on each block. **Coherence win**: the same model holds the actual lyrical mood/pacing/emotional arc in context when picking style tags — the previous tags-only call only saw `genre + artist + title` as input and had to guess. **Cost/latency**: ~50% Sonnet-portion savings (one round-trip vs two), ~5s latency saved. Malformed response (missing block) → raise → handler's `bail_or_retry` path retries via `prompt_failures` counter. The prompt is assembled at runtime by concatenating `Settings.suno['lyrics_prompt']` (with `{REQUEST}`/`{GENRE}`/etc. substituted) + `TAGS_PROMPT` (with `%{genre}`/`%{artist}`/`%{title}` substituted) + an XML response-format instruction.

When the user DID supply verbatim lyrics, the handler skips composition and runs only `resolve_tags` (`purpose: 'suno_tags'`) — the tags-only fallback path remains unchanged.

#### Tag-ordering convention (TAGS_PROMPT)
`SunoTaskHandler::TAGS_PROMPT` instructs the enrichment LLM (Anthropic Sonnet 4.6 via `setting: 'lyrics'`) to emit tags in *genre → mood → instruments → vocals → mix* order, ~120–180 chars total. Mix descriptors (`polished production`, `lo-fi`, `wet reverb`, `dry mix`, `punchy drums`, `radio-ready`) are optional seasoning — composer skips when generic. **Negatives are NOT emitted into the tag string** — they flow exclusively through the structured `negative_tags` agent-tool param → `SunoClient#submit(negative_tags:)` → Suno's `negativeTags` POST field (omitted from the body when empty). Inlining `"no X / without Y"` inside `tags` would let Suno parse them as positive descriptors.

**Always-enrich (structural):** the `compose_song` agent tool does NOT accept a `tags` arg — the handler runs `resolve_tags` on every gen, regardless of agent input. Single source of truth for style emulation; eliminates the failure mode where the agent inlined generic genre tags and bypassed the enrichment path (prod task 1360, 2026-05-18). Tag input to enrichment is `genre + artist + title`. Artist-emulation rule in `TAGS_PROMPT`: when copying a specific artist's style, describe *distinctive* traits (vocal manner, timbre, phrasing, tempo, production quirks), not shared genre traits — e.g. Rammstein vs OOMPH share NDH but differ in operatic baritone / rolled R consonants / spoken-word verses / mid-tempo stomp / cinematic synths / glossy production.

#### Lyric-craft directives (lyrics_prompt)
`Settings.suno['lyrics_prompt']` carries an "ВЫРАЗИТЕЛЬНЫЕ СРЕДСТВА Suno" block telling the composer LLM to use Suno's vocal-control vocabulary sparingly:
- Stage directions in parens before lines/sections — `(whispered)`, `(softly)`, `(belted)`, `(building)`, `(sad)`, `(emotional vocals)`, `(fade out)`, `(echo)`.
- Vocalizations inside hook/chorus — `Oooooh whoa-ah-ah`, `na-na-na`, `la-la-la`, `mmm-hmm`.
- Call-and-response with parenthetical backup answers — `Lead line (backup answer)`.
- Punctuation as pacing — `...` slows, `!` accents.
- Rhythm notation for solo/instrumental sections — `. . . ! . .` (dots = soft tick, `!` = accent).
- Prefer `[Instrumental Bridge]` or `[Solo]` over bare `[Bridge]` — Suno often mis-renders the latter.

Enumerated section-marker palette (composer picks only what fits the genre): `[Intro] [Verse] [Pre-Chorus] [Chorus] [Hook] [Post-Chorus] [Bridge] [Instrumental Bridge] [Interlude] [Break] [Build] [Drop] [Solo] [Instrumental] [Spoken Word] [Whisper] [Ad-lib] [Harmony] [Outro]`.

#### Cover Audio mode resolution
The `/api/v1/generate/upload-cover` endpoint takes a `customMode` flag + a `prompt` field whose meaning depends on mode — `customMode: true` sings `prompt` verbatim as lyrics (≤5000 chars on V5); `customMode: false` treats `prompt` as a "core idea" theme and Suno auto-generates fresh lyrics from it (≤500 chars). Suno does NOT preserve the original mp3's lyrics in either mode. The tool exposes two explicit args: `lyrics` (verbatim user-provided text → custom mode) and `topic` (short Russian theme phrase → auto mode).

`SunoTaskHandler#resolve_cover_prompt` resolution order: `instrumental=true` → auto-mode + title-as-prompt (lyrics/topic ignored — prompt isn't sung under instrumental but Suno still requires a value); else `lyrics` (truncated to 5000) → `topic` (truncated to 500) → legacy `prompt` if present (back-compat for in-flight tasks at deploy time, treated as topic) → `title` fallback.

**Reply-target source-lyrics auto-fallback**: when the user replies to a previously-bot-generated Suno song asking for a remix without supplying explicit `lyrics`, `cover_audio` resolves `ctx[:reply_to_message_id]` → `Message.bg_task_external_id` → source `BackgroundTask` and copies lyrics from `params['lyrics']` (compose_song path) or first clip's `result.lyrics` (add_vocals/cover_audio path). Mirrors `cover_art`'s reply-target chain — robust against the lyrics scrolling out of the 50-msg chat-context window.

#### Cover Art source resolution
`cover_art` resolution chain: (1) explicit `args['suno_task_id']`; (2) `ctx[:reply_to_message_id]` → `Message.bg_task_external_id` (populated by both Suno handlers when persisting bot media rows); (3) most recent `done` task in chat across `suno_generate` / `suno_add_vocals` / `suno_cover_audio`. The reply-target step is what makes "бот, нарисуй обложку" resolve to a specific bot song instead of always the latest one.

`SunoCoverArtHandler` polls via `SunoClient#poll_cover_art_once` against a **different endpoint** (`/api/v1/suno/cover/record-info`, not `/api/v1/generate/record-info` — separate ID spaces) with a different response shape (`successFlag`, `response.images`, `errorCode`/`errorMessage`). Failures emit `cover_art_failed` agent_event so the agent can comment.

#### Suno WAV export
`convert_to_wav` agent tool, `suno_wav_convert` task type, `SunoWavConvertHandler`. Uses `POST /api/v1/wav/generate` (requires both `taskId` AND `audioId` — the per-clip id from `response.sunoData[].id`, NOT the song's task id) + `GET /api/v1/wav/record-info`. `successFlag` enum: `PENDING` / `SUCCESS` / `CREATE_TASK_FAILED` / `GENERATE_WAV_FAILED` / `CALLBACK_EXCEPTION`.

Source resolution mirrors `cover_art` (explicit `suno_task_id` → reply target's `bg_task_external_id` → most recent done song). `clip_index` (1 or 2, default 1) picks which of the two Suno clips to convert; the handler re-fetches the source's `record-info` via `SunoClient#fetch_audio_ids` to map `clip_index` → `audioId` since clip ids aren't persisted in `BackgroundTask.result`. Output sent as Telegram audio (`sendAudio`) named `Performer_-_Title.wav`.

#### Combined "song + cover art" requests
All three song-producing tools (`compose_song`, `add_vocals`, `cover_audio`) accept `with_cover_art: true`. After the song's `:done` polling, `SunoTaskHandler#maybe_chain_cover_art` enqueues a chained `suno_cover_art` task pointing at the just-completed song's `external_id`. Dedup via `json_extract(params, '$.source_task_id')` lookup. Charged against the `suno` rate-limit bucket (RateLimiter counts all `suno_*` task types); silently dropped at chain time if the bucket is exhausted.

### Image generation — `lib/image_gen/` + `lib/model_provider_client.rb`
Service-adapter layer. The `ImageGenTaskHandler` is provider-agnostic; concrete backends live as `ImageGen::Adapter` subclasses. The active backend is chosen per-request from an agent-selectable **model catalog**, falling back to `Settings.image_gen['provider']` for legacy/no-model tasks.

- **Per-request model selection** — the `generate_image` agent tool exposes a `model` enum; the agent picks a catalog key (e.g. `nano-banana-2`, `wan-2.7`, `flux-2-pro`). **`ImageGen::Catalog`** (`lib/image_gen/catalog.rb`) maps each key → `{provider, t2i, edit, desc}` from config (`image_gen.models`). The tool stores the resolved key in `task.params['model']`; `ImageGenTaskHandler` resolves the entry, selects the adapter **by the entry's provider** (not just `current_adapter`), validates that provider against `ImageGen::ADAPTERS` (unknown → re-resolve to `default_model` so adapter and model id stay coherent), snapshots both `provider` and `model` into params, and threads the provider-specific id into `adapter.submit(model:)`. Missing/invalid key → `image_gen.default_model`. `edit: false` in an entry → `model_id_for(:edit)` returns nil → the adapter falls back to its configured `image_edit_model`. The catalog is read **lazily**: Settings isn't loaded at tool-require time (boot.rb requires the tools before `Settings.load!`), so the tool defers the enum/description via `enum_source`/`desc_suffix_source` lambdas resolved in `ToolRegistry.definitions_for` (per-turn, at runtime). `Catalog.all` is memoized; `reset!` is the test seam.
- **Multi-image edit + chat-history sourcing** — the `generate_image` tool also takes `source_message_ids` (array of Telegram `message_id`s of earlier `photo: true` messages). Edit sources are therefore: the current/replied photo (inline, already base64 in `ctx[:image]`) **plus** any history photos the agent picks by message_id. History photos are **downloaded in the handler** (`ImageGenTaskHandler#resolve_input_images` reuses the `view_image` resolution: `Message…pick(:attachment_photo_file_id)` → `TelegramFile.download_image`) — never in the tool, which runs in the bot's listen loop (no blocking I/O). Missing/old message_ids (no stored file_id) are skipped with a warning; if an edit was requested but **zero** images resolve, the task fails with a user-facing notice instead of silently regenerating from scratch. Total source images are capped at `ImageGen::MAX_EDIT_IMAGES` (6). Only models flagged `multi_image: true` in the catalog (nano-banana family) can combine several inputs; when the agent picks an incapable model (Wan/Flux) for a >1-image request, the tool **auto-switches** to the capable `default_model` (`ImageGen::Catalog.multi_image?`).
- **`ImageGen::Adapter`** (`lib/image_gen/adapter.rb`) — base class. Four abstract-or-overridable methods: `submit(prompt:, input_images:, model:)` (`input_images:` = array of `{data:, media_type:}` edit sources or nil for text-to-image — single-image adapters use the first; `model:` nil ⇒ adapter's configured default), `poll_once(external_id)`, `prompt_template(:text_to_image|:edit)`, plus `name` (returns `self.class::NAME`) and `synchronous?` (defaults `false`).
- **`ImageGen` facade** (`lib/image_gen.rb`) — `ADAPTERS = { 'flux' => FluxAdapter, 'atlas' => AtlasAdapter, 'closerouter' => CloseRouterImgAdapter }.freeze`. Submit-side: `current_adapter` reads `Settings.image_gen['provider']` (used only for legacy/no-model tasks; catalog-keyed tasks call `adapter_for(entry_provider)`). Poll-side: `adapter_for(snapshot)` resolves by the value snapshotted into `task.params['provider']` at submit time, so a config flip mid-flight doesn't reroute polling to a different prediction id space (legacy rows fall back to `current_adapter`).
- **Synchronous adapters** — when `Adapter#synchronous?` returns `true`, `#submit` returns a terminal result Hash (`{url:, completed:true}`) instead of an external_id String. `ImageGenTaskHandler#deliver_sync_result` short-circuits the poll cycle and marks the task done in one call. `#poll_once` raises `NotImplementedError` if reached. Only `CloseRouterImgAdapter` is sync today; Flux + Atlas stay async with the existing `:pending` / `:retry` / `:failed` / `{url:}` poll return contract.
- **`ImageGen::FluxAdapter`** (`lib/image_gen/flux_adapter.rb`) — FLUX 2 via `api.bfl.ai`. Submit POST to `/v1/{model}`, poll GET `/v1/get_result`. Uses `safety_tolerance: 5` and `output_format: 'jpeg'`. Owns the FLUX-tuned prompt-enrichment templates. Auth header is `x-key`. NOT built on `ModelProviderClient` (different host + auth scheme). Has a one-release back-compat shim that reads top-level `Settings.flux` if `image_gen.providers.flux` is absent — removed once prod settings.yml is migrated.
- **`ImageGen::AtlasAdapter`** (`lib/image_gen/atlas_adapter.rb`) — Atlas Cloud (default t2i: `google/nano-banana-2/text-to-image`, default edit: `alibaba/wan-2.7/image-edit`, both configurable; per-request `model:` overrides). Prompt templates are model-agnostic (`%{model_name}` interpolated by the handler) since the adapter now serves multiple Atlas models. Submit POST to `/api/v1/model/generateImage`, poll GET `/api/v1/model/prediction/{id}`. **Request body is FLAT**: `{model, prompt, width, height}` for T2I. The **edit image field is per-model** (getting it wrong makes the model silently ignore the source and regenerate): Wan reads singular `image: 'data:…;base64,…'`, the **nano-banana family reads plural `images: ['data:…', …]`** (the adapter branches on whether the model id contains `nano-banana`; both accept base64 data URIs, no upload step; nano-banana combines up to ~10, Wan takes the first; min resolution 240×240). Atlas's published `input.{...}` example shape silently fails — submit returns 200+id but poll instantly returns masked "Field required" — so we use the flat shape, confirmed via live probe (nano-banana `images` shape confirmed 2026-06-24). Status mapping: `processing|queued` → `:pending`, `completed|succeeded` → `{url:}`, `failed` → `:failed`, anything else → log once + `:pending`. Response wraps under `data.{...}`; adapter accepts both wrapped and unwrapped defensively. Submit-response id resolution accepts both `data.id` (canonical) and top-level `id`. Owns Wan-tuned prompt templates.
- **`ImageGen::CloseRouterImgAdapter`** (`lib/image_gen/closerouter_adapter.rb`) — CloseRouter Nano Banana Pro (Google) via `api.closerouter.dev`. Default models: `google/nano-banana-pro` (T2I) and `google/nano-banana-pro-edit` (image edit) — two separate model ids, NOT a flag on the base model. **Synchronous**: single `POST /v1/images/generations` returns `{data: [{url: 'https://cdn/...png', ...}]}` directly; adapter extracts `data[0].url` and returns `{url:, completed:true}`. Edit body uses plural `images: ['data:image/<type>;base64,<b64>', …]` (array; Nano Banana Pro combines multiple input images, so all resolved sources are mapped in). `synchronous? = true` so `ImageGenTaskHandler` skips the poll cycle. Owns Nano-Banana-tuned prompt-enrichment templates (Russian-aware, names-preserved, FLUX-style structure conventions).
- **`ModelProviderClient`** (`lib/model_provider_client.rb`) — generic Bearer+JSON HTTP wrapper (formerly `AtlasClient`; renamed because it's no longer Atlas-specific). Constructor takes a config dict (`api_url`, `api_key`) + `tag:` for greppable logs (`'AtlasImg'`, `'CloseRouterImg'`, future `'CloseRouterVideo'`). Asymmetry: `post` raises on non-2xx (so handler `bail_or_retry` engages); `get` returns `[code, body]` and swallows `OpenSSL::SSL::SSLError`/`Net::OpenTimeout`/`Errno::ECONNRESET` (so polling degrades to `:pending` on transient blips). `post` does NOT swallow SSL errors — preserves FluxAdapter's existing behavior; submit-side TLS resilience can be retrofitted with a per-call retry wrapper if needed.

### TtsService — `lib/tts_service.rb`
Facade over Polly. `TtsService.speak(text, voice:, speed:, minus:, track_id:)` generates OGG and returns the public URL.

### Polly — `lib/polly.rb`
AWS Polly TTS synthesis (region: `eu-west-1`). Voices: `Maxim` (Russian), `Hans` (German). Post-processes MP3 with FFmpeg to OGG Opus at 32 kbps. Supports karaoke mode: mixes speech over an MP3 backing track from `lib/samples/`.

### Gogolmogol — `lib/gogolmogol.rb`
Google Custom Search API. Constructor takes `media_type:` (`'text'`/`'photo'`/`'gif'`); the intent is set explicitly by the caller (the agent picks via the `media_type` tool param), never sniffed from the query string. Two output methods: `search_results(limit:)` returns `{title:, link:, snippet:}` hashes; `download_results(limit:)` searches + scrapes each result link to a Tempfile and returns `{tmp:, mime:, link:}` (caller owns lifecycle, failed downloads are dropped). The scraper has an SSRF guard (`safe_url?`): http(s) only; literal-IP hosts in loopback/private/link-local ranges are refused before any HTTP call. CSE `safe` parameter is forced to `off` for every request (set in `get_search`); the ultimate filter is the CSE Engine's own admin panel — if results still look filtered, check it at https://programmablesearchengine.google.com/. Falls back across a pool of API key pairs when rate-limited.

### Horoscope — `lib/horoscope.rb`
Scrapes XML from `img.ignio.com` for zodiac horoscopes. Also scrapes `newsler.ru` for erotic horoscopes. Uses Nokogiri.

### Weather — `lib/weather.rb`
OpenWeatherMap JSON API. Returns temperature, wind speed, cloud cover for a given city.

### ReplyMaster — `lib/reply_master.rb`
Loads `config/replies/*.yml`. Each entry has a regex trigger and a list of response templates. Randomly selects responses. Also pulls user-saved `phrases` from the DB for personalized insult replies.

### Dice — `lib/dice.rb`
Rolls 2 dice for user and 2 for bot, determines winner, returns templated response from `config/lib/dice.yml`.

### Admin menu — `lib/admin_menu/` + `lib/bot_dispatcher.rb`
Inline-keyboard menu in the super-admin's private chat for runtime bot administration (no SSH or YAML edits required for routine config). Triggered by `/admin` or `бот меню`; gated on `Settings.auth['super_admin_uids']`.
- **`BotDispatcher`** (`lib/bot_dispatcher.rb`) — entry from `bot.listen`. Note: `bot.listen` (gem 2.7.0) yields `update.current_message` directly (the inner `Message` / `CallbackQuery` / `EditedMessage` / etc.), NOT the wrapper `Update`. `BotDispatcher.dispatch` does `case update when Message ... when CallbackQuery ... else log` — anything else is silently logged as ignored; add new `when` branches there to handle additional update types. Dispatches `Message` → `MessageResponder`, `CallbackQuery` → `AdminMenu::CallbackHandler`. Owns the chat-allowlist check including the implicit-auth bypass for super-admins in private chat.
- **`AdminMenu::Session`** (`lib/admin_menu/session.rb`) — Mutex-guarded in-memory state per super-admin uid. Lost on restart (acceptable — sessions are short). `awaiting_input?` has a built-in 5-min TTL; stale sessions auto-clear on access.
- **`AdminMenu::Views`** (`lib/admin_menu/views.rb`) — view builders. Each method returns `{ text:, reply_markup: }`. Plain text + emoji only — no `parse_mode` (chat titles can contain Markdown-active characters that would break renders).
- **`AdminMenu::Router`** (`lib/admin_menu/router.rb`) — parses `adm:<view>[:<param>...]` callback_data into `Action` structs (`render` / `mutate` / `await_input` / `close` / `unknown`).
- **`AdminMenu::CallbackHandler`** (`lib/admin_menu/callback_handler.rb`) — invoked from `BotDispatcher`. Permission-checks against `super_admin_uids`, performs DB mutations, calls `editMessageText` to update the menu in place, dismisses the loading spinner via `answerCallbackQuery`. Includes guards: refuse to deauthorize a super-admin's own private chat; refuse to demote a super-admin's `users.role`; show a confirmation sub-view before deauthorizing the LAST authorized chat.
- **`AdminMenu::TextInputHandler`** (`lib/admin_menu/text_input_handler.rb`) — invoked from `MessageResponder#maybe_handle_admin_input` when the super-admin types free text and `Session.awaiting_input?` is true. Validates input (rate-limit edits: `max,window_minutes` both positive integers), calls `Chat#update_rate_limits!`, redraws the menu. Bypasses on `/cancel`, any `/`-prefix command, or `бот`/`жпт`/`балаболь`-prefix agent triggers.
- **`Commands::AdminMenuOpen`** (`lib/commands/admin_menu_open.rb`) — registered first in `Commands::REGISTRY`. `match?` returns true ONLY for super-admin in private chat with text `/admin` or `бот меню` — preserves existing behavior in all other contexts (e.g. `бот меню` in groups still routes to `GptChat` / Agent).

**Open-profile / open-chat links.** `chat_detail` and `user_detail` include a Telegram deep-link **url button** (`Views.link_btn`) so a super-admin can jump straight to the profile or chat. Users and **private** chats link via `tg://user?id=<uid>` (a private chat's `chat_id` is the user's uid — no API call, always present). Groups/channels have no id-based deep link, so `chat_open_button` best-effort-fetches a public `https://t.me/<username>` (or the primary `invite_link`) via `getChat` — **authorized rows only** (same single-threaded-loop rationale as the title self-heal below), and shows no button when nothing is linkable (typical for private groups). `@chat_link_cache` caching is **selective** (mirrors `refresh_titles!`'s definitive-vs-transient split): stable `@username` results and genuine misses are cached; a revocable `invite_link` is returned live and never cached (so a rotated invite self-heals); a permanent `chat not found` is cached but transient errors (429/network/proxy) are retried on the next open. `chat_detail` gained an `api:` param, threaded from both `CallbackHandler.render` and `post_mutation_view` so the link survives a toggle redraw.

**Chat labels & title self-heal.** Legacy config-seeded rows carry the literal title `"unknown"` — `Views.unknown_title?` treats it like an empty title and every render falls back to the chat_id, so buttons are always identifiable. The Чаты list orders `authorized DESC, last_seen_at DESC` (live chats on page 1, dead legacy rows sink to the tail) and, on each page render, backfills unknown titles via `getChat` (`Views.refresh_titles!` — **authorized rows only**, because these calls run synchronously inside `bot.listen`'s single-threaded loop). Failures never retry on every render (verified on prod: each `getChat` 400 on a dead-but-still-authorized row cost ~1s of whole-bot stall, repeating per page view): a definitive `Bad Request: chat not found` persists a `💀 <chat_id>` title — a visible dead-row marker that's never re-fetched and gets overwritten by `touch_seen` if the chat ever comes back with a derivable name (groups always have one); any other error goes into an in-process negative cache (retried only after a restart). `Chat.sync_from_config!` ignores `name: unknown` config entries (`Chat.unknown_title?`) so a restart can't re-clobber a backfilled real title. `Chat.label_from_telegram` (models/chat.rb) is the shared label rule — group `title`, else private-chat `first_name last_name`, else `@username` — used both by the backfill and by `BotDispatcher` when calling `Chat.touch_seen` (Telegram private chats have no `.title`, so without this their rows would stay nameless forever).

**`/start` access requests — `lib/access_request.rb`.** Unauthorized chats are still silently dropped, with one exception: `/start` (optionally `/start@botname`) in an unauthorized **private** chat files an access request. Flow: `BotDispatcher`'s unauthorized branch → `AccessRequest.maybe_handle` → creates the `chats` row (`authorized: false`, titled via `label_from_telegram`), replies «заявка отправлена», and DMs every super-admin a notification with inline `✅ Принять / ❌ Отклонить` buttons (`adm:req_accept:<id>` / `adm:req_decline:<id>`, routed through the standard admin-menu callback machinery). Accept → `authorized: true` + «Доступ открыт ✅» to the requester; decline → row stays unauthorized + «В доступе отказано ❌». The notification message is edited in place to show the verdict (`Views.request_resolved`). Anti-spam: an existing row (pending or declined) → "заявка уже на рассмотрении" reply with NO admin re-notification; group chats never trigger requests (group authorization stays a deliberate menu act).

**Unauthorized-group recording — `BotDispatcher#handle_message`.** Group authorization is a deliberate menu act, but the menu can only act on chats that already have a `chats` row — and until this fix a group the bot was added to never got one (`touch_seen` ran only *after* the auth check passed, and groups never file `/start` requests), so a fresh group was invisible in `/admin` and could only be authorized by config-seed + restart. The unauthorized branch now records **non-private** chats via `Chat.touch_seen` (right after `AccessRequest.maybe_handle`, so the `/start` anti-spam `already_filed` check still sees pre-existing state): the row lands `authorized: false` and surfaces in the Чаты list as `✗ <title>`, ready for the Авторизовать toggle — **no admin notification** (recording ≠ access request). Private chats are skipped here (their row is owned by the `/start` flow; recording every unauthorized DM would be a table-growth vector). `touch_seen` sets `authorized: false` only on brand-new rows, so recording can never flip an already-authorized chat.

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
| Atlas Cloud (api.atlascloud.ai) | REST via ModelProviderClient | Bearer token |
| CloseRouter (api.closerouter.dev) | REST via ModelProviderClient (image gen) + GptMaster openai-compat (LLMs) | Bearer token |

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

### Translation (inline by agent)
No dedicated command, no tool. Users say `бот переведи на немецкий: …` or use slang aliases (`пиздани` → ukrainian, `бульбани` → belarusian, `шпрехни` → german, `пшекни` → polish, `блгрни` → bulgarian, `татарни` → tatar, `казахни` → kazakh, `грекни` → greek, `сербни` → serbian) and `Agent::Runner` translates inline in a single LLM turn — the `agent_prompt` in `config/settings.common.yml` enumerates the slang aliases and instructs the agent to return only the raw translation without persona wrapping. DeepSeek V4 Pro speaks all those languages natively, so routing through a tool would just add round-trips for zero benefit.

### Info / Entertainment
| Command | Description |
|---------|-------------|
| `бот топ` | User phrase leaderboard |
| `бот чо нового / новости` | Latest news (RSS) |
| `бот правила` | Rules-war constitution lister («📜 УСТАВ ЧАТА») — deterministic, no LLM |
| `бот цитата` | Quote of the day — random top-reacted human message of the last 30 days |
| `бот итоги` | Chat Wrapped on demand (read-only — never triggers «Революция») |
| `!помощь / !help` | Command list |

Setting/repealing/challenging rules and handing out awards go through the
agent (`set_rule` / `repeal_rule` / `challenge_rule` / `court_rule` /
`make_award` tools) — e.g. «бот поставь правило …», «бот оспорь r-003»,
«бот награди Катю за …».

Horoscopes, Google search, image search, gif search — no direct command.
The agent (via `бот <anything>` → `GptChat`) handles them through its
`horoscope`, `google_search`, and `generate_image` tools and can compose
multiple tools in a single turn (e.g. "бот найди новости и нарисуй" →
`google_search` then `generate_image`).

---

## Development Guide

How-to recipes for common changes. Area-specific trap knowledge lives in `.claude/rules/*.md` (auto-loaded by Claude Code when working with matching files).

### How to add a new command

1. **Create the command class** in `lib/commands/my_command.rb`:
   ```ruby
   module Commands
     class MyCommand < Base
       PATTERN = /^бот мояфича (.+)/i

       def match?
         cmd =~ PATTERN
       end

       def execute
         text = cmd.match(PATTERN)[1]
         CommandResult.text("result: #{text}")
       end
     end
   end
   ```

2. **Require it** in `lib/message_responder.rb`:
   ```ruby
   require './lib/commands/my_command'
   ```

3. **Add it to the registry** in `lib/commands/registry.rb` at the correct position (order = priority):
   ```ruby
   REGISTRY = [
     ...,
     MyCommand,
     FallbackReply,   # always last
   ].freeze
   ```

4. **Add config** to `config/settings.yml` if the feature needs API keys or parameters.

5. **Update `lib/commands/help.rb`** so users can discover the command.

6. **Update docs** — this file's command reference; the matching `.claude/rules/*.md` if the change touches a documented invariant; CLAUDE.md tables if entry points changed.

### Key code patterns

**Building a reply:**
```ruby
CommandResult.text("message")
CommandResult.sticker(STICKER_ID)
CommandResult.image("https://...")
CommandResult.voice(file_or_url)
CommandResult.audio(url, title: "...", performer: "...")  # :audio (MP3 with metadata)
CommandResult.none   # handled silently, no reply sent
```

**Accessing context inside a command** (all ctx fields are delegated in `Commands::Base`):
```ruby
cmd        # downcased message text (String or nil)
user       # User ActiveRecord instance
chat_id    # Telegram chat ID
radio      # Radio instance (lazy TCP)
message    # raw Telegram::Bot::Types::Message
bot        # Telegram bot client
reply_master  # ReplyMaster instance
```

**Chat commands route through the agent.** `GptChat` / `GptQuestion` always call `Agent::Runner.new(...).run` — there is no non-agent path. Triggers: `бот …` / `жпт …` / `балаболь …` prefixes, a Telegram reply to a bot message, or — in **private chats** — any non-slash text (`GptChat#private_no_prefix?`). The Phrase-collection egg (`maybe_save_phrase`) only fires on explicitly-addressed messages (prefix/reply), never on bare DM text.

**Calling GPT for a one-off task (no chat context):**
```ruby
PROMPT = 'Do something with: {REQUEST}'
CommandResult.text(GptMaster.ask(text, prompt: PROMPT, setting: 'agent',
                                  chat_id: chat_id, purpose: 'my_new_purpose'))
```
Always pass `setting:` explicitly (see GptMaster) and pick a short snake_case `purpose` label so `бот затраты` can attribute costs.

**Text-to-speech:**
```ruby
url = TtsService.speak(text, voice: 'Maxim', speed: nil, minus: false, track_id: nil)
CommandResult.voice(url)
```

**Calling the radio server** (TCP connects lazily on first call):
```ruby
radio.current_track
radio.search(query)
radio.request(track_id, user)
```

**Current user fields:**
```ruby
user.role              # 'new', 'member', 'admin'
user.uid               # Telegram ID
user.last_order        # Time of last track request
```

### Adding new settings

Add a top-level group to `config/settings.yml` (secrets) or `config/settings.common.yml` (non-secret defaults):
```yaml
my_feature:
  api_key: xxx
  some_param: value
```

Access in code (`method_missing` in `Settings` handles it automatically):
```ruby
Settings.my_feature['api_key']
```

If the group is **required for the app to boot**, also add the key to `REQUIRED_KEYS` in `lib/settings.rb` — the deep-merge validator rejects unknown required groups otherwise. Optional groups (e.g. `digests`) stay out of `REQUIRED_KEYS` deliberately.

### Database changes

Create a migration file (sequential number prefix). ActiveRecord is 7.2 — use `Migration[7.2]` for new migrations:
```ruby
# db/migrate/023_add_something.rb
class AddSomething < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :new_field, :string
  end
end
```

Run with:
```bash
bundle exec rake db:migrate
```

(In Docker, the entrypoint runs migrations automatically on every start.) Update the relevant model in `models/` and the schema table in this file.

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
    # `main` was deprecated 2026-04 — every consumer now passes setting:
    # explicitly. The kwarg default in GptMaster.new/.ask still says 'main'
    # so any forgotten caller fails loudly with `Unknown chat_gpt setting:
    # main` at first call rather than silently picking some other model.
    agent:                        # Agent::Runner tool loop, suno tags/parse, image-gen prompt enrich
      provider: deepseek
      model: deepseek-v4-pro
      max_tokens: 16000
    agent_vision:                 # Agent::Runner picks this when @image is attached
      provider: grok
      model: grok-4-fast-reasoning
      max_tokens: 16000
    knowledge:                    # KnowledgeBase extract + compact (background, frequent)
      provider: deepseek
      model: deepseek-v4-pro
      max_tokens: 16000
    lyrics:                       # suno_handler song lyrics generation
      provider: deepseek
      model: deepseek-v4-pro
      max_tokens: 16000
    embedder:                     # EmbeddingService — text→vector
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
  api_url: https://api.bfl.ai     # legacy top-level block (read by FluxAdapter back-compat shim)
  api_key: ...
  model: flux-2-pro
image_gen:
  provider: atlas                 # adapter for legacy/no-model tasks ('atlas' | 'flux' | 'closerouter')
  default_model: nano-banana-2    # catalog key used when agent omits/sends unknown model
  providers:
    atlas:
      api_url: https://api.atlascloud.ai
      api_key: ...
      text_to_image_model: google/nano-banana-2/text-to-image
      image_edit_model:    alibaba/wan-2.7/image-edit
      width:  1024
      height: 1024
    flux:
      api_url: https://api.bfl.ai
      api_key: ...
      model: flux-2-pro
  models:                         # agent-selectable catalog (ImageGen::Catalog); KEY = generate_image(model:) enum value
    nano-banana-2: { provider: atlas, t2i: google/nano-banana-2/text-to-image, edit: google/nano-banana-2/edit, desc: '...' }
    wan-2.7:       { provider: atlas, t2i: alibaba/wan-2.7-pro/text-to-image,  edit: alibaba/wan-2.7/image-edit, desc: '...' }
    nano-banana-pro: { provider: closerouter, t2i: google/nano-banana-pro, edit: google/nano-banana-pro-edit, desc: '...' }
    flux-2-pro:    { provider: flux,  t2i: flux-2-pro, edit: flux-2-pro, desc: '...' }
digests:                    # scheduled auto-posts (CronScheduler#maybe_fire_digests)
  enabled: true             # optional group — deliberately NOT in Settings::REQUIRED_KEYS
  chat_id:                  # env-specific: set in settings.yml on prod (edit in place, never scp); nil = no-op
  utc_offset: 3             # Europe/Moscow (no DST); schedule times are local
  news:    { hour: 9,  minute: 0 }            # reserved — not fired yet (no daily_news handler)
  wrapped: { wday: 0, hour: 18, minute: 0 }   # weekly Chat Wrapped; 0 = Sunday
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
| LLM request/response dumps | `log/gpt.log` |
| Knowledge compaction (`COMPACT_LOGGER`) | `log/knowledge_compact.log` |

**`gpt.log`** — NDJSON dump of every LLM request+response (system prompt, messages, tools, raw response, stop_reason, usage). One JSON object per line, rotation 5×50MB. Useful for reconstructing exactly what the model saw and said when debugging odd replies. Query with `jq`, e.g. `jq 'select(.chat==-1001273623296 and .purpose=="agent")' log/gpt.log`. Disable via `Settings.chat_gpt['debug_log'] = false`.

**`knowledge_compact.log`** — per-run knowledge-compaction traces (cluster before/after).

`AppConfigurator#setup_logging` runs first in `configure`, builds the loggers from settings, and passes the main logger to `DatabaseConnector`. The global `LOGGER` and `COMPACT_LOGGER` constants are assigned in `bot.rb` after `configure` returns.

**Chat-id prefix convention.** Every per-message / per-chat / per-task log line is prefixed with `[chat=<id>]` so one grep reconstructs the full timeline for a single chat (e.g. `grep 'chat=-1001273623296' log/bot.log`). Agent turns carry an additional `[AGENT]` tag. Generic / singleton services without chat context (radio socket, FluxAdapter, ModelProviderClient, SunoClient, Gogolmogol, Polly, etc.) intentionally log without the prefix — their per-call context is already surrounded by chat-tagged lines from the caller.

Log rotation: size-based — rotates at `max_size_mb`, keeps `keep_files` old files (e.g. `bot.log.0`, `bot.log.1`). The `log/` directory is created automatically at startup.

---

## Deployment

- **Ruby:** 4.0
- **Production runs in Docker:** `docker compose up -d --build`; the entrypoint runs `rake db:migrate` then execs the bot as PID 1. `restart: unless-stopped` handles crashes (the bot's own rescue/retry loop also retries within the process). Deploy from local: `make deploy`. See CLAUDE.md for the full run/deploy procedure.
- **Local non-Docker runs only:** `daemons` gem via `./bin/bot start|stop|restart|status` — PID file in `pids/42fm_bot.pid`. `:monitor => false` — the bot's own `rescue/retry` loop handles restarts (never set `:monitor => true`; it spawns a second bot process causing duplicate responses).
- **SOCKS proxy:** configured in `settings.yml`, applied globally in `AppConfigurator#setup_proxy` via `socksify` (patches `Net::HTTP` — affects ALL outbound HTTP including Telegram polling and GPT calls)

---

## Operations

### Backing up the prod DB

```bash
make backup                    # keeps 5 newest snapshots on prod host (default)
make backup BACKUP_KEEP=10     # keep 10 newest
```

Runs [bin/backup.sh](../bin/backup.sh) remotely via `ssh bash -exs`. Uses SQLite's online backup API (`sqlite3 db/bot.db ".backup db/bot.db.bak-<utc_ts>"`), so the snapshot is consistent **even in WAL mode under concurrent writes** — a plain `cp` would miss writes still sitting in the `-wal` file. The resulting `.bak` is a standalone SQLite DB; no `-wal` or `-shm` sidecars needed. After writing, it prunes older snapshots so only the most recent N remain.

**When to run:** before a deploy that includes a new migration under `db/migrate/`. Code-only deploys don't touch schema or data, so no backup.

**Restoring** (if a migration or deploy goes bad):
```bash
ssh $DEPLOY_HOST 'cd ~/bot && docker compose down && \
  cp db/bot.db.bak-<ts> db/bot.db && \
  git reset --hard <previous-sha> && docker compose up -d --build'
```
