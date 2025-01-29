class Message < ActiveRecord::Base
    belongs_to :user, foreign_key: 'user_uid', primary_key: 'uid'
end
