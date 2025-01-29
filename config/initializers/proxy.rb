require 'faraday_adapter_socks'

def enable_proxy
  Telegram::Bot.configure do |config|
    proxy_addr = "socks://" 
    config.proxy = URI.parse(proxy_addr)
    config.adapter = :net_http_socks
  end
end
