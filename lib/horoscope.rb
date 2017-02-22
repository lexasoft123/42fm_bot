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
    @username = username
  end

  def predict!
    response = RestClient.get @@url
    xml = Nokogiri::XML(response.body)
    horos = xml.xpath('//yesterday | //today | //tomorrow | //tomorrow02').collect{|s| s.content}

    ind = get_horo_hash % horos.size

    @username + horos[ind]

  rescue Exception => e
    @@fails.sample
  end

  def get_horo_hash
    @username.hash + Time.now.day
  end
end