require_relative '../../suno_client'
require_relative '../../audio_attachment'
require_relative '../../pending_audio_request'

# Agent mode → Suno separation `type`.
SEPARATE_VOCALS_MODES = {
  'vocals'     => 'separate_vocal',
  'stems'      => 'split_stem',
  'instrument' => 'split_stem_advanced',
}.freeze

# Suggestions shown when stem_name is missing/unknown — the full enum (~100
# names) lives in SunoClient::STEM_NAMES and is validated handler-side rather
# than shipped in the schema on every agent turn.
SEPARATE_VOCALS_COMMON_STEMS = ['Lead Vocal', 'Backing Vocals', 'Drum Kit', 'Bass', 'Electric Guitar',
                                'Acoustic Guitar', 'Piano', 'Synth', 'String Section', 'Brass Section'].freeze

module SeparateVocalsTool
  module_function

  def resolve_stem_name(raw)
    name = raw.to_s.strip
    return nil if name.empty?
    SunoClient::STEM_NAMES.find { |n| n.casecmp?(name) }
  end

  def stem_suggestions(raw)
    # Singularize crudely so "drums" still finds "Drum Kit".
    words = raw.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?).map { |w| w.length > 3 ? w.sub(/s\z/, '') : w }
    close = SunoClient::STEM_NAMES.select { |n| words.any? { |w| n.downcase.include?(w) } }
    (close.empty? ? SEPARATE_VOCALS_COMMON_STEMS : close).first(12)
  end

  # Clip index from a bot song row body — "[песня: Title (2/2)]". Anchored to
  # the end so a "(1/2)" inside the title itself doesn't win.
  def clip_index_from_body(body)
    m = body.to_s.match(%r{\((\d+)/\d+\)\]?\s*\z})
    m && m[1].to_i
  end

  def normalize_clip_index(raw)
    idx = raw.to_s[/\A\d+\z/] ? raw.to_i : 1
    [1, 2].include?(idx) ? idx : 1
  end

  def done_song(chat_id, external_id)
    BackgroundTask.where(chat_id: chat_id, task_type: SONG_TASK_TYPES, status: 'done',
                         external_id: external_id).first
  end

  def suno_source(task_id, clip_index, task)
    p = task&.params_hash || {}
    { kind: :suno, task_id: task_id, clip_index: clip_index,
      title: p['title'], performer: p['artist'].to_s }
  end

  def audio_source(audio)
    { kind: :telegram, file_id: audio[:file_id], message_id: audio[:message_id],
      title: audio[:title], performer: audio[:performer].to_s }
  end

  def song_from_bot_row(chat_id, row, clip_arg)
    song = row&.bg_task_external_id && done_song(chat_id, row.bg_task_external_id)
    return nil unless song
    clip = clip_index_from_body(row.body)
    suno_source(song.external_id, [1, 2].include?(clip) ? clip : clip_arg, song)
  end

  # A message the agent points at explicitly (`source_message_id`, e.g. from
  # a deferred intent): a user upload row → its file; a bot song row → the
  # Suno clip. No age bound — the reference is explicit.
  def source_from_message_id(chat_id, message_id, clip_arg)
    row = Message.where(chat_id: chat_id, message_id: message_id).order(id: :desc).first
    return nil unless row
    return song_from_bot_row(chat_id, row, clip_arg) if row.role == 'bot'
    return nil unless row.attachment_file_id
    { kind: :telegram, file_id: row.attachment_file_id, message_id: row.message_id,
      title: row.attachment_title, performer: row.attachment_performer.to_s }
  end

  # Newest bot song row (≤ max age) in the chat — inside the forum topic when
  # the request came from one. Rows, not BackgroundTask, because only rows
  # know their thread and which clip (1/2) they carry.
  def recent_bot_song(chat_id, forum_thread_id, clip_arg, now)
    scope = Message.where(chat_id: chat_id, role: 'bot').where.not(bg_task_external_id: nil)
                   .where('created_at >= ?', now - AudioAttachment::LOOKBACK_MAX_AGE_MIN * 60)
    scope = scope.where(message_thread_id: forum_thread_id) if forum_thread_id
    scope.order(id: :desc).limit(AudioAttachment::LOOKBACK_ROWS).each do |row|
      src = song_from_bot_row(chat_id, row, clip_arg)
      return [src, ((now - row.created_at) / 60).floor] if src
    end
    nil
  end

  # Source resolution, most specific first:
  #   1. explicit suno_task_id
  #   2. explicit source_message_id (user upload row or bot song row)
  #   3. reply to a bot song message — unless this message carries its own
  #      attachment (that one wins, as in AudioAttachment); checked before
  #      ctx[:audio] because a reply to a bot song ALSO carries its audio
  #   4. upload_url
  #   5. audio on the current message / its reply target
  #   6. nothing explicit, real user turn only → the newest of a fresh
  #      lookback upload and the latest bot song (same forum topic), both
  #      bounded by LOOKBACK_MAX_AGE_MIN. Never on agent_event/cron turns:
  #      those carry no audio/reply context, so "latest song" would bill a
  #      track the user never pointed at.
  def resolve_source(args, ctx, now: Time.now)
    chat_id  = ctx[:chat_id]
    clip_arg = normalize_clip_index(args['clip_index'])
    explicit = args['suno_task_id'].to_s.strip
    return suno_source(explicit, clip_arg, done_song(chat_id, explicit)) unless explicit.empty?

    src_msg = args['source_message_id'].to_s[/\A\d+\z/]
    return source_from_message_id(chat_id, src_msg.to_i, clip_arg) if src_msg

    audio_src = ctx[:audio_source] || (ctx[:audio] && :message)
    if ctx[:reply_to_message_id] && audio_src != :message
      bot_msg = Message.find_by(chat_id: chat_id, role: 'bot', message_id: ctx[:reply_to_message_id])
      src = song_from_bot_row(chat_id, bot_msg, clip_arg)
      return src if src
    end

    url = args['upload_url'].to_s.strip
    return { kind: :url, url: url, title: nil, performer: '' } unless url.empty?

    return audio_source(ctx[:audio]) if ctx[:audio] && %i[message reply].include?(audio_src)
    return nil if ctx[:user_initiated] == false

    lookback_age = ctx[:audio] && audio_src == :lookback ? ctx[:audio][:age_min].to_i : nil
    lookback_age = nil if lookback_age && lookback_age > AudioAttachment::LOOKBACK_MAX_AGE_MIN
    song, song_age = recent_bot_song(chat_id, ctx[:forum_thread_id], clip_arg, now)

    if lookback_age && (song_age.nil? || lookback_age <= song_age)
      audio_source(ctx[:audio])
    elsif song
      song
    end
  end

  # Concrete tool-call arguments that re-select the same source later — put
  # into a deferred intent so a cron-driven retry (no audio/reply context)
  # bills the track the user meant, not whatever is newest by then.
  def source_handle(source, mode, stem_name)
    parts = ["mode=#{mode}"]
    parts << "stem_name=#{stem_name.inspect}" if stem_name
    case source[:kind]
    when :suno     then parts << "suno_task_id=#{source[:task_id]}" << "clip_index=#{source[:clip_index]}"
    when :telegram then parts << (source[:message_id] ? "source_message_id=#{source[:message_id]}" : "трек «#{source[:title]}»")
    when :url      then parts << "upload_url=#{source[:url]}"
    end
    "separate_vocals(#{parts.join(', ')})"
  end
end

Agent::ToolRegistry.register(
  name: 'separate_vocals',
  description: 'Разделить трек на дорожки через Suno, СОХРАНЯЯ ОРИГИНАЛЬНУЮ запись (ничего не перегенерирует). Используй когда просят: "убери вокал", "сделай минус/минусовку", "караоке-версию", "оставь только вокал", "акапелла", "раздели на дорожки/стемы", "вытащи барабаны/бас/гитару". Это НЕ cover_audio: cover_audio (даже с instrumental=true) сочиняет НОВУЮ музыку в другом стиле, а separate_vocals вырезает дорожки из исходника. Источник: если пользователь ОТВЕЧАЕТ (reply) на песню бота — берётся она; иначе прикреплённое/процитированное аудио; иначе upload_url; без явного источника — самый свежий (≤30 мин) трек в чате. Если непонятно, о каком треке речь — спроси. Режимы: vocals — вокал + минус (по умолчанию, дёшево); stems — все дорожки до 12 шт. (в 5 раз дороже — только если явно просят ВСЕ дорожки/стемы); instrument — одна конкретная дорожка (заполни stem_name).',
  parameters: {
    'mode'         => { type: 'string', enum: SEPARATE_VOCALS_MODES.keys, optional: true,
                        description: 'vocals (по умолчанию) — вокал + минус; stems — все дорожки; instrument — одна дорожка из stem_name.' },
    'stem_name'    => { type: 'string', optional: true,
                        description: "Только для mode=instrument: инструмент по-английски, как в каталоге Suno, e.g. #{SEPARATE_VOCALS_COMMON_STEMS.map { |n| "\"#{n}\"" }.join(', ')}." },
    'suno_task_id' => { type: 'string', optional: true,
                        description: 'Опционально: Suno taskId конкретной песни бота. Обычно не нужен — reply на песню резолвится сам.' },
    'source_message_id' => { type: 'integer', optional: true,
                        description: 'Опционально: message_id сообщения в этом чате с нужным треком (аудио пользователя или песня бота) — используй при отложенном повторе, если он указан в intention.' },
    'clip_index'   => { type: 'integer', optional: true,
                        description: 'Для песни бота: какой из двух клипов (1 или 2). Если пользователь ответил на конкретный клип — определяется сам.' },
    'upload_url'   => { type: 'string', optional: true,
                        description: 'Опционально: прямая ссылка на аудио (до 20 МБ), если пользователь дал ссылку, а не файл.' },
  },
  handler: ->(args, ctx) {
    mode = args['mode'].to_s.strip.downcase
    mode = 'vocals' if mode.empty?
    type = SEPARATE_VOCALS_MODES[mode]
    next "Неизвестный mode=#{mode.inspect}. Допустимо: #{SEPARATE_VOCALS_MODES.keys.join(', ')}." unless type

    stem_name = nil
    if type == 'split_stem_advanced'
      stem_name = SeparateVocalsTool.resolve_stem_name(args['stem_name'])
      unless stem_name
        options = SeparateVocalsTool.stem_suggestions(args['stem_name'])
        next "Для mode=instrument нужен stem_name из каталога Suno. Подходящие варианты: #{options.join(', ')}. Вызови separate_vocals ещё раз с точным названием."
      end
    end

    # Source before rate limit (DB-only; the Telegram getFile happens after
    # the limit check): a rate-limited deferral must record WHICH track, so
    # the cron retry — which has no audio/reply context — re-selects it.
    source = SeparateVocalsTool.resolve_source(args, ctx)
    role = ctx[:user]&.role
    unless source
      unless RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
        offer = PendingAudioRequest.offer(ctx, tool: 'separate_vocals')
        next offer if offer
      end
      next Agent::ToolResult.deferred(
        user_text:    'Не вижу, какой трек разделять: ответь (reply) на песню или прикрепи аудиофайл.',
        intent:       'разделить трек на дорожки, как только пользователь укажет трек',
        retry_in_min: nil
      )
    end

    if RateLimiter.exceeded?(ctx[:chat_id], 'suno', role: role)
      mins = RateLimiter.minutes_until_free(ctx[:chat_id], 'suno', role: role)
      next Agent::ToolResult.deferred(
        user_text:    RateLimiter.reply(ctx[:chat_id], 'suno', role: role),
        intent:       "через #{mins} мин вызвать #{SeparateVocalsTool.source_handle(source, mode, stem_name)}",
        retry_in_min: mins
      )
    end

    params = { type: type, stem_name: stem_name, mode: mode,
               source_title: source[:title], source_performer: source[:performer],
               user_uid: ctx[:user]&.uid }
    case source[:kind]
    when :suno
      params[:source_task_id] = source[:task_id]
      params[:clip_index]     = source[:clip_index]
    when :url
      params[:audio_url] = source[:url]
    when :telegram
      url = TelegramFile.public_url(ctx[:api], source[:file_id], chat_id: ctx[:chat_id]).to_s
      next 'Не получилось забрать этот файл из Telegram (бот может скачивать файлы только до 20 МБ). Пришли файл поменьше или прямую ссылку.' if url.empty?
      params[:audio_url] = url
    end

    PendingAudioRequest.clear_for(ctx) # a task is being created — the follow-up is moot
    BackgroundTask.create!(
      task_type: 'suno_separate_vocals',
      chat_id: ctx[:chat_id],
      max_attempts: 60,
      params: params.to_json
    )

    title = source[:title].to_s.empty? ? 'трек' : "«#{source[:title]}»"
    case type
    when 'separate_vocal'      then "Разделяю #{title} на вокал и минус — скоро пришлю 2 дорожки"
    when 'split_stem'          then "Раскладываю #{title} на все дорожки (до 12) — скоро пришлю"
    else                            "Вытаскиваю из #{title} дорожку #{stem_name} — скоро пришлю"
    end
  }
)
