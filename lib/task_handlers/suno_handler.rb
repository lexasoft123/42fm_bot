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
      LOGGER.debug "SunoTaskHandler[#{task.id}]: parsing request '#{p['request']}'"

      parsed = parse_request(p['request'])
      p.merge!(parsed)
      p['parsed'] = true
      task.update!(params: p.to_json)

      LOGGER.debug "SunoTaskHandler[#{task.id}]: parsed → genre=#{p['genre']}, artist=#{p['artist']}, topic=#{p['topic']}, tags=#{p['tags']}"
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

      LOGGER.debug "SunoTaskHandler[#{task.id}]: composing lyrics for '#{subject}' (#{genre}#{artist.empty? ? '' : ", artist: #{artist}"})"

      lyrics = GptMaster.new([{ role: 'user', content: prompt }]).call
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

    LOGGER.debug "SunoTaskHandler[#{task.id}]: tags='#{tags}' generic=#{generic_tags} needs_enrichment=#{needs_enrichment}"

    if needs_enrichment
      tags = resolve_tags(genre, artist, title)
      p['tags'] = tags
    end

    tags = SunoClient.resolve_genre(genre) || 'rock' if tags.empty?

    suno_task_id = SunoClient.new.submit(title: title, lyrics: p['lyrics'], tags: tags)
    LOGGER.debug "SunoTaskHandler[#{task.id}]: submitted #{suno_task_id} with tags '#{tags}'"

    task.update!(external_id: suno_task_id,
                 params: p.merge('title' => title).to_json)
    :pending
  end

  def poll_and_deliver(task, api)
    result = SunoClient.new.poll_once(task.external_id)

    LOGGER.debug "SunoTaskHandler[#{task.id}]: polling #{task.external_id} (attempt #{task.attempts + 1}/#{task.max_attempts}) → #{result.inspect}"

    case result
    when :pending
      :pending
    when :failed
      LOGGER.error "SunoTaskHandler[#{task.id}]: Suno generation failed for #{task.external_id}"
      task.mark_failed!('suno_failed')
      api.sendMessage(chat_id: task.chat_id, text: "Не удалось сгенерировать песню") rescue nil
      :failed
    when Hash
      LOGGER.info "SunoTaskHandler[#{task.id}]: complete! #{result[:audio_url]} (#{result[:duration]}s)"
      task.mark_done!(result)
      title = task.params_hash['title'] || 'Песня от 42FM'
      send_audio(api, task.chat_id, result[:audio_url], title, task.params_hash)
      :done
    end
  end

  def resolve_tags(genre, artist, title = '')
    # Try predefined genres first — only if no artist to describe
    known = SunoClient.resolve_genre(genre)
    return known if known && artist.empty? && title.empty?

    prompt = TAGS_PROMPT % {
      genre: genre.empty? ? 'рок' : genre,
      artist: artist.empty? ? 'не указан' : artist,
      title: title.empty? ? 'не указано' : title
    }
    response = GptMaster.new([{ role: 'user', content: prompt }], setting: 'agent').call
    tags = response.to_s.strip.gsub(/^["']|["']$/, '')
    LOGGER.debug "SunoTaskHandler: resolved tags → '#{tags}'"
    tags.empty? ? (known || 'rock') : tags
  rescue => e
    LOGGER.warn "SunoTaskHandler resolve_tags failed: #{e.message}"
    known || 'rock'
  end

  def parse_request(request)
    return { 'genre' => 'рок', 'artist' => '', 'topic' => '', 'tags' => 'rock, energetic' } if request.empty?

    genres_list = SunoClient::GENRES.keys.join(', ')
    prompt = PARSE_PROMPT % { genres: genres_list, request: request }

    response = GptMaster.new([{ role: 'user', content: prompt }], setting: 'agent').call
    json = response[/\{.*\}/m]
    parsed = JSON.parse(json)

    {
      'genre'  => parsed['genre'].to_s.strip.downcase.presence || 'рок',
      'artist' => parsed['artist'].to_s.strip,
      'topic'  => parsed['topic'].to_s.strip,
      'tags'   => parsed['tags'].to_s.strip
    }
  rescue => e
    LOGGER.warn "SunoTaskHandler parse_request failed: #{e.message}, falling back to raw request"
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
      Сочини короткую песню (2 куплета + припев) на тему: "{REQUEST}"
      Жанр: {GENRE}
      {ARTIST}
      Верни ТОЛЬКО текст с тегами [Verse], [Chorus], [Outro]. Без пояснений.
    PROMPT
  end

  def send_audio(api, chat_id, url, title, params)
    caption = "🎵 *#{title}*"
    caption += "\n🎸 #{params['genre']}" if params['genre']
    caption += " (#{params['artist']})" if params['artist'].to_s != ''
    caption += "\n\n#{params['lyrics']}" if params['lyrics']
    caption = caption[0..1020] + "..." if caption.length > 1024

    retries = 0
    begin
      api.sendAudio(
        chat_id: chat_id, audio: url,
        title: title, performer: '42FM Bot',
        caption: caption, parse_mode: 'Markdown'
      )
    rescue OpenSSL::SSL::SSLError, Faraday::ConnectionFailed => e
      retries += 1
      LOGGER.warn "SunoTaskHandler sendAudio retry #{retries}: #{e.class}"
      sleep 3 and retry if retries <= 3
    end
  end
end

TaskRunner.register('suno_generate', SunoTaskHandler)
