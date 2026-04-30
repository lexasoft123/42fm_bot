class AddAttachmentToMessages < ActiveRecord::Migration[6.0]
  # Capture the Telegram file_id + mime when an incoming user message has
  # audio (audio / voice / audio-MIME document). Lets `Commands::GptChat`
  # walk back through recent messages to find an earlier upload when the
  # user later asks for a cover/add-vocals without using Telegram's reply
  # feature to point at the upload.
  #
  # Generic naming (`attachment_*` rather than `audio_*`) leaves room for
  # extending to other attachment kinds later (e.g. video) without a
  # second migration.
  def change
    add_column :messages, :attachment_file_id,   :string
    add_column :messages, :attachment_mime_type, :string
  end
end
