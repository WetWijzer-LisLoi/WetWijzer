# frozen_string_literal: true

module Retention
  # Purges chatbot reports past ChatbotReport::RETENTION_PERIOD (90 days,
  # unchanged - the period is the legal owner's).
  #
  # FBL-030: this used to run only inside Admin::ChatbotReportsController#index,
  # so retention depended on somebody opening an admin page. It is idempotent,
  # deletes in bounded batches (SQLite has no DELETE..LIMIT through Active
  # Record, hence pluck-then-delete), and reports counts plus the oldest
  # remaining timestamp - never report contents, which are encrypted PII.
  class ChatbotReportRetentionService
    DEFAULT_BATCH_SIZE = 1_000
    MAX_BATCHES = 100 # backstop: one run never deletes more than 100k rows

    def self.call(batch_size: DEFAULT_BATCH_SIZE)
      new(batch_size: batch_size).call
    end

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = Integer(batch_size)
      raise ArgumentError, 'batch_size must be positive' unless @batch_size.positive?
    end

    def call
      ChatbotReport.ensure_table_exists
      deleted = 0
      batches = 0
      while batches < MAX_BATCHES
        ids = ChatbotReport.stale.limit(@batch_size).pluck(:id)
        break if ids.empty?

        deleted += ChatbotReport.where(id: ids).delete_all
        batches += 1
      end

      {
        deleted: deleted,
        batches: batches,
        backlog: ChatbotReport.stale.exists?,
        oldest_remaining_created_at: ChatbotReport.minimum(:created_at),
        retention_days: (ChatbotReport::RETENTION_PERIOD / 1.day).to_i
      }
    end
  end
end
