# frozen_string_literal: true

# Polls a bounded, rotating slice of locally-known Mollie resources. Webhooks
# remain the primary update path; this job repairs missed callbacks without an
# unbounded provider scan or reusing updated_at as a reconciliation cursor
# (updated_at is already the durable invoice-processing lease).
class MollieProviderReconciliationJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 25
  MAX_BATCH_SIZE = 100
  ROTATION_PERIOD = 15.minutes
  PAYMENT_CHANGE_FIELDS = %w[status fulfilled_at refunded_amount_cents charged_back_amount_cents
                             chargeback_reversal_candidate_cents failure_notification_enqueued_at].freeze

  # Errors that mean "the provider or the database was momentarily out of
  # reach", not "this row cannot be reconciled". Same split the Mollie webhook
  # controller makes; an ApiError counts as transient only when the client
  # itself calls it retryable (429 or 5xx).
  TRANSIENT_ERRORS = [MolliePaymentProcessor::TransientError, MollieApiClient::NetworkError,
                      MollieApiClient::InvalidResponseError, ActiveRecord::ConnectionNotEstablished,
                      ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::QueryCanceled].freeze

  # A recorded failure is stored in the durable job failure record and in the
  # log, so it must never carry a provider payload or customer data. Only this
  # application's own error classes are quoted: their messages are built from
  # literals plus field/metadata KEY names, never from a value. Everything else
  # contributes its class name alone.
  SAFE_MESSAGE_ERRORS = [MollieApiClient::Error, MolliePaymentProcessor::VerificationError,
                         MolliePaymentProcessor::TransientError, MollieConfiguration::ConfigurationError].freeze
  MAX_FAILURE_MESSAGE = 120
  MAX_REPORTED_FAILURES = 10

  # MolliePaymentProcessor::TransientError covers two unlike things. Most of
  # its raise sites are races a later attempt clears on its own: a checkout
  # intent still being committed, a renewal that overtook its subscription
  # write, a compare-and-swap on a cumulative total that lost. These three fire
  # when an associated row is simply NOT THERE (app/services/
  # mollie_payment_processor.rb fulfill_credit_purchase!,
  # fulfill_subscription_initial!, fulfill_subscription_renewal!). This job
  # re-reads the SAME rotating slice every cycle, so such an item would burn
  # five attempts on every run and never clear. Recorded as permanent instead,
  # which refuses the run at once and names the row for a human.
  #
  # The match is on the message because the processor raises one class for
  # both meanings. Those messages are frozen literals; a test asserts each one
  # is still present verbatim at a raise site, so a reword cannot rot this
  # silently.
  PERMANENT_PROCESSOR_FAILURES = ['credit purchase is not available', 'subscription is not available'].freeze

  class ReconciliationError < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      summary = "Mollie provider reconciliation failed for #{result.fetch(:failed)} item(s)"
      details = MollieProviderReconciliationJob.reported_failures(result[:failures], MAX_REPORTED_FAILURES)
      super(details.empty? ? summary : "#{summary}: #{details}")
    end
  end

  # Every item failed for a reason a later run can clear on its own. Retried
  # with backoff instead of failing the job outright: the job re-reads the same
  # bounded slice every cycle, so one refused provider read is repaired by the
  # next attempt. Retrying only DELAYS the alarm - once the attempts are spent
  # the job still lands in solid_queue_failed_executions, so a real outage is
  # still reported.
  class TransientReconciliationError < ReconciliationError; end

  retry_on TransientReconciliationError, wait: :polynomially_longer, attempts: 5

  def perform(batch_size: DEFAULT_BATCH_SIZE, dry_run: false)
    batch_size = validated_batch_size(batch_size)
    raise MollieConfiguration::ConfigurationError, 'Mollie is not fully configured' unless MollieConfiguration.configured?

    client = MollieApiClient.new
    result = {
      payments_checked: 0, payments_changed: 0,
      recurring_payments_discovered: 0, discovery_pages_truncated: 0,
      subscriptions_checked: 0, subscriptions_changed: 0,
      failed: 0, transient_failures: 0, failures: [],
      dry_run: ActiveModel::Type::Boolean.new.cast(dry_run)
    }

    rotating_batch(payment_scope, batch_size).each do |payment|
      reconcile_payment(client, payment, result)
    rescue StandardError => e
      record_failure(:payment, payment.id, e, result)
    end

    rotating_batch(subscription_scope, batch_size).each do |subscription|
      reconcile_subscription(client, subscription, result)
    rescue StandardError => e
      record_failure(:subscription, subscription.id, e, result)
    end

    log_summary(result)
    raise failure_class(result), result if result[:failed].positive?

    result
  end

  private

  def payment_scope
    MolliePayment.where.not(mollie_payment_id: [nil, ''])
  end

  def subscription_scope
    Subscription.where(payment_method: 'mollie').where.not(mollie_customer_id: [nil, ''])
  end

  def rotating_batch(scope, batch_size)
    ordered = scope.reorder(:id)
    count = ordered.count
    return [] if count.zero?

    cycle = Time.current.to_i / ROTATION_PERIOD.to_i
    offset = (cycle * batch_size) % count
    records = ordered.offset(offset).limit(batch_size).to_a
    remaining = [batch_size - records.length, count - records.length].min
    records.concat(ordered.limit(remaining).to_a) if remaining.positive?
    records
  end

  def reconcile_payment(client, payment, result)
    result[:payments_checked] += 1
    snapshot = client.get_payment(payment.mollie_payment_id)
    return if result[:dry_run]

    before = payment.attributes.slice(*PAYMENT_CHANGE_FIELDS)
    MolliePaymentProcessor.new(snapshot).process!
    after = payment.reload.attributes.slice(*PAYMENT_CHANGE_FIELDS)
    result[:payments_changed] += 1 if before != after
  end

  def reconcile_subscription(client, subscription, result)
    result[:subscriptions_checked] += 1
    discover_unknown_recurring_payments(client, subscription, result)
    return if subscription.mollie_subscription_id.blank?

    changed = MollieProviderSubscriptionReconciler.new(client: client, subscription: subscription,
                                                       dry_run: result[:dry_run]).call
    result[:subscriptions_changed] += 1 if changed
  end

  def discover_unknown_recurring_payments(client, subscription, result)
    remote_subscription_ids = MolliePayment.where(subscription_id: subscription.id)
                                           .where.not(mollie_subscription_id: [nil, ''])
                                           .distinct.pluck(:mollie_subscription_id)
    remote_subscription_ids << subscription.mollie_subscription_id if subscription.mollie_subscription_id.present?
    remote_subscription_ids.uniq!
    return if remote_subscription_ids.empty?

    response = client.list_customer_payments(subscription.mollie_customer_id)
    payments = response.dig('_embedded', 'payments')
    unless payments.is_a?(Array)
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned an invalid customer payment collection'
    end

    result[:discovery_pages_truncated] += 1 if response.dig('_links', 'next', 'href').present?
    candidates = payments.select do |candidate|
      candidate.is_a?(Hash) &&
        candidate['resource'] == 'payment' &&
        candidate['sequenceType'] == 'recurring' &&
        candidate['customerId'] == subscription.mollie_customer_id &&
        remote_subscription_ids.include?(candidate['subscriptionId'])
    end
    candidates.sort_by { |candidate| candidate['createdAt'].to_s }.reverse_each do |candidate|
      next if MolliePayment.exists?(mollie_payment_id: candidate['id'])

      result[:recurring_payments_discovered] += 1
      next if result[:dry_run]

      MolliePaymentProcessor.new(candidate).process!
    end
  end

  # One permanent failure is enough to refuse the whole run: a contract that no
  # longer matches its provider snapshot needs a human, not another attempt.
  def failure_class(result)
    result[:failed] == result[:transient_failures] ? TransientReconciliationError : ReconciliationError
  end

  def transient_failure?(error)
    return error.retryable? if error.is_a?(MollieApiClient::ApiError)
    return false if missing_record_failure?(error)

    TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  def missing_record_failure?(error)
    error.is_a?(MolliePaymentProcessor::TransientError) && PERMANENT_PROCESSOR_FAILURES.include?(error.message.to_s)
  end

  # The cause has to survive into the durable failure record. Logging the class
  # alone, as this did, leaves a failed execution that names a count and nothing
  # a reader can act on.
  def failure_detail(kind, id, error, transient)
    detail = "#{transient ? 'transient' : 'permanent'} #{kind} id=#{id} #{error.class}"
    return detail unless SAFE_MESSAGE_ERRORS.any? { |klass| error.is_a?(klass) }

    "#{detail}: #{error.message.to_s.truncate(MAX_FAILURE_MESSAGE)}"
  end

  def record_failure(kind, id, error, result)
    transient = transient_failure?(error)
    result[:failed] += 1
    result[:transient_failures] += 1 if transient
    detail = failure_detail(kind, id, error, transient)
    result[:failures] << detail
    Rails.logger.error("[Mollie Reconciliation] failed: #{detail}")
  end

  def log_summary(result)
    message =
      "[Mollie Reconciliation] payments=#{result[:payments_checked]} " \
      "changed=#{result[:payments_changed]} discovered=#{result[:recurring_payments_discovered]} " \
      "truncated=#{result[:discovery_pages_truncated]} subscriptions=#{result[:subscriptions_checked]} " \
      "changed=#{result[:subscriptions_changed]} failures=#{result[:failed]} transient=#{result[:transient_failures]}" \
      "#{" [#{self.class.reported_failures(result[:failures], MAX_REPORTED_FAILURES)}]" if result[:failed].positive?}" \
      "#{' dry_run=true' if result[:dry_run]}"

    result[:failed].positive? ? Rails.logger.error(message) : Rails.logger.info(message)
  end

  def validated_batch_size(value)
    size = Integer(value)
    return size if size.between?(1, MAX_BATCH_SIZE)

    raise ArgumentError, "batch_size must be between 1 and #{MAX_BATCH_SIZE}"
  rescue TypeError, ArgumentError
    raise ArgumentError, "batch_size must be between 1 and #{MAX_BATCH_SIZE}"
  end
end
