# frozen_string_literal: true

class UsageLog < AnalyticsRecord
  # Renamed from PartnerUsageLog on 2026-08-08: this was never partner-specific -
  # it backs WetWijzer\'s own billing. The TABLE keeps its original name so the
  # rename needs no migration and touches no data.

  belongs_to :user

  attribute :sources, :json

  validates :app, presence: true
  validates :question, presence: true

  # Encrypt sensitive fields at rest (GDPR - user legal queries are PII)
  encrypts :question
  encrypts :answer

  scope :recent, -> { order(created_at: :desc) }

  def sources
    value = super
    value.is_a?(Array) ? value : []
  end

  def self.log_usage!(user:, app:, question:, answer:, sources:, credits_used: 1)
    create!(
      user: user,
      app: app,
      question: question,
      answer: answer,
      sources: sources,
      credits_used: credits_used
    )
  end
end
