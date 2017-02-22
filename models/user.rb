class User < ActiveRecord::Base
  validates :uid, uniqueness: true

  def next_order
    return self.last_order + 10.minutes
  end

end
