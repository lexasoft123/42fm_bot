# 42FM Bot — Claude Code Agent Guide

This document is the entry point for AI-assisted development on this project. Read it before making any changes.

---

## Project Snapshot

- **Language:** Ruby 4.0
- **Framework:** None (plain Ruby + ActiveRecord)
- **DB:** SQLite3 at `db/bot.db` via ActiveRecord 6.1
- **Key entry point:** `lib/bot.rb` → `lib/message_responder.rb` → `lib/commands/registry.rb`
- **Config:** `config/settings.common.yml` (defaults, committed) + `config/settings.yml` (secrets, gitignored)
- **Docs:** `docs/architecture.md` — full architecture reference

---

## Running the Bot

**Always use the daemon script. Never run `ruby lib/bot.rb` directly.**

```bash
./bin/bot start    # start as background daemon
./bin/bot stop     # stop the daemon
./bin/bot restart  # restart (use after code changes)
./bin/bot status   # check if running
```

- **Logs:** `log/bot.log` — all app output, Telegram client, and SQL queries in one file. Every per-chat line is prefixed `[chat=<id>]`; agent turns add `[AGENT]`. Grep one chat with `grep 'chat=-100...' log/bot.log`.
- **PID:** `pids/42fm_bot.pid`
- Running `ruby lib/bot.rb` directly bypasses the daemon and mixes with any already-running instance, causing duplicate responses.

---

## Keeping Docs Up to Date

**Before every commit, update `CLAUDE.md`, `docs/architecture.md`, and this file** to reflect:
- New/removed/renamed commands, services, or files
- Changes to dispatch logic, command structure, or response patterns
- DB schema changes
- New settings groups or required keys
- New external service integrations
- Changes to startup, logging, or deployment

Outdated docs are worse than no docs — keep them in sync with the code.

---

## Before You Start

1. Read `docs/architecture.md` — it explains every class, service, and command.
2. Commands are in `lib/commands/` — each is a class with `match?` / `execute`. Wired via `lib/commands/registry.rb`.
3. Services are single-class files in `lib/`. Adding a feature = new service file + require in `config/boot.rb` (or `message_responder.rb`) + new command class.
4. Secrets are in `config/settings.yml` (not in git). Access them via `Settings.<group>['key']`.

---

## How to Add a New Command

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

6. **Update docs** — `CLAUDE.md` command table, `docs/architecture.md` command reference.

---

## Key Patterns

### Building a reply
```ruby
CommandResult.text("message")
CommandResult.sticker(STICKER_ID)
CommandResult.image("https://...")
CommandResult.voice(file_or_url)
CommandResult.audio(url, title: "...", performer: "...")  # :audio (MP3 with metadata)
CommandResult.none   # handled silently, no reply sent
```

### Accessing context inside a command
```ruby
# All ctx fields are delegated in Commands::Base:
cmd        # downcased message text (String or nil)
user       # User ActiveRecord instance
chat_id    # Telegram chat ID
radio      # Radio instance (lazy TCP)
message    # raw Telegram::Bot::Types::Message
bot        # Telegram bot client
reply_master  # ReplyMaster instance
```

### Chat commands route through the agent
`GptChat` / `GptQuestion` always call `Agent::Runner.new(...).run` — there is no non-agent path. See `lib/commands/gpt_chat.rb` for the exact invocation.

### Calling GPT for a one-off task (no chat context)
```ruby
PROMPT = 'Do something with: {REQUEST}'
CommandResult.text(GptMaster.ask(text, prompt: PROMPT,
                                  chat_id: chat_id, purpose: 'my_new_purpose'))
```

### Telemetry (`chat_id` + `user_uid` + `purpose`)
Every `GptMaster` call persists a row to `api_usage` with the `chat_id`, `user_uid`, and `purpose` you pass. Always pass all three where possible so `бот затраты` can attribute costs and show top spenders. Existing purpose labels: `agent` / `translate` / `knowledge_extract` / `knowledge_compact` / `suno_lyrics` / `suno_tags` / `suno_parse` / `image_prompt`. If you add a new call site, pick a short snake_case label and use it consistently. Background tasks that don't have a triggering user (knowledge extraction, compaction) leave `user_uid` nil — the top-spenders section filters those out.

### Prompt caching
`Settings.chat_gpt['agent_prompt']` contains a `{CACHE_BREAK}` marker. `Agent::Runner` splits on it — the static prefix is sent as a cached Anthropic `system` block, the dynamic suffix (`{KNOWLEDGE}` / `{CONTEXT}` / `{REQUEST}`) as the user message. Agent tool definitions are also cached via `cache_control` on the last tool. Second+ calls within 5 min hit the cache (see `cache_read_tokens > 0` in `api_usage`). `GptMaster.ask` does **not** cache — its prompts vary per call.

### Text-to-speech
```ruby
url = TtsService.speak(text, voice: 'Maxim', speed: nil, minus: false, track_id: nil)
CommandResult.voice(url)
```

### Calling the radio server
```ruby
radio.current_track
radio.search(query)
radio.request(track_id, user)
```
TCP connects lazily on first call — no need to guard against startup failures.

### Looking up / checking the current user
```ruby
user.role              # 'new', 'member', 'admin'
user.uid               # Telegram ID
user.last_order        # Time of last track request
```

### Accessing settings
```ruby
Settings.chat_gpt['api_key']
Settings.auth['chat_ids']
Settings.proxy['enabled']
```

---

## Adding New Settings

Add a top-level group to `config/settings.yml`:
```yaml
my_feature:
  api_key: xxx
  some_param: value
```

Access in code:
```ruby
Settings.my_feature['api_key']
```

`method_missing` in `Settings` handles it automatically. If the group is **required for the app to boot**, also add the key to `REQUIRED_KEYS` in `lib/settings.rb`.

---

## Database Changes

Create a migration file (sequential number prefix):
```ruby
# db/migrate/007_add_something.rb
class AddSomething < ActiveRecord::Migration[6.0]
  def change
    add_column :users, :new_field, :string
  end
end
```

Run with:
```bash
bundle exec rake db:migrate
```

Update the relevant model in `models/` and the schema table in `docs/architecture.md`.

---

## Common Gotchas

- **Auth check:** `lib/bot.rb` silently drops messages from chats not in `Settings.auth['chat_ids']`.
- **Message age:** Messages older than 30 seconds are skipped (catch-up protection after restart).
- **Rate limiting:** Track requests from `new` role users check `user.last_order` — keep that logic intact.
- **Voice messages:** Only processed in chats listed in `Settings.auth['audio_chat_ids']`.
- **Google API keys:** `gogolmogol.rb` cycles through a pool — add more pairs to settings if rate-limited.
- **FFmpeg:** `polly.rb` shells out to `ffmpeg` — must be installed.
- **Radio TCP:** Lazy connect — first use opens the socket. Restart bot if radio server restarts.
- **Daemons `:monitor => false`:** The bot has its own `rescue/retry` loop. Never set `:monitor => true` — it spawns a second bot process causing duplicate responses.
- **SOCKS proxy:** Applied globally in `AppConfigurator#setup_proxy` via `socksify`. Affects all `Net::HTTP` including Telegram polling and GPT calls.
- **Bot replies in context:** GPT chat commands store bot replies in `messages` with `role: 'bot'`, `user_uid: nil`. `get_chat_context` includes them formatted as `"Жзяцля: ..."`.
- **Command order:** `FallbackReply` must always be last in `REGISTRY` — it matches almost anything.
- **GptChat pattern is broad:** It can match most text — keep more specific commands above it in REGISTRY.
- **Vision/Image recognition:** When a user replies to a photo with "бот ...", `GptChat` downloads the photo, base64-encodes it, and passes it to the agent as a multi-modal message. The agent can describe, analyze, and answer questions about images. Falls back to text-only if download fails.
- **Background tasks:** The `compose_song` and `generate_image` agent tools create `BackgroundTask` records instead of blocking — songs/images are generated asynchronously and delivered to the chat when ready. The agent receives a confirmation message immediately.
- **Suno tags:** Never include artist names in Suno tags — Suno blocks them. Describe the sound characteristics instead.
- **ChatContext module:** `lib/chat_context.rb` provides `get_chat_context` and `get_relevant_knowledge` — shared by task handlers for context-aware generation.
- **Music search:** `Song.search` uses FTS4 full-text search on metadata (title, artist, album, genre). Populated by `MusicScanner` via `rake music:scan`. Falls back to legacy file-path matching if DB is empty.
- **wahwah:** Pure Ruby gem for reading audio tags — no native dependencies.

---

## File Reference for Common Tasks

| Task | File(s) |
|------|---------|
| Add/modify a bot command | `lib/commands/new_cmd.rb` + `message_responder.rb` (require) + `registry.rb` (position) |
| Add a service/API integration | `lib/new_service.rb` + `config/boot.rb` (or `message_responder.rb`) |
| Add a background task handler | `lib/task_handlers/my_handler.rb` + `TaskRunner.register(...)` |
| FLUX image generation | `lib/flux_client.rb` + `lib/task_handlers/image_gen_handler.rb` + `lib/agent/tools/image_gen.rb` (agent-only, no direct command) |
| Suno song generation | `lib/suno_client.rb` + `lib/task_handlers/suno_handler.rb` + `lib/agent/tools/suno.rb` (agent-only, no direct command) |
| Change reply/response text | `config/replies/*.yml` |
| Change TTS behavior | `lib/polly.rb` + `lib/tts_service.rb` |
| Change GPT prompt/model | `config/settings.yml` (`chat_gpt` group) |
| Change GPT API logic | `lib/gpt_master.rb` |
| Change chat context window | `lib/commands/gpt_helpers.rb` + `context_messages_size` in settings |
| Change radio commands | `lib/radio.rb` + relevant command in `lib/commands/` |
| Music library / search | `models/song.rb` + `lib/music_scanner.rb` + `rake music:scan` |
| Database schema change | `db/migrate/NNN_*.rb` + model in `models/` |
| Add new settings | `config/settings.yml` + optionally `REQUIRED_KEYS` in `lib/settings.rb` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy config | `config/settings.yml` (`proxy` group) |
