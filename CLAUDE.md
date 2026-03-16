# 42FM Bot

Ruby Telegram bot for a private radio station community. No framework — plain Ruby + ActiveRecord + SQLite3.

Full docs: `docs/architecture.md` | Agent guide: `docs/agents.md`

## Entry Points

- `bin/bot` → `lib/bot.rb` — daemon loop, filters by authorized `chat_ids`, dispatches to `MessageResponder`
- `lib/message_responder.rb` — **all commands live here**, regex-matched in `respond`
- `config/boot.rb` — requires every lib file; add new ones here
- `config/settings.yml` — secrets (gitignored); access via `Settings.group['key']`

## Key Files by Task

| Task | File |
|------|------|
| Add/change a command | `lib/message_responder.rb` |
| New service/API | `lib/new_service.rb` + require in `config/boot.rb` |
| Reply text templates | `config/replies/*.yml` |
| GPT prompt/model | `config/settings.yml` + `lib/gpt_master.rb` |
| TTS / audio | `lib/polly.rb` (AWS Polly + FFmpeg → OGG Opus) |
| Radio (Icecast TCP) | `lib/radio.rb` |
| DB schema | `db/migrate/` + `models/` |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |

## Services

`Radio` (TCP socket), `GptMaster` (OpenAI-compatible), `Polly` (AWS TTS), `Translator` (Yandex), `Gogolmogol` (Google Search), `Horoscope` (scraper), `Weather` (OpenWeatherMap), `Markov` (text gen), `ReplyMaster` (YAML replies), `Dice` (game)

## DB Tables

`users` (uid, name, role: new/member/admin, last_order), `messages` (user_uid, chat_id, body), `phrases` (user_id, content)

## Gotchas

- Messages from non-whitelisted `chat_ids` are silently dropped in `lib/bot.rb`
- Messages older than 30s are skipped
- Voice messages only go to `audio_chat_ids`
- `new` role users are rate-limited on track requests (checks `user.last_order`)
- Google API keys are a pool in settings — `gogolmogol.rb` cycles through them
- `ffmpeg` must be installed for TTS to work
