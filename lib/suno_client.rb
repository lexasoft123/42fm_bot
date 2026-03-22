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
    resp = HTTParty.post("#{@base_url}/api/v1/generate",
      body: { customMode: true, prompt: lyrics, style: tags, title: title,
              model: @model, instrumental: instrumental,
              callBackUrl: 'https://example.com/noop' }.to_json,
      headers: headers, timeout: 30)
    raise "Suno submit failed: #{resp.code} #{resp.body}" unless resp.code == 200
    resp.parsed_response.dig('data', 'taskId') || raise("No taskId in response")
  end

  # Single non-blocking poll. Returns :pending, :failed, or { audio_url:, title:, duration: }
  def poll_once(task_id)
    resp = HTTParty.get("#{@base_url}/api/v1/generate/record-info",
      query: { taskId: task_id }, headers: headers, timeout: 30)
    return :pending unless resp.code == 200
    data = resp.parsed_response['data']
    return :pending unless data
    case data['status']
    when 'SUCCESS'
      song = data.dig('response', 'sunoData')&.first
      return :failed unless song
      { audio_url: song['audioUrl'] || song['audio_url'],
        title: song['title'], duration: song['duration'] }
    when 'CREATE_TASK_FAILED', 'GENERATE_AUDIO_FAILED', 'SENSITIVE_WORD_ERROR'
      :failed
    else
      :pending
    end
  rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Errno::ECONNRESET => e
    LOGGER.warn "SunoClient poll_once: #{e.class}: #{e.message}"
    :pending
  end

  # Blocking convenience — submit + poll until done. Returns result hash.
  def compose(title:, lyrics:, tags:, instrumental: false)
    task_id = submit(title: title, lyrics: lyrics, tags: tags, instrumental: instrumental)
    LOGGER.debug "SunoClient: submitted task #{task_id}"
    deadline = Time.now + POLL_TIMEOUT
    loop do
      raise "Suno timed out (#{POLL_TIMEOUT}s)" if Time.now > deadline
      sleep POLL_INTERVAL
      result = poll_once(task_id)
      case result
      when Hash    then return result
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

  def headers
    { 'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{@api_key}" }
  end
end
