require 'google_custom_search_api'

class Gogolmogol
  @@fails = ["нихуя не нашел...",
      "иди ты нахуй с такими запросами!",
      "сам ищи такое блядство!",
      "ты кижуч, плыви отсюда!",
      "мамку свою проси такое поискать!",
      "зовите санитаров, тут кого-то пячит!",
      "попячься!",
      "губу обратно закатай!"
    ]

  @@access_rights = Settings.google

  def initialize query
    @query = query
    @access_idx = Array.new(@@access_rights.count){|i| i}.shuffle
  end

  def search!

    @@access_rights.size.times do |attempt|
      search = search_attempt(attempt)
      LOGGER.debug "#{self.class.name}#search!: result=#{search.to_s.slice(0, 200)}"
      LOGGER.debug "#{self.class.name}#search!: key_index=#{@access_idx[attempt]}"
      next if search["error"] && (search["error"]["errors"][0]["reason"] == "dailyLimitExceeded")
      return catch_result(search)
    end

    "Похоже гугле опять нас забанил..."

  rescue => e
    LOGGER.error "#{self.class.name}#search!: #{e.message}\n\t#{e.backtrace&.first(5)&.join("\n\t")}"
    return "хуйня какая-то..."
  end

  def search_results(limit: 3)
    @@access_rights.size.times do |attempt|
      search = search_attempt(attempt)
      next if search["error"] && (search["error"]["errors"][0]["reason"] == "dailyLimitExceeded")
      items = search.items
      return items.first(limit).map { |item| { title: item.title, link: item.link, snippet: item.respond_to?(:snippet) ? item.snippet : '' } }
    end
    []
  rescue => e
    LOGGER.error "#{self.class.name}#search_results: #{e.message}"
    []
  end

  def catch_result search
    items = search.items
    if items.count > 0
      items.sample.link
    else
      @@fails.sample
    end
  end

  def search_attempt number
    id = @access_idx[number]
    search = get_search @query, {api_key: @@access_rights[id]['api_key'], cx_key: @@access_rights[id]['cx_key']}
  end

  def get_search query, opts = {}
    image_pattern = /\s*(фото|картинк)/
    gif_pattern = /(гиф|gif)/
    if query =~ image_pattern
      opts["searchType"] = "image"
    end
    if query =~ gif_pattern
      opts["searchType"] = "image"
      opts["fileType"] = "gif"
    end
    opts["imgSize"]  = "large"
    q = query.gsub('гиф', 'gif animated')
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = GoogleCustomSearchApi.search(q, opts)
    LOGGER.debug "#{self.class.name}#get_search took=#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms results=#{result['items']&.size || 0}"
    result
  end

end
