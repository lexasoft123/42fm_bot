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

  def generate
    resp = @client.synthesize_speech({
      output_format: "mp3",
      text: @phrase,
      voice_id: @voice
    })
    filepath = File.join(__dir__, "../web/message.mp3")
    clear_old_files
    IO.copy_stream(resp.audio_stream, filepath)
    filename = "#{SecureRandom.hex(4)}.ogg"
    Dir.chdir File.join(__dir__, "../web/")

    if @speed
      exec_command "ffmpeg -i message.mp3 -filter:a \"atempo=#{@speed}\" out.mp3 && mv out.mp3 message.mp3"
    end

    samples = Dir.entries("../lib/samples/").select{|f| f =~ /.mp3$/}
    if @minus
      track = if @track_id
        "minus#{@track_id % samples.size}.mp3"
      else
        samples.sample
      end
      exec_command "ffmpeg -y -i message.mp3 -i ../lib/samples/#{track} -filter_complex amerge=inputs=2 -ac 2 output.mp3 && mv output.mp3 message.mp3"
    end

    exec_command "ffmpeg -y -i message.mp3 -acodec pcm_s16le -ar 44100 message.wav"
    exec_command "opusenc --bitrate #{BITRATE} message.wav #{filename}"
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
