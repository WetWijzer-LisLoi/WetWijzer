# frozen_string_literal: true

# Cancels recurring billing remotely before changing local state. Provider ids
# are never detached on an API error. Successful cancellation clears the live
# pointer so late recurring callbacks cannot reactivate the canceled contract;
# MolliePayment keeps the immutable historical provider reference.
class MollieSubscriptionCancellationService
  class CancellationError < StandardError; end

  NON_BILLING_STATUSES = %w[canceled completed].freeze

  def initialize(subscription, client: MollieApiClient.new, guard: nil)
    @subscription = subscription
    @client = client
    @guard = guard
  end

  def cancel!
    capture_expected_contract!
    return @subscription unless cancellation_allowed?

    reject_live_legacy_subscription!
    reject_active_provisioning!
    cancel_mollie_subscription!
    finalize_local_cancellation!

    @subscription
  rescue MollieApiClient::Error => e
    Rails.logger.error("[Mollie] Subscription cancellation failed: #{e.class}")
    raise CancellationError, 'subscription cancellation could not be confirmed'
  end

  private

  def cancellation_allowed?
    @guard.nil? || @guard.call(@subscription)
  end

  def capture_expected_contract!
    @subscription.reload
    @expected_customer_id = @subscription.mollie_customer_id
    @expected_subscription_id = @subscription.mollie_subscription_id
    @expected_first_payment_id = @subscription.mollie_first_payment_id
    @expected_payment_method = @subscription.payment_method
    @expected_status = @subscription.status
  end

  def reject_live_legacy_subscription!
    return unless @subscription.stripe_subscription_id.present?
    # The controlled cutover cancels the sole legacy recurring contract at
    # the old provider, verifies it remotely, then records both fields below
    # while retaining the provider id as accounting evidence.
    return if @subscription.status == 'canceled' && @subscription.canceled_at.present?

    raise CancellationError, 'legacy subscription must be canceled during provider cutover'
  end

  def cancel_mollie_subscription!
    remote_ids = [@expected_subscription_id].compact_blank
    remote_ids.concat(remembered_remote_subscription_ids)

    # A first payment can be followed by an ambiguous provision response: the
    # provider may have created a recurring subscription before its id was
    # stored locally. Reconcile by the opaque WetWijzer subscription id even
    # when one local pointer exists, so a second orphaned provider contract
    # cannot survive cancellation.
    remote_ids.concat(discover_billable_subscription_ids!) if mollie_contract_might_exist?

    remote_ids.uniq.each { |remote_id| cancel_remote_subscription!(remote_id) }
  end

  def mollie_contract_might_exist?
    @expected_payment_method == 'mollie' &&
      @expected_status != 'canceled'
  end

  def discover_billable_subscription_ids!
    raise CancellationError, 'Mollie customer id is missing' unless @expected_customer_id.present?

    response = @client.list_subscriptions(@expected_customer_id)
    subscriptions = response.dig('_embedded', 'subscriptions')
    unless subscriptions.is_a?(Array)
      raise MollieApiClient::InvalidResponseError,
            'Mollie returned an invalid subscription collection'
    end

    # Refuse to claim a complete reconciliation if Mollie says another page
    # exists and this deliberately small client cannot inspect it.
    if response.dig('_links', 'next', 'href').present?
      raise MollieApiClient::InvalidResponseError,
            'Mollie subscription reconciliation is incomplete'
    end

    subscriptions.filter_map do |candidate|
      next unless matching_local_subscription?(candidate)
      next if NON_BILLING_STATUSES.include?(candidate['status'].to_s)

      candidate['id'].presence
    end
  rescue MollieApiClient::ApiError => e
    # A missing customer cannot have a live subscription left to cancel.
    return [] if e.http_status == 404

    raise
  end

  def matching_local_subscription?(candidate)
    return false unless candidate.is_a?(Hash)

    metadata = candidate['metadata']
    metadata.is_a?(Hash) &&
      metadata['wetwijzer_subscription_id'].to_s == @subscription.id.to_s
  end

  def cancel_remote_subscription!(remote_id)
    response = @client.cancel_subscription(
      customer_id: required_mollie_customer_id!,
      subscription_id: remote_id
    )
    remote_status = response['status'].to_s
    return if remote_status.empty? || remote_status == 'canceled'

    raise CancellationError, 'Mollie did not confirm cancellation'
  rescue MollieApiClient::ApiError => e
    # A 404 means no remote subscription remains capable of billing.
    return if e.http_status == 404

    # Mollie REFUSES to cancel a subscription that is already canceled or
    # completed (422), which is not a failure: nothing can bill any more.
    # Before this, that refusal aborted account erasure permanently - a user
    # whose subscription had already been canceled at Mollie could never be
    # deleted (production, user 73, 2026-08-19).
    #
    # Only accept it when the remote status PROVES the contract is dead. If
    # that confirming read fails or shows a still-billable status, the
    # original error stands: this service must never claim a cancellation it
    # could not confirm.
    raise unless remote_subscription_non_billing?(remote_id)
  end

  # True only when Mollie itself reports a status that cannot bill again.
  def remote_subscription_non_billing?(remote_id)
    remote = @client.get_subscription(
      customer_id: required_mollie_customer_id!,
      subscription_id: remote_id
    )
    NON_BILLING_STATUSES.include?(remote['status'].to_s)
  rescue MollieApiClient::ApiError => e
    # Gone at the provider: it cannot bill.
    e.http_status == 404
  rescue MollieApiClient::Error
    false
  end

  def required_mollie_customer_id!
    @expected_customer_id.presence ||
      raise(CancellationError, 'Mollie customer id is missing')
  end

  def remembered_remote_subscription_ids
    scope = MolliePayment.where(
      subscription_id: @subscription.id,
      payment_type: 'subscription_initial'
    ).where.not(mollie_subscription_id: [nil, ''])
    scope = if @expected_first_payment_id.present?
              scope.where(mollie_payment_id: @expected_first_payment_id)
            else
              scope.none
            end
    scope.pluck(:mollie_subscription_id)
  end

  def reject_active_provisioning!
    return unless provisioning_in_progress?

    raise CancellationError, 'subscription provisioning is still being reconciled'
  end

  def provisioning_in_progress?
    MolliePayment.where(
      subscription_id: @subscription.id,
      payment_type: 'subscription_initial'
    ).where.not(subscription_provisioning_started_at: nil)
                 .where(
                   'subscription_provisioning_started_at >= ?',
                   MollieSubscriptionProvisionJob::CLAIM_TTL.ago
                 ).exists?
  end

  def finalize_local_cancellation!
    @subscription.with_lock do
      # Keep the database critical section local and short. This write obtains
      # the SQLite lock before checking the provisioning lease, while all
      # provider reads/deletes above happened without a database transaction.
      claimed = Subscription.where(id: @subscription.id)
                            .update_all(updated_at: Time.current)
      raise ActiveRecord::RecordNotFound unless claimed == 1

      @subscription.reload
      next if @subscription.status == 'canceled' &&
              @subscription.mollie_subscription_id.blank?

      # The guard is a pre-I/O authorization check. Once Mollie confirmed the
      # DELETE, a concurrent chargeback reversal cannot make that exact remote
      # generation live again. Finalize it as canceled-at-period-end while
      # preserving the restored paid period. If a replacement generation won
      # the race, leave that different set of immutable identifiers untouched.
      next unless local_generation_unchanged?

      @subscription.update!(
        status: 'canceled',
        canceled_at: @subscription.canceled_at || Time.current,
        mollie_subscription_id: nil
      )
    end
  end

  def local_generation_unchanged?
    @subscription.mollie_customer_id == @expected_customer_id &&
      @subscription.mollie_first_payment_id == @expected_first_payment_id &&
      @subscription.mollie_subscription_id == @expected_subscription_id
  end
end
