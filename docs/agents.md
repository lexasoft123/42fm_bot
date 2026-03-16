# 42FM Bot — Claude Code Agent Guide

This document is the entry point for AI-assisted development on this project. Read it before making any changes.

---

## Project Snapshot

- **Language:** Ruby 3.0
- **Framework:** None (plain Ruby + ActiveRecord)
- **DB:** SQLite3 at `db/bot.db` via ActiveRecord 6.0
- **Key entry point:** `lib/bot.rb` → `lib/message_responder.rb`
- **Config:** `config/settings.yml` (gitignored — never committed)
- **Docs:** `docs/architecture.md` — full architecture reference

---

## Before You Start

1. Read `docs/architecture.md` — it explains every class, service, and command.
2. All bot commands are routed through `lib/message_responder.rb` via regex matching in `respond`. This is where most feature additions happen.
3. Services are decoupled single-class files in `lib/`. Adding a feature = adding a service file + wiring it in `message_responder.rb`.
4. Secrets are in `config/settings.yml` (not in git). Access them via `Settings.<group>['key']`.

---

## How to Add a New Command

1. **Create a service class** in `lib/my_feature.rb`:
   ```ruby
   class MyFeature
     def initialize(message)
       @message = message
     end

     def call
       # return a string or send directly
     end
   end
   ```

2. **Require it** in `config/boot.rb`:
   ```ruby
   require_relative '../lib/my_feature'
   ```

3. **Add a regex route** in `lib/message_responder.rb` inside `respond`:
   ```ruby
   when /бот мояфича (.+)/i
     @message_sender.send_message(MyFeature.new(@message).call)
   ```

4. **Add config** to `config/settings.yml` if the feature needs API keys or parameters.

5. **Update `!помощь` output** in `message_responder.rb` so users can discover the command.

---

## Key Patterns

### Sending a reply
```ruby
@message_sender.send_message("text")
@message_sender.send_voice(file_path)
@message_sender.send_photo(url)
```

### Getting message text
```ruby
@message.text          # full text
@message.from.id       # sender Telegram ID
@message.chat.id       # chat ID
```

### Looking up the current user
```ruby
user = User.find_by(uid: @message.from.id)
user.role              # 'new', 'member', 'admin'
```

### Accessing settings
```ruby
Settings.chat_gpt['api_key']
Settings.auth['chat_ids']
```

### Calling the radio server
```ruby
radio = Radio.new
radio.current_track
radio.search(query)
radio.request(track_id, user)
```

### Calling GPT
```ruby
GptMaster.new(@message).respond(text)
GptMaster.new(@message, model: :gpt4).respond(text)
```

### Text-to-speech
```ruby
Polly.new.synthesize(text, voice: 'Maxim')         # returns file path
Polly.new.synthesize_with_track(text, track_num)   # karaoke mode
```

---

## Adding New Settings

Add to `config/settings.yml`:
```yaml
my_feature:
  api_key: xxx
  some_param: value
```

Access in code:
```ruby
Settings.my_feature['api_key']
```

No code changes needed in `settings.rb` — `method_missing` handles it.

---

## Database Changes

Create a migration:
```bash
# create db/migrate/YYYYMMDDHHMMSS_add_something.rb
```

```ruby
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

---

## Common Gotchas

- **Auth check:** The main loop in `lib/bot.rb` filters messages by `Settings.auth['chat_ids']`. Test messages from other chats are silently dropped.
- **Message age:** Messages older than 30 seconds are skipped (bot restart catch-up protection).
- **Rate limiting:** Track requests from `new` role users check `user.last_order` — leave that logic intact when modifying the request command.
- **Voice messages:** Only sent to chats listed in `Settings.auth['audio_chat_ids']`.
- **Google API keys:** `gogolmogol.rb` cycles through a pool of key pairs — add more pairs to settings if hitting rate limits.
- **FFmpeg dependency:** `polly.rb` shells out to `ffmpeg` — must be installed in the runtime environment.
- **TCP socket to radio:** `radio.rb` opens a new socket per request — no persistent connection is maintained.

---

## File Reference for Common Tasks

| Task | File(s) |
|------|---------|
| Add/modify a bot command | `lib/message_responder.rb` |
| Add a service/API integration | `lib/new_service.rb` + `config/boot.rb` |
| Change reply/response text | `config/replies/*.yml` |
| Change TTS behavior | `lib/polly.rb` |
| Change GPT prompt/model | `config/settings.yml` + `lib/gpt_master.rb` |
| Change radio commands | `lib/radio.rb` + `lib/message_responder.rb` |
| Database schema change | `db/migrate/` + relevant model in `models/` |
| Add new settings | `config/settings.yml` (access via `Settings.*`) |
| Sticker IDs | `config/initializers/telegram_stickers.rb` |
