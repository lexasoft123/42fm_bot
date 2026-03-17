# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md`

## Rules

- **Never commit automatically.** Always ask the user before creating a git commit.
- **Never run `ruby lib/bot.rb` directly.** Always use `./bin/bot start/stop/restart`.

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
- `config/settings.yml` — secrets (gitignored); access via `Settings.group['key']`

## Command System

Commands live in `lib/commands/`. Each is a class inheriting `Commands::Base` with two methods:
- `match?` — returns truthy if this command handles the current message
- `execute` — runs the command, returns a `CommandResult`

`CommandContext` (struct) carries per-message state: `bot`, `message`, `user`, `chat_id`, `radio`, `reply_master`, `cmd`.
`CommandResult` (value object) wraps the response type (`:text`, `:sticker`, `:image`, `:voice`, `:none`) and payload.

## Key Files by Task

| Task | File |
|------|------|
| Add/change a command | New file in `lib/commands/` + require in `message_responder.rb` + entry in `lib/commands/registry.rb` |
| New service/API | `lib/new_service.rb` + require in `config/boot.rb` |
| Reply text templates | `config/replies/*.yml` |
| GPT prompt/model | `config/settings.yml` (`chat_gpt` group) + `lib/gpt_master.rb` |
| TTS / audio | `lib/polly.rb` (AWS Polly + FFmpeg → OGG Opus) + `lib/tts_service.rb` |
| Radio (Icecast TCP) | `lib/radio.rb` |
| DB schema | `db/migrate/` + `models/` — run with `bundle exec rake db:migrate` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
| SOCKS proxy | `config/settings.yml` (`proxy` group) + `lib/app_configurator.rb` |

## Services

`Radio` (TCP socket, lazy connect), `GptMaster` (OpenAI-compatible, `.chat`/`.ask`), `Polly` (AWS TTS), `TtsService` (wraps Polly + URL), `Gogolmogol` (Google Search), `Horoscope` (scraper), `Weather` (OpenWeatherMap), `ReplyMaster` (YAML replies), `Dice` (game)

## DB Tables

| Table | Columns |
|-------|---------|
| `users` | `uid`, `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable), `chat_id`, `body`, `role` (`user`/`bot`) |
| `phrases` | `user_id`, `content` |

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
- `Settings` validates required keys on load — add new top-level groups to `REQUIRED_KEYS` in `lib/settings.rb`
