require_relative 'test_helper'
# Deliberately NOT defining COMPACT_LOGGER: it is assigned only in lib/bot.rb,
# so the review path must survive its absence (rake, bin/console).
LOGGER ||= Logger.new(IO::NULL) unless defined?(LOGGER)
require 'set'
require_relative '../lib/embedding_service'
require_relative '../lib/embedding_cache'

class FakeGptMaster
  class << self
    attr_accessor :reply
    def calls; @calls ||= []; end
    def reset!; @calls = []; @reply = '{"merge":[],"delete":[]}'; end
    # `reply` may be a Proc so a test can respond to the actual prompt WITHOUT
    # redefining this method -- a singleton redefinition would leak into every
    # test that runs after it.
    def ask(*args, **kw)
      calls << [args, kw]
      @reply.respond_to?(:call) ? @reply.call(kw[:prompt]) : @reply
    end
  end
end
FakeGptMaster.reset!
Object.const_set(:GptMaster, FakeGptMaster)

module Settings
  # `review_overrides` lets a test change one review knob without redefining
  # this method (a redefinition would leak into every later test).
  class << self
    attr_accessor :review_overrides
  end
  def self.knowledge
    { 'compact_threshold' => 0.66, 'compact_min_pairwise' => 0.62, 'max_cluster' => 8,
      'subject_threshold' => 0.55, 'subject_min_pairwise' => 0.50,
      'subject_min_facts' => 2, 'subject_min_residual' => 0.0, 'compact_at' => 100_000,
      'review' => { 'max_delete_per_day' => 50, 'max_delete_pct' => 100,
                    'max_merge_per_run' => 40, 'min_age_days' => 0, 'ttl_days' => 30 }
                  .merge(review_overrides || {}) }
  end
end

require_relative '../models/knowledge_subject'
require_relative '../lib/knowledge_base'
require_relative '../lib/command_result'
require_relative '../lib/commands/base'
require_relative '../lib/commands/knowledge_review'
require_relative '../lib/commands/knowledge_restore'
require_relative '../models/background_task'

# The LLM judge is the only path that deletes knowledge facts, so every rule
# below is a guard against it doing so wrongly. Candidate precision measured on
# prod tops out around 67-80%, which is exactly why nothing merges mechanically.
class KnowledgeReviewTest < BotTest
  CHAT = -88

  def setup
    super
    EmbeddingCache.reset_for_test!
    EmbeddingService.singleton_class.send(:alias_method, :__embed, :embed)
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_t| [1.0, 0.0] }
    FakeGptMaster.reset!
  end

  def teardown
    EmbeddingService.singleton_class.send(:alias_method, :embed, :__embed)
    EmbeddingService.singleton_class.send(:remove_method, :__embed)
    EmbeddingCache.reset_for_test!
    Settings.review_overrides = nil
    super
  end

  def make(vec, content:, source: 'auto', created_at: Time.now - 10 * 86_400)
    k = Knowledge.new(topic: 't', content: content, chat_id: CHAT, source: source,
                      created_at: created_at, updated_at: created_at)
    k.embedding_vector = vec
    k.save!
    k
  end

  def cfg(**over)
    KnowledgeBase::Review::Config.new(
      { max_delete_per_day: 50, max_delete_pct: 100, max_merge_per_run: 40,
        min_age_days: 0, max_chunks: nil, dry_run: false }.merge(over)
    )
  end

  def run_review(clusters, **over)
    KnowledgeBase::Review.run(chat_id: CHAT, clusters: clusters,
                              config: cfg(**over), logger: Logger.new(IO::NULL))
  end

  def test_runs_without_compact_logger_defined
    refute defined?(COMPACT_LOGGER), 'meaningless if COMPACT_LOGGER is defined'
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"merged"}],"delete":[]})
    assert_equal 1, KnowledgeBase.review!(chat_id: CHAT)[:merged]
  end

  def test_merge_soft_deletes_sources_and_records_merged_from
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"merged"}],"delete":[]})
    stats = run_review([[a.id, b.id]])

    assert_equal 1, stats[:merged]
    assert_equal 2, stats[:removed]
    assert a.reload.deleted?, 'sources are soft-deleted, never destroyed'
    assert_equal 'merged', a.deleted_reason
    merged = Knowledge.live.where(chat_id: CHAT).order(:id).last
    assert_equal 'merged', merged.content
    assert_equal [a.id, b.id].sort, merged.merged_from_ids.sort
    refute_nil merged.reviewed_at, 'merged facts must be stamped, or they re-enter the queue'
  end

  # The single most important guard: at ~50-80% candidate precision the judge
  # refusing is the normal case, not an error.
  def test_refusing_to_merge_destroys_nothing
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = '{"merge":[],"delete":[]}'
    stats = run_review([[a.id, b.id]])
    assert_equal 0, stats[:merged]
    refute a.reload.deleted?
    refute b.reload.deleted?
  end

  def test_hallucinated_ids_are_dropped
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},999999],"topic":"m","content":"x"}],"delete":[]})
    assert_equal 0, run_review([[a.id, b.id]])[:merged], 'a merge of one real id is not a merge'
    refute a.reload.deleted?
  end

  def test_manual_facts_are_never_touched
    m = make([1.0, 0.0], content: 'manual', source: 'manual')
    a = make([1.0, 0.0], content: 'a')
    b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[],"delete":[{"id":#{m.id},"reason":"noise"}]})
    run_review([[m.id, a.id, b.id]])
    refute m.reload.deleted?, 'admin-curated facts must be immune'
  end

  def test_facts_younger_than_min_age_are_skipped
    a = make([1.0, 0.0], content: 'a', created_at: Time.now)
    b = make([1.0, 0.0], content: 'b', created_at: Time.now)
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"x"}],"delete":[]})
    assert_equal 0, run_review([[a.id, b.id]], min_age_days: 3)[:merged]
  end

  def test_merge_wins_over_delete_for_the_same_id
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"x"}],) +
                          %("delete":[{"id":#{a.id},"reason":"noise"}]})
    stats = run_review([[a.id, b.id]])
    assert_equal 1, stats[:merged]
    assert_equal 0, stats[:deleted]
  end

  def test_unparseable_verdict_writes_nothing
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = 'not json'
    stats = run_review([[a.id, b.id]])
    assert_equal 1, stats[:parse_failures]
    assert_equal 0, stats[:merged]
    refute a.reload.deleted?
  end

  def test_dry_run_writes_nothing
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"x"}],"delete":[]})
    before = Knowledge.count
    run_review([[a.id, b.id]], dry_run: true)
    assert_equal before, Knowledge.count
    refute a.reload.deleted?
  end

  # Merge-sourced deletions count against the budget: merging is the dominant
  # deletion vector, so a cap governing only the `delete` array understates the
  # real blast radius by an order of magnitude.
  def test_merge_sourced_deletions_count_against_the_daily_budget
    pairs = 4.times.map { |i| [make([1.0, 0.0], content: "a#{i}"), make([1.0, 0.0], content: "b#{i}")] }
    FakeGptMaster.reply = lambda do |prompt|
      ids = prompt.scan(/id=(\d+)/).flatten.first(2).map(&:to_i)
      %({"merge":[{"ids":#{ids.inspect},"topic":"m","content":"merged"}],"delete":[]})
    end
    stats = run_review(pairs.map { |a, b| [a.id, b.id] }, max_delete_per_day: 5)
    assert_equal 2, stats[:merged], 'budget of 5 allows two 2-source merges, not four'
    assert_equal 4, stats[:removed]
  end

  def test_budget_is_shared_across_runs_on_the_same_day
    KnowledgeCompactLog.create!(chat_id: CHAT, merged: 1, removed: 5, deleted: 0, kept: 0,
                                threshold: 0.55, run_type: 'review', created_at: Time.now)
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"x"}],"delete":[]})
    stats = run_review([[a.id, b.id]], max_delete_per_day: 5)
    assert_equal 0, stats[:merged], 'earlier runs today already spent the budget'
  end

  def test_soft_deleted_facts_leave_search_and_the_cache
    a = make([1.0, 0.0], content: 'a')
    assert_equal 1, EmbeddingCache.fetch(CHAT).ids.size
    a.soft_delete!('admin')
    assert_equal 0, EmbeddingCache.fetch(CHAT).ids.size, 'tombstones must not pollute the matrix'
    assert_equal [], KnowledgeBase.search('q', chat_id: CHAT)
  end

  # --- commands ---

  def test_review_command_enqueues_and_does_not_duplicate
    cmd = Commands::KnowledgeReview.allocate
    cmd.define_singleton_method(:admin?) { true }
    cmd.define_singleton_method(:chat_id) { CHAT }
    cmd.execute
    assert_equal 1, BackgroundTask.where(task_type: 'knowledge_review', chat_id: CHAT).count
    assert_empty FakeGptMaster.calls, 'must not call the LLM on the listen loop'
    assert_match(/уже в очереди/, cmd.execute.payload.to_s)
    assert_equal 1, BackgroundTask.where(task_type: 'knowledge_review', chat_id: CHAT).count
  end

  def test_restore_refuses_merged_facts_without_confirmation
    a = make([1.0, 0.0], content: 'a')
    a.soft_delete!('merged')
    cmd = Commands::KnowledgeRestore.allocate
    cmd.define_singleton_method(:admin?) { true }
    cmd.define_singleton_method(:chat_id) { CHAT }
    cmd.define_singleton_method(:cmd) { "бот верни #{a.id}" }
    assert_match(/снова создать дубль/, cmd.execute.payload.to_s)
    assert a.reload.deleted?

    cmd.define_singleton_method(:cmd) { "бот верни #{a.id} точно" }
    cmd.execute
    refute a.reload.deleted?
  end

  def test_restore_round_trips_an_admin_deletion
    a = make([1.0, 0.0], content: 'a')
    a.soft_delete!('admin')
    cmd = Commands::KnowledgeRestore.allocate
    cmd.define_singleton_method(:admin?) { true }
    cmd.define_singleton_method(:chat_id) { CHAT }
    cmd.define_singleton_method(:cmd) { "бот верни #{a.id}" }
    cmd.execute
    refute a.reload.deleted?
    assert_equal [a.id], KnowledgeBase.search('q', chat_id: CHAT).map(&:id)
  end
  # --- verdict robustness (regressions) ---

  # A single verdict may propose overlapping groups. Applying both would
  # soft-delete the shared fact twice and make the second merged fact quote a
  # source already merged away -- recreating the duplicate the sweep removes.
  def test_overlapping_merge_groups_apply_only_the_first
    a = make([1.0, 0.0], content: 'a')
    b = make([1.0, 0.0], content: 'b')
    c = make([1.0, 0.0], content: 'c')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m1","content":"x"},) +
                          %({"ids":[#{b.id},#{c.id}],"topic":"m2","content":"y"}],"delete":[]})
    stats = run_review([[a.id, b.id, c.id]])
    assert_equal 1, stats[:merged]
    assert_equal 2, stats[:removed], 'the shared fact must not be charged twice'
    refute c.reload.deleted?, 'the overlapping second group must be dropped whole'
    assert_equal 1, Knowledge.live.where(chat_id: CHAT).where.not(merged_from: nil).count
  end

  # Well-formed JSON of the wrong SHAPE must not escape Review.run: the handler
  # would mark the whole task failed and abandon the remaining clusters.
  def test_malformed_verdict_elements_do_not_raise
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    ['{"delete":[3]}', '{"merge":[[1,2]]}', '{"merge":"nope","delete":null}'].each do |reply|
      FakeGptMaster.reply = reply
      stats = nil
      assert_silent { stats = run_review([[a.id, b.id]]) }
      assert_equal 0, stats[:merged], "reply #{reply} must be a no-op"
      refute a.reload.deleted?
    end
  end

  # gsub with a STRING replacement expands \1, \& etc. appearing in the fact
  # text, silently mangling what the judge sees.
  def test_backslashes_in_fact_content_reach_the_prompt_intact
    a = make([1.0, 0.0], content: 'path C:\dir\1 end')
    b = make([1.0, 0.0], content: 'b')
    run_review([[a.id, b.id]])
    prompt = FakeGptMaster.calls.last[1][:prompt]
    assert_includes prompt, 'path C:\dir\1 end'
  end

  # --- dry run ---

  def test_dry_run_reports_what_it_would_have_done
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"x"}],"delete":[]})
    stats = run_review([[a.id, b.id]], dry_run: true)
    assert_equal 1, stats[:would_merge], 'a dry run that reports zeros is useless'
    assert_equal 2, stats[:would_remove]
    assert_equal 0, stats[:merged]
    refute a.reload.deleted?
  end

  def test_dry_run_is_bounded_by_the_budget
    pairs = 6.times.map { |i| [make([1.0, 0.0], content: "a#{i}"), make([1.0, 0.0], content: "b#{i}")] }
    FakeGptMaster.reply = lambda do |prompt|
      ids = prompt.scan(/id=(\d+)/).flatten.first(2).map(&:to_i)
      %({"merge":[{"ids":#{ids.inspect},"topic":"m","content":"merged"}],"delete":[]})
    end
    stats = run_review(pairs.map { |a, b| [a.id, b.id] }, dry_run: true, max_delete_per_day: 5)
    assert_operator stats[:chunks], :<, 6, 'dry mode must still stop at the budget'
  end

  def test_max_chunks_bounds_the_run
    pairs = 5.times.map { |i| [make([1.0, 0.0], content: "a#{i}"), make([1.0, 0.0], content: "b#{i}")] }
    stats = run_review(pairs.map { |a, b| [a.id, b.id] }, max_chunks: 2)
    assert_equal 2, stats[:chunks]
  end

  # --- budget accounting ---

  # `removed` is the TOTAL soft-deletes; `deleted` is the subset from the delete
  # array. Summing both would charge a direct deletion twice.
  def test_direct_deletions_are_not_charged_twice
    # Enough live facts that max_delete_pct isn't the binding constraint.
    20.times { |i| make([0.0, 1.0], content: "filler#{i}") }
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[],"delete":[{"id":#{a.id},"reason":"noise"}]})
    stats = run_review([[a.id, b.id]])
    assert_equal 1, stats[:deleted]
    assert_equal 1, stats[:removed]

    KnowledgeCompactLog.create!(chat_id: CHAT, merged: 0, removed: stats[:removed],
                                deleted: stats[:deleted], kept: 0, threshold: 0.55,
                                run_type: 'review', created_at: Time.now)
    budget = KnowledgeBase::Review.deletion_budget(CHAT, cfg(max_delete_per_day: 5))
    assert_equal 4, budget, 'one deletion must spend one, not two'
  end

  # --- resumability ---

  def test_reviewed_facts_are_skipped_by_the_next_run
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = '{"merge":[],"delete":[]}'
    first = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 1, first[:chunks]
    refute_nil a.reload.reviewed_at, 'judged facts must be stamped'

    FakeGptMaster.reset!
    second = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 0, second[:chunks], 'a second run must not re-pay for the same refusal'
    assert_empty FakeGptMaster.calls
  end

  def test_dry_run_does_not_stamp_reviewed_at
    a = make([1.0, 0.0], content: 'a'); make([1.0, 0.0], content: 'b')
    KnowledgeBase.review!(chat_id: CHAT, dry_run: true)
    assert_nil a.reload.reviewed_at, 'a dry run must not consume the queue'
  end

  # --- stamping: only what the judge actually ruled on (regressions) ---
  #
  # The first version stamped EVERY candidate cluster after a run. On prod that
  # marked 1,250 facts reviewed on day one against ~650 actually judged, and
  # locked the rest out of review for ttl_days without a single look.

  def two_clusters
    a = [make([1.0, 0.0], content: 'a1'), make([1.0, 0.0], content: 'a2')]
    b = [make([0.0, 1.0], content: 'b1'), make([0.0, 1.0], content: 'b2')]
    [a, b]
  end

  def stamped_ids
    Knowledge.where(chat_id: CHAT).where.not(reviewed_at: nil).pluck(:id).sort
  end

  def test_a_run_cut_short_by_max_chunks_stamps_only_what_it_judged
    a, b = two_clusters
    stats = KnowledgeBase.review!(chat_id: CHAT, max_chunks: 1)
    assert_equal 1, stats[:chunks]
    judged = [a, b].find { |pair| pair.all? { |k| k.reload.reviewed_at } }
    refute_nil judged, 'the cluster that was judged must be stamped'
    other = ([a, b] - [judged]).first
    assert other.all? { |k| k.reload.reviewed_at.nil? }, 'a cluster never sent to the judge must not be stamped'
  end

  def test_a_run_blocked_by_budget_stamps_nothing
    two_clusters
    KnowledgeCompactLog.create!(chat_id: CHAT, merged: 0, removed: 50, deleted: 0, kept: 0,
                                threshold: 0.55, run_type: 'review', created_at: Time.now)
    stats = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 0, stats[:chunks]
    assert_empty stamped_ids, 'nothing was judged, so nothing may be stamped'
  end

  def test_an_unparseable_verdict_is_not_stamped
    two_clusters
    FakeGptMaster.reply = 'not json'
    KnowledgeBase.review!(chat_id: CHAT)
    assert_empty stamped_ids, 'no ruling, no stamp -- the cluster must be retried'
  end

  # A verdict cut off by the budget was not fully acted on. Stamping it would
  # lock an APPROVED merge out for ttl_days.
  def test_a_cluster_whose_verdict_hit_the_cap_is_not_stamped
    f = 4.times.map { |i| make([1.0, 0.0], content: "f#{i}") }
    FakeGptMaster.reply = %({"merge":[{"ids":[#{f[0].id},#{f[1].id}],"topic":"m","content":"x"},) +
                          %({"ids":[#{f[2].id},#{f[3].id}],"topic":"m","content":"y"}],"delete":[]})
    stats = run_review([f.map(&:id)], max_delete_per_day: 3)
    assert_equal 1, stats[:merged], 'budget of 3 fits one 2-fact merge, not two'
    assert stats[:cap_reached]
    assert_empty stats[:judged_ids], 'a partially-applied verdict must leave its cluster for next time'
  end

  def test_judged_ids_are_reported_for_a_clean_ruling
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    stats = run_review([[a.id, b.id]])
    assert_equal [a.id, b.id].sort, stats[:judged_ids].sort
  end

  # --- eligibility: young and manual facts are not candidates (regressions) ---
  #
  # The first version dropped a young fact's merge AFTER the judge approved it,
  # then stamped it anyway: every new fact got one look, while too young to act
  # on. All 14 merges the judge proposed in 24 days on prod died this way.

  def test_young_facts_are_not_candidates_and_are_not_stamped
    Settings.review_overrides = { 'min_age_days' => 3 }
    a = make([1.0, 0.0], content: 'a', created_at: Time.now - 3600)
    b = make([1.0, 0.0], content: 'b', created_at: Time.now - 3600)

    stats = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 0, stats[:chunks]
    assert_empty FakeGptMaster.calls, 'young facts must not be sent to the judge'
    assert_nil a.reload.reviewed_at, 'a young fact must stay unstamped so it is reconsidered later'

    # Once old enough, the same pair is judged -- and would be merged.
    [a, b].each { |k| k.update_columns(created_at: Time.now - 5 * 86_400) }
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"merged"}],"delete":[]})
    assert_equal 1, KnowledgeBase.review!(chat_id: CHAT)[:merged]
  end

  def test_manual_facts_are_not_candidates
    manual = make([1.0, 0.0], content: 'manual', source: 'manual')
    auto   = make([1.0, 0.0], content: 'auto')
    assert_includes KnowledgeBase.unavailable_for_review(CHAT, ttl: 30, min_age: 0), manual.id

    stats = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 0, stats[:chunks], 'a lone auto fact next to a manual one is not a cluster'
    assert_empty FakeGptMaster.calls
    # The discriminating assertion: 56706cf also made no judge call here (it
    # stripped the manual fact before judging) but still stamped BOTH facts.
    assert_nil auto.reload.reviewed_at, 'a fact that was never judged must not be stamped'
  end

  # --- review-of-the-fixes regressions ---

  # A merge bigger than the whole daily cap can never apply. Treated as "no
  # budget left today" it stayed unstamped at the head of the queue and ended
  # every later run after one paid call -- a permanent stall.
  def test_a_merge_larger_than_the_daily_cap_does_not_stall_the_sweep
    Settings.review_overrides = { 'max_delete_per_day' => 5 }
    big   = 6.times.map { |i| make([1.0, 0.0], content: "big#{i}") }
    small = 2.times.map { |i| make([0.0, 1.0], content: "small#{i}") }
    FakeGptMaster.reply = lambda do |prompt|
      ids = prompt.scan(/id=(\d+)/).flatten.map(&:to_i)
      %({"merge":[{"ids":#{ids.inspect},"topic":"m","content":"merged #{ids.size}"}],"delete":[]})
    end

    stats = KnowledgeBase.review!(chat_id: CHAT)
    assert_equal 1, stats[:oversized], 'the 6-fact merge exceeds the cap of 5 and must be ruled out'
    refute stats[:cap_reached], 'an impossible merge is not "budget spent for today"'
    assert_equal 1, stats[:merged], 'the run must carry on to the next cluster'
    assert small.all? { |k| k.reload.deleted? }
    assert big.none? { |k| k.reload.deleted? }
    assert big.all? { |k| k.reload.reviewed_at }, 'the oversized cluster is resolved and must be stamped'
  end

  # EmbeddingService.embed returns nil on failure. Tombstoning the sources
  # behind a vectorless merged fact would make that content unreachable.
  def test_a_merge_whose_text_cannot_be_embedded_writes_nothing
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_t| nil }
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"merged"}],"delete":[]})
    before = Knowledge.count

    stats = run_review([[a.id, b.id]])
    assert_equal 0, stats[:merged]
    assert_equal 1, stats[:embed_failures]
    assert_equal before, Knowledge.count, 'no vectorless merged fact may be created'
    refute a.reload.deleted?, 'sources must survive'
    assert_empty stats[:judged_ids], 'a transient failure must leave the cluster for a retry'
  end

  # `$!` is also set while a CALLER is handling an exception. Keyed on `$!`, a
  # clean run invoked from inside someone's rescue looked "failed", and its own
  # failure to write the budget log was logged and silently swallowed.
  def test_a_clean_run_called_from_a_rescue_still_surfaces_a_log_write_failure
    make([1.0, 0.0], content: 'a'); make([1.0, 0.0], content: 'b')
    KnowledgeCompactLog.singleton_class.send(:alias_method, :__create!, :create!)
    KnowledgeCompactLog.singleton_class.send(:define_method, :create!) { |*| raise ActiveRecord::StatementInvalid, 'locked' }
    begin
      assert_raises(ActiveRecord::StatementInvalid, 'a failed budget-log write must not be swallowed') do
        begin
          raise 'an unrelated error the caller is handling'
        rescue RuntimeError
          KnowledgeBase.review!(chat_id: CHAT)
        end
      end
    ensure
      KnowledgeCompactLog.singleton_class.send(:alias_method, :create!, :__create!)
      KnowledgeCompactLog.singleton_class.send(:remove_method, :__create!)
    end
  end

  # Merges applied before a mid-run exception must still be charged to the
  # 24h budget, which is computed from the run log.
  def test_a_run_that_raises_part_way_still_records_its_log_row
    first  = [make([1.0, 0.0], content: 'a1'), make([1.0, 0.0], content: 'a2')]
    second = [make([0.0, 1.0], content: 'b1'), make([0.0, 1.0], content: 'b2')]
    FakeGptMaster.reply = lambda do |prompt|
      ids = prompt.scan(/id=(\d+)/).flatten.map(&:to_i)
      %({"merge":[{"ids":#{ids.inspect},"topic":"m","content":"merged"}],"delete":[]})
    end
    calls = 0
    KnowledgeBase.singleton_class.send(:alias_method, :__add, :add)
    KnowledgeBase.singleton_class.send(:define_method, :add) do |**kw|
      calls += 1
      raise ActiveRecord::StatementInvalid, 'SQLite3::BusyException: database is locked' if calls == 2
      __add(**kw)
    end
    begin
      assert_raises(ActiveRecord::StatementInvalid) { KnowledgeBase.review!(chat_id: CHAT) }
    ensure
      KnowledgeBase.singleton_class.send(:alias_method, :add, :__add)
      KnowledgeBase.singleton_class.send(:remove_method, :__add)
    end
    log = KnowledgeCompactLog.where(chat_id: CHAT).order(:id).last
    refute_nil log, 'the run log must be written even though the run raised'
    assert_equal 1, log.merged
    assert_equal 2, log.removed, 'the applied merge must be charged to the budget'
    applied = [first, second].find { |pair| pair.all? { |k| k.reload.deleted? } }
    refute_nil applied
    assert applied.all? { |k| k.reload.reviewed_at }, 'the fully resolved cluster is stamped'
  end

  def test_a_top_level_array_verdict_does_not_raise
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = '["merge", 1, 2]'
    stats = nil
    assert_silent { stats = run_review([[a.id, b.id]]) }
    assert_equal 1, stats[:parse_failures]
    refute a.reload.deleted?
  end

  # Same lock regression as extraction: the merged fact's embedding must be
  # computed before apply_merge opens its transaction.
  def test_merge_embeds_outside_any_transaction
    conn   = ActiveRecord::Base.connection
    depths = []
    EmbeddingService.singleton_class.send(:define_method, :embed) { |_t| depths << conn.open_transactions; [1.0, 0.0] }
    a = make([1.0, 0.0], content: 'a'); b = make([1.0, 0.0], content: 'b')
    FakeGptMaster.reply = %({"merge":[{"ids":[#{a.id},#{b.id}],"topic":"m","content":"merged"}],"delete":[]})
    baseline = conn.open_transactions

    assert_equal 1, run_review([[a.id, b.id]])[:merged]
    assert_equal [baseline], depths, 'the merged fact was embedded inside a transaction'

    ActiveRecord::Base.transaction { EmbeddingService.embed('probe') }   # negative control
    assert_equal baseline + 1, depths.last, 'detector cannot see an open transaction'
  end
end
