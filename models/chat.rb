class Chat < ActiveRecord::Base
  self.primary_key = :chat_id

  has_one  :chat_state,       foreign_key: :chat_id, dependent: :destroy
  has_many :messages,         foreign_key: :chat_id
  has_many :background_tasks, foreign_key: :chat_id
  has_many :api_usages,       foreign_key: :chat_id
  has_many :knowledge_facts,  class_name: 'Knowledge', foreign_key: :chat_id

  # Upsert chat metadata on every incoming Telegram message. Idempotent.
  # First-time-seen chats land with authorized=false; promotion to true happens
  # via Chat.sync_from_config! (config-driven) or by manual UPDATE.
  def self.touch_seen(chat_id, title: nil, type: nil)
    ActiveRecord::Base.connection_pool.with_connection do
      chat = find_or_initialize_by(chat_id: chat_id)
      chat.authorized = false if chat.new_record?
      chat.title      = title if title
      chat.chat_type  = type.to_s if type
      chat.first_seen_at ||= Time.now
      chat.last_seen_at  = Time.now
      chat.save!
      chat
    end
  end

  # Bulk-populate Chat rows from Settings.auth.chats. Called at bot startup so
  # Chat.all is sensible even for chats that haven't sent a message yet.
  #
  # title/audio/rate_limits get overwritten from config (settings is the source
  # of truth for those). `authorized` is only set on first creation — so a
  # runtime deauthorization (UPDATE chats SET authorized=0 WHERE chat_id=...)
  # survives restarts even though settings.yml still lists the chat. Doesn't
  # touch last_seen_at; only touch_seen advances that.
  def self.sync_from_config!
    chats = Settings.auth&.dig('chats') || []
    ActiveRecord::Base.connection_pool.with_connection do
      chats.each do |c|
        chat = find_or_initialize_by(chat_id: c['id'])
        chat.authorized  = true if chat.new_record?
        chat.title       = c['name']            if c['name']
        chat.audio       = !!c['audio']
        chat.rate_limits = c['rate_limits'].to_json if c['rate_limits']
        chat.first_seen_at ||= Time.now
        chat.save!
      end
    end
    chats.size
  end

  # Merge a per-bucket rate limit into the existing rate_limits JSON column.
  # Validates positive integers — second line of defense behind TextInputHandler.
  def update_rate_limits!(bucket, max:, window_minutes:)
    raise ArgumentError, 'max must be a positive integer' unless max.is_a?(Integer) && max.positive?
    raise ArgumentError, 'window_minutes must be a positive integer' unless window_minutes.is_a?(Integer) && window_minutes.positive?
    current = rate_limits.to_s.empty? ? {} : (JSON.parse(rate_limits) rescue {})
    current[bucket.to_s] = { 'max' => max, 'window_minutes' => window_minutes }
    update!(rate_limits: current.to_json)
  end
end
