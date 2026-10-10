# frozen_string_literal: true

# Re-enqueues durable Mollie work whose original post-commit enqueue was lost
# or whose worker stopped after taking a processing lease. Each work type has
# its own bounded batch so one backlog cannot starve the others.
class MolliePendingWorkReconciliationJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 50
  MAX_BATCH_SIZE = 200
  MAX_REPORTED_FAILURES = 10

  # The only work this job does is insert one queue row per eligible record, so
  # what it can fail on is database-side and clears on its own. Anything else
  # (a serialization error, a missing constant) is a defect a retry cannot fix.
  TRANSIENT_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::LockWaitTimeout,
                      ActiveRecord::Deadlocked, ActiveRecord::QueryCanceled].freeze

  class EnqueueError < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      summary = "Mollie pending-work reconciliation failed to enqueue #{result.fetch(:failed)} item(s)"
      details = MolliePendingWorkReconciliationJob.reported_failures(result[:failures], MAX_REPORTED_FAILURES)
      super(details.empty? ? summary : "#{summary}: #{details}")
    end
  end

  # Every enqueue failed for a reason a later attempt can clear. Retrying
  # re-reads every scope and re-enqueues what the failed attempt already
  # enqueued, which is safe and is already the steady state: this job runs
  # every five minutes and an item stays eligible until its work completes.
  # Each job it enqueues takes an atomic claim before acting - claim! in
  # MollieInvoiceJob, MolliePaymentAdjustmentJob and
  # MolliePaymentFailureNotificationJob, claim_provisioning! in
  # MollieSubscriptionProvisionJob - while MollieSubscriptionCancellationJob
  # and MollieChargebackReversalConfirmationJob re-read and return when the
  # state they were enqueued for has moved. A duplicate copy therefore cannot
  # invoice, charge, refund, grant credit or cancel a second time. Retrying
  # only DELAYS the alarm: a spent chain still lands in
  # solid_queue_failed_executions.
  class TransientEnqueueError < EnqueueError; end

  retry_on TransientEnqueueError, wait: :polynomially_longer, attempts: 5

  def perform(batch_size: DEFAULT_BATCH_SIZE)
    batch_size = validated_batch_size(batch_size)
    result = {
      provisioning: 0,
      invoices: 0,
      adjustments: 0,
      cancellations: 0,
      chargeback_confirmations: 0,
      notifications: 0,
      failed: 0,
      transient_failures: 0,
      failures: []
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
      "notifications=#{result[:notifications]} failures=#{result[:failed]} " \
      "transient=#{result[:transient_failures]}" \
      "#{" [#{self.class.reported_failures(result[:failures], MAX_REPORTED_FAILURES)}]" if result[:failed].positive?}"
    )
    raise failure_class(result), result if result[:failed].positive?

    result
  end

  private

  # One enqueue that no later attempt can place is enough to refuse the run.
  def failure_class(result)
    result[:failed] == result[:transient_failures] ? TransientEnqueueError : EnqueueError
  end

  # The detail is stored in the durable failure record, so it carries this
  # application's own identifiers only: a work kind, a local integer id and an
  # error class name. No provider id, no message, no row content.
  def record_failure(kind, id, error, result)
    transient = TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) }
    result[:failed] += 1
    result[:transient_failures] += 1 if transient
    detail = "#{transient ? 'transient' : 'permanent'} #{kind} id=#{id} #{error.class}"
    result[:failures] << detail
    Rails.logger.error("[Mollie Recovery] enqueue failed: #{detail}")
  end

  def enqueue_batch(kind, scope, job_class, batch_size, result)
    scope.reorder(updated_at: :asc, id: :asc).limit(batch_size).each do |record|
      job_class.perform_later(record)
      result[kind] += 1
    rescue StandardError => e
      record_failure(kind, record.id, e, result)
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
      record_failure(:cancellations, payment.id, e, result)
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
