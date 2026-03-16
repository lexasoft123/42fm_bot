class TtsService
  BASE_URL = "https://42fm.ru/bot-kek1488191929173/".freeze

  def self.speak(text, voice: "Maxim", speed: nil, minus: false, track_id: nil)
    filename = Polly.new(text, voice: voice, speed: speed, minus: minus, track_id: track_id).generate
    "#{BASE_URL}#{filename}"
  end
end
