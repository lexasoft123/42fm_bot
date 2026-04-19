class SunoTaskHandler
  include ChatContext

  def call(task, api)
    if task.external_id.nil?
      compose_and_submit(task)
    else
      poll_and_deliver(task, api)
    end
  end

  private

  PARSE_PROMPT = <<~PROMPT.freeze
    Разбери запрос на генерацию песни. Извлеки жанр, исполнителя (если упоминается) и тему.
    Известные жанры (используй если подходит): %{genres}
    Если жанр не указан, используй "рок".
    Если упоминается конкретный исполнитель/группа (например "как Цой", "в стиле Коррозии Металла"), укажи его в artist.
    Для Suno tags: напиши через запятую на английском стиль музыки, настроение, инструменты, характер вокала. Минимум 8 тегов.
    ВАЖНО: НИКОГДА не включай имена исполнителей или групп в теги — Suno блокирует имена артистов!
    Вместо имени опиши характерное звучание исполнителя максимально подробно (жанр, поджанр, инструменты, вокал, настроение, эпоха).
    Например для Rammstein: "industrial metal, Neue Deutsche Härte, heavy distorted riffs, deep German male vocals, aggressive, martial drums, dark, powerful, stomping rhythm, electronic elements"
    Например для Цоя: "russian post-punk, new wave, melancholic baritone vocals, jangly guitar, 80s Soviet rock, anthemic, minor key"

    Верни ТОЛЬКО JSON без пояснений:
    {"genre": "жанр на русском", "artist": "исполнитель или пустая строка", "topic": "тема песни", "tags": "english tags for suno (WITHOUT artist names!)"}

    Запрос: "%{request}"
  PROMPT

  TAGS_PROMPT = <<~PROMPT.freeze
    Опиши музыкальный стиль для Suno AI — через запятую на английском: жанр, поджанр, инструменты, характер вокала, настроение, темп.
    ВАЖНО: НИКОГДА не включай имена исполнителей или групп в теги — Suno блокирует имена артистов!
    Вместо имени опиши характерное звучание максимально подробно.
    Например для Rammstein: "industrial metal, Neue Deutsche Härte, heavy distorted riffs, deep German male vocals, aggressive, martial drums, dark, powerful, stomping rhythm, electronic elements"
    Например для Цоя: "russian post-punk, new wave, melancholic baritone vocals, jangly guitar, 80s Soviet rock, anthemic, minor key"
    Если даны текст/название песни — определи по ним подходящий стиль.
    Верни ТОЛЬКО теги через запятую, без пояснений. Минимум 8 тегов. Без имён артистов!

    Жанр: %{genre}
    Исполнитель (для определения стиля, НЕ включать имя в теги): %{artist}
    Название: %{title}
  PROMPT

  def compose_and_submit(task)
    p = task.params_hash

    # Step 1: Parse freeform request with LLM (only for chat command path)
    if !p['parsed'] && p.key?('request') && !p['request'].to_s.empty?
      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: parsing request '#{p['request']}'"

      parsed = parse_request(p['request'], chat_id: task.chat_id, user_uid: p['user_uid'])
      p.merge!(parsed)
      p['parsed'] = true
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }

      LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: parsed → genre=#{p['genre']}, artist=#{p['artist']}, topic=#{p['topic']}, tags=#{p['tags']}"
    end

    # Step 2: Compose lyrics with GPT
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

      lyrics = GptMaster.new([{ role: 'user', content: prompt }],
                             chat_id: task.chat_id, user_uid: p['user_uid'],
                             purpose: 'suno_lyrics').call
      raise "GPT lyrics failed" unless lyrics && lyrics != 'жпт не жпт'
      p['lyrics'] = lyrics
    end

    # Step 3: Resolve tags for Suno
    tags = p['tags'].to_s.strip
    artist = p['artist'].to_s.strip
    genre = p['genre'].to_s.strip
    title = p['title'] || build_title(p)

    # Enrich tags with LLM when they look generic or don't reflect artist/title
    generic_tags = SunoClient::GENRES.values.include?(tags)
    needs_enrichment = tags.empty? ||
      generic_tags ||
      (artist != '' && !tags.downcase.include?(artist.downcase.split.first)) ||
      tags.split(',').size <= 3

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: tags='#{tags}' generic=#{generic_tags} needs_enrichment=#{needs_enrichment}"

    if needs_enrichment
      tags = resolve_tags(genre, artist, title, chat_id: task.chat_id, user_uid: p['user_uid'])
      p['tags'] = tags
    end

    tags = SunoClient.resolve_genre(genre) || 'rock' if tags.empty?

    begin
      suno_task_id = SunoClient.new.submit(title: title, lyrics: p['lyrics'], tags: tags)
    rescue => e
      p['submit_failures'] = (p['submit_failures'] || 0) + 1
      ActiveRecord::Base.connection_pool.with_connection { task.update!(params: p.to_json) }
      if p['submit_failures'] >= 3
        LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submit failed #{p['submit_failures']} times, giving up: #{e.message}"
        ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!("submit_failed: #{e.message}") }
        return :failed
      end
      raise
    end
    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: submitted #{suno_task_id} with tags '#{tags}'"

    ActiveRecord::Base.connection_pool.with_connection do
      task.update!(external_id: suno_task_id, params: p.merge('title' => title).to_json)
    end
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_once(task.external_id)

    LOGGER.debug "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :failed
      LOGGER.error "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: Suno generation failed for #{task.external_id}"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_failed!('suno_failed') }
      begin
        api.sendMessage(chat_id: task.chat_id, text: "Не удалось сгенерировать песню")
      rescue => e
        LOGGER.warn "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: failed to notify chat: #{e.class}: #{e.message}"
      end
      :failed
    when Array
      LOGGER.info "[chat=#{task.chat_id}] #{self.class.name}[#{task.id}]: complete! #{result.size} clips"
      ActiveRecord::Base.connection_pool.with_connection { task.mark_done!(result) }
      title = task.params_hash['title'] || 'Песня от 42FM'
      send_audio(api, task.chat_id, result, title, task.params_hash)
      :done
    end
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
    response = GptMaster.new([{ role: 'user', content: prompt }], setting: 'agent',
                             chat_id: chat_id, user_uid: user_uid, purpose: 'suno_tags').call
    tags = response.to_s.strip.gsub(/^["']|["']$/, '')
    LOGGER.debug "[chat=#{chat_id}] #{self.class.name}: resolved tags → '#{tags}'"
    tags.empty? ? (known || 'rock') : tags
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} resolve_tags failed: #{e.message}"
    known || 'rock'
  end

  def parse_request(request, chat_id: nil, user_uid: nil)
    return { 'genre' => 'рок', 'artist' => '', 'topic' => '', 'tags' => 'rock, energetic' } if request.empty?

    genres_list = SunoClient::GENRES.keys.join(', ')
    prompt = PARSE_PROMPT % { genres: genres_list, request: request }

    response = GptMaster.new([{ role: 'user', content: prompt }], setting: 'agent',
                             chat_id: chat_id, user_uid: user_uid, purpose: 'suno_parse').call
    json = response[/\{.*\}/m]
    parsed = JSON.parse(json)

    {
      'genre'  => parsed['genre'].to_s.strip.downcase.presence || 'рок',
      'artist' => parsed['artist'].to_s.strip,
      'topic'  => parsed['topic'].to_s.strip,
      'tags'   => parsed['tags'].to_s.strip
    }
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} parse_request failed: #{e.message}, falling back to raw request"
    { 'genre' => 'рок', 'artist' => '', 'topic' => request, 'tags' => '' }
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

  def send_audio(api, chat_id, clips, title, params)
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

    persist_bot_media_rows(chat_id, messages, title, params)

    return unless params['lyrics']

    LOGGER.debug "[chat=#{chat_id}] #{self.class.name} send_audio: sending lyrics (#{params['lyrics'].to_s.length} chars, reply_to=#{msg_id.inspect})"
    lyrics_resp = api.sendMessage(chat_id: chat_id, text: params['lyrics'], reply_to_message_id: msg_id)
    persist_lyrics_row(chat_id, lyrics_resp, params['lyrics'], msg_id)
    LOGGER.info "[chat=#{chat_id}] #{self.class.name} send_audio: lyrics sent"
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} send_audio failed: #{e.class}: #{e.message} (#{e.backtrace&.first})"
  end

  # Save each clip from the media group as a bot Message row. Without these,
  # a user reply to the audio would point at a Telegram message_id we never
  # indexed, breaking reply_to-based context resolution.
  def persist_bot_media_rows(chat_id, messages, title, params)
    return unless messages.is_a?(Array)
    messages.each_with_index do |msg, i|
      mid = msg.respond_to?(:message_id) ? msg.message_id : msg['message_id']
      tid = msg.respond_to?(:message_thread_id) ? msg.message_thread_id : msg['message_thread_id']
      next unless mid
      body = "[песня: #{title}#{messages.size > 1 ? " (#{i + 1}/#{messages.size})" : ''}]"
      ActiveRecord::Base.connection_pool.with_connection do
        Message.create(role: 'bot', chat_id: chat_id, body: body, message_id: mid, message_thread_id: tid)
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

  def download_to_tempfile(url, filename, chat_id: nil)
    response = HTTParty.get(url, timeout: 60)
    unless response.code == 200
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} download_to_tempfile: HTTP #{response.code} for #{url}"
      return nil
    end

    tmp = Tempfile.new(['suno_', '.mp3'], '/tmp')
    tmp.binmode
    tmp.write(response.body)
    tmp.rewind
    LOGGER.debug "[chat=#{chat_id}] #{self.class.name} download_to_tempfile: #{response.body.bytesize} bytes → #{filename}"
    tmp
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} download_to_tempfile failed: #{e.class}: #{e.message}"
    nil
  end
end

TaskRunner.register('suno_generate', SunoTaskHandler)
