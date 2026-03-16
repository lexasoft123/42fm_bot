# 42FM Bot — Architecture

## Overview

42FM Bot is a Ruby Telegram bot for a private radio station community. It integrates with an Icecast radio server via TCP, provides AI-generated responses via ChatGPT, text-to-speech via AWS Polly, and various entertainment commands. The bot is chat-restricted: only messages from authorized `chat_ids` are processed.

---

## Startup Flow

```
bin/bot
  └── daemons gem (process supervisor, auto-restart on crash)
       └── lib/bot.rb
            ├── config/boot.rb (loads Settings, requires all modules)
            ├── AppConfigurator.setup (i18n, database, logger)
            ├── Radio.new (TCP connection to Icecast server)
            └── Telegram::Bot.run (long-polling loop)
                 └── MessageResponder.new(bot, message).respond
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
│   ├── database.yml     # SQLite3 connection config
│   ├── settings.yml     # Secrets (gitignored)
│   ├── radio.yml        # Radio DB path
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
│   ├── message_responder.rb   # Command router (core logic)
│   ├── message_sender.rb      # Telegram output wrapper
│   ├── settings.rb            # Config singleton
│   ├── app_configurator.rb    # i18n, DB, logger init
│   ├── database_connector.rb  # ActiveRecord setup
│   ├── radio.rb               # Icecast TCP client
│   ├── gpt_master.rb          # OpenAI API client
│   ├── polly.rb               # AWS Polly TTS + FFmpeg
│   ├── markov.rb              # Markov chain text gen
│   ├── translator.rb          # Yandex Translate API
│   ├── gogolmogol.rb          # Google Custom Search
│   ├── horoscope.rb           # Horoscope scraper
│   ├── weather.rb             # OpenWeatherMap API
│   ├── dice.rb                # Dice game logic
│   ├── reply_master.rb        # YAML-driven reply engine
│   ├── reply_markup_formatter.rb  # Telegram keyboard builder
│   ├── holidays.rb            # Holiday announcer (dormant)
│   ├── giphy_master.rb        # Giphy API (disabled)
│   └── robot/
│       └── robocoder.rb       # Base64+XOR encode/decode util
├── models/
│   ├── user.rb       # ActiveRecord: users
│   ├── message.rb    # ActiveRecord: messages
│   └── phrase.rb     # ActiveRecord: phrases
├── db/
│   ├── bot.db        # SQLite3 database
│   ├── migrate/      # ActiveRecord migrations (5 files)
│   └── markov/       # Markov chain dictionary files (*.mmd)
├── lib/samples/      # MP3 backing tracks for karaoke TTS
├── Gemfile
├── Rakefile          # db:migrate tasks
├── Dockerfile
└── docker-compose.yml
```

---

## Core Classes

### `MessageResponder` — `lib/message_responder.rb`

The central class. Receives every inbound message and routes it via regex matching.

- Instantiated per message: `MessageResponder.new(bot, message)`
- `respond` — main dispatch method; runs through pattern matches top-to-bottom
- Handles user creation/lookup, role checks, logging
- Delegates to service classes for each feature

### `MessageSender` — `lib/message_sender.rb`

Thin wrapper around the Telegram bot client:
- `send_message(text)`, `send_sticker`, `send_photo`, `send_document`, `send_voice`
- Shows typing indicator before responses

### `Settings` — `lib/settings.rb`

Singleton that loads `config/settings.yml` via `method_missing` for dot-access:
```ruby
Settings.telegram['token']
Settings.chat_gpt['api_key']
```

---

## Database Schema

**ORM:** ActiveRecord 6.0 with SQLite3

| Table | Key Columns |
|-------|-------------|
| `users` | `uid` (Telegram ID), `name`, `first_name`, `last_name`, `role` (`new`/`member`/`admin`), `last_order` |
| `messages` | `user_uid`, `chat_id`, `body` |
| `phrases` | `user_id`, `content` (unique) — user-submitted catchphrases |

**Relationships:**
- `User` has_many `messages` (FK: `user_uid` → `users.uid`)
- `User` has_many `phrases`

---

## Service Modules

### Radio — `lib/radio.rb`
Communicates with Icecast server over a raw TCP socket on `localhost:1234`. Sends text commands, parses responses. Key operations: get current track, search, request track, manage queue, fetch stats.

### GptMaster — `lib/gpt_master.rb`
HTTP client (HTTParty) for an OpenAI-compatible API. Supports two model tiers (default + GPT-4o). Configurable endpoint, system prompt with `{REQUEST}` / `{CONTEXT}` substitution. Maintains a context window of recent chat messages from the DB.

### Polly — `lib/polly.rb`
AWS Polly TTS synthesis (region: `eu-west-1`). Voices: `Maxim` (Russian), `Hans` (German). Post-processes MP3 with FFmpeg to OGG Opus at 32 kbps. Supports karaoke mode: mixes speech over an MP3 backing track from `lib/samples/`.

### Translator — `lib/translator.rb`
Yandex Translate REST API. Translates from Russian to: Ukrainian, Belarusian, German, Polish, Bulgarian, Tatar, Kazakh, Greek, Serbian.

### Gogolmogol — `lib/gogolmogol.rb`
Google Custom Search API. Supports image and GIF queries. Falls back across a pool of API key pairs when rate-limited.

### Horoscope — `lib/horoscope.rb`
Scrapes XML from `img.ignio.com` for zodiac horoscopes. Also scrapes `newsler.ru` for erotic horoscopes. Uses Nokogiri.

### Weather — `lib/weather.rb`
OpenWeatherMap JSON API. Returns temperature, wind speed, cloud cover for a given city.

### Markov — `lib/markov.rb`
Generates 5-sentence random text from Markov chain dictionaries in `db/markov/*.mmd` using the `marky_markov` gem.

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
| Yandex Translate | REST | API key |
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

### AI / Text (prefix `бот,` or `бот `)
| Command | Description |
|---------|-------------|
| `бот, [question]` | GPT response (default model) |
| `жпт [text]` | GPT response (slang trigger) |
| `жпт4 [text]` | GPT-4o model |
| `балаболь [text]` | GPT response (alternative trigger) |
| `бот пиши / пейши` | Markov-generated text |

### Voice TTS
| Command | Description |
|---------|-------------|
| `ублюдки / бот скажи [ганс] [минус] [track#] [text]` | Text-to-speech (Maxim or Hans voice, optional karaoke) |
| `бобёр [минус] [track#]` | Random phrase as TTS |

### Translation
| Command | Description |
|---------|-------------|
| `бот пиздани / укр [text]` | Translate to Ukrainian |
| `бот бульбани / бел [text]` | Translate to Belarusian |
| `бот немчи / нем [text]` | Translate to German |
| ...etc | Other language aliases |

### Info / Entertainment
| Command | Description |
|---------|-------------|
| `бот гороскоп [sign]` | Zodiac horoscope |
| `бот вещай [sign]` | Erotic horoscope |
| `бот топ` | User phrase leaderboard |
| `бот чо нового / новости` | Latest news |
| `бот найди / ищи [фото] [query]` | Google image search |
| `!помощь / !help` | Command list |

---

## Configuration

All secrets live in `config/settings.yml` (gitignored). The `Settings` module exposes them at runtime. Key setting groups:

```yaml
telegram:
  token: ...
auth:
  chat_ids: [...]          # Whitelisted chat IDs
  audio_chat_ids: [...]    # Chats where voice messages are sent
chat_gpt:
  api_key: ...
  api_url: ...
  default_model: ...
  context_messages_size: 10
  prompt: "..."
translator:
  api_url: ...
  api_key: ...
weather:
  api_url: ...
  api_key: ...
google:
  - api_key: ...
    cx_key: ...
aws:
  key_id: ...
  access_key: ...
```

---

## Deployment

- **Docker:** `Dockerfile` + `docker-compose.yml` using `ruby:3.0` base image
- **Makefile:** SSH deploy via `git pull` + `bundle install` + service restart
- **Process management:** `daemons` gem — auto-restart, PID file in `../pids/`, logs to `../log/`
