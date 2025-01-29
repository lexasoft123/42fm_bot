class User < ActiveRecord::Base
  validates :uid, uniqueness: true
  has_many :messages, foreign_key: 'user_uid', primary_key: 'uid'

  def next_order
    return self.last_order + 2.minutes
  end

end
