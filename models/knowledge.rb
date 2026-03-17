class Knowledge < ActiveRecord::Base
  self.table_name = 'knowledge'
  def embedding_vector
    return nil unless embedding
    JSON.parse(embedding)
  end

  def embedding_vector=(vec)
    self.embedding = vec.to_json
  end
end
