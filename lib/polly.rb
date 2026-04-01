require 'securerandom'
require 'fileutils'
require 'aws-sdk-polly'
class Polly
  BITRATE = 32

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

  WEB_DIR     = File.expand_path('../web', __dir__)
  SAMPLES_DIR = File.expand_path('samples', __dir__)

  def generate
    resp = @client.synthesize_speech({
      output_format: "mp3",
      text: @phrase,
      voice_id: @voice
    })
    mp3  = File.join(WEB_DIR, 'message.mp3')
    wav  = File.join(WEB_DIR, 'message.wav')
    filename = "#{SecureRandom.hex(4)}.ogg"
    ogg  = File.join(WEB_DIR, filename)
    clear_old_files
    IO.copy_stream(resp.audio_stream, mp3)

    if @speed
      out = File.join(WEB_DIR, 'out.mp3')
      exec_command "ffmpeg -i #{mp3} -filter:a \"atempo=#{@speed}\" #{out} && mv #{out} #{mp3}"
    end

    samples = Dir.entries(SAMPLES_DIR).select { |f| f =~ /.mp3$/ }
    if @minus
      track = if @track_id
        "minus#{@track_id % samples.size}.mp3"
      else
        samples.sample
      end
      out = File.join(WEB_DIR, 'output.mp3')
      exec_command "ffmpeg -y -i #{mp3} -i #{File.join(SAMPLES_DIR, track)} -filter_complex amerge=inputs=2 -ac 2 #{out} && mv #{out} #{mp3}"
    end

    exec_command "ffmpeg -y -i #{mp3} -acodec pcm_s16le -ar 44100 #{wav}"
    exec_command "opusenc --bitrate #{BITRATE} #{wav} #{ogg}"
    return filename
  end
  def exec_command command
    LOGGER.debug "execute command: #{command}"
    result = `#{command}`
    LOGGER.debug "command result: #{result}"
  end

  def clear_old_files
    ["mp3", "opus", "ogg", "wav"].each do |format|
      old_files = Dir.glob("#{__dir__}/../web/*.#{format}")
      FileUtils.rm_rf old_files unless old_files.empty?
    end
  end
end
