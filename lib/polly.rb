require 'securerandom'
require 'fileutils'
require 'aws-sdk-polly'
class Polly
  BITRATE = 32

  WEB_DIR     = File.expand_path('../web', __dir__)
  SAMPLES_DIR = File.expand_path('samples', __dir__)

  def initialize phrase, voice: "Maxim", speed: nil, minus: false, track_id: nil
    @phrase = phrase
    @voice = voice
    @speed = speed
    @minus = minus
    @track_id = track_id
    @client = Aws::Polly::Client.new(
      region: 'eu-west-1',
      credentials: Aws::Credentials.new(Settings.aws["key_id"], Settings.aws["access_key"])
    )
  end

  def generate
    hex  = SecureRandom.hex(4)
    mp3  = File.join(WEB_DIR, "#{hex}.mp3")
    wav  = File.join(WEB_DIR, "#{hex}.wav")
    ogg  = File.join(WEB_DIR, "#{hex}.ogg")

    clear_old_files(except: ogg)

    resp = @client.synthesize_speech({
      output_format: "mp3",
      text: @phrase,
      voice_id: @voice
    })
    IO.copy_stream(resp.audio_stream, mp3)

    if @speed
      out = File.join(WEB_DIR, "#{hex}_out.mp3")
      exec_command! "sox #{mp3} #{out} tempo #{@speed} && mv #{out} #{mp3}"
    end

    if @minus
      samples = Dir.glob(File.join(SAMPLES_DIR, '*.mp3'))
      raise "No minus tracks in #{SAMPLES_DIR}" if samples.empty?
      track = @track_id ? samples[@track_id % samples.size] : samples.sample
      out   = File.join(WEB_DIR, "#{hex}_mix.mp3")
      norm  = File.join(WEB_DIR, "#{hex}_norm.wav")
      # Polly mp3 is mono/16kHz; backing tracks are stereo/44.1kHz. sox -m needs
      # matching format on both inputs, so resample voice first.
      exec_command! "sox #{mp3} -r 44100 -c 2 #{norm}"
      # `trim 0 <voice_duration>` cuts the backing track off when the voice ends
      # (ffmpeg amerge did this implicitly; sox -m pads to the longest input).
      # `gain -n -3` normalizes peaks to -3 dBFS so loud TTS doesn't clip.
      voice_duration = `soxi -D #{norm}`.strip
      raise "soxi -D returned empty for #{norm}" if voice_duration.empty?
      exec_command! "sox -m #{norm} #{track} #{out} trim 0 #{voice_duration} gain -n -3 && mv #{out} #{mp3} && rm -f #{norm}"
    end

    exec_command! "sox #{mp3} -b 16 -r 44100 -e signed-integer #{wav}"
    exec_command! "opusenc --bitrate #{BITRATE} #{wav} #{ogg}"
    FileUtils.rm_f [mp3, wav]
    "#{hex}.ogg"
  rescue => e
    FileUtils.rm_f [mp3, wav, ogg]
    raise
  end

  private

  def exec_command!(command)
    LOGGER.debug "#{self.class.name}#exec_command!: #{command}"
    output = `#{command} 2>&1`
    raise "Command failed (exit #{$?.exitstatus}): #{command}\n#{output.strip}" unless $?.success?
    LOGGER.debug "#{self.class.name}#exec_command!: result=#{output.strip}"
  end

  def clear_old_files(except: nil)
    %w[mp3 wav ogg opus].each do |ext|
      Dir.glob(File.join(WEB_DIR, "*.#{ext}")).each do |f|
        FileUtils.rm_f(f) unless f == except
      end
    end
  end
end
