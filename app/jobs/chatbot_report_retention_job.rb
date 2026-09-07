# frozen_string_literal: true

# Nightly 90-day chatbot-report retention (FBL-030). Thin wrapper: the
# policy lives in Retention::ChatbotReportRetentionService.
class ChatbotReportRetentionJob < ApplicationJob
  queue_as :default

  def perform(batch_size: Retention::ChatbotReportRetentionService::DEFAULT_BATCH_SIZE)
    result = Retention::ChatbotReportRetentionService.call(batch_size: batch_size)
    Rails.logger.info(
      "[RETENTION] chatbot reports deleted=#{result[:deleted]} batches=#{result[:batches]} " \
      "backlog=#{result[:backlog]} oldest_remaining=#{result[:oldest_remaining_created_at]}"
    )
    Rails.logger.warn('[RETENTION] chatbot report purge left a backlog') if result[:backlog]
    result
  end
end
