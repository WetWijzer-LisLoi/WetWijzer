# frozen_string_literal: true

# Drains the transactional-email outbox (FBL-032). Bounded batch, per-entry
# rescue, structured counts, and a queue-lag warning when the oldest
# undelivered row is older than the alert threshold. Logs identify entries
# by user id and kind only - never address or token.
class EmailOutboxDrainJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 50
  LAG_WARN_SECONDS = 15 * 60

  def perform(batch_size: DEFAULT_BATCH_SIZE)
    return { skipped: 'table_missing' } unless EmailOutboxEntry.table_exists?

    result = { delivered: 0, retried: 0, failed_permanently: 0, superseded: 0 }

    EmailOutboxEntry.pending.order(:id).limit(batch_size).each do |entry|
      unless entry.deliverable?
        # The token was consumed or rotated (user confirmed, reset finished)
        # before delivery; nothing useful can be sent anymore.
        entry.record_success!
        result[:superseded] += 1
        next
      end

      begin
        entry.build_mail.deliver_now
        entry.record_success!
        result[:delivered] += 1
      rescue StandardError => e
        entry.record_failure!(e)
        entry.reload.failed_at ? result[:failed_permanently] += 1 : result[:retried] += 1
      end
    end

    lag = EmailOutboxEntry.oldest_pending_age_seconds
    result[:oldest_pending_seconds] = lag
    Rails.logger.info("[EmailOutbox] drain #{result.map { |k, v| "#{k}=#{v}" }.join(' ')}")
    Rails.logger.warn("[EmailOutbox] queue lag #{lag}s exceeds #{LAG_WARN_SECONDS}s") if lag > LAG_WARN_SECONDS
    result
  end
end
