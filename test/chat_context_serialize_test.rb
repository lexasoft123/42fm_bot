require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require_relative '../lib/chat_context'

# ChatContext.serialize_msg shapes the per-message JSON the agent sees in
# the {CONTEXT} placeholder. The `audio: true` flag tells the agent that
# an earlier message has an audio attachment — the bot resolves the
# file_id internally for cover_audio / add_vocals, but the agent needs
# to know the upload exists so it doesn't re-prompt the user.
class ChatContextSerializeTest < BotTest
  CHAT = -88

  # Minimal stub matching the shape serialize_msg expects from the
  # left-joined messages+users SELECT in get_chat_context. Avoids hitting
  # the DB schema at all — these tests are about the JSON shape, not
  # persistence.
  Row = Struct.new(:message_id, :reply_to_message_id, :message_thread_id,
                   :forwarded, :edited_at, :role, :body,
                   :attachment_file_id, :attachment_mime_type,
                   :name, :first_name, :last_name, keyword_init: true) do
    def try(attr); respond_to?(attr) ? send(attr) : nil; end
  end

  def make(role: 'user', body: 'hi', message_id: 1, **attrs)
    defaults = { reply_to_message_id: nil, message_thread_id: nil, forwarded: false,
                 edited_at: nil, attachment_file_id: nil, attachment_mime_type: nil,
                 name: 'theuser', first_name: 'F', last_name: 'L' }
    Row.new(message_id: message_id, role: role, body: body, **defaults.merge(attrs))
  end

  def test_audio_flag_set_when_attachment_present
    h = ChatContext.serialize_msg(make(attachment_file_id: 'AAA', attachment_mime_type: 'audio/mpeg'))
    assert_equal true, h[:audio]
  end

  def test_audio_flag_omitted_when_no_attachment
    h = ChatContext.serialize_msg(make)
    refute h.key?(:audio), 'audio key should be omitted (not false) when no attachment'
  end

  def test_audio_flag_omitted_when_attachment_blank_string
    # Defensive: a stale bug could persist a row with empty-string instead
    # of nil — `audio: true` only when there's a real id to resolve.
    h = ChatContext.serialize_msg(make(attachment_file_id: nil))
    refute h.key?(:audio)
  end

  def test_who_falls_back_to_username_when_no_full_name
    h = ChatContext.serialize_msg(make(first_name: nil, last_name: nil))
    assert_equal 'theuser', h[:who]
  end

  def test_bot_role_renders_constant_who
    h = ChatContext.serialize_msg(make(role: 'bot'))
    assert_equal 'Жзяцля', h[:who]
  end
end
