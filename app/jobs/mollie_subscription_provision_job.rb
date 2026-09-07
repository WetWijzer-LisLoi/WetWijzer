# frozen_string_literal: true

# Creates the recurring Mollie subscription after a verified first payment has
# established a valid mandate. The job reconciles by immutable local metadata
# before creating anything, so a timeout beyond Mollie's idempotency cache
# cannot create a duplicate remote subscription.
class MollieSubscriptionProvisionJob < ApplicationJob
  queue_as :default

  MandateNotReady = Class.new(StandardError)
  ProvisioningInProgress = Class.new(StandardError)
  CLAIM_TTL = 10.minutes
  BILLABLE_REMOTE_STATUSES = %w[pending active suspended].freeze
  NON_BILLABLE_REMOTE_STATUSES = %w[canceled completed].freeze

  retry_on MandateNotReady, wait: 1.minute, attempts: 12
  retry_on ProvisioningInProgress, wait: 30.seconds, attempts: 20
  retry_on MollieApiClient::Error, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(mollie_payment)
    return unless MollieConfiguration.checkout_enabled?

    payment = mollie_payment.reload
    subscription = payment.subscription
    return unless subscription

    client = MollieApiClient.new
    if payment.mollie_subscription_id.present? &&
       subscription.mollie_subscription_id != payment.mollie_subscription_id &&
       !provisionable?(subscription.reload, payment.reload)
      cancel_unadopted_remote_subscription!(
        client,
        customer_id: payment.mollie_customer_id,
        remote_id: payment.mollie_subscription_id
      )
      return
    end

    return unless provisionable?(subscription.reload, payment.reload)
    return if subscription.mollie_subscription_id.present?

    claim_started_at = claim_provisioning!(payment)
    return unless claim_started_at

    begin
      payment.reload
      subscription.reload
      return unless provisionable?(subscription, payment)

      idempotency_key = ensure_subscription_idempotency_key!(subscription, payment)

      remote = find_remembered_subscription(client, subscription, payment) ||
               find_existing_subscription(client, subscription, payment)
      mandate_id = remote&.dig('mandateId').presence

      unless remote
        mandate = valid_mandate(client, subscription.mollie_customer_id)
        raise MandateNotReady, 'Mollie mandate is not valid yet' unless mandate
        return unless provisionable?(subscription.reload, payment.reload)

        mandate_id = mandate.fetch('id')

        remote = client.create_subscription(
          customer_id: subscription.mollie_customer_id,
          amount_cents: payment.amount_cents,
          currency: payment.currency,
          interval: '1 month',
          start_date: payment.service_period_end.to_date,
          description: "WetWijzer Pro ##{subscription.id}",
          webhook_url: MollieConfiguration.webhook_url,
          mandate_id: mandate.fetch('id'),
          metadata: {
            kind: 'subscription_renewal',
            user_id: payment.user_id.to_s,
            wetwijzer_subscription_id: subscription.id.to_s,
            wetwijzer_payment_id: payment.id.to_s,
            wetwijzer_first_payment_id: payment.mollie_payment_id
          },
          idempotency_key: idempotency_key
        )
      end

      remote_id = remote.fetch('id').to_s
      remember_remote_subscription!(payment, remote_id)
      adopted = persist_remote_subscription!(
        subscription,
        payment,
        remote_id,
        mandate_id: mandate_id
      )
      return if adopted

      cancel_unadopted_remote_subscription!(
        client,
        customer_id: payment.mollie_customer_id,
        remote_id: remote_id
      )
      raise MollieApiClient::InvalidResponseError,
            'local subscription contract changed during provisioning'
    ensure
      release_provisioning_claim!(payment, claim_started_at)
    end
  end

  private

  def provisionable?(subscription, payment)
    user = payment.user

    payment.payment_type == 'subscription_initial' &&
      payment.status == 'paid' &&
      payment.fulfilled_at? &&
      payment.subscription_id == subscription.id &&
      payment.user_id == subscription.user_id &&
      payment.mollie_payment_id.present? &&
      payment.mollie_customer_id.present? &&
      payment.mollie_customer_id == subscription.mollie_customer_id &&
      payment.service_period_end.present? &&
      payment.refundable_amount_cents.positive? &&
      (!payment.entitlement_revoked_at? || payment.entitlement_restored_at?) &&
      user&.active? &&
      user.deletion_scheduled_for.nil? &&
      subscription.tier == 'pro' &&
      subscription.status == 'active' &&
      subscription.payment_method == 'mollie' &&
      subscription.mollie_first_payment_id == payment.mollie_payment_id
  end

  def claim_provisioning!(payment)
    cutoff = CLAIM_TTL.ago
    claimed_at = Time.current
    claimed = MolliePayment.where(id: payment.id)
                           .where(
                             'subscription_provisioning_started_at IS NULL OR ' \
                             'subscription_provisioning_started_at < ?',
                             cutoff
                           )
                           .update_all(subscription_provisioning_started_at: claimed_at)
    return claimed_at if claimed == 1
    return false if payment.reload.mollie_subscription_id.present?

    raise ProvisioningInProgress, 'Mollie subscription provisioning is already in progress'
  end

  def release_provisioning_claim!(payment, claimed_at)
    return unless claimed_at

    MolliePayment.where(
      id: payment.id,
      subscription_provisioning_started_at: claimed_at
    ).update_all(subscription_provisioning_started_at: nil)
  end

  def find_existing_subscription(client, subscription, payment)
    response = client.list_subscriptions(subscription.mollie_customer_id)
    subscriptions = response.dig('_embedded', 'subscriptions')
    unless subscriptions.is_a?(Array)
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned an invalid subscription collection'
    end
    if response.dig('_links', 'next', 'href').present?
      raise MollieApiClient::InvalidResponseError,
            'Mollie subscription reconciliation is incomplete'
    end

    matching = subscriptions.select do |candidate|
      matching_billable_subscription?(candidate, subscription, payment)
    end
    if matching.many?
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned duplicate matching subscriptions'
    end

    matching.first
  end

  def find_remembered_subscription(client, subscription, payment)
    remote_id = payment.mollie_subscription_id.presence
    return unless remote_id

    candidate = client.get_subscription(
      customer_id: payment.mollie_customer_id,
      subscription_id: remote_id
    )
    matches_contract = matching_remote_contract?(
      candidate,
      subscription,
      payment,
      expected_remote_id: remote_id
    )
    return candidate if matches_contract &&
                        BILLABLE_REMOTE_STATUSES.include?(candidate['status'].to_s)
    return if matches_contract &&
              NON_BILLABLE_REMOTE_STATUSES.include?(candidate['status'].to_s)

    raise MollieApiClient::InvalidResponseError,
          'remembered Mollie subscription does not match its immutable metadata'
  rescue MollieApiClient::ApiError => e
    return if e.http_status == 404

    raise
  end

  def matching_billable_subscription?(candidate, subscription, payment,
                                      expected_remote_id: nil)
    matching_remote_contract?(
      candidate,
      subscription,
      payment,
      expected_remote_id: expected_remote_id
    ) && BILLABLE_REMOTE_STATUSES.include?(candidate['status'].to_s)
  end

  def matching_remote_contract?(candidate, subscription, payment,
                                expected_remote_id: nil)
    return false unless candidate.is_a?(Hash)
    return false if expected_remote_id &&
                    candidate['id'].to_s != expected_remote_id.to_s

    metadata = normalize_metadata(candidate['metadata'])
    metadata['wetwijzer_subscription_id'].to_s == subscription.id.to_s &&
      metadata['user_id'].to_s == payment.user_id.to_s &&
      metadata['wetwijzer_payment_id'].to_s == payment.id.to_s &&
      metadata['wetwijzer_first_payment_id'].to_s == payment.mollie_payment_id
  end

  def valid_mandate(client, customer_id)
    response = client.list_mandates(customer_id)
    mandates = response.dig('_embedded', 'mandates')
    return unless mandates.is_a?(Array)

    mandates.find { |mandate| mandate['status'] == 'valid' }
  end

  def ensure_subscription_idempotency_key!(subscription, payment)
    if payment.subscription_idempotency_key.blank?
      candidate = SecureRandom.uuid
      MolliePayment.where(id: payment.id, subscription_idempotency_key: [nil, ''])
                   .update_all(subscription_idempotency_key: candidate)
      payment.reload
    end

    key = payment.subscription_idempotency_key.presence ||
          raise(MollieApiClient::InvalidResponseError, 'subscription idempotency key is missing')
    subscription.update!(mollie_subscription_idempotency_key: key) unless
      subscription.mollie_subscription_idempotency_key == key
    key
  end

  def persist_remote_subscription!(subscription, payment, remote_id, mandate_id:)
    raise MollieApiClient::InvalidResponseError, 'Mollie returned an invalid subscription id' unless
      remote_id.to_s.match?(MolliePaymentProcessor::SUBSCRIPTION_ID)

    subscription.with_lock do
      # Acquire an actual SQLite write lock before the final eligibility read.
      Subscription.where(id: subscription.id).update_all(updated_at: Time.current)
      subscription.reload
      payment.reload
      next false unless provisionable?(subscription, payment)
      if subscription.mollie_subscription_id.present?
        next subscription.mollie_subscription_id == remote_id
      end

      subscription.update!(
        mollie_subscription_id: remote_id,
        mollie_mandate_id: mandate_id || subscription.mollie_mandate_id
      )
      payment.update!(mollie_subscription_id: remote_id)
      true
    end
  end

  def remember_remote_subscription!(payment, remote_id)
    raise MollieApiClient::InvalidResponseError, 'Mollie returned an invalid subscription id' unless
      remote_id.match?(MolliePaymentProcessor::SUBSCRIPTION_ID)

    payment.with_lock do
      payment.reload
      if payment.mollie_subscription_id.present? &&
         payment.mollie_subscription_id != remote_id
        raise MollieApiClient::InvalidResponseError,
              'payment is already bound to another Mollie subscription'
      end
      payment.update!(mollie_subscription_id: remote_id)
    end
  end

  def cancel_unadopted_remote_subscription!(client, customer_id:, remote_id:)
    response = client.cancel_subscription(
      customer_id: customer_id,
      subscription_id: remote_id
    )
    status = response['status'].to_s
    return if status.empty? || status == 'canceled'

    raise MollieApiClient::InvalidResponseError,
          'Mollie did not confirm orphan subscription cancellation'
  rescue MollieApiClient::ApiError => e
    raise unless e.http_status == 404
  end

  def normalize_metadata(value)
    return value.deep_stringify_keys if value.is_a?(Hash)
    return {} unless value.is_a?(String)

    parsed = JSON.parse(value)
    parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
  rescue JSON::ParserError
    {}
  end
end
