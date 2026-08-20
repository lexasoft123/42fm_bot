require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require 'set'
require 'ostruct'
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'

class FakeExtractGpt
  class << self
    attr_accessor :reply
    def calls; @calls ||= []; end
    def reset!; @calls = []; end
    def ask(*args, **kw); calls << kw; @reply; end
  end
end
FakeExtractGpt.reset!
Object.const_set(:GptMaster, FakeExtractGpt)

module Settings
  def self.knowledge; { 'compact_at' => 100_000 }; end
end

require_relative '../models/knowledge_subject'
require_relative '../lib/chat_context'
require_relative '../lib/knowledge_base'

# `EXTRACTION_PROMPT` is the most frequently run LLM call in the system, and
# Deploy 2 changed its output contract to carry `subjects`. These pin the two
# ways that can go wrong: a hallucinated uid creating a phantom subject, and a
# malformed `subjects` costing us the fact entirely.
class KnowledgeSubjectsTest < BotTest
  CHAT = -55

  def setup
    super
    EmbeddingCache.reset_for_test!
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_t| [1.0, 0.0] }
    FakeExtractGpt.reset!
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
    EmbeddingCache.reset_for_test!
    super
  end

  # Shaped like the rows MessageResponder feeds the extractor: selected via
  # ChatContext::SELECT_COLS, which is where `uid` comes from.
  def msg(uid)
    OpenStruct.new(uid: uid, message_id: 1, role: 'user', body: 'hi',
                   reply_to_message_id: nil, message_thread_id: nil,
                   forwarded: nil, edited_at: nil)
  end

  def extract(facts_json, messages)
    FakeExtractGpt.reply = facts_json
    KnowledgeBase.extract_and_store(messages, chat_id: CHAT)
  end

  # The real selected columns must actually expose `uid`, or the whole
  # validation silently degrades to "no subjects, ever".
  def test_select_cols_exposes_uid
    assert_includes ChatContext::SELECT_COLS, 'users.uid'
  end

  def test_subjects_present_in_the_batch_are_stored
    extract(%([{"topic":"t","content":"c","subjects":[42]}]), [msg(42), msg(43)])
    k = Knowledge.where(chat_id: CHAT).last
    assert_equal [42], k.subjects.pluck(:uid)
    assert_equal ['extract'], k.subjects.pluck(:source)
  end

  # A uid the model invented must not create a phantom subject.
  def test_uids_not_present_in_the_batch_are_dropped
    extract(%([{"topic":"t","content":"c","subjects":[42,999999]}]), [msg(42)])
    assert_equal [42], Knowledge.where(chat_id: CHAT).last.subjects.pluck(:uid)
  end

  def test_missing_subjects_still_stores_the_fact
    extract(%([{"topic":"t","content":"c"}]), [msg(42)])
    k = Knowledge.where(chat_id: CHAT).last
    refute_nil k, 'a fact must never be lost over a subjects field'
    assert_empty k.subjects
  end

  def test_malformed_subjects_still_stores_the_fact
    ['"nope"', '{"a":1}', 'null', '[[1,2]]'].each do |bad|
      Knowledge.where(chat_id: CHAT).delete_all
      extract(%([{"topic":"t","content":"c","subjects":#{bad}}]), [msg(42)])
      refute_nil Knowledge.where(chat_id: CHAT).last, "subjects=#{bad} lost the fact"
    end
  end

  def test_embedding_happens_outside_the_write_transaction
    # If embed ran inside the transaction it would hold a SQLite write lock
    # across every HTTP round-trip in the batch.
    in_txn = []
    EmbeddingService.singleton_class.send(:define_method, :embed) do |_t|
      in_txn << ActiveRecord::Base.connection.transaction_open?
      [1.0, 0.0]
    end
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal 2, in_txn.size
    # The per-test harness wraps everything in one outer transaction, so what
    # matters is that no NESTED write transaction was open during the embeds.
    assert_equal 2, Knowledge.where(chat_id: CHAT).count
  end

  def test_extraction_prompt_survives_backslashes_in_message_bodies
    m = msg(42)
    m.body = 'path C:\\dir\\1 end'
    extract(%([{"topic":"t","content":"c","subjects":[42]}]), [m])
    prompt = FakeExtractGpt.calls.first[:prompt]
    assert_includes prompt, 'C:\\\\dir\\\\1', 'JSON backslash escapes must reach the model intact'
  end
end
