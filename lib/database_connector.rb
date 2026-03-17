require 'active_record'
require 'yaml'

class DatabaseConnector
  class << self
    def establish_connection(logger: nil)
      ActiveRecord::Base.logger = nil

      configuration = YAML.load(IO.read('config/database.yml'))
      ActiveRecord::Base.establish_connection(configuration)
      ActiveRecord::Base.default_timezone = :local
    end
  end
end
