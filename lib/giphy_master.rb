require 'giphy'
require './lib/translator'

Giphy::Configuration.configure do |config|
  config.api_key = Settings.giphy["api_key"]
end

class GiphyMaster

  def self.search(text)
    if /\p{Cyrillic}/.match text
      text = Translator.new(text).translate_ru_en!
    end
    self.random_search text if text
  end

  def self.random_search(text)
    res = Giphy.search(text, {limit: 100})
    res.sample.fixed_height_image.url.to_s if res.size > 0
  end

end
