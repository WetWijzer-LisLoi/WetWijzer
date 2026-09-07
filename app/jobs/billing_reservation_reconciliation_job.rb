# frozen_string_literal: true

# Repairs abandoned billing reservations for users who never make another
# request. Work is globally bounded; any backlog is continued by the next run.
class BillingReservationReconciliationJob < ApplicationJob
  queue_as :default

  def perform(limit = BillingReservation::GLOBAL_RECONCILIATION_BATCH_SIZE)
    result = BillingReservation.reconcile_stale!(limit: limit)
    if result[:backlog]
      Rails.logger.warn(
        "Stale billing reservation backlog remains " \
        "(selected=#{result[:selected]}, failed=#{result[:failed]})"
      )
    end
    result
  end
end
