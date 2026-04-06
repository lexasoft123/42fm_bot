module Fixtures
  module Messages
    def user_message(chat_id:, body:, user: nil, attrs: {})
      Message.create!({ user_uid: user&.uid, chat_id: chat_id, body: body, role: 'user' }.merge(attrs))
    end

    def bot_message(chat_id:, body:, attrs: {})
      Message.create!({ user_uid: nil, chat_id: chat_id, body: body, role: 'bot' }.merge(attrs))
    end
  end
end
