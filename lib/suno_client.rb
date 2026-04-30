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
  def cover_audio(upload_url:, style:, title:, prompt: '', negative_tags: '', vocal_gender: nil)
    body = { uploadUrl: upload_url, customMode: true, instrumental: false,
             style: style, title: title, prompt: prompt,
             negativeTags: negative_tags, model: @model,
             callBackUrl: 'https://example.com/noop' }
    body[:vocalGender] = vocal_gender if vocal_gender
    post_for_task_id('/api/v1/generate/upload-cover', **body)
  end

  # Submit cover-art request: generate 2 album-art images for an existing Suno
  # song task. Polled via /record-info like everything else.
  def cover_art(suno_task_id:)
    post_for_task_id('/api/v1/suno/cover/generate',
      taskId: suno_task_id, callBackUrl: 'https://example.com/noop')
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
      return :failed
    end

    :pending
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "#{self.class.name} poll_cover_art_once: #{e.class}: #{e.message}"
    :pending
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
      :failed # permanent — content flagged
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
        return :failed
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
