# frozen_string_literal: true

class ChatbotFeedback < ApplicationRecord
  belongs_to :user, optional: true

  validates :question, presence: true
  validates :answer, presence: true
  validates :feedback_type, presence: true, inclusion: { in: %w[positive negative] }

  scope :positive, -> { where(feedback_type: 'positive') }
  scope :negative, -> { where(feedback_type: 'negative') }
  scope :recent, -> { order(created_at: :desc) }

  def self.ensure_table_exists
    return if connection.table_exists?(:chatbot_feedbacks)
    
    connection.create_table :chatbot_feedbacks do |t|
      t.text :question, null: false
      t.text :answer, null: false
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
end
