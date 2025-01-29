require 'rest-client'
require 'json'

class Translator

  ALIASES = {
    "пиздани"        => 'uk',
    "бульба(ни)?"    => 'be',
    'шпрех(ни)?'     => 'de',
    'пше(кни)?'      => 'pl',
    'блгр(ни)?'      => 'bg',
    'татар(ни)?'     => 'tt',
    'казах(ни)?'     => 'kk',
    'грек(ни)?'      => 'el',
    'серб(ни)?'      => 'sr'
  }

  def initialize text
    @text = text
    @api_url = Settings.translator['api_url']
    @api_key = Settings.translator['api_key']
  end

  def translate_alias! lang_alias
    translate! find_lang(lang_alias)
  end


  def translate! lang
    resp = RestClient.get @api_url, { params: {key: @api_key, lang: "ru-#{lang}", format: 'plain', text: @text} }
    out = JSON.parse resp.body
    if out['code'].to_i == 200
      out["text"].first
    else
      "яндекс упрлс..."
    end
  end

  def translate_ru_en!
    resp = RestClient.get @api_url, { params: {key: @api_key, lang: "ru-en", format: 'plain', text: @text} }
    out = JSON.parse resp.body
    if out['code'].to_i == 200
      out["text"].first
    end
  end

  def find_lang lang_alias
    ALIASES.each{|k,v| return v if /#{k}/ =~ lang_alias}
  end
end
