require 'minitest/autorun'
require 'logger'
require 'active_record'
require 'sqlite3'
require 'translit'
require 'json'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = nil

module Settings
  @radio = { 'path' => '/music', 'host_path' => nil }
  def self.radio; @radio; end
  def self.radio=(v); @radio = v; end
end

ActiveRecord::MigrationContext.new(
  File.expand_path('../db/migrate', __dir__),
  ActiveRecord::SchemaMigration
).migrate

Dir[File.expand_path('../models/*.rb', __dir__)].sort.each { |f| require f }
Dir[File.expand_path('fixtures/*.rb', __dir__)].sort.each  { |f| require f }

class BotTest < Minitest::Test
  def setup
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
  end
end
