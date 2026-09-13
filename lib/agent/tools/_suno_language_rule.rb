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
require_relative '../../suno_client' # SunoToolModel / SUNO_MODEL_PARAM below

SUNO_LANGUAGE_RULE_RU = <<~RULE.freeze
  ЯЗЫК ТЕКСТА — по жанру, а не по языку запроса: русско-говорящие жанры (частушка, шансон, бардовская, советский рок/панк/эстрада) → русский; остальные (rock, metal, pop, surf rock, blues, jazz, hip-hop, country, electronic, punk, folk и т.д.) → английский по умолчанию, даже если запрос пользователя на русском. Section markers ([Verse], [Chorus] и т.д.) и parenthetical stage directions внутри блоков ВСЕГДА на английском (Suno натренирован на английском словаре стилей). Если пользователь явно требует другой язык ("сделай рэп НА РУССКОМ") — слушайся override'а.
RULE

# Shared description for the `negative_tags` parameter on every Suno-bound
# agent tool (compose_song, add_vocals, cover_audio). Centralised for the
# same reason as the language rule above — three tool files used to
# carry near-duplicate wording with drift. Suno's `negativeTags` field is
# applied AFTER positives, so use it instead of inline "no X / without Y"
# inside `tags`/`style` (which Suno parses as positive descriptors).
SUNO_NEGATIVE_TAGS_DESC = 'Опционально: чего НЕ хотим в стиле/вокале, через запятую на английском (e.g. "female vocals, acoustic guitar, slow tempo"). Поле Suno `negativeTags` — обрабатывается ПОСЛЕ позитивных тегов. Пустая строка если не нужно. Не дублируй в `tags`/`style`.'.freeze

# Shared `model` parameter for the Suno generation tools (compose_song,
# add_vocals, cover_audio). Optional, so the model never has to pick one; the
# enum is read from settings at definition time (`suno.models` + default) —
# Settings isn't loaded when the tools are required. The rescue keeps a
# schema build from failing where settings carry no `suno` group (tests):
# build_properties then just omits the enum.
SUNO_MODEL_PARAM = {
  type: 'string', optional: true,
  enum_source: -> { (SunoClient.allowed_models rescue nil) },
  description: 'Модель Suno. НЕ указывай, если пользователь не просил конкретную — по умолчанию V6_WILD (новая v6 в экспериментальном, самом креативном режиме). V6 — стандартная v6, предсказуемее ("обычная v6", "без экспериментов"). V5_5 — старая версия, только по явной просьбе ("на 5.5", "пятой версией", "как раньше звучало").',
}.freeze

# Validates a tool call's `model` in the listen loop, before any task exists:
# returns [model_or_nil, error_or_nil]. The agent-supplied value must be
# checked HERE — SunoClient#resolve_model only falls back to the default at
# submit time, after the tool already told the agent "queued", so "на v5"
# (V5 isn't allowed) would silently run on the default. On a miss the error
# lists the allowed models so the agent can correct itself in the same turn.
# `inherited` is a model copied from an earlier task (retry_of_task_id): a
# value no longer allowed there just means the default, not an error.
module SunoToolModel
  module_function

  def resolve(requested, inherited: nil)
    req = requested.to_s.strip
    if req.empty?
      return [nil, nil] if inherited.to_s.strip.empty?
      return [SunoClient.match_model(inherited), nil]
    end
    match = SunoClient.match_model(req)
    return [match, nil] if match
    [nil, "Модели Suno #{req.inspect} нет. Доступные: #{SunoClient.allowed_models.join(', ')}. " \
          'Вызови инструмент ещё раз с одной из них — или без model, тогда будет модель по умолчанию. ' \
          'Если пользователь просил недоступную версию — скажи ему об этом.']
  end

  # Suffix for a rate-limited deferred intent so the later (cron) call keeps
  # the model the user asked for.
  def intent_suffix(model)
    model ? " (model=#{model})" : ''
  end
end
