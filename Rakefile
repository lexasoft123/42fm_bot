require 'rubygems'
require 'bundler/setup'

require 'logger'
require 'sqlite3'
require 'active_record'
require 'yaml'

namespace :db do

  desc "Migrate the database (use VERSION=x if you want to specify a version)"
  task :migrate do
    ActiveRecord::Base.establish_connection(YAML.load(File.open('config/database.yml')))
    ActiveRecord::MigrationContext.new(File.join(__dir__, 'db/migrate')).migrate(ENV["VERSION"] ? ENV["VERSION"].to_i : nil)
  end

  desc "Rollback the database (use STEP=x to go back x steps)"
  task :rollback do
    ActiveRecord::Base.establish_connection(YAML.load(File.open('config/database.yml')))
    migration_context = ActiveRecord::MigrationContext.new(File.join(__dir__, 'db/migrate'))

    steps = ENV["STEP"] ? ENV["STEP"].to_i : 1
    migration_context.rollback(steps)
  end
end

namespace :knowledge do
  desc "Analyze pairwise similarity distribution and top near-pairs (CHAT_ID=optional, TOP=20)"
  task :analyze do
    require './config/boot'
    AppConfigurator.new.configure

    chat_ids = ENV['CHAT_ID'] ? [ENV['CHAT_ID'].to_i] : Knowledge.distinct.pluck(:chat_id)
    top_n    = ENV.fetch('TOP', '20').to_i

    cosine = ->(a, b) {
      dot    = a.zip(b).sum { |x, y| x * y }
      norm_a = Math.sqrt(a.sum { |x| x**2 })
      norm_b = Math.sqrt(b.sum { |x| x**2 })
      (norm_a.zero? || norm_b.zero?) ? 0.0 : dot / (norm_a * norm_b)
    }

    buckets = { '0.9+' => 0, '0.8-0.9' => 0, '0.7-0.8' => 0, '0.6-0.7' => 0, '0.5-0.6' => 0, '<0.5' => 0 }

    chat_ids.each do |cid|
      records = Knowledge.where(chat_id: cid).where("#{Knowledge::BLOB_PRESENT} OR embedding IS NOT NULL").to_a
      next if records.size < 2

      puts "\n=== chat #{cid}: #{records.size} entries ==="
      no_embedding = Knowledge.where(chat_id: cid).where(Knowledge::BLOB_MISSING).where(embedding: nil).count
      puts "  Entries without embedding: #{no_embedding}" if no_embedding > 0

      vecs  = records.map { |k| [k.id, k.embedding_vector] }.to_h
      pairs = []

      records.combination(2) do |a, b|
        sim = cosine.(vecs[a.id], vecs[b.id])
        pairs << [sim, a, b]
        if    sim >= 0.9  then buckets['0.9+']    += 1
        elsif sim >= 0.8  then buckets['0.8-0.9'] += 1
        elsif sim >= 0.7  then buckets['0.7-0.8'] += 1
        elsif sim >= 0.6  then buckets['0.6-0.7'] += 1
        elsif sim >= 0.5  then buckets['0.5-0.6'] += 1
        else                   buckets['<0.5']    += 1
        end
      end

      puts "  Similarity distribution (#{pairs.size} pairs):"
      buckets.each { |label, count| puts "    #{label}: #{count}" }
      buckets.transform_values! { 0 }

      puts "\n  Top #{top_n} most similar pairs:"
      pairs.sort_by { |sim, _| -sim }.first(top_n).each do |sim, a, b|
        puts "  [#{sim.round(4)}] ##{a.id}[#{a.topic}] vs ##{b.id}[#{b.topic}]"
        puts "    A: #{a.content.slice(0, 120)}"
        puts "    B: #{b.content.slice(0, 120)}"
      end
    end
  end

  desc "Backfill packed float32 embedding_blob from legacy JSON embedding (BATCH=200, CHAT_ID=optional)"
  task :pack_embeddings do
    require './config/boot'
    config = AppConfigurator.new
    config.configure
    LOGGER = config.logger unless defined?(LOGGER)

    batch = ENV.fetch('BATCH', '200').to_i
    # Resumable + idempotent by construction: the predicate shrinks as we go,
    # so re-running after a Ctrl-C converts exactly what remains, nothing twice.
    scope = Knowledge.unpacked_embeddings
    scope = scope.where(chat_id: ENV['CHAT_ID'].to_i) if ENV['CHAT_ID']

    total = scope.count
    puts "knowledge:pack_embeddings: #{total} row(s) to convert (batch=#{batch})"
    next if total.zero?

    done = 0
    skipped_ids = []
    t0 = Time.now

    loop do
      rows = scope.where.not(id: skipped_ids).reorder(:id).limit(batch).pluck(:id, :embedding)
      break if rows.empty?
      ActiveRecord::Base.transaction do
        rows.each do |id, json|
          vec = (JSON.parse(json) rescue nil)
          unless vec.is_a?(Array) && !vec.empty? && vec.all? { |v| v.is_a?(Numeric) }
            skipped_ids << id
            puts "  skip id=#{id}: unparseable embedding (left as JSON)"
            next
          end
          # update_all: skips the after_commit cache invalidation (7k pointless
          # rebuilds) and the AR object allocation. Safe -- the vector value is
          # unchanged, only its storage format.
          Knowledge.where(id: id).update_all(embedding_blob: vec.map(&:to_f).pack(Knowledge::PACK_FORMAT))
          done += 1
        end
      end
      pct = ((done + skipped_ids.size) * 100.0 / total).round(1)
      puts "  #{done + skipped_ids.size}/#{total} (#{pct}%) elapsed=#{(Time.now - t0).round}s"
    end
    puts "knowledge:pack_embeddings: done=#{done} skipped=#{skipped_ids.size} in #{(Time.now - t0).round}s"
    puts "  skipped ids: #{skipped_ids.inspect}" unless skipped_ids.empty?
  end

  desc "Verify embedding_blob matches the legacy JSON embedding (SAMPLE=200)"
  task :verify_embeddings do
    require './config/boot'
    AppConfigurator.new.configure

    sample = ENV.fetch('SAMPLE', '200').to_i
    rows = Knowledge.packed_embeddings
                    .order(Arel.sql('RANDOM()')).limit(sample).pluck(:id, :embedding_blob, :embedding)
    if rows.empty?
      puts "knowledge:verify_embeddings: no rows with both columns -- nothing to verify"
      next
    end

    bad = []
    rows.each do |id, blob, json|
      a = blob.unpack(Knowledge::PACK_FORMAT)
      b = JSON.parse(json)
      unless a.size == b.size && a.zip(b).all? { |x, y| (x - y).abs <= 1e-5 * [1.0, y.abs].max }
        bad << id
      end
    end
    puts "knowledge:verify_embeddings: checked #{rows.size} row(s)"
    if bad.empty?
      puts "  PASS"
    else
      puts "  FAIL: #{bad.size} mismatched row(s): #{bad.first(20).inspect}"
      exit 1
    end
  end

  desc "Rebuild legacy JSON embedding from embedding_blob (rollback path for migration 023)"
  task :unpack_embeddings do
    require './config/boot'
    AppConfigurator.new.configure

    scope = Knowledge.where(embedding: nil).where(Knowledge::BLOB_PRESENT)
    total = scope.count
    puts "knowledge:unpack_embeddings: #{total} row(s) to restore"
    next if total.zero?
    done = 0
    loop do
      rows = scope.reorder(:id).limit(500).pluck(:id, :embedding_blob)
      break if rows.empty?
      ActiveRecord::Base.transaction do
        rows.each do |id, blob|
          Knowledge.where(id: id).update_all(embedding: blob.unpack(Knowledge::PACK_FORMAT).to_json)
          done += 1
        end
      end
      puts "  #{done}/#{total}"
    end
    puts "knowledge:unpack_embeddings: restored #{done}"
  end

  desc "Null the legacy JSON embedding column for packed rows (BATCH=500) -- run AFTER verify_embeddings"
  task :drop_legacy_embeddings do
    require './config/boot'
    AppConfigurator.new.configure

    # Refuse while any row still has ONLY the legacy column. Those are exactly
    # the rows pack_embeddings skipped as unparseable; an unqualified
    # `update_all(embedding: nil)` would destroy their only embedding.
    unconverted = Knowledge.unpacked_embeddings
    if (n = unconverted.count) > 0
      puts "REFUSING: #{n} row(s) still have embedding but no embedding_blob."
      puts "  ids: #{unconverted.limit(20).pluck(:id).inspect}"
      puts "  Run `rake knowledge:pack_embeddings` first (these were skipped as unparseable)."
      exit 1
    end
    if Knowledge.dual_write_legacy?
      puts "REFUSING: knowledge.dual_write_legacy is still true -- new rows would immediately"
      puts "  repopulate the column. Set it to false in config/settings.yml and restart first."
      exit 1
    end

    batch = ENV.fetch('BATCH', '500').to_i
    scope = Knowledge.packed_embeddings
    total = scope.count
    puts "knowledge:drop_legacy_embeddings: clearing #{total} row(s)"
    next if total.zero?
    done = 0
    while (ids = scope.reorder(:id).limit(batch).pluck(:id)).any?
      Knowledge.where(id: ids).update_all(embedding: nil)
      done += ids.size
      puts "  #{done}/#{total}"
    end
    puts "knowledge:drop_legacy_embeddings: cleared #{done}"
    puts "NOTE: SQLite does not shrink the file. To reclaim the space: stop the bot, then"
    puts "  sqlite3 db/bot.db 'VACUUM;'   (needs ~2x the db size in free disk)"
  end

  desc "Populate knowledge_subjects from the curated alias map (CHAT_ID=, DRY_RUN=1)"
  task :backfill_subjects do
    require './config/boot'
    config = AppConfigurator.new
    config.configure
    LOGGER = config.logger unless defined?(LOGGER)

    aliases = (Settings.knowledge['subject_aliases'] rescue nil)
    if aliases.nil? || aliases.empty?
      puts "knowledge.subject_aliases is not configured."
      puts "It maps Telegram uids to the names people are called by in chat, which is"
      puts "personal data about a private community -- it belongs in the GITIGNORED"
      puts "config/settings.yml, never in this repo (which is public). Shape:"
      puts
      puts "  knowledge:"
      puts "    subject_aliases:"
      puts "      123456789: ['nanomechanic']"
      puts "      987654321: ['vitalif', '\\\\bВитали\\\\w*', 'На Заборе']"
      puts
      puts "Each value is a list of case-insensitive regex sources. Match handles and"
      puts "distinctive given-name stems; NEVER match a bare first name that several"
      puts "people share -- that collapses them into one bucket and the centroid then"
      puts "produces confident, wrong clusters."
      exit 1
    end

    dry      = ENV['DRY_RUN'] == '1'
    chat_ids = ENV['CHAT_ID'] ? [ENV['CHAT_ID'].to_i] : Knowledge.live.distinct.pluck(:chat_id)
    compiled = aliases.to_h { |uid, pats| [uid.to_i, pats.map { |p| Regexp.new(p, Regexp::IGNORECASE) }] }

    chat_ids.each do |cid|
      rows = Knowledge.live.where(chat_id: cid).pluck(:id, :content)
      next if rows.empty?
      hits = Hash.new { |h, k| h[k] = [] }
      rows.each do |id, content|
        compiled.each { |uid, res| hits[uid] << id if res.any? { |re| content.to_s =~ re } }
      end
      covered = hits.values.flatten.uniq.size
      puts "\nchat #{cid}: #{rows.size} live facts, #{covered} with >=1 subject (#{(100.0 * covered / rows.size).round(1)}%)"
      hits.sort_by { |_, ids| -ids.size }.each do |uid, ids|
        sample = rows.find { |id, _| id == ids.first }&.last.to_s[0, 90]
        puts "  uid=#{uid.to_s.ljust(12)} #{ids.size.to_s.rjust(5)} facts   e.g. #{sample}"
      end
      next if dry

      # Delete and re-derive only OUR rows: fixing a wrong alias on a second
      # pass must remove the wrong rows the first pass created, not just add
      # correct ones alongside them.
      ids = rows.map(&:first)
      KnowledgeSubject.from_backfill.where(knowledge_id: ids).delete_all
      hits.each do |uid, fact_ids|
        fact_ids.each_slice(500) do |slice|
          rowvals = slice.map { |kid| { knowledge_id: kid, uid: uid, source: 'backfill' } }
          KnowledgeSubject.insert_all(rowvals, unique_by: %i[knowledge_id uid])
        end
      end
      puts "  wrote #{hits.values.flatten.size} subject rows"
    end
    puts "\n(dry run -- nothing written)" if dry
  end

  desc "Preview dedup candidate clusters -- no LLM, no writes (CHAT_ID=, SUBJECT_THRESHOLD=, THRESHOLD=, SHOW=8)"
  task :cluster_preview do
    require './config/boot'
    config = AppConfigurator.new
    config.configure
    LOGGER = config.logger unless defined?(LOGGER)

    cid  = (ENV['CHAT_ID'] || Knowledge.live.group(:chat_id).order('count_id desc').limit(1).count(:id).keys.first).to_i
    cfg  = (Settings.knowledge || {}).dup
    cfg['subject_threshold'] = ENV['SUBJECT_THRESHOLD'].to_f if ENV['SUBJECT_THRESHOLD']
    cfg['compact_threshold'] = ENV['THRESHOLD'].to_f         if ENV['THRESHOLD']

    entry   = EmbeddingCache.fetch(cid)
    buckets = KnowledgeBase.send(:subject_buckets, cid)
    params  = KnowledgeBase.send(:cluster_params, cfg)
    puts "chat #{cid}: #{entry.ids.size} live facts, #{buckets.size} subject buckets " \
         "(>= #{params.subject_min_facts} facts: #{buckets.count { |_, v| v.size >= params.subject_min_facts }})"
    puts "G1 threshold=#{params.threshold} / G2 subject_threshold=#{params.subject_threshold} / max_cluster=#{params.max_cluster}"

    norms = KnowledgeBase::Cluster.residual_norms(entry, buckets, params)
    unless norms.empty?
      sorted = norms.sort
      pct = ->(q) { sorted[(sorted.size * q).floor.clamp(0, sorted.size - 1)].round(4) }
      puts "\nresidual norms across qualifying buckets (n=#{norms.size}) -- pick subject_min_residual from here:"
      puts "  min=#{sorted.first.round(4)} p10=#{pct.(0.10)} p25=#{pct.(0.25)} median=#{pct.(0.50)} " \
           "p75=#{pct.(0.75)} p90=#{pct.(0.90)} max=#{sorted.last.round(4)}"
      puts "  below current subject_min_residual (#{params.subject_min_residual}): " \
           "#{norms.count { |n| n < params.subject_min_residual }}"
    end

    claimed = {}
    g2 = KnowledgeBase::Cluster.subject_clusters(entry, buckets, params, claimed)
    g1 = KnowledgeBase::Cluster.seed_and_absorb(entry.matrix, entry.ids, params.threshold,
                                                params.min_pairwise, params.max_cluster, claimed)
    all = g2 + g1
    if all.empty?
      puts "no candidate clusters at these thresholds"
      next
    end
    hist = all.map(&:size).tally.sort
    puts "\nG2 subject: #{g2.size} clusters / #{g2.sum(&:size)} facts"
    puts "G1 global:  #{g1.size} clusters / #{g1.sum(&:size)} facts"
    puts "size histogram: #{hist.map { |sz, n| "#{sz}:#{n}" }.join(' ')}"
    puts "max reclaim if EVERY cluster merged: #{all.sum(&:size) - all.size} facts " \
         "(the judge is expected to refuse a large share of these)"

    by_id = Knowledge.where(id: all.flatten).pluck(:id, :content).to_h
    show  = (ENV['SHOW'] || '8').to_i
    puts "\n=== #{show} random clusters (sample for precision) ==="
    all.sample(show).each do |c|
      puts "-- #{c.size} facts:"
      c.each { |id| puts "   ##{id} #{by_id[id].to_s[0, 150]}" }
    end
  end

  desc "Run the LLM dedup review (CHAT_ID=, DRY_RUN=1, MAX_CHUNKS=)"
  task :review do
    require './config/boot'
    config = AppConfigurator.new
    config.configure
    LOGGER = config.logger unless defined?(LOGGER)

    dry        = ENV['DRY_RUN'] == '1'
    max_chunks = ENV['MAX_CHUNKS']&.to_i
    chat_ids   = ENV['CHAT_ID'] ? [ENV['CHAT_ID'].to_i] : Knowledge.live.distinct.pluck(:chat_id)
    chat_ids.each do |cid|
      before = Knowledge.live.where(chat_id: cid).count
      stats  = KnowledgeBase.review!(chat_id: cid, dry_run: dry, max_chunks: max_chunks)
      if dry
        puts "chat #{cid}: judged #{stats[:chunks]} cluster(s) -> WOULD merge #{stats[:would_merge]}, " \
             "remove #{stats[:would_remove]} fact(s); #{stats[:parse_failures]} unparseable"
      else
        puts "chat #{cid}: #{stats} (live #{before} -> #{Knowledge.live.where(chat_id: cid).count})"
      end
    end
    puts "(dry run -- nothing written)" if dry
    puts "NOTE: restart the bot to pick these changes up (its embedding cache is per-process)." unless dry
  end

  desc "Hard-delete soft-deleted facts older than knowledge.review.purge_after_days"
  task :purge_deleted do
    require './config/boot'
    AppConfigurator.new.configure

    days   = ((Settings.knowledge['review'] rescue nil) || {}).fetch('purge_after_days', 30)
    cutoff = Time.now - days * 86_400

    # Merge sources are the only way to undo a bad merge, so protect the ones
    # whose replacement is still young enough for rollback_merges to reach.
    # Per-fact, NOT an all-or-nothing refusal: once the sweep runs daily there
    # is always some recent merge, and an all-or-nothing guard would mean
    # tombstones are never purged and the table grows forever.
    protected_ids = Knowledge.where('merged_from IS NOT NULL AND created_at >= ?', cutoff)
                             .flat_map(&:merged_from_ids).uniq
    scope = Knowledge.deleted.where('deleted_at < ?', cutoff)
    scope = scope.where.not(id: protected_ids) if protected_ids.any?

    n = scope.count
    puts "knowledge:purge_deleted: hard-deleting #{n} fact(s) soft-deleted before #{cutoff.utc}"
    puts "  (protecting #{protected_ids.size} source(s) of merges still within the rollback window)" if protected_ids.any?
    scope.find_each(&:destroy)
    puts "done"
  end

  desc "Undo review merges made since a timestamp (SINCE='YYYY-MM-DD HH:MM:SS') -- run BEFORE reverting Deploy 2"
  task :rollback_merges do
    require './config/boot'
    AppConfigurator.new.configure

    unless ENV['SINCE']
      puts "SINCE is required, e.g. SINCE='2026-08-20 00:00:00' (UTC)"
      exit 1
    end
    since  = Time.parse(ENV['SINCE'])
    merged = Knowledge.where('merged_from IS NOT NULL AND created_at >= ?', since).to_a
    puts "knowledge:rollback_merges: #{merged.size} merged fact(s) since #{since.utc}"
    restored = 0
    merged.each do |k|
      ids = k.merged_from_ids
      restored += Knowledge.deleted.where(id: ids, deleted_reason: 'merged').count
      # 'admin' deletions were deliberate and stay deleted.
      Knowledge.deleted.where(id: ids, deleted_reason: 'merged').find_each(&:restore!)
      k.destroy
    end
    puts "restored #{restored} source fact(s), removed #{merged.size} merged fact(s)"
    puts "NOTE: restart the bot; then it is safe to revert the code."
  end

  desc "Deprecated alias for knowledge:review"
  task :compact do
    puts "knowledge:compact was replaced by knowledge:review -- compaction and the"
    puts "dedup sweep were collapsed into one pipeline so there is a single deleting"
    puts "actor, one deletion budget and one audit trail. Run:"
    puts "  rake knowledge:review [CHAT_ID=...] [DRY_RUN=1]"
    exit 1
  end
end

namespace :scratchpad do
  desc "Compact scratchpads: prune expired + old entries (MAX_AGE_DAYS=30, CHAT_ID=optional)"
  task :compact do
    require './config/boot'
    AppConfigurator.new.configure

    max_age = ENV.fetch('MAX_AGE_DAYS', '30').to_i
    scope   = ENV['CHAT_ID'] ? [ENV['CHAT_ID'].to_i] : ChatState.pluck(:chat_id)

    scope.each do |cid|
      stats = Agent::Scratchpad.compact(cid, max_age_days: max_age)
      puts "chat #{cid}: removed=#{stats[:removed]} kept=#{stats[:kept]}"
    end
  end
end

namespace :chats do
  desc "Populate chats table from Settings.auth.chats and authorize them"
  task :sync do
    require './config/boot'
    AppConfigurator.new.configure

    n = Chat.sync_from_config!
    puts "Synced #{n} chats from Settings.auth.chats"
    Chat.where(authorized: true).order(:chat_id).each do |c|
      puts "  authorized: #{c.chat_id} #{c.title.inspect} audio=#{c.audio}"
    end
    unauthed = Chat.where(authorized: false).count
    puts "  (also tracked: #{unauthed} unauthorized chat#{unauthed == 1 ? '' : 's'})" if unauthed > 0
  end

  desc "List all chats with auth status, last_seen and message counts"
  task :list do
    require './config/boot'
    AppConfigurator.new.configure

    Chat.order(:chat_id).each do |c|
      auth = c.authorized? ? 'auth' : 'NOAUTH'
      msgs = c.messages.count
      puts "#{c.chat_id.to_s.rjust(15)} [#{auth}] type=#{c.chat_type} audio=#{c.audio} msgs=#{msgs} last=#{c.last_seen_at} #{c.title.inspect}"
    end
  end
end

namespace :music do
  desc "Scan music library and populate songs database"
  task :scan do
    require './config/boot'
    config = AppConfigurator.new
    config.configure

    scanner = MusicScanner.new
    stats = scanner.scan
    puts "Scan complete: #{stats}"
  end
end
