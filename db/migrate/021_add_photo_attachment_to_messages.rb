class AddPhotoAttachmentToMessages < ActiveRecord::Migration[6.0]
  # Capture the Telegram photo file_id when an incoming user message has a
  # photo. Lets the agent's `view_image` tool fetch an image from an earlier
  # message on demand (the chat context only flags `photo: true`; the
  # file_id stays DB-internal).
  #
  # Separate column from `attachment_file_id` (audio) so the audio paths —
  # serialize_msg's `audio: true` branch and GptChat#recent_chat_audio's
  # presence filter — stay untouched. Photos sent as uncompressed documents
  # (image/* MIME) are not captured — matches the existing extract_image
  # limitation.
  def change
    add_column :messages, :attachment_photo_file_id, :string
  end
end
