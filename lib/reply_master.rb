require 'yaml'

class ReplyMaster

  DAMN_RATE = 1
  @@wildcard = './config/replies/*.yml'

  def initialize
    @replies = Hash.new

    sources = []

    Dir.glob(@@wildcard) do |yml_file|
      sources << YAML.load(File.read(yml_file))
    end

    sources.each{|s| @replies.merge! s}
  end

  def reply user, tlg_user, msg
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
end
