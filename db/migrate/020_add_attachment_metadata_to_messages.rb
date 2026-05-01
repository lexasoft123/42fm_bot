class AddAttachmentMetadataToMessages < ActiveRecord::Migration[6.0]
  # When an incoming message has an audio attachment, MessageResponder
  # captures Telegram's metadata fields (title from ID3 / file_name fallback,
  # performer, duration). Surfacing these in the chat context lets the agent
  # name a cover/add-vocals output after the actual track instead of
  # inferring from prior chat context (which gets wrong when the user
  # uploads a fresh, unrelated track).
  #
  # All nullable — existing rows have nothing to backfill, and future text
  # messages won't have these set either.
  def change
    add_column :messages, :attachment_title,     :string
    add_column :messages, :attachment_performer, :string
    add_column :messages, :attachment_duration,  :integer
  end
end
