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
      exec_command! "ffmpeg -i #{mp3} -filter:a \"atempo=#{@speed}\" #{out} && mv #{out} #{mp3}"
    end

    if @minus
      samples = Dir.glob(File.join(SAMPLES_DIR, '*.mp3'))
      raise "No minus tracks in #{SAMPLES_DIR}" if samples.empty?
      track = @track_id ? samples[@track_id % samples.size] : samples.sample
      out   = File.join(WEB_DIR, "#{hex}_mix.mp3")
      exec_command! "ffmpeg -y -i #{mp3} -i #{track} -filter_complex amerge=inputs=2 -ac 2 #{out} && mv #{out} #{mp3}"
    end

    exec_command! "ffmpeg -y -i #{mp3} -acodec pcm_s16le -ar 44100 #{wav}"
    exec_command! "opusenc --bitrate #{BITRATE} #{wav} #{ogg}"
    FileUtils.rm_f [mp3, wav]
    "#{hex}.ogg"
  rescue => e
    FileUtils.rm_f [mp3, wav, ogg]
    raise
  end

  private

  def exec_command!(command)
    LOGGER.debug "execute command: #{command}"
    output = `#{command} 2>&1`
    raise "Command failed (exit #{$?.exitstatus}): #{command}\n#{output.strip}" unless $?.success?
    LOGGER.debug "command result: #{output.strip}"
  end

  def clear_old_files(except: nil)
    %w[mp3 wav ogg opus].each do |ext|
      Dir.glob(File.join(WEB_DIR, "*.#{ext}")).each do |f|
        FileUtils.rm_f(f) unless f == except
      end
    end
  end
end
