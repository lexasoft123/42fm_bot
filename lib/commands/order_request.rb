module Commands
  class OrderRequest < Base
    PATTERN = /^!(заказ|request|req|замовлення)\s+(.*)$/

    def match?
      cmd =~ PATTERN
    end

    def execute
      track_query = cmd.match(PATTERN)[2]
      if check_order_privileges
        tr = radio.request(track_query)
        if tr
          update_last_order
          CommandResult.text(tr[:name])
        else
          sticker_key = [:kiss_my_ass, :govnar, :lemmy].sample
          CommandResult.sticker(STICKER[sticker_key])
        end
      else
        CommandResult.text("А не охуел ли ты часом, %username%? Заказывай не ранее #{user.next_order}")
      end
    end

    private

    def check_order_privileges
      case user.role
      when 'new'
        return false if user.last_order && Time.now < user.next_order
        true
      else
        true
      end
    end

    def update_last_order
      user.last_order = Time.now
      user.save
    end
  end
end
