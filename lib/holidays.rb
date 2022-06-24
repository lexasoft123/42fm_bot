require 'nokogiri'
require './lib/app_configurator'

class Holidays
  URL = 'https://kakoysegodnyaprazdnik.ru/'

  @last_update = Time.at(0).to_date
  @holidays = {}
  @logger = AppConfigurator::LOGGER

  class << self
    def schedule
      Thread.new do
        while true do
          begin
            sleep 60
            update if @last_update != Time.now.to_date
          rescue => e
            @logger.error(e)
          end
        end
      end
    end

    def update
      interface = Settings.horoscope['interface']
      user_agent = Settings.horoscope['user_agent']

      response = HTTParty.get(Holidays::URL, headers: {"User-Agent" => user_agent}, local_host: interface)

      raise "bad response from #{Holidays::URL}: #{response}" unless response.code.eql?(200)
      doc = Nokogiri::HTML(response.body)
      selector = '.listing_wr > div > .main > span'
      content = doc.css(selector).map{|el| el.content}
      @holidays = content.select{|e| e.length > 10}
      @last_update = Time.now.to_date
      @logger.debug("holidays list updated")
    end

    def get
      update if @holidays.empty?
      @holidays
    end

    def get_for id
      list = get
      list[id % list.size]
    end
  end
end
