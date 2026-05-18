require_relative 'agent_event_emitter'
require_relative '../media_download'

class SunoTaskHandler
  include ChatContext
  include AgentEventEmitter
  include MediaDownload

  MAX_PROMPT_FAILURES = 3
  MAX_SUBMIT_FAILURES = 3

  def call(task, api)
    if task.external_id.nil?
      compose_and_submit(task, api)
    else
      poll_and_deliver(task, api)
    end
  end

  private

  def compose_and_submit(task, api)
    case task.task_type
    when 'suno_add_vocals'  then submit_add_vocals(task, api)
    when 'suno_cover_audio' then submit_cover_audio(task, api)
    else                          compose_and_submit_generate(task, api)
    end
  end

  def submit_add_vocals(task, api)
    p = task.params_hash
    begin
      suno_task_id = SunoClient.new.add_vocals(
        upload_url:    p['upload_url'],
        prompt:        p['theme'].to_s,
        title:         p['title'],
        style:         p['style'].to_s,
        negative_tags: p['negative_tags'].to_s,
        vocal_gender:  p['vocal_gender']
      )
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit add_vocals: #{e.message}", raise_on_retry: e)
    end
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted add_vocals #{suno_task_id}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: suno_task_id) }
    :pending
  end

  # Resolve `lyrics`/`topic` from the agent tool into Suno's
  # `customMode` + `prompt` pair. Suno requires a non-empty prompt in BOTH
  # modes (and has no "preserve original" mode), so the fallback chain ends
  # at `title` to guarantee something sensible to send. See
  # docs.sunoapi.org/suno-api/upload-and-cover-audio for the contract.
  def submit_cover_audio(task, api)
    p = task.params_hash
    custom_mode, prompt = resolve_cover_prompt(p)
    begin
      suno_task_id = SunoClient.new.cover_audio(
        upload_url:    p['upload_url'],
        style:         p['style'].to_s,
        title:         p['title'],
        prompt:        prompt,
        custom_mode:   custom_mode,
        negative_tags: p['negative_tags'].to_s,
        vocal_gender:  p['vocal_gender'],
        instrumental:  p['instrumental'] == true
      )
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit cover_audio: #{e.message}", raise_on_retry: e)
    end
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted cover_audio #{suno_task_id} mode=#{custom_mode ? 'custom' : 'auto'}"
    ActiveRecord::Base.connection_pool.with_connection { task.update!(external_id: suno_task_id) }
    :pending
  end

  # Returns [custom_mode, prompt] for Suno's upload-cover endpoint.
  #
  # Suno requires `prompt` to be non-empty in BOTH modes (≤5000 chars in
  # custom mode on V5, ≤500 chars in auto mode), and has no "preserve
  # original lyrics" option. The fallback chain guarantees a sensible
  # non-empty prompt regardless of what the agent supplied.
  #
  # Resolution order:
  #   instrumental=true → auto mode + title-as-prompt (lyrics/topic ignored
  #     per the tool description; prompt isn't sung under instrumental but
  #     Suno still needs a value).
  #   lyrics non-empty  → custom mode, prompt=lyrics (truncated to 5000).
  #   topic non-empty   → auto mode, prompt=topic (truncated to 500).
  #   legacy `prompt`   → auto mode, treated as topic. Triggered only when
  #     neither `lyrics` nor `topic` keys are present in params (i.e.
  #     in-flight task created against the pre-split schema). Post-split
  #     tasks always serialise both keys, so this branch is dead for fresh
  #     tasks but keeps an at-deploy in-flight task afloat.
  #   nothing usable    → auto mode + title fallback.
  def resolve_cover_prompt(p)
    title = p['title'].to_s.strip
    title_fallback = (title.empty? ? 'Кавер' : title).slice(0, 500)

    return [false, title_fallback] if p['instrumental'] == true

    lyrics = p['lyrics'].to_s.strip
    topic  = p['topic'].to_s.strip
    legacy = (!p.key?('lyrics') && !p.key?('topic')) ? p['prompt'].to_s.strip : ''
    return [true,  lyrics.slice(0, 5000)] unless lyrics.empty?
    return [false, topic.slice(0, 500)]   unless topic.empty?
    return [false, legacy.slice(0, 500)]  unless legacy.empty?
    [false, title_fallback]
  end

  TAGS_PROMPT = <<~PROMPT.freeze
    Опиши музыкальный стиль для Suno AI — через запятую на английском В ПОРЯДКЕ:
    1) жанр и поджанр (например "industrial metal, Neue Deutsche Härte"),
    2) настроение/эмоция (aggressive, melancholic, dreamy, anthemic, dark, powerful),
    3) инструменты (heavy distorted riffs, jangly guitar, analog synth, martial drums),
    4) характер вокала (deep German male vocals, raspy, falsetto, choir, baritone),
    5) описание сведения — необязательно, добавляй если уместно жанру (polished production, lo-fi, wet reverb, dry mix, punchy drums, radio-ready, wide stereo, 80s tape hiss).
    НЕ пиши негативные теги ("no X", "without Y") внутри этой строки — у Suno для них отдельное поле, оно заполняется параметром negative_tags в инструменте, а не здесь.
    ВАЖНО: НИКОГДА не включай имена исполнителей или групп в теги — Suno блокирует имена артистов!
    Когда копируешь стиль конкретного исполнителя — описывай его ОТЛИЧИТЕЛЬНЫЕ черты (вокальная манера, тембр, фразировка, темп, фишки продакшна), а не общие черты жанра. Избегай слишком широких genre-cluster ярлыков (например "Neue Deutsche Härte" описывает целый кластер: OOMPH, Megaherz, Eisbrecher, Stahlmann — у Suno этот тег тянет к среднему по кластеру, не к конкретному артисту). Используй более узкие/специфичные термины ("Tanz-Metall", "industrial cabaret", "Wagnerian metal touches") и упор на distinctive descriptors (вокал, тембр, тембр баса, пейс).
    Например для Rammstein: "industrial metal, Tanz-Metall, slow heavy doom-paced stomp, mid-tempo grinding rhythm, heavy distorted thick palm-muted downtuned riffs, prominent driving bass, thunderous hammering drums, cinematic orchestral synth pads, deep low clean baritone German vocals, operatic delivery, rolled R consonants, declamatory spoken-word verses, dramatic vibrato, glossy polished production"
    Например для Цоя: "russian post-punk, 80s Soviet new wave, melancholic deadpan baritone, monotone delivery, jangly clean guitar, minor key, steady simple drums, anthemic refrain, restrained sparse arrangement"
    Если даны текст/название песни — определи по ним подходящий стиль.
    Верни ТОЛЬКО теги через запятую, без пояснений. Минимум 8 тегов, целься в 180-280 символов суммарно (для эмуляции конкретного артиста лучше ближе к верхней границе — Suno нужно больше distinctive descriptors, чтобы не скатиться к жанровому среднему). Без имён артистов!

    Жанр: %{genre}
    Исполнитель (для определения стиля, НЕ включать имя в теги): %{artist}
    Название: %{title}
  PROMPT

  def compose_and_submit_generate(task, api)
    p = task.params_hash

    # Step 1: Compose lyrics with GPT (Sonnet 4.6) when not user-supplied.
    unless p['lyrics']
      topic = p['topic'].to_s
      genre = p['genre'].to_s
      artist = p['artist'].to_s
      subject = topic.empty? ? genre : topic

      context = get_chat_context(task.chat_id)
      knowledge = get_relevant_knowledge(subject, task.chat_id)

      artist_line = artist.empty? ? '' : "Стиль исполнения: как #{artist}. Подражай манере, лексике и темам этого исполнителя."

      prompt = lyrics_prompt
        .gsub('{REQUEST}', subject)
        .gsub('{GENRE}', genre)
        .gsub('{ARTIST}', artist_line)
        .gsub('{CONTEXT}', context)
        .gsub('{KNOWLEDGE}', knowledge)

      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: composing lyrics for '#{subject}' (#{genre}#{artist.empty? ? '' : ", artist: #{artist}"})"

      begin
        lyrics = GptMaster.new([{ role: 'user', content: prompt }],
                               setting: 'lyrics',
                               chat_id: task.chat_id, user_uid: p['user_uid'],
                               purpose: 'suno_lyrics').call
        raise "GPT lyrics failed" unless lyrics && lyrics != 'жпт не жпт'
        p['lyrics'] = lyrics
      rescue => e
        return bail_or_retry(task, api, p, 'prompt_failures', MAX_PROMPT_FAILURES, "lyrics: #{e.message}", raise_on_retry: e)
      end
    end

    # Step 2: Resolve tags for Suno — always via the dedicated LLM call.
    # Tag enrichment is single-sourced here (TAGS_PROMPT + Sonnet 4.6) rather
    # than depending on whatever the agent inlined; the agent's compose_song
    # tool no longer takes a `tags` param. See docs/architecture.md.
    artist = p['artist'].to_s.strip
    genre  = p['genre'].to_s.strip
    title  = p['title'] || build_title(p)
    tags   = resolve_tags(genre, artist, title, chat_id: task.chat_id, user_uid: p['user_uid'])
    p['tags'] = tags
    tags = SunoClient.resolve_genre(genre) || 'rock' if tags.empty?

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: tags='#{tags}'"

    begin
      suno_task_id = SunoClient.new.submit(title: title, lyrics: p['lyrics'], tags: tags,
                                           negative_tags: p['negative_tags'].to_s)
    rescue => e
      return bail_or_retry(task, api, p, 'submit_failures', MAX_SUBMIT_FAILURES, "submit: #{e.message}", raise_on_retry: e)
    end
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{suno_task_id} with tags '#{tags}'"

    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(external_id: suno_task_id, params: p.merge('title' => title).to_json)
    end
    :pending
  end

  # Increment a step-failure counter; if cap reached, fail+notify; otherwise re-raise so
  # TaskRunner retries on the next poll cycle.
  def bail_or_retry(task, api, params, counter, max, reason, raise_on_retry:)
    params[counter] = (params[counter] || 0) + 1
    ActiveRecord::Base.connection_pool.with_connection { task.update!(params: params.to_json) }
    if params[counter] >= max
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]} (max #{max}), giving up: #{reason}"
      # Pass the underlying exception/reason as error_detail so the agent
      # event summary distinguishes "Suno API rejected with 4xx" vs
      # "transient network failure" vs "submit_failed_after_retries".
      mark_failed_and_notify(task, api, "#{counter}_after_retries", error_detail: reason.to_s)
      return :failed
    end
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: #{counter}=#{params[counter]}/#{max} — will retry: #{reason}"
    raise raise_on_retry
  end

  MAX_GENERATION_RETRIES = 3

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_once(task.external_id)

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :retry
      p = task.params_hash
      retries = (p['generation_retries'] || 0) + 1
      p['generation_retries'] = retries
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Suno transient failure for #{task.external_id} (retry #{retries}/#{MAX_GENERATION_RETRIES})"
      if retries <= MAX_GENERATION_RETRIES
        # Clear external_id so next handler call re-submits with cached lyrics/tags.
        ActiveRecord::Base.connection_pool.with_connection do
          task.update!(external_id: nil, params: p.to_json)
        end
        return :pending
      end
      mark_failed_and_notify(task, api, 'suno_failed_after_retries')
      :failed
    when :failed
      mark_failed_and_notify(task, api, 'suno_failed')
      :failed
    when Hash
      # Failure-with-detail from poll_once (see SunoClient#format_suno_error).
      # The detail makes it into the agent_event summary so the agent knows
      # WHY (copyright, content flagged, etc.) rather than just generic
      # "suno_failed", and can pick a meaningful next move.
      mark_failed_and_notify(task, api, 'suno_failed', error_detail: result[:error])
      :failed
    when Array
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result.size} clips"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      p = task.params_hash
      title = p['title'] || 'Песня от 42FM'
      maybe_chain_cover_art(task, p, title)
      send_audio(api, task.chat_id, result, title, p, bg_task_external_id: task.external_id)
      if (p['generation_retries'] || 0) >= 1
        emit_agent_event(task, 'song_succeeded_after_retries',
          summary: "Песня '#{title}' получилась с #{p['generation_retries']}-й попытки.")
      end
      :done
    end
  end

  # If the originating tool call set with_cover_art=true, enqueue a chained
  # suno_cover_art task pointing at this song's external_id.
  #
  # The chain is **not** subject to the 'suno' rate-limit bucket: the user
  # paid the bucket cost when they asked for the song-with-cover-art, and
  # the chain is bounded (one cover-art per song). Re-charging the bucket
  # at chain time would silently drop the cover-art under default settings
  # (max=1, window=20min) because the parent suno_generate row is still
  # inside the window. The user was already promised the cover-art —
  # delivering it isn't a separate user-initiated request.
  #
  # Dedup against re-entry / process restart via json_extract on
  # source_task_id (sqlite-only; revisit if we migrate to Postgres).
  def maybe_chain_cover_art(task, params, title)
    return unless params['with_cover_art'] == true
    return unless task.external_id

    already = ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.where(chat_id: task.chat_id, task_type: 'suno_cover_art')
                    .where("json_extract(params, '$.source_task_id') = ?", task.external_id)
                    .exists?
    end
    return if already

    ActiveRecord::Base.connection_pool.with_connection do
      BackgroundTask.create!(
        task_type: 'suno_cover_art',
        chat_id: task.chat_id,
        max_attempts: 60,
        params: { source_task_id: task.external_id,
                  source_title:   title,
                  user_uid:       params['user_uid'] }.to_json
      )
    end
    LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: chained suno_cover_art for #{task.external_id}"
  rescue => e
    LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: chain cover_art failed: #{e.class}: #{e.message}"
  end

  # `error_detail` is the human-readable Suno error string (e.g. "Suno [413]:
  # Uploaded audio matches existing work of art") from
  # SunoClient#format_suno_error. When present it gets appended to the
  # summary that reaches the agent via agent_event — lets the agent
  # distinguish copyright reject vs content flag vs worker hiccup vs
  # rate-limit, and pick a meaningful next move (rephrase, suggest
  # different source, retry later, etc.) rather than blind-retry.
  def mark_failed_and_notify(task, api, reason, error_detail: nil)
    LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Suno generation #{reason} for #{task.external_id}#{error_detail ? " (#{error_detail})" : ''}"
    ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!(reason) }
    text = "Не удалось сгенерировать песню"
    begin
      resp = api.sendMessage(chat_id: task.chat_id, text: text)
      Message.persist_bot_reply(chat_id: task.chat_id, body: text, response: resp)
    rescue => e
      LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
    end
    p = task.params_hash
    event_type = reason.to_s.include?('after_retries') ? 'song_failed_after_retries' : 'song_failed'
    summary = "Тема: #{(p['topic'] || p['request']).to_s[0..150]} | Жанр: #{p['genre']} | Артист: #{p['artist']} | Причина: #{reason}"
    summary += " | #{error_detail}" if error_detail && !error_detail.to_s.empty?
    emit_agent_event(task, event_type, summary: summary)
  end

  def resolve_tags(genre, artist, title = '', chat_id: nil, user_uid: nil)
    # Try predefined genres first — only if no artist to describe
    known = SunoClient.resolve_genre(genre)
    return known if known && artist.empty? && title.empty?

    prompt = TAGS_PROMPT % {
      genre: genre.empty? ? 'рок' : genre,
      artist: artist.empty? ? 'не указан' : artist,
      title: title.empty? ? 'не указано' : title
    }
    response = GptMaster.new([{ role: 'user', content: prompt }], setting: 'lyrics',
                             chat_id: chat_id, user_uid: user_uid, purpose: 'suno_tags').call
    tags = response.to_s.strip.gsub(/^["']|["']$/, '')
    LOGGER.debug "[chat=#{chat_id}] #{self.class.name}: resolved tags → '#{tags}'"
    tags.empty? ? (known || 'rock') : tags
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} resolve_tags failed: #{e.message}"
    known || 'rock'
  end

  def build_title(p)
    parts = ['42FM']
    parts << p['artist'] if p['artist'].to_s != ''
    parts << p['topic'] if p['topic'].to_s != ''
    parts << p['genre'] if parts.size == 1
    parts.join(' - ').slice(0, 80)
  end

  def lyrics_prompt
    Settings.suno['lyrics_prompt'] || <<~PROMPT
      Сочини песню на тему: "{REQUEST}"
      Жанр: {GENRE}
      {ARTIST}
      Выбери структуру, подходящую жанру (verse/chorus для рока, verse/hook для рэпа, AAB для блюза, четверостишия для частушек и т.д.).
      Верни ТОЛЬКО текст с тегами секций. Без пояснений.
    PROMPT
  end

  def send_audio(api, chat_id, clips, title, params, bg_task_external_id: nil)
    artist = params['artist'].to_s.strip
    performer = artist.empty? ? '42FM Bot' : artist

    caption = "🎵 *#{title}*"
    caption += "\n🎸 #{params['genre']}" if params['genre']
    caption += " (#{artist})" if artist != ''

    temp_files = []
    media = []

    clips.each_with_index do |clip, i|
      filename = build_filename(performer, clip[:title] || title, i + 1, clips.size)
      tmp = download_to_tempfile(clip[:audio_url], filename, chat_id: chat_id)
      next unless tmp

      temp_files << { file: tmp, name: filename }
      attach_key = "audio#{i}"
      entry = { type: 'audio', media: "attach://#{attach_key}",
                title: clip[:title] || title, performer: performer }
      entry[:caption] = caption if i == 0
      entry[:parse_mode] = 'Markdown' if i == 0
      media << entry
    end

    if media.empty?
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_audio: no clips downloaded — skipping send"
      return
    end

    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_audio: sendMediaGroup → #{media.size} clips (#{temp_files.sum { |tf| File.size(tf[:file].path) }} bytes total)"

    retries = 0
    result = begin
      send_params = { chat_id: chat_id, media: media.to_json }
      temp_files.each_with_index { |tf, i| send_params[:"audio#{i}"] = Faraday::UploadIO.new(tf[:file].path, 'audio/mpeg', tf[:name]) }
      api.sendMediaGroup(**send_params)
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} sendMediaGroup retry #{retries}: #{e.class}: #{e.message}"
      if retries <= 3
        sleep 3
        retry
      end
      LOGGER.error "[chat=#{chat_id}] #{self.class.name} sendMediaGroup gave up after #{retries} retries"
      nil
    ensure
      temp_files.each { |tf| tf[:file].close; tf[:file].unlink rescue nil }
    end

    messages = result.is_a?(Hash) ? result['result'] : result
    msg_id = messages&.first&.respond_to?(:message_id) ? messages.first.message_id : messages&.first&.dig('message_id')
    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_audio: sendMediaGroup ok, first_message_id=#{msg_id.inspect}"

    persist_bot_media_rows(chat_id, messages, title, params, bg_task_external_id: bg_task_external_id)

    lyrics = resolve_delivery_lyrics(params, clips)
    return if lyrics.empty?

    LOGGER.debug "[chat=#{chat_id}] #{self.class.name} send_audio: sending lyrics (#{lyrics.length} chars, reply_to=#{msg_id.inspect})"
    lyrics_resp = api.sendMessage(chat_id: chat_id, text: lyrics, reply_to_message_id: msg_id)
    persist_lyrics_row(chat_id, lyrics_resp, lyrics, msg_id)
    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_audio: lyrics sent"
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_audio failed: #{e.class}: #{e.message} (#{e.backtrace&.first})"
  end

  # compose_song stores the locally-composed lyrics in `params['lyrics']`
  # at submit time. add_vocals / cover_audio don't compose locally — Suno
  # generates lyrics server-side and returns them in each clip's `:lyrics`
  # field (extracted from the response's `prompt` by SunoClient#poll_once).
  # Without the fallback, those task types would silently skip the
  # follow-up text reply because `params['lyrics']` is nil for them.
  def resolve_delivery_lyrics(params, clips)
    from_params = params['lyrics'].to_s.strip
    return from_params unless from_params.empty?
    return '' unless clips.is_a?(Array) && clips.first
    clips.first[:lyrics].to_s.strip
  end

  # Save each clip from the media group as a bot Message row. Without these,
  # a user reply to the audio would point at a Telegram message_id we never
  # indexed, breaking reply_to-based context resolution.
  def persist_bot_media_rows(chat_id, messages, title, params, bg_task_external_id: nil)
    return unless messages.is_a?(Array)
    messages.each_with_index do |msg, i|
      mid = msg.respond_to?(:message_id) ? msg.message_id : msg['message_id']
      tid = msg.respond_to?(:message_thread_id) ? msg.message_thread_id : msg['message_thread_id']
      next unless mid
      body = "[песня: #{title}#{messages.size > 1 ? " (#{i + 1}/#{messages.size})" : ''}]"
      ActiveRecord::Base.connection_pool.with_connection do
        Message.create(role: 'bot', chat_id: chat_id, body: body, message_id: mid,
                       message_thread_id: tid, bg_task_external_id: bg_task_external_id)
      end
    end
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} persist_bot_media_rows failed: #{e.class}: #{e.message}"
  end

  def persist_lyrics_row(chat_id, resp, body, reply_to)
    mid = resp.respond_to?(:message_id) ? resp.message_id : resp.is_a?(Hash) ? (resp.dig('result', 'message_id') || resp['message_id']) : nil
    tid = resp.respond_to?(:message_thread_id) ? resp.message_thread_id : resp.is_a?(Hash) ? (resp.dig('result', 'message_thread_id') || resp['message_thread_id']) : nil
    return unless mid
    ActiveRecord::Base.connection_pool.with_connection do
      Message.create(role: 'bot', chat_id: chat_id, body: body, message_id: mid,
                     message_thread_id: tid, reply_to_message_id: reply_to)
    end
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} persist_lyrics_row failed: #{e.class}: #{e.message}"
  end

  def build_filename(performer, title, index, total)
    name = [performer, title].reject { |s| s.to_s.empty? }.join('_-_')
    name = name.gsub(/[\/\\:*?"<>|]/, '').gsub(/\s+/, '_')
    name += "_(#{index})" if total > 1
    "#{name}.mp3"
  end

end

TaskRunner.register('suno_generate', SunoTaskHandler)
TaskRunner.register('suno_add_vocals', SunoTaskHandler)
TaskRunner.register('suno_cover_audio', SunoTaskHandler)
