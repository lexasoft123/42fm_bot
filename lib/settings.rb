module Settings
  extend self

  @_settings = {}
  attr_reader :_settings

  def load! filename
    @_settings = OpenStruct.new(YAML::load_file(filename))
  end

  # deep_merge by Stefan Rusterholz, see http://www.ruby-forum.com/topic/142809
  def deep_merge!(target, data)
    merger = proc{|key, v1, v2|
      Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
    target.merge! data, &merger
  end

  def method_missing(name, *args, &block)
    @_settings.send(name) ||
    fail(NoMethodError, "unknown configuration #{name}", caller)
  end

end
