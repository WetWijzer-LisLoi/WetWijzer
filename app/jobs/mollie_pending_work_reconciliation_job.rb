# frozen_string_literal: true

# Re-enqueues durable Mollie work whose original post-commit enqueue was lost
# or whose worker stopped after taking a processing lease. Each work type has
# its own bounded batch so one backlog cannot starve the others.
class MolliePendingWorkReconciliationJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 50
  MAX_BATCH_SIZE = 200

  class EnqueueError < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super("Mollie pending-work reconciliation failed to enqueue #{result.fetch(:failed)} item(s)")
    end
  end

  def perform(batch_size: DEFAULT_BATCH_SIZE)
    batch_size = validated_batch_size(batch_size)
    result = {
      provisioning: 0,
      invoices: 0,
      adjustments: 0,
      cancellations: 0,
      chargeback_confirmations: 0,
      notifications: 0,
      failed: 0
    }

    scopes = MolliePendingWorkRecoveryScopes.new
    [
      [:provisioning, scopes.provisioning, MollieSubscriptionProvisionJob],
      [:invoices, scopes.invoices, MollieInvoiceJob],
      [:adjustments, scopes.adjustments, MolliePaymentAdjustmentJob],
      [:chargeback_confirmations, scopes.chargeback_confirmations, MollieChargebackReversalConfirmationJob],
      [:notifications, scopes.notifications, MolliePaymentFailureNotificationJob]
    ].each do |kind, scope, job_class|
      enqueue_batch(kind, scope, job_class, batch_size, result)
    end
    enqueue_cancellations(scopes.cancellations, batch_size, result)

    Rails.logger.info(
      "[Mollie Recovery] enqueued provisioning=#{result[:provisioning]} " \
      "invoices=#{result[:invoices]} adjustments=#{result[:adjustments]} " \
      "cancellations=#{result[:cancellations]} " \
      "chargeback_confirmations=#{result[:chargeback_confirmations]} " \
      "notifications=#{result[:notifications]} failures=#{result[:failed]}"
    )
    raise EnqueueError, result if result[:failed].positive?

    result
  end

  private

  def enqueue_batch(kind, scope, job_class, batch_size, result)
    scope.reorder(updated_at: :asc, id: :asc).limit(batch_size).each do |record|
      job_class.perform_later(record)
      result[kind] += 1
    rescue StandardError => e
      result[:failed] += 1
      Rails.logger.error(
        "[Mollie Recovery] #{kind} id=#{record.id} enqueue failed: #{e.class}"
      )
    end
  end

  def enqueue_cancellations(scope, batch_size, result)
    scope.reorder(updated_at: :asc, id: :asc).limit(batch_size).each do |payment|
      subscription = payment.subscription
      next unless subscription

      MollieSubscriptionCancellationJob.perform_later(
        subscription,
        expected_mollie_subscription_id: subscription.mollie_subscription_id,
        expected_first_payment_id: subscription.mollie_first_payment_id,
        expected_payment_id: payment.id
      )
      result[:cancellations] += 1
    rescue StandardError => e
      result[:failed] += 1
      Rails.logger.error(
        "[Mollie Recovery] cancellations id=#{payment.id} enqueue failed: #{e.class}"
      )
    end
  end

  def validated_batch_size(value)
    size = Integer(value)
    return size if size.between?(1, MAX_BATCH_SIZE)

    raise ArgumentError, "batch_size must be between 1 and #{MAX_BATCH_SIZE}"
  rescue TypeError, ArgumentError
    raise ArgumentError, "batch_size must be between 1 and #{MAX_BATCH_SIZE}"
  end
end
