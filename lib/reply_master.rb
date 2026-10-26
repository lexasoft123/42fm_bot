require 'yaml'

class ReplyMaster

  DAMN_RATE = 1
  @@wildcard = './config/replies/*.yml'

  def initialize(enabled: nil)
    @enabled = enabled.nil? ? configured_enabled? : enabled
    @replies = Hash.new
    return unless @enabled

    sources = []

    Dir.glob(@@wildcard) do |yml_file|
      sources << YAML.load(File.read(yml_file))
    end

    sources.each{|s| @replies.merge! s}
  end

  def reply user, tlg_user, msg
    return nil unless @enabled

    @replies.each do |regex, replies|
      if msg =~ /#{regex}/i
        if replies.is_a?(Hash)
          return replies['answers'].sample if reply_now?(replies["rate"])
        else
          return replies.sample
        end
      end
    end

    if reply_now?(DAMN_RATE)
      username = user.name ? "@#{user.name}" : make_username(tlg_user)
      p = Phrase.order("random()").first
      return nil unless p
      return "#{username}" + ", ты " + p.content
    else
      return nil
    end
  end

  def reply_now? rate
    rand(100) < rate.to_i
  end

  def make_username user
    name = user.first_name.to_s
    name += " #{user.last_name}" if user.last_name
    name
  end

  def configured_enabled?
    return true unless defined?(Settings) && Settings.respond_to?(:replies)
    Settings.replies.fetch('trigger_replies_enabled', true) != false
  rescue NoMethodError
    true
  end
end
