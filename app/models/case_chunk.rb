# frozen_string_literal: true

# Text chunk from a court case with embedding for semantic search
class CaseChunk < JurisprudenceRecord
  self.table_name = 'case_chunks'

  belongs_to :court_case, foreign_key: 'case_id'

  validates :chunk_text, presence: true
  validates :chunk_index, presence: true

  def embedding_vector
    return nil if embedding.blank?

    JSON.parse(embedding)
  end

  def embedding_vector=(vector)
    self.embedding = vector.to_json
  end
end
