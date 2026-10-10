# frozen_string_literal: true

class SavedAnswer < AccountRecord
  belongs_to :user

  attribute :sources, :json

  validates :question, presence: true, length: { maximum: 1000 }
  validates :answer, presence: true, length: { maximum: 50_000 } # ~50KB max (typical chatbot answers are 2-5KB)
  validates :title, length: { maximum: 200 }
  validates :category, length: { maximum: 100 }
  validate :validate_sources

  # WW-SEC-16: bounds on what is stored, not on what the getter shows.
  SOURCES_MAX_BYTES = 100_000
  SOURCES_MAX_ENTRIES = 100
  SOURCE_ENTRY_MAX_BYTES = 4_000

  # Encrypt sensitive fields at rest (GDPR - user legal queries are PII)
  encrypts :question
  encrypts :answer

  scope :recent, -> { order(created_at: :desc) }
  scope :by_category, ->(cat) { where(category: cat) if cat.present? }

  def sources
    value = super
    value.is_a?(Array) ? value : []
  end

  def self.categories_for_user(user)
    where(user: user).distinct.pluck(:category).compact
  end

  private

  # WW-SEC-16: the raw stored value. The getter turns anything that is not a
  # list into [], and the old size check read the getter, so an oversized
  # object was stored unchecked while reading back as empty.
  def validate_sources
    raw = read_attribute(:sources)
    return if raw.nil?
    return errors.add(:sources, 'must be a list') unless raw.is_a?(Array)

    errors.add(:sources, "has more than #{SOURCES_MAX_ENTRIES} entries") if raw.size > SOURCES_MAX_ENTRIES
    errors.add(:sources, 'has an entry that is not a source') unless raw.all? { |entry| acceptable_source?(entry) }
    errors.add(:sources, 'is too large (maximum 100KB)') if raw.to_json.bytesize > SOURCES_MAX_BYTES
  end

  def acceptable_source?(entry)
    (entry.is_a?(Hash) || entry.is_a?(String)) && entry.to_json.bytesize <= SOURCE_ENTRY_MAX_BYTES
  end
end
