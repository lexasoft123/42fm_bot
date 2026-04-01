class TtsService
  def self.speak(text, voice: "Maxim", speed: nil, minus: false, track_id: nil)
    filename = Polly.new(text, voice: voice, speed: speed, minus: minus, track_id: track_id).generate
    File.join(Polly::WEB_DIR, filename)
  end
end
