# frozen_string_literal: true

class SavedAnswer < AccountRecord
  belongs_to :user

  validates :question, presence: true, length: { maximum: 1000 }
  validates :answer, presence: true, length: { maximum: 50_000 } # ~50KB max (typical chatbot answers are 2-5KB)
  validate :validate_sources_size

  # Encrypt sensitive fields at rest (GDPR - user legal queries are PII)
  encrypts :question
  encrypts :answer

  scope :recent, -> { order(created_at: :desc) }
  scope :by_category, ->(cat) { where(category: cat) if cat.present? }

  def self.categories_for_user(user)
    where(user: user).distinct.pluck(:category).compact
  end

  private

  # Prevent abuse via oversized sources payloads
  def validate_sources_size
    return unless sources.present?

    serialized = sources.is_a?(String) ? sources : sources.to_json
    return unless serialized.bytesize > 100_000 # 100KB max for sources JSON

    errors.add(:sources, 'is too large (maximum 100KB)')
  end
end
