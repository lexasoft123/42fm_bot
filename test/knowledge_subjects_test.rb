require_relative 'test_helper'
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require 'set'
require 'ostruct'
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'

class FakeExtractGpt
  class << self
    # `reply` answers the extraction call; `verdict` answers any judge call
    # (batch dedup). Kept separate so the extraction JSON is never fed to the
    # judge as if it were a verdict.
    attr_accessor :reply, :verdict
    def calls; @calls ||= []; end
    def reset!; @calls = []; @verdict = '{"merge":[],"delete":[]}'; end
    # Either may be a Proc taking the prompt, so a test can answer per group
    # without redefining this method (which would leak into later tests).
    def ask(*_args, **kw)
      calls << kw
      v = kw[:purpose] == 'knowledge_extract' ? @reply : @verdict
      v.respond_to?(:call) ? v.call(kw[:prompt]) : v
    end
  end
end
FakeExtractGpt.reset!
Object.const_set(:GptMaster, FakeExtractGpt)

module Settings
  class << self
    attr_accessor :knowledge_overrides
  end
  def self.knowledge; { 'compact_at' => 100_000 }.merge(knowledge_overrides || {}); end
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
    Settings.knowledge_overrides = nil
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

  # REGRESSION for the lock failures after the 2026-08-20 deploy. SQLite takes
  # the write lock at a transaction's first write and holds it until COMMIT, so
  # an embeddings HTTP call after that point holds the lock for its duration;
  # in prod that starved the listen loop's own writes past the 5s busy_timeout
  # 48 times in 24 days. The detector checks transaction DEPTH, which is
  # stricter than the lock itself: it forbids network calls anywhere inside a
  # transaction, even before its first write. The first version of this test recorded transaction state and
  # never asserted it, which is how the bug shipped -- so this one asserts, and
  # proves its detector can fail.
  def test_no_embedding_call_runs_inside_a_transaction
    conn     = ActiveRecord::Base.connection
    depths   = []
    vectors  = { 'a' => [1.0, 0.0], 'b' => [0.99, 0.14], 'ab' => [1.0, 0.0] }
    EmbeddingService.singleton_class.send(:define_method, :embed) do |text|
      depths << conn.open_transactions
      vectors.fetch(text, [0.0, 1.0])
    end
    # a and b are near-identical, so batch dedup runs too and embeds the merged
    # text -- a second network path that must also stay outside.
    FakeExtractGpt.verdict = '{"merge":[{"ids":[1,2],"topic":"m","content":"ab"}],"delete":[]}'
    baseline = conn.open_transactions

    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])

    assert_equal 3, depths.size, 'expected embeds for a, b and the merged text'
    assert_equal [baseline] * depths.size, depths,
                 'an embeddings call ran inside a transaction -- it holds the SQLite write lock across HTTP'
    assert_equal ['ab'], Knowledge.where(chat_id: CHAT).pluck(:content), 'fixture should have merged'

    # Negative control: the same detector MUST see a real transaction, or the
    # assertion above passes vacuously.
    ActiveRecord::Base.transaction { EmbeddingService.embed('probe') }
    assert_equal baseline + 1, depths.last, 'detector cannot see an open transaction'
  end

  # --- same-batch duplicates (KnowledgeBase::BatchDedup) ---

  def stub_vectors(map)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |text| map.fetch(text, [0.0, 1.0]) }
  end

  def judge_calls
    FakeExtractGpt.calls.count { |c| c[:purpose] == KnowledgeBase::BatchDedup::PURPOSE }
  end

  def test_batch_duplicates_are_collapsed_before_saving
    stub_vectors('Mark trashed his watch' => [1.0, 0.0], 'Mark hates the Google Watch' => [0.98, 0.2],
                 'Mark bought a Google Watch and trashed it' => [1.0, 0.05])
    FakeExtractGpt.verdict = '{"merge":[{"ids":[1,2],"topic":"watch","content":"Mark bought a Google Watch and trashed it"}],"delete":[]}'
    extract(%([{"topic":"a","content":"Mark trashed his watch","subjects":[42]},) +
            %({"topic":"b","content":"Mark hates the Google Watch","subjects":[43]}]),
            [msg(42), msg(43)])

    facts = Knowledge.where(chat_id: CHAT).to_a
    assert_equal ['Mark bought a Google Watch and trashed it'], facts.map(&:content)
    assert_equal [42, 43], facts.first.subjects.pluck(:uid).sort, 'merged fact must keep both sides\' subjects'
    assert_nil facts.first.merged_from, 'nothing was persisted to merge from -- no tombstones'
    assert_equal 0, Knowledge.deleted.where(chat_id: CHAT).count
    assert_equal 1, judge_calls
  end

  def test_batch_keeps_both_facts_when_the_judge_refuses
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.99, 0.14])
    FakeExtractGpt.verdict = '{"merge":[],"delete":[]}'
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal %w[a b], Knowledge.where(chat_id: CHAT).order(:id).pluck(:content)
    assert_equal 1, judge_calls
  end

  def test_batch_keeps_both_facts_when_the_verdict_is_garbage
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.99, 0.14])
    ['not json', '["merge"]', '{"merge":[[1,2]]}', '{"merge":[{"ids":[1,99],"topic":"x","content":"y"}]}'].each do |bad|
      Knowledge.where(chat_id: CHAT).delete_all
      FakeExtractGpt.verdict = bad
      extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
      assert_equal %w[a b], Knowledge.where(chat_id: CHAT).order(:id).pluck(:content), "verdict #{bad} lost a fact"
    end
  end

  # If the merged text cannot be embedded, storing it would create a fact that
  # search can never find. Keep the originals instead.
  def test_batch_keeps_originals_when_the_merged_text_cannot_be_embedded
    EmbeddingService.singleton_class.send(:define_method, :embed) do |text|
      { 'a' => [1.0, 0.0], 'b' => [0.99, 0.14] }[text]   # nil for the merged text
    end
    FakeExtractGpt.verdict = '{"merge":[{"ids":[1,2],"topic":"m","content":"merged"}],"delete":[]}'
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal %w[a b], Knowledge.where(chat_id: CHAT).order(:id).pluck(:content)
  end

  def test_dissimilar_batch_facts_never_reach_the_judge
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.0, 1.0])
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal 0, judge_calls
    assert_equal 2, Knowledge.where(chat_id: CHAT).count
  end

  # Through settings, the way prod configures it -- not by calling BatchDedup
  # with threshold: nil directly, which would skip the `fetch` that reads it.
  def test_batch_dedup_can_be_disabled_in_settings
    Settings.knowledge_overrides = { 'batch_dedup_threshold' => nil }
    stub_vectors('a' => [1.0, 0.0], 'b' => [1.0, 0.0])
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal 0, judge_calls, 'a null threshold must disable batch dedup'
    assert_equal 2, Knowledge.where(chat_id: CHAT).count
  end

  # The shared prompt calls a verbatim restatement a DELETE, not a merge, so
  # the natural verdict for the most obvious sibling duplicate is a delete.
  def test_batch_honours_a_duplicate_delete_and_keeps_its_subjects
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.99, 0.14])
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":2,"reason":"duplicate","of":1}]}'
    extract(%([{"topic":"t","content":"a","subjects":[42]},{"topic":"t","content":"b","subjects":[43]}]),
            [msg(42), msg(43)])
    facts = Knowledge.where(chat_id: CHAT).to_a
    assert_equal ['a'], facts.map(&:content)
    assert_equal [42, 43], facts.first.subjects.pluck(:uid).sort, 'the survivor inherits the duplicate\'s subjects'
  end

  def test_batch_ignores_deletes_that_are_not_duplicates
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.99, 0.14])
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":2,"reason":"trivial"}]}'
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal %w[a b], Knowledge.where(chat_id: CHAT).order(:id).pluck(:content),
                 'a fresh fact is not dropped for being "trivial"'
  end

  # Two facts each named as the other's duplicate: exactly one must survive.
  def test_batch_never_deletes_every_member_of_a_group
    stub_vectors('a' => [1.0, 0.0], 'b' => [0.99, 0.14])
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":1,"reason":"duplicate","of":2},{"id":2,"reason":"duplicate","of":1}]}'
    extract(%([{"topic":"t","content":"a"},{"topic":"t","content":"b"}]), [msg(42)])
    assert_equal 1, Knowledge.where(chat_id: CHAT).count
  end

  # --- three-member groups: the survivor must be KNOWN, not inferred ---
  #
  # A=[1,0], B=[0.7,0.71], C=[0.2,0.98]: A~B and B~C clear 0.50, A~C does not,
  # so similar_groups CHAINS them into one group [A, B, C] although only B
  # connects A and C. "Some other member survives" was the original rule; B
  # surviving says nothing about A's or C's content.

  def chained_group
    [{ topic: 't', content: 'A', subjects: [1], embedding: [1.0, 0.0] },
     { topic: 't', content: 'B', subjects: [2], embedding: [0.7, 0.71] },
     { topic: 't', content: 'C', subjects: [3], embedding: [0.2, 0.98] }]
  end

  def dedup(prepared)
    KnowledgeBase::BatchDedup.run(prepared, chat_id: CHAT, logger: Logger.new(IO::NULL))
  end

  def test_fixture_really_is_one_chained_group
    groups = KnowledgeBase::BatchDedup.similar_groups(chained_group, 0.50)
    assert_equal [[0, 1, 2]], groups
  end

  # Both halves of the real duplicate pair named as each other's duplicate:
  # nothing was saved yet, so dropping both would lose that content for good.
  def test_a_chained_group_never_loses_both_halves_of_a_duplicate_pair
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":1,"reason":"duplicate","of":3},' \
                             '{"id":3,"reason":"duplicate","of":1}]}'
    out, collapsed = dedup(chained_group)
    contents = out.map { |f| f[:content] }
    assert_equal 1, collapsed
    assert_includes contents, 'B'
    assert_equal 1, (contents & %w[A C]).size, 'exactly one of the duplicate pair must survive'
  end

  def test_dropped_subjects_go_to_the_named_survivor_not_a_bystander
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":1,"reason":"duplicate","of":3}]}'
    out, = dedup(chained_group)
    by = out.to_h { |f| [f[:content], f[:subjects].sort] }
    refute by.key?('A')
    assert_equal [1, 3], by['C'], 'C is the named survivor and must inherit A\'s subjects'
    assert_equal [2], by['B'], 'B is a bystander and must be untouched'
  end

  def test_an_unnamed_delete_in_a_group_of_three_is_ignored
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":1,"reason":"duplicate"}]}'
    out, collapsed = dedup(chained_group)
    assert_equal 0, collapsed, 'without `of` the survivor is ambiguous in a group of three'
    assert_equal %w[A B C], out.map { |f| f[:content] }
  end

  def test_a_named_survivor_folded_into_a_merge_still_counts
    vectors = { 'B+C' => [0.4, 0.9] }
    EmbeddingService.singleton_class.send(:define_method, :embed) { |t| vectors[t] }
    FakeExtractGpt.verdict = '{"merge":[{"ids":[2,3],"topic":"m","content":"B+C"}],' \
                             '"delete":[{"id":1,"reason":"duplicate","of":3}]}'
    out, = dedup(chained_group)
    assert_equal ['B+C'], out.map { |f| f[:content] }
    assert_equal [1, 2, 3], out.first[:subjects].sort, 'the merge carrying C inherits A\'s subjects'
  end

  # The only write BatchDedup makes to a fact hash is the survivor's subjects.
  def test_batch_dedup_never_mutates_its_input
    prepared = [{ topic: 't', content: 'a', subjects: [42], embedding: [1.0, 0.0] },
                { topic: 't', content: 'b', subjects: [43], embedding: [0.99, 0.14] }]
    FakeExtractGpt.verdict = '{"merge":[],"delete":[{"id":2,"reason":"duplicate","of":1}]}'
    out, = dedup(prepared)
    assert_equal [42, 43], out.first[:subjects].sort, 'fixture must actually move subjects'
    assert_equal [42], prepared.first[:subjects], 'the caller\'s hash must not change'
  end

  def test_batch_handles_two_groups_and_counts_what_it_collapsed
    stub_vectors('merged 1,2' => [1.0, 0.0], 'merged 3,4' => [0.0, 1.0])
    FakeExtractGpt.verdict = lambda do |prompt|
      ids = prompt.scan(/id=(\d+)/).flatten.map(&:to_i)
      %({"merge":[{"ids":#{ids.inspect},"topic":"m","content":"merged #{ids.join(',')}"}],"delete":[]})
    end
    prepared = [{ topic: 't', content: 'a1', subjects: [1], embedding: [1.0, 0.0] },
                { topic: 't', content: 'a2', subjects: [2], embedding: [0.99, 0.14] },
                { topic: 't', content: 'b1', subjects: [3], embedding: [0.0, 1.0] },
                { topic: 't', content: 'b2', subjects: [4], embedding: [0.14, 0.99] }]
    out, collapsed = KnowledgeBase::BatchDedup.run(prepared, chat_id: CHAT, logger: Logger.new(IO::NULL))

    assert_equal 2, judge_calls, 'one judge call per similar group'
    assert_equal 2, collapsed
    assert_equal ['merged 1,2', 'merged 3,4'], out.map { |f| f[:content] }.sort
    assert_equal [1, 2], out.find { |f| f[:content] == 'merged 1,2' }[:subjects].sort
  end

  def test_extraction_prompt_survives_backslashes_in_message_bodies
    m = msg(42)
    m.body = 'path C:\\dir\\1 end'
    extract(%([{"topic":"t","content":"c","subjects":[42]}]), [m])
    prompt = FakeExtractGpt.calls.first[:prompt]
    assert_includes prompt, 'C:\\\\dir\\\\1', 'JSON backslash escapes must reach the model intact'
  end
end
