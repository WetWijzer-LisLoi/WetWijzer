# frozen_string_literal: true

# ChatbotReport stores user-reported failed chatbot answers.
#
# GDPR NOTE: Unlike ChatbotFeedback and ChatbotAnalytic, this model DOES store
# the question and answer text. This is an intentional, user-initiated exception
# to the architectural privacy guarantee. The user must explicitly consent via
# a confirm dialog that warns them their question will become visible to the admin.
#
# Reports auto-purge after 90 days to minimize data retention.
class ChatbotReport < AnalyticsRecord
  belongs_to :user, optional: true

  validates :question, presence: true
  validates :status, inclusion: { in: %w[pending reviewed resolved] }

  # Encrypt sensitive fields at rest (GDPR - user legal queries are PII)
  encrypts :question
  encrypts :answer

  # Retention window for GDPR auto-purge (see purge_stale!)
  RETENTION_PERIOD = 90.days

  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }
  scope :stale, -> { where(created_at: ...RETENTION_PERIOD.ago) }

  # Self-migrating table creation (consistent with ChatbotFeedback pattern)
  def self.ensure_table_exists
    return if connection.table_exists?(:chatbot_reports)

    connection.create_table :chatbot_reports do |t|
      # Question and answer stored WITH explicit user consent only
      t.text :question, null: false
      t.text :answer
      t.string :language, limit: 5
      t.string :source
      t.string :intelligence
      t.references :user, foreign_key: false, null: true
      t.bigint :analytic_id
      t.string :status, null: false, default: 'pending'
      t.text :admin_notes
      t.timestamps
    end
    connection.add_index :chatbot_reports, :status unless connection.index_exists?(:chatbot_reports, :status)
    connection.add_index :chatbot_reports, :created_at unless connection.index_exists?(:chatbot_reports, :created_at)
    connection.add_index :chatbot_reports, :user_id unless connection.index_exists?(:chatbot_reports, :user_id)
  end

  # Auto-purge reports older than 90 days (GDPR data minimization)
  def self.purge_stale!
    stale.delete_all
  end
end
