# frozen_string_literal: true

class DocumentNumberLookup < ReadonlyRecord
  validates :document_number, presence: true, uniqueness: true
  validates :numac, presence: true

  # Association to Content via content_id (per schema foreign key)
  belongs_to :content, optional: true

  # Method to get the language_id from associated content
  def content_language_id
    content&.language_id || 1 # Fallback to default language_id 1 if content not found
  end
end
