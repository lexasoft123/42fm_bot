require 'rest_client'
require 'faraday'
require 'filemagic'

class FileUploader

  @@file_prefix = './tmp/'

  def initialize url
    @url = url
  end

  def upload!
    response = RestClient.get(@url)
    @url =~ /[.](?<ext>jpg|jpeg|gif|png|tif|bmp)/
    ext = Regexp.last_match(:ext)
    filename = @@file_prefix + Time.now.to_i.to_s + "." + ext
    File.open(filename, 'w') { |file| file.write(response.body)}
    Faraday::UploadIO.new(filename, magic(filename))
  end

private

  def magic f
    FileMagic.new(FileMagic::MAGIC_MIME).file(f).split(";")[0]
  end

end


