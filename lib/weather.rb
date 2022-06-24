require 'rest_client'
require 'json'
class Weather

  def initialize cmd
    @api_url = Settings.weather["api_url"]
    @app_id  = Settings.weather["api_key"]

    @cmd = cmd.split(/\s/).join(",")
  end

  def search!
    response = RestClient.get @api_url, {params: {q: @cmd, appid: @app_id, units: 'metric'}}
    puts response.code
    puts response.body
    generate_answer JSON.parse(response.body)
  rescue Exception => e
    "хуйня какая-то..."
  end

  def generate_answer response
    if response["count"]
      msg = response["list"].map{|item| city_weather(item)}.join("\n")
    else
      msg = city_weather response
    end
  end

  def city_weather item
    template = "%{city},%{country} %{weather}\n%{temp}°C temperature from %{temp_min} to %{temp_max}°С\nwind: %{speed}m/s, clouds: %{clouds}%"
    template % {
      city: item['name'], country: item["sys"]["country"],
      weather: item["weather"].first["description"],
      temp: item["main"]["temp"],
      temp_min: item["main"]["temp_min"],
      temp_max: item["main"]["temp_max"],
      speed: item["wind"]["speed"],
      clouds: item["clouds"]["all"]
    }
  end
end
