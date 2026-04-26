class Chat < ActiveRecord::Base
  self.primary_key = :chat_id

  has_one  :chat_state,       foreign_key: :chat_id, dependent: :destroy
  has_many :messages,         foreign_key: :chat_id
  has_many :background_tasks, foreign_key: :chat_id
  has_many :api_usages,       foreign_key: :chat_id
  has_many :knowledge_facts,  class_name: 'Knowledge', foreign_key: :chat_id

  # Upsert chat metadata on every incoming Telegram message. Idempotent.
  def self.touch_seen(chat_id, title: nil, type: nil)
    ActiveRecord::Base.connection_pool.with_connection do
      chat = find_or_initialize_by(chat_id: chat_id)
      chat.title       = title if title
      chat.chat_type   = type.to_s if type
      chat.first_seen_at ||= Time.now
      chat.last_seen_at  = Time.now
      chat.save!
      chat
    end
  end

  # Bulk-populate Chat rows from Settings.auth.chats. Called at bot startup so
  # Chat.all is sensible even for chats that haven't sent a message yet. Does
  # not touch last_seen_at — only touch_seen advances that.
  def self.sync_from_config!
    chats = Settings.auth&.dig('chats') || []
    ActiveRecord::Base.connection_pool.with_connection do
      chats.each do |c|
        chat = find_or_initialize_by(chat_id: c['id'])
        chat.title       = c['name']            if c['name']
        chat.audio       = !!c['audio']
        chat.rate_limits = c['rate_limits'].to_json if c['rate_limits']
        chat.authorized  = true
        chat.first_seen_at ||= Time.now
        chat.save!
      end
    end
    chats.size
  end
end
