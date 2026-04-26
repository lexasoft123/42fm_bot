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
      records = Knowledge.where(chat_id: cid).where.not(embedding: nil).to_a
      next if records.size < 2

      puts "\n=== chat #{cid}: #{records.size} entries ==="
      no_embedding = Knowledge.where(chat_id: cid).where(embedding: nil).count
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

  desc "Merge near-duplicate knowledge entries via LLM (THRESHOLD=0.85, CHAT_ID=optional)"
  task :compact do
    require './config/boot'
    config = AppConfigurator.new
    config.configure
    LOGGER = config.logger

    threshold = ENV['THRESHOLD'] ? ENV['THRESHOLD'].to_f : (Settings.knowledge['compact_threshold'] || 0.85)
    chat_ids  = ENV['CHAT_ID'] ? [ENV['CHAT_ID'].to_i] : Knowledge.distinct.pluck(:chat_id)

    chat_ids.each do |cid|
      before = Knowledge.where(chat_id: cid).count
      stats  = KnowledgeBase.compact!(chat_id: cid, threshold: threshold)
      puts "chat #{cid}: #{stats[:merged]} clusters merged, #{stats[:removed]} removed (#{before} → #{stats[:kept]})"
    end
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
