require 'yaml'

module Settings
  extend self

  REQUIRED_KEYS = %w[telegram auth proxy chat_gpt voice_messages aws translator logging].freeze

  @_settings = {}
  attr_reader :_settings

  def load!(filename)
    common_file = filename.sub(/\.yml$/, '.common.yml')
    common = File.exist?(common_file) ? YAML.load_file(common_file) || {} : {}
    override = File.exist?(filename) ? YAML.load_file(filename) || {} : {}

    data = deep_merge(common, override)

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

  private

  def deep_merge(base, override)
    base.merge(override) do |_key, old_val, new_val|
      if old_val.is_a?(Hash) && new_val.is_a?(Hash)
        deep_merge(old_val, new_val)
      else
        new_val
      end
    end
  end
end
