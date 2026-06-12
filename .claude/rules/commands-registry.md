---
paths:
  - "lib/commands/registry.rb"
  - "lib/commands/base.rb"
  - "lib/commands/fallback_reply.rb"
  - "lib/commands/bober_voice.rb"
  - "lib/commands/tts_voice.rb"
  - "lib/commands/help.rb"
  - "lib/polly.rb"
  - "lib/tts_service.rb"
---

# Command registry / dispatch order / TTS gotchas

Reference: `docs/architecture.md` § Commands::REGISTRY / § Development Guide (how to add a command).

- `GptChat` must be last `бот`-prefixed command in registry — it matches `бот <anything>`
- `FallbackReply` must always be last in `REGISTRY` — it matches almost anything. `GptChat`'s pattern is also broad — keep more specific commands above it.
- **Private chats need no prefix** — `GptChat#private_no_prefix?` matches ANY non-slash text when `message.chat.type == 'private'` (slash commands fall through to `FallbackReply` instead of burning an LLM call). Consequences, all deliberate: (a) `FallbackReply`/ReplyMaster Easter eggs are shadowed in DMs for plain text; (b) **`BoberVoice`/`TtsVoice` keep winning in DMs** — their unprefixed PATTERNs (`боб(е|ё)р` — unanchored, matches anywhere in a sentence; `ублюдки …` — start-anchored) sit above `GptChat` in the registry, so DM «у меня бобёр живёт» triggers the voice egg, not the agent (pinned by `test/gpt_chat_test.rb`); (c) the **Phrase egg is prefix-gated** — `maybe_save_phrase` runs only when the message was explicitly addressed (PATTERN matched or reply-to-bot), so bare DM «ты …»/«вы …» small talk is NOT harvested; (d) a super-admin with an armed admin-menu `awaiting_input` session has plain DM text eaten by the menu, not the agent (escape: `/cancel`, any `/`-command, or a `бот`/`жпт` prefix; 5-min TTL); (e) every plain-text DM now costs an agent LLM call + the `get_relevant_knowledge` embedding lookup. Bare DM text reaches the agent downcased (same as the reply-to-bot path).
- Admin-only commands use `return admin_denied unless admin?` from `Commands::Base`; agent tools check `@user.role` — both pull denial messages from `Settings.replies['admin_denied']` in `settings.common.yml`
- `ffmpeg` and `opusenc` (from `opus-tools`) must be installed for TTS to work — both are included in the Docker image
