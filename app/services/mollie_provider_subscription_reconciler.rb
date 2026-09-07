# frozen_string_literal: true

# Applies one trusted Mollie subscription snapshot to the still-matching local
# contract. A provider 404 is authoritative absence: that exact local pointer
# is retired, while historical MolliePayment ledger references remain intact.
class MollieProviderSubscriptionReconciler
  STATUS_MAP = {
    'active' => 'active', 'pending' => 'active',
    'suspended' => 'past_due',
    'canceled' => 'canceled', 'completed' => 'canceled'
  }.freeze

  def initialize(client:, subscription:, dry_run:)
    @client = client
    @subscription = subscription
    @dry_run = dry_run
  end

  def call
    @expected_customer_id = @subscription.mollie_customer_id
    @expected_subscription_id = @subscription.mollie_subscription_id
    snapshot = @client.get_subscription(
      customer_id: @expected_customer_id,
      subscription_id: @expected_subscription_id
    )
    mapped_status = mapped_status!(snapshot)
    return false if @dry_run

    persist(mapped_status)
  rescue MollieApiClient::ApiError => e
    raise unless e.http_status == 404
    return false if @dry_run

    persist('canceled', clear_pointer: true)
  end

  private

  def persist(mapped_status, clear_pointer: false)
    @subscription.with_lock do
      @subscription.reload
      next false unless target_unchanged?
      next false unless clear_pointer || safe_transition?(mapped_status)

      changes = {
        status: mapped_status,
        canceled_at: mapped_status == 'canceled' ? (@subscription.canceled_at || Time.current) : nil
      }
      changes[:mollie_subscription_id] = nil if clear_pointer
      @subscription.update!(changes)
      true
    end
  end

  def target_unchanged?
    @subscription.payment_method == 'mollie' &&
      @subscription.mollie_customer_id == @expected_customer_id &&
      @subscription.mollie_subscription_id == @expected_subscription_id
  end

  # A stale provider read must not undo a concurrent/local cancellation or a
  # refund downgrade while its remote cancellation job is still pending.
  def safe_transition?(mapped_status)
    return false if @subscription.status == 'canceled' && mapped_status != 'canceled'
    return false if mapped_status == 'active' && @subscription.tier != 'pro'
    # An active subscription schedule only means Mollie may attempt future
    # charges. It does not prove that the failed renewal which set past_due has
    # been paid. Only a verified paid payment may restore entitlement state.
    return false if mapped_status == 'active' && @subscription.status != 'active'

    @subscription.status != mapped_status
  end

  def mapped_status!(snapshot)
    unless snapshot.is_a?(Hash) && snapshot['id'].to_s == @expected_subscription_id
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned the wrong subscription resource'
    end
    if snapshot['customerId'].present? &&
       snapshot['customerId'].to_s != @expected_customer_id
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned the wrong subscription customer'
    end

    STATUS_MAP.fetch(snapshot['status'].to_s) do
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned an unknown subscription status'
    end
  end
end
