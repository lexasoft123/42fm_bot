require 'active_record'
require 'yaml'

class DatabaseConnector
  class << self
    def establish_connection(logger: nil)
      ActiveRecord::Base.logger = nil

      configuration = YAML.load(IO.read('config/database.yml'))
      ActiveRecord::Base.establish_connection(configuration)
      ActiveRecord.default_timezone = :local
      register_editdist
    end

    def register_editdist
      ActiveRecord::Base.connection.raw_connection.create_function('editdist', 2) do |func, a, b|
        a = a.to_s.downcase
        b = b.to_s.downcase
        m, n = a.length, b.length
        d = Array.new(m + 1) { |i| i }
        (1..n).each do |j|
          prev = d[0]; d[0] = j
          (1..m).each do |i|
            temp = d[i]
            d[i] = b[j - 1] == a[i - 1] ? prev : [prev, d[i], d[i - 1]].min + 1
            prev = temp
          end
        end
        func.result = d[m]
      end
    end
  end
end
