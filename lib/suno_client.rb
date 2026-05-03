require 'httparty'

class SunoClient
  POLL_INTERVAL = 8
  POLL_TIMEOUT  = 180

  GENRES = {
    # Metal
    'хеви метал'  => 'heavy metal, distorted guitar, powerful drums, headbanging',
    'блэк метал'  => 'black metal, blast beats, shrieking vocals, tremolo picking',
    'дэт метал'   => 'death metal, growling vocals, heavy riffs, double bass',
    'трэш метал'  => 'thrash metal, fast riffs, aggressive drums, moshing',
    'пауэр метал' => 'power metal, epic vocals, fast guitar, symphonic, soaring melody',
    'ню метал'    => 'nu metal, downtuned guitars, turntables, aggressive rap-rock',
    'метал'       => 'heavy metal, distorted guitar, powerful drums',
    'металкор'    => 'metalcore, breakdowns, screaming vocals, heavy riffs, melodic chorus',
    # Rock
    'панк'        => 'punk rock, fast tempo, aggressive, power chords, rebellious',
    'гранж'       => 'grunge, distorted guitar, angst, raw vocals, Seattle sound',
    'инди'        => 'indie rock, jangly guitars, lo-fi, dreamy, alternative',
    'хард рок'    => 'hard rock, heavy guitar riffs, powerful vocals, classic rock',
    'рок'         => 'rock, electric guitar, drums, energetic',
    # Electronic
    'техно'       => 'techno, electronic, synthesizer, 4-on-the-floor, dark, hypnotic',
    'транс'       => 'trance, euphoric, synth pads, uplifting melody, electronic',
    'драм энд бейс' => 'drum and bass, fast breakbeats, deep bass, electronic',
    'дабстеп'     => 'dubstep, heavy bass drops, wobble, electronic, aggressive',
    'электро'     => 'electronic, synth, EDM, dance, pulsating beats',
    'хаус'        => 'house music, four-on-the-floor, groovy, dance, electronic',
    # Hip-hop / R&B
    'рэп'         => 'rap, hip-hop, trap beats, rhythmic flow, 808 bass',
    'хип хоп'     => 'hip-hop, boom bap, sampled beats, turntables, lyrical',
    'трэп'        => 'trap, 808 bass, hi-hats, dark, atmospheric',
    'рнб'         => 'r&b, smooth vocals, soul, groove, romantic',
    # Classic / Jazz / Soul
    'блюз'        => 'blues, blues guitar, soulful, 12-bar blues, harmonica',
    'джаз'        => 'jazz, saxophone, piano, swing, improvisation, smooth',
    'соул'        => 'soul, emotional vocals, gospel, warm, Motown',
    'фанк'        => 'funk, slap bass, groove, rhythmic guitar, brass section',
    'регги'       => 'reggae, offbeat rhythm, bass heavy, chill, island vibes',
    'кантри'      => 'country, acoustic guitar, banjo, fiddle, Nashville, storytelling',
    'фолк'        => 'folk, acoustic guitar, storytelling, warm vocals, traditional',
    'классика'    => 'classical, orchestral, strings, piano, symphonic, epic',
    # Pop / Other
    'поп'         => 'pop, catchy melody, upbeat, radio-friendly, polished production',
    'диско'       => 'disco, groovy, funky bassline, strings, dance, 70s',
    'бардовская'  => 'russian bard, acoustic guitar, poetic, heartfelt, campfire',
    'шансон'      => 'russian chanson, acoustic guitar, emotional, storytelling, prison folk',
    'частушки'    => 'russian chastushki, fast accordion, folk, humorous, upbeat, balalaika',
    'ска'         => 'ska, upbeat, brass, offbeat guitar, energetic, danceable',
    'лоу фай'    => 'lo-fi, chill beats, relaxing, vinyl crackle, jazzy, mellow',
    'фонк'       => 'phonk, dark trap, Memphis rap, cowbell, aggressive bass, drift',
    'хардкор'    => 'hardcore, fast tempo, aggressive, distorted, intense, breakbeat',
    'хеппи хардкор' => 'happy hardcore, fast tempo, euphoric, rave, uplifting synth, 170bpm',
    'синтвейв'   => 'synthwave, retro 80s, analog synth, neon, nostalgic, driving',
    'постпанк'   => 'post-punk, dark, angular guitar, bass-driven, cold wave, new wave',
    'нойз'       => 'noise rock, abrasive, feedback, distortion, chaotic, experimental',
    'эмо'        => 'emo, emotional vocals, melodic punk, confessional, dynamic',
    'госпел'     => 'gospel, choir, soulful, uplifting, spiritual, powerful vocals',
    'латино'     => 'latin, reggaeton, tropical, percussive, danceable, rhythmic',
    'свинг'      => 'swing, big band, brass, jazz, upbeat, 1940s, danceable',
  }.freeze

  def initialize
    @base_url = Settings.suno['api_url']
    @api_key  = Settings.suno['api_key']
    @model    = Settings.suno['model'] || 'V4'
  end

  # Submit song generation request. Returns task_id string.
  def submit(title:, lyrics:, tags:, instrumental: false)
    post_for_task_id('/api/v1/generate',
      customMode: true, prompt: lyrics, style: tags, title: title,
      model: @model, instrumental: instrumental,
      callBackUrl: 'https://example.com/noop')
  end

  # Submit add-vocals request: layer AI vocals over a user-provided audio URL.
  # Returns one clip on success. task_id polled via /record-info like submit.
  # Per https://docs.sunoapi.org/suno-api/add-vocals the required fields are
  # uploadUrl/prompt/title/style/negativeTags/callBackUrl — customMode and
  # instrumental are NOT applicable (this endpoint always layers vocals over
  # the input, no opt-out), so we omit them deliberately.
  def add_vocals(upload_url:, prompt:, title:, style:, negative_tags: '', vocal_gender: nil)
    body = { uploadUrl: upload_url, prompt: prompt, title: title, style: style,
             negativeTags: negative_tags, model: @model,
             callBackUrl: 'https://example.com/noop' }
    body[:vocalGender] = vocal_gender if vocal_gender
    post_for_task_id('/api/v1/generate/add-vocals', **body)
  end

  # Submit upload-cover request: musical reinterpretation of a user-provided
  # audio URL in a new style. Returns 2 clips on success.
  #
  # Two modes (per docs.sunoapi.org/suno-api/upload-and-cover-audio):
  # - custom_mode: true  → `prompt` is sung verbatim as lyrics (≤5000 chars on V5).
  # - custom_mode: false → `prompt` is a "core idea"; Suno auto-generates fresh
  #   lyrics from it (≤500 chars). Suno does NOT preserve the source mp3's
  #   original lyrics in either mode — that is not a feature of this endpoint.
  #
  # `instrumental: true` skips vocals entirely; `prompt` then describes mood/
  # instrumentation only (no vocals to sing).
  def cover_audio(upload_url:, style:, title:, prompt:, custom_mode:,
                  negative_tags: '', vocal_gender: nil, instrumental: false)
    body = { uploadUrl: upload_url, customMode: custom_mode, instrumental: instrumental,
             style: style, title: title, prompt: prompt,
             negativeTags: negative_tags, model: @model,
             callBackUrl: 'https://example.com/noop' }
    body[:vocalGender] = vocal_gender if vocal_gender && !instrumental
    post_for_task_id('/api/v1/generate/upload-cover', **body)
  end

  # Submit cover-art request: generate 2 album-art images for an existing Suno
  # song task. Polled via /record-info like everything else.
  def cover_art(suno_task_id:)
    post_for_task_id('/api/v1/suno/cover/generate',
      taskId: suno_task_id, callBackUrl: 'https://example.com/noop')
  end

  # Submit WAV-conversion request for one specific clip of an existing Suno
  # song task. Both `taskId` (the source song's Suno taskId) and `audioId`
  # (the per-clip id from response.sunoData[].id) are required.
  def convert_to_wav(task_id:, audio_id:)
    post_for_task_id('/api/v1/wav/generate',
      taskId: task_id, audioId: audio_id, callBackUrl: 'https://example.com/noop')
  end

  # Poll once for WAV conversion. Returns :pending, :failed, :retry, or
  # { wav_url: '...' }. Response shape:
  #
  #   { data: { successFlag: 'PENDING' | 'SUCCESS' | 'CREATE_TASK_FAILED'
  #             | 'GENERATE_WAV_FAILED' | 'CALLBACK_EXCEPTION',
  #             response: { audioWavUrl: '...' },
  #             errorCode, errorMessage } }
  def poll_wav_once(task_id)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.get("#{@base_url}/api/v1/wav/record-info",
      query: { taskId: task_id }, headers: headers, timeout: 30)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    return :pending unless resp.code == 200
    data = resp.parsed_response['data']
    return :pending unless data
    LOGGER.debug "#{self.class.name}#poll_wav_once took=#{took_ms}ms successFlag=#{data['successFlag'].inspect}"

    case data['successFlag']
    when 'SUCCESS'
      url = data.dig('response', 'audioWavUrl')
      url.to_s.empty? ? :retry : { wav_url: url }
    when 'CREATE_TASK_FAILED', 'GENERATE_WAV_FAILED', 'CALLBACK_EXCEPTION'
      err_code = data['errorCode']
      err_msg  = data['errorMessage'] || data['successFlag']
      LOGGER.warn "#{self.class.name}#poll_wav_once Suno error: code=#{err_code} msg=#{err_msg.inspect}"
      { failed: true, error: format_suno_error(err_code, err_msg) }
    else
      :pending
    end
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{self.class.name} poll_wav_once: #{e.class}: #{e.message}"
    :pending
  end

  # Helper: fetch the per-clip `id` array for a completed Suno song task.
  # Used by the WAV-convert handler — `convert_to_wav` requires `audioId`,
  # but we don't currently persist clip ids when a song completes
  # (`SunoClient#poll_once` strips them). Re-fetching `record-info` is a
  # cheap GET; cleaner than retrofitting persistence for old rows.
  def fetch_audio_ids(task_id)
    resp = HTTParty.get("#{@base_url}/api/v1/generate/record-info",
      query: { taskId: task_id }, headers: headers, timeout: 30)
    return [] unless resp.code == 200
    songs = resp.parsed_response.dig('data', 'response', 'sunoData') || []
    songs.map { |s| s['id'] }.compact
  rescue => e
    LOGGER.warn "#{self.class.name} fetch_audio_ids: #{e.class}: #{e.message}"
    []
  end

  # Poll once for cover-art task. Cover-art uses a different polling
  # endpoint (`/api/v1/suno/cover/record-info`) and response shape than
  # song generation. The shape is:
  #
  #   { data: { taskId, parentTaskId, completeTime, response: { images: [...] },
  #             successFlag: 1|2, errorCode, errorMessage, createTime } }
  #
  # Empirically: successFlag=1 with non-empty response.images means done;
  # successFlag=2 means still in progress; errorCode!=0 or errorMessage
  # populated indicates failure. Returns :pending, :failed, :retry, or
  # [{ image_url: }, ...].
  def poll_cover_art_once(task_id)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.get("#{@base_url}/api/v1/suno/cover/record-info",
      query: { taskId: task_id }, headers: headers, timeout: 30)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    return :pending unless resp.code == 200
    data = resp.parsed_response['data']
    return :pending unless data
    LOGGER.debug "#{self.class.name}#poll_cover_art_once took=#{took_ms}ms successFlag=#{data['successFlag'].inspect}"

    images = data.dig('response', 'images')
    return Array(images).map { |url| { image_url: url } } if images && !images.empty?

    err_code = data['errorCode']
    err_msg  = data['errorMessage']
    if (err_code && err_code.to_i != 0) || (err_msg && !err_msg.to_s.empty?)
      LOGGER.warn "#{self.class.name}#poll_cover_art_once Suno error: code=#{err_code} msg=#{err_msg.inspect}"
      return { failed: true, error: format_suno_error(err_code, err_msg) }
    end

    :pending
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{self.class.name} poll_cover_art_once: #{e.class}: #{e.message}"
    :pending
  end

  # Compose a single human-readable error string from Suno's
  # errorCode/errorMessage pair for inclusion in agent_event summaries.
  # Either field may be nil/blank — pick whatever is present and tag with
  # the code if both exist. The agent sees this through
  # mark_failed_and_notify's summary, so it should read as a hint, not a
  # log line.
  #
  # SECURITY: agent_event summaries are persisted in background_tasks.params
  # (DB), forwarded to the LLM, and echoed in WARN logs. Suno's
  # errorMessage on certain 4xx paths echoes back the input URL, which for
  # cover_audio/add_vocals is the Telegram file URL containing the bot
  # token (`api.telegram.org/file/bot<id>:<token>/...`). Strip URLs out
  # before they enter the summary chain — the agent doesn't need the URL,
  # and a leaked bot token is a credential. Defense-in-depth: the input
  # could still leak via WARN logs from the `LOGGER.warn` lines in the
  # poll_* methods, but those are on a single host and not in DB / LLM
  # context.
  URL_REDACT_RE = %r{https?://\S+}.freeze
  def format_suno_error(err_code, err_msg)
    msg = err_msg.to_s.gsub(URL_REDACT_RE, '<url-redacted>').strip
    code = err_code.to_s.strip
    if !msg.empty? && !code.empty? && code != '0'
      "Suno [#{code}]: #{msg}"
    elsif !msg.empty?
      "Suno: #{msg}"
    elsif !code.empty?
      "Suno error code #{code}"
    else
      'Suno: неизвестная ошибка'
    end
  end

  # Single non-blocking poll. Returns :pending, :failed, or { audio_url:, title:, duration: }
  def poll_once(task_id)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.get("#{@base_url}/api/v1/generate/record-info",
      query: { taskId: task_id }, headers: headers, timeout: 30)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    return :pending unless resp.code == 200
    data = resp.parsed_response['data']
    return :pending unless data
    LOGGER.debug "#{self.class.name}#poll_once took=#{took_ms}ms status=#{data['status'].inspect}"
    case data['status']
    when 'SUCCESS'
      songs = data.dig('response', 'sunoData')
      return :retry if songs.nil? || songs.empty?
      songs.map do |song|
        # `prompt` carries the actual lyrics Suno used in the clip — for
        # add_vocals/cover_audio we never compose lyrics ourselves, so this
        # is the only place to surface them. compose_song already passes
        # lyrics through `params`, so this is additive (not the source of
        # truth there).
        { audio_url: song['audioUrl'] || song['audio_url'],
          title: song['title'], duration: song['duration'],
          lyrics: song['prompt'] }
      end
    when 'CREATE_TASK_FAILED', 'GENERATE_AUDIO_FAILED'
      :retry # Suno-side transient — worker died; re-submitting usually works
    when 'SENSITIVE_WORD_ERROR'
      # Permanent — content flagged. Suno's `status` is the categorical
      # bucket but its actual `errorMessage` is what the agent needs:
      # observed real messages like "Your tags contain artist name kuban
      # — we don't reference specific artists on Our, please change your
      # tags and try again." That tells the agent to rewrite TAGS, not
      # theme. Hardcoding "контент помечен как чувствительный" hid the
      # actionable info and sent the agent on a wrong-direction rephrase
      # spree (prod 2026-05-03 chat=-1001273623296). Prefer actual
      # errorMessage; fall back to the static line only if Suno omits it.
      err_code = data['errorCode']
      err_msg  = data['errorMessage']
      if err_msg && !err_msg.to_s.strip.empty?
        { failed: true, error: format_suno_error(err_code || 'SENSITIVE_WORD_ERROR', err_msg) }
      else
        { failed: true, error: 'Suno: контент помечен как чувствительный (SENSITIVE_WORD_ERROR) — нужна переформулировка темы/текста' }
      end
    else
      # Status can stay PENDING for minutes after Suno has already rejected
      # the input (e.g. uploadUrl audio matched a copyrighted work — Suno
      # surfaces error 413 / "Uploaded audio matches existing work of art"
      # in errorCode/errorMessage while status lingers on PENDING). Mirror
      # the poll_cover_art_once handling so we don't burn 6+ minutes of
      # polling before the retry cap marks the task failed.
      err_code = data['errorCode']
      err_msg  = data['errorMessage']
      if (err_code && err_code.to_i != 0) || (err_msg && !err_msg.to_s.empty?)
        LOGGER.warn "#{self.class.name}#poll_once Suno error: code=#{err_code} msg=#{err_msg.inspect}"
        return { failed: true, error: format_suno_error(err_code, err_msg) }
      end
      :pending
    end
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{self.class.name} poll_once: #{e.class}: #{e.message}"
    :pending
  end

  # Blocking convenience — submit + poll until done. Returns result hash.
  def compose(title:, lyrics:, tags:, instrumental: false)
    task_id = submit(title: title, lyrics: lyrics, tags: tags, instrumental: instrumental)
    LOGGER.debug "#{self.class.name}: submitted task #{task_id}"
    deadline = Time.now + POLL_TIMEOUT
    loop do
      raise "Suno timed out (#{POLL_TIMEOUT}s)" if Time.now > deadline
      sleep POLL_INTERVAL
      result = poll_once(task_id)
      case result
      when Array   then return result
      when :failed then raise "Suno failed"
      end
    end
  end

  def self.resolve_genre(text)
    normalized = text.strip.downcase
    GENRES.each { |key, tags| return tags if normalized.include?(key) }
    nil
  end

  private

  def post_for_task_id(path, **body)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resp = HTTParty.post("#{@base_url}#{path}", body: body.to_json, headers: headers, timeout: 30)
    LOGGER.debug "#{self.class.name}#post #{path} took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms code=#{resp.code}"
    raise "Suno #{path} failed: #{resp.code} #{resp.body}" unless resp.code == 200
    resp.parsed_response.dig('data', 'taskId') || raise("No taskId in response from #{path}")
  end

  def headers
    { 'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{@api_key}" }
  end
end
