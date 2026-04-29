module MediaDownload
  # Download a public URL to a Tempfile. Returns the open Tempfile (binmode,
  # rewound) on 200, or nil on any failure. Caller is responsible for closing
  # and unlinking. `suffix` controls the tempfile extension (e.g. '.mp3', '.png').
  def download_to_tempfile(url, filename, chat_id: nil, suffix: '.mp3')
    response = HTTParty.get(url, timeout: 60)
    unless response.code == 200
      LOGGER.warn "[chat=#{chat_id}] #{self.class.name} download_to_tempfile: HTTP #{response.code} for #{url}"
      return nil
    end

    tmp = Tempfile.new(['media_', suffix], '/tmp')
    tmp.binmode
    tmp.write(response.body)
    tmp.rewind
    LOGGER.debug "[chat=#{chat_id}] #{self.class.name} download_to_tempfile: #{response.body.bytesize} bytes → #{filename}"
    tmp
  rescue => e
    LOGGER.warn "[chat=#{chat_id}] #{self.class.name} download_to_tempfile failed: #{e.class}: #{e.message}"
    nil
  end
end
