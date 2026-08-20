class KnowledgeSubject < ActiveRecord::Base
  belongs_to :knowledge

  scope :from_backfill, -> { where(source: 'backfill') }
  scope :from_extract,  -> { where(source: 'extract') }
end
