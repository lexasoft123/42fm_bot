class Phrase < ActiveRecord::Base
  validates :content, uniqueness: true
  belongs_to :user
end
