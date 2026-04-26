class Message < ActiveRecord::Base
  belongs_to :user, foreign_key: 'user_uid', primary_key: 'uid', optional: true

  # Persist a bot-sent message as a Message row so user replies can resolve
  # the bot's message_id back to context. response can be a Telegram::Bot
  # OpenStruct or a Hash (sometimes Telegram returns the raw hash).
  def self.persist_bot_reply(chat_id:, body:, response:, reply_to: nil)
    return unless response
    mid = response.respond_to?(:message_id) ? response.message_id :
          (response.is_a?(Hash) ? (response.dig('result', 'message_id') || response['message_id']) : nil)
    tid = response.respond_to?(:message_thread_id) ? response.message_thread_id :
          (response.is_a?(Hash) ? (response.dig('result', 'message_thread_id') || response['message_thread_id']) : nil)
    return unless mid
    ActiveRecord::Base.connection_pool.with_connection do
      create(role: 'bot', chat_id: chat_id, body: body, message_id: mid,
             message_thread_id: tid, reply_to_message_id: reply_to)
    end
  rescue => e
    LOGGER.warn "Message.persist_bot_reply failed: #{e.class}: #{e.message}" if defined?(LOGGER)
  end
end
