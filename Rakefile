require 'rubygems'
require 'bundler/setup'

require 'sqlite3'
require 'active_record'
require 'yaml'

namespace :db do

  desc "Migrate the database (use VERSION=x if you want to specify a version)"
  task :migrate do
    ActiveRecord::Base.establish_connection(YAML.load(File.open('config/database.yml')))
    ActiveRecord::MigrationContext.new(File.join(__dir__, 'db/migrate'), ActiveRecord::SchemaMigration).migrate(ENV["VERSION"] ? ENV["VERSION"].to_i : nil)
  end

  desc "Rollback the database (use STEP=x to go back x steps)"
  task :rollback do
    ActiveRecord::Base.establish_connection(YAML.load(File.open('config/database.yml')))
    migration_context = ActiveRecord::MigrationContext.new(File.join(__dir__, 'db/migrate'), ActiveRecord::SchemaMigration)
    
    steps = ENV["STEP"] ? ENV["STEP"].to_i : 1
    migration_context.rollback(steps)
  end
end
