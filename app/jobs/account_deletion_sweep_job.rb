# frozen_string_literal: true

# Daily unverified-account lifecycle and due-deletion purge (FBL-030).
# Before this job existed the sweep had no scheduler at all. The policy
# lives in Retention::AccountDeletionSweepService; erasure stays behind
# AccountErasureService's financial-work fences.
class AccountDeletionSweepJob < ApplicationJob
  queue_as :default

  def perform(batch_size: Retention::AccountDeletionSweepService::DEFAULT_BATCH_SIZE)
    result = Retention::AccountDeletionSweepService.call(batch_size: batch_size)
    summary = result.map { |key, value| "#{key}=#{value}" }.join(' ')
    Rails.logger.info("[RETENTION] account sweep #{summary}")
    Rails.logger.warn("[RETENTION] account sweep had #{result[:failed]} failure(s)") if result[:failed].positive?
    result
  end
end
