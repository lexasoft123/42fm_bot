class ChatState < ActiveRecord::Base
  self.primary_key = :chat_id
  belongs_to :chat, foreign_key: :chat_id, optional: true
end
