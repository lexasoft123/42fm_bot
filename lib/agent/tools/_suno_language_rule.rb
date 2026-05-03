# Canonical Russian wording of the genre-language rule shared by every
# Suno-bound agent tool (compose_song, add_vocals, cover_audio).
#
# Shared so that a rewording in one place can't quietly drift from the
# other call sites — agents that consult multiple tool descriptions
# should see consistent advice.
#
# Filename has a leading underscore so the Dir glob in
# lib/message_responder.rb auto-loads this file before any tool that
# references the constant (Ruby string-sorts `_` < `a`).
#
# The lyrics_prompt template in config/settings.common.yml carries the
# same rule but in the YAML world — kept word-for-word in sync with this
# constant by test/suno_language_policy_test.rb regression greps.
SUNO_LANGUAGE_RULE_RU = <<~RULE.freeze
  ЯЗЫК ТЕКСТА — по жанру, а не по языку запроса: русско-говорящие жанры (частушка, шансон, бардовская, советский рок/панк/эстрада) → русский; остальные (rock, metal, pop, surf rock, blues, jazz, hip-hop, country, electronic, punk, folk и т.д.) → английский по умолчанию, даже если запрос пользователя на русском. Section markers ([Verse], [Chorus] и т.д.) и parenthetical stage directions внутри блоков ВСЕГДА на английском (Suno натренирован на английском словаре стилей). Если пользователь явно требует другой язык ("сделай рэп НА РУССКОМ") — слушайся override'а.
RULE
