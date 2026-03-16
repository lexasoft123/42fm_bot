# 42FM Bot — Architecture

## Overview

42FM Bot is a Ruby Telegram bot for a private radio station community. It integrates with an Icecast radio server via TCP, provides AI-generated responses via an OpenAI-compatible API, text-to-speech via AWS Polly, and various entertainment commands. The bot is chat-restricted: only messages from authorized `chat_ids` are processed.

---

## Startup Flow

```
bin/bot
  └── daemons gem (process manager, :monitor => false — bot handles its own restarts)
       └── lib/bot.rb
            ├── config/boot.rb (loads Settings, requires all modules)
            ├── AppConfigurator.configure (i18n, DB, SOCKS proxy)
            ├── Radio.new (lazy TCP connection to Icecast — connects on first use)
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
│   ├── radio.yml        # Radio server config
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
│   ├── radio.rb               # Icecast TCP client (lazy connect)
│   ├── gpt_master.rb          # OpenAI-compatible API client (.chat / .ask)
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
│   │   ├── gpt_helpers.rb     # get_chat_context, save_bot_reply
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
│   │   ├── gpt_question.rb
│   │   ├── gpt_chat.rb
│   │   ├── horoscope_sign.rb
│   │   ├── horoscope_general.rb
│   │   ├── news.rb
│   │   ├── translate.rb       # GPT-based translation (no Yandex)
│   │   ├── dice.rb
│   │   ├── reply_you.rb
│   │   ├── phrase_top.rb
│   │   ├── gif_search.rb
│   │   ├── google_search.rb
│   │   └── fallback_reply.rb
│   └── robot/
│       └── robocoder.rb       # Base64+XOR encode/decode util
├── models/
│   ├── user.rb       # ActiveRecord: users
│   ├── message.rb    # ActiveRecord: messages (user optional for bot replies)
│   └── phrase.rb     # ActiveRecord: phrases
├── db/
│   ├── bot.db        # SQLite3 database
│   └── migrate/      # ActiveRecord migrations (006 files)
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

Base class for all commands. Exposes `ctx` members as delegated accessors (`bot`, `message`, `user`, `chat_id`, `radio`, `reply_master`, `cmd`).

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

**ORM:** ActiveRecord 6.1 with SQLite3 (`db/bot.db`)
**Run migrations:** `bundle exec rake db:migrate`

| Table | Key Columns |
|-------|-------------|
| `users` | `uid` (Telegram ID), `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid` (nullable — nil for bot replies), `chat_id`, `body`, `role` (`user`/`bot`) |
| `phrases` | `user_id`, `content` (unique) — user-submitted catchphrases |

**Relationships:**
- `User` has_many `messages` (FK: `user_uid` → `users.uid`)
- `User` has_many `phrases`
- `Message` belongs_to `user`, `optional: true` (bot replies have no user)

---

## Service Modules

### Radio — `lib/radio.rb`
Communicates with Icecast server over a raw TCP socket on `localhost:1234`. Connection is **lazy** — socket opens on first use, not at startup. Sends text commands, parses responses. Key operations: get current track, search, request, manage queue, fetch stats.

### GptMaster — `lib/gpt_master.rb`
HTTP client (HTTParty) for an OpenAI-compatible API. Two class-method interfaces:

- `GptMaster.chat(text, context:, model:)` — uses the prompt template from `settings.yml` (`{REQUEST}` / `{CONTEXT}` substitution). Used by chat commands. Saves bot reply to DB context.
- `GptMaster.ask(text, prompt:, model:)` — caller supplies prompt template (`{REQUEST}` only). Used for one-off tasks like translation. No context.

### GptHelpers — `lib/commands/gpt_helpers.rb`
Mixed into GPT commands:
- `get_chat_context` — fetches recent messages for current chat, including bot replies (formatted as `"Жзяцля: ..."`)
- `save_bot_reply(text)` — stores bot reply in `messages` with `role: 'bot'`, `user_uid: nil`

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
| Icecast Radio Server | Raw TCP socket | None (localhost) |
| OpenAI-compatible API | HTTPS/HTTParty | Bearer token |
| AWS Polly | AWS SDK | Access key + secret |
| Google Custom Search | REST | API key + CX key |
| OpenWeatherMap | REST | API key |
| img.ignio.com | HTTP scrape | None |
| newsler.ru | HTTP scrape | None |
| lenta.ru | RSS | None |

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

### AI / Text
| Command | Description |
|---------|-------------|
| `бот, [question]` | GPT response (default model, with chat context) |
| `жпт [text]` | GPT response (slang trigger) |
| `балаболь [text]` | GPT response (alternative trigger) |
| `бот почему/как/зачем... [text]` | GPT question matcher |

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
| `бот гороскоп [sign]` | Zodiac horoscope |
| `бот вещай [sign]` | Erotic horoscope |
| `бот топ` | User phrase leaderboard |
| `бот чо нового / новости` | Latest news |
| `бот найди / ищи [фото] [query]` | Google image/GIF search |
| `!помощь / !help` | Command list |

---

## Configuration

All secrets live in `config/settings.yml` (gitignored). Key setting groups:

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
  api_key: ...
  api_url: ...
  default_model: ...
  context_messages_size: 10
  prompt: "...{CONTEXT}...{REQUEST}..."
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
```

---

## Deployment

- **Ruby:** 4.0
- **Docker:** `Dockerfile` + `docker-compose.yml`
- **Process management:** `daemons` gem — PID file in `../pids/`, logs to stdout. `:monitor => false` — the bot's own `rescue/retry` loop handles restarts.
- **SOCKS proxy:** configured in `settings.yml`, applied globally in `AppConfigurator#setup_proxy` via `socksify` (patches `Net::HTTP`)
