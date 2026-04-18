class CommandResult
  TYPES = %i[text sticker image voice audio none].freeze

  attr_reader :type, :payload, :meta

  def initialize(type: :none, payload: nil, meta: {})
    @type    = type
    @payload = payload
    @meta    = meta
  end

  def self.text(str, reply_to_message_id: nil, persist_as_bot_reply: false)
    new(type: :text, payload: str,
        meta: { reply_to_message_id: reply_to_message_id, persist_as_bot_reply: persist_as_bot_reply })
  end
  def self.sticker(id)  = new(type: :sticker, payload: id)
  def self.image(url)   = new(type: :image,   payload: url)
  def self.voice(url)   = new(type: :voice,   payload: url)
  def self.none         = new(type: :none)

  def self.audio(url, title: nil, performer: nil)
    new(type: :audio, payload: url, meta: { title: title, performer: performer })
  end
end
