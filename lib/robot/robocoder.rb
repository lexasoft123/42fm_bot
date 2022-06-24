require "base64"

class Robocoder
  def initialize text, key
    @text = text
    @key = key
  end

  def encode!
    Base64.urlsafe_encode64 (Base64.urlsafe_encode64(@text) ^ @key)
  end

  def decode!
    Base64.urlsafe_decode64 (Base64.urlsafe_decode64(@text) ^ @key)
  end
end

class String
  def ^( other )
    self.unpack('C*').zip(other.unpack('C*')).map{ |a,b| a ^ b }.pack('C*')
  end
end