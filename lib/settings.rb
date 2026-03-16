require 'yaml'

module Settings
  extend self

  REQUIRED_KEYS = %w[telegram auth proxy chat_gpt voice_messages aws translator logging].freeze

  @_settings = {}
  attr_reader :_settings

  def load! filename
    data = YAML::load_file(filename)
    missing = REQUIRED_KEYS - data.keys
    raise "Missing required settings keys: #{missing.join(', ')}" unless missing.empty?
    @_settings = OpenStruct.new(data)
  end

  def method_missing(name, *args, &block)
    @_settings.send(name) ||
    fail(NoMethodError, "unknown configuration #{name}", caller)
  end

  def respond_to_missing?(name, include_private = false)
    @_settings.respond_to?(name) || super
  end
end
