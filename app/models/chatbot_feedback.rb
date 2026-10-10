# frozen_string_literal: true

class ChatbotFeedback < AnalyticsRecord
  belongs_to :user, optional: true

  # GDPR by design: NO question/answer text stored
  validates :feedback_type, presence: true, inclusion: { in: ChatbotMetadataVocabulary::FEEDBACK_TYPES }
  # WW-SEC-07: language and source are request values too.
  validate :metadata_in_vocabulary, on: :create

  scope :positive, -> { where(feedback_type: 'positive') }
  scope :negative, -> { where(feedback_type: 'negative') }
  scope :recent, -> { order(created_at: :desc) }

  def self.ensure_table_exists
    return if connection.table_exists?(:chatbot_feedbacks)

    connection.create_table :chatbot_feedbacks do |t|
      # question/answer columns intentionally omitted - GDPR by design
      t.string :feedback_type, null: false
      t.string :language, limit: 5
      t.string :source
      t.references :user, foreign_key: false, null: true
      t.string :ip_hash, limit: 64
      t.timestamps
    end
    connection.add_index :chatbot_feedbacks, :feedback_type
    connection.add_index :chatbot_feedbacks, :created_at
  end

  private

  def metadata_in_vocabulary
    { language: :language, source: :source }.each do |attribute, reader|
      value = self[attribute]
      next if value.nil?

      errors.add(attribute, :inclusion) unless ChatbotMetadataVocabulary.public_send(reader, value) == value
    end
  end
end
