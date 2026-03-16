class CommandResult
  TYPES = %i[text sticker image voice none].freeze

  attr_reader :type, :payload

  def initialize(type: :none, payload: nil)
    @type    = type
    @payload = payload
  end

  def self.text(str)    = new(type: :text,    payload: str)
  def self.sticker(id)  = new(type: :sticker, payload: id)
  def self.image(url)   = new(type: :image,   payload: url)
  def self.voice(url)   = new(type: :voice,   payload: url)
  def self.none         = new(type: :none)
end
