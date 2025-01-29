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
    response = RestClient.get @@url
    xml = Nokogiri::XML(response.body)
    horos = xml.xpath('//yesterday | //today | //tomorrow | //tomorrow02').collect{|s| s.content}

    ind = get_horo_hash % horos.size

    @username + horos[ind]

  rescue Exception => e
    puts e
    @@fails.sample
  end

  def get_horo_hash
    @username.hash + Time.now.day
  end

  def get_sexy sign
    response = RestClient.get 'https://www.newsler.ru/horoscope/erotic'
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
