CommandContext = Struct.new(
  :bot,
  :message,
  :user,
  :chat_id,
  :radio,
  :reply_master,
  :cmd,
  keyword_init: true
)
