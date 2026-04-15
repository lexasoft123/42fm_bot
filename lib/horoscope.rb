require 'nokogiri'
require 'rest-client'
class Horoscope

  @@url = "http://img.ignio.com/r/export/utf/xml/daily/com.xml"
  @@fails = [
    "мана кончилась...",
    "оракул пьян!",
    "никто не знает что тебя ждет..."
  ]

  def initialize username
    @username = username || "hobo_kek_#{rand(1000)}"
  end

  def predict!
    response = RestClient::Request.execute(method: :get, url: @@url, timeout: 10)
    xml = Nokogiri::XML(response.body)
    horos = xml.xpath('//yesterday | //today | //tomorrow | //tomorrow02').collect{|s| s.content}

    ind = get_horo_hash % horos.size

    @username + horos[ind]

  rescue => e
    LOGGER.error "Horoscope#predict!: #{e.message}"
    @@fails.sample
  end

  def get_horo_hash
    @username.hash + Time.now.day
  end

  def get_sexy sign
    response = RestClient::Request.execute(method: :get, url: 'https://www.newsler.ru/horoscope/erotic', timeout: 10)
    doc = Nokogiri::HTML(response.body)
    content = doc.css('.horoscope-row .horoscope-block')
    all = content.map do |e|
      key = e.css('.ico > span.t').first.content
      value = e.css('.text').first.content
      [key.downcase, value]
    end.to_h
    all[sign]
  end
end
