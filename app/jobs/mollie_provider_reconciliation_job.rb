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
  PAYMENT_CHANGE_FIELDS = %w[
    status fulfilled_at refunded_amount_cents charged_back_amount_cents
    chargeback_reversal_candidate_cents
    failure_notification_enqueued_at
  ].freeze
  class ReconciliationError < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super("Mollie provider reconciliation failed for #{result.fetch(:failed)} item(s)")
    end
  end

  def perform(batch_size: DEFAULT_BATCH_SIZE, dry_run: false)
    batch_size = validated_batch_size(batch_size)
    raise MollieConfiguration::ConfigurationError, 'Mollie is not fully configured' unless MollieConfiguration.configured?

    client = MollieApiClient.new
    result = {
      payments_checked: 0, payments_changed: 0,
      recurring_payments_discovered: 0, discovery_pages_truncated: 0,
      subscriptions_checked: 0, subscriptions_changed: 0,
      failed: 0, dry_run: ActiveModel::Type::Boolean.new.cast(dry_run)
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
    raise ReconciliationError, result if result[:failed].positive?

    result
  end

  private

  def payment_scope
    MolliePayment.where.not(mollie_payment_id: [nil, ''])
  end

  def subscription_scope
    Subscription.where(payment_method: 'mollie')
                .where.not(mollie_customer_id: [nil, ''])
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

    changed = MollieProviderSubscriptionReconciler.new(
      client: client,
      subscription: subscription,
      dry_run: result[:dry_run]
    ).call
    result[:subscriptions_changed] += 1 if changed
  end

  def discover_unknown_recurring_payments(client, subscription, result)
    remote_subscription_ids = MolliePayment.where(
      subscription_id: subscription.id
    ).where.not(mollie_subscription_id: [nil, ''])
                                           .distinct
                                           .pluck(:mollie_subscription_id)
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

  def record_failure(kind, id, error, result)
    result[:failed] += 1
    Rails.logger.error("[Mollie Reconciliation] #{kind} id=#{id} failed: #{error.class}")
  end

  def log_summary(result)
    message =
      "[Mollie Reconciliation] payments=#{result[:payments_checked]} " \
      "changed=#{result[:payments_changed]} discovered=#{result[:recurring_payments_discovered]} " \
      "truncated=#{result[:discovery_pages_truncated]} subscriptions=#{result[:subscriptions_checked]} " \
      "changed=#{result[:subscriptions_changed]} failures=#{result[:failed]}" \
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
