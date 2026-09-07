# frozen_string_literal: true

require 'bigdecimal'
require 'json'

# Verifies and applies a Mollie payment snapshot fetched from Mollie's API.
#
# Mollie can call the same webhook for several states of one mutable payment.
# Consequently, the provider payment id is not an event ledger. This processor
# stores monotonic state, atomically claims each paid fulfillment, and records
# every refund/chargeback increase plus each provider-confirmed chargeback
# decrease as a separate durable adjustment.
class MolliePaymentProcessor
  class VerificationError < StandardError; end
  class TransientError < StandardError; end

  PAYMENT_ID = /\Atr_[A-Za-z0-9]+\z/
  CUSTOMER_ID = /\Acst_[A-Za-z0-9]+\z/
  SUBSCRIPTION_ID = /\Asub_[A-Za-z0-9]+\z/
  TERMINAL_FAILURES = %w[canceled expired failed].freeze
  PRE_PAID_STATUSES = %w[created open pending authorized].freeze
  KNOWN_STATUSES = (PRE_PAID_STATUSES + TERMINAL_FAILURES + %w[paid]).freeze
  ADJUSTMENT_CAS_ATTEMPTS = 10
  CHARGEBACK_REVERSAL_CONFIRMATION_DELAY = 2.minutes

  def initialize(
    payment_data,
    confirm_chargeback_reversal: false,
    suppress_entitlement: false
  )
    @data = payment_data.deep_stringify_keys
    @confirm_chargeback_reversal = confirm_chargeback_reversal
    @suppress_entitlement = suppress_entitlement
    @post_commit = []
  end

  def process!
    validate_provider_snapshot!
    lease = acquire_financial_processing_lease!
    payment = find_or_build_local_payment!
    validate_local_contract!(payment)

    AccountRecord.transaction do
      payment.lock!
      apply_status!(payment)
      apply_adjustments!(payment)
    end

    run_post_commit
    payment.reload
  ensure
    lease&.release!
  end

  private

  def validate_provider_snapshot!
    raise VerificationError, 'invalid payment id' unless @data['id'].to_s.match?(PAYMENT_ID)
    raise VerificationError, 'unexpected resource type' unless @data['resource'] == 'payment'
    raise VerificationError, 'unknown payment status' unless KNOWN_STATUSES.include?(@data['status'].to_s)

    expected_mode = ENV.fetch('MOLLIE_API_KEY', '').start_with?('live_') ? 'live' : 'test'
    raise VerificationError, 'payment mode does not match API credentials' unless @data['mode'] == expected_mode

    amount_cents!(@data.fetch('amount'), expected_currency: 'EUR')
    raise VerificationError, 'invalid payment creation timestamp' unless parse_time(@data['createdAt'])
    if @data['status'] == 'paid' && !parse_time(@data['paidAt'])
      raise VerificationError, 'invalid payment paid timestamp'
    end
  rescue KeyError
    raise VerificationError, 'incomplete payment snapshot'
  end

  def find_or_build_local_payment!
    existing = MolliePayment.find_by(mollie_payment_id: @data['id'])
    return existing if existing

    adopted = adopt_ambiguous_checkout_payment!
    return adopted if adopted

    build_recurring_payment!
  end

  # Mollie may deliver a webhook before the checkout request has stored the
  # provider id, or the create response may be lost after Mollie accepted it.
  # The local intent id is part of the immutable provider metadata precisely so
  # that the verified provider snapshot can be adopted without guessing by
  # amount, user, or time.
  def adopt_ambiguous_checkout_payment!
    return if @data['sequenceType'] == 'recurring'

    metadata = parsed_metadata
    local_id = metadata['wetwijzer_payment_id'].to_s
    raise VerificationError, 'payment metadata local id is invalid' unless local_id.match?(/\A[1-9]\d*\z/)

    payment = MolliePayment.find_by(id: local_id)
    raise TransientError, 'checkout payment arrived before its local intent was committed' unless payment

    validate_local_contract!(payment, allow_unadopted_remote_id: true)
    adopted = MolliePayment.where(id: payment.id, mollie_payment_id: [nil, ''])
                           .update_all(
                             mollie_payment_id: @data['id'],
                             provider_created_at: parse_time(@data['createdAt']),
                             updated_at: Time.current
                           )
    return payment.reload if adopted == 1

    payment.reload
    return payment if payment.mollie_payment_id == @data['id']

    raise VerificationError, 'local payment intent is already bound to another provider payment'
  rescue ActiveRecord::RecordNotUnique
    existing = MolliePayment.find_by(mollie_payment_id: @data['id'])
    return existing if existing&.id == payment&.id

    raise VerificationError, 'provider payment is already bound to another local intent'
  end

  def build_recurring_payment!
    raise VerificationError, 'unknown non-recurring payment' unless @data['sequenceType'] == 'recurring'

    remote_subscription_id = @data['subscriptionId'].to_s
    raise VerificationError, 'invalid recurring subscription id' unless remote_subscription_id.match?(SUBSCRIPTION_ID)

    subscription = recurring_subscription(remote_subscription_id)
    raise TransientError, 'recurring payment arrived before its subscription was stored' unless subscription

    metadata = parsed_metadata
    verify_metadata_value!(metadata, 'kind', 'subscription_renewal')
    verify_metadata_value!(metadata, 'wetwijzer_subscription_id', subscription.id.to_s)
    verify_metadata_value!(metadata, 'user_id', subscription.user_id.to_s)

    expected_amount = Subscription::TIER_CONFIG.fetch('pro').fetch(:price_monthly)
    verify_amount!(expected_amount, 'EUR')
    verify_remote_customer!(subscription.mollie_customer_id)

    MolliePayment.create!(
      user_id: subscription.user_id,
      subscription: subscription,
      payment_type: 'subscription_renewal',
      status: normalized_status,
      amount_cents: expected_amount,
      currency: 'EUR',
      sequence_type: 'recurring',
      mollie_payment_id: @data['id'],
      mollie_customer_id: @data['customerId'],
      mollie_subscription_id: remote_subscription_id,
      provider_created_at: parse_time(@data['createdAt'])
    )
  rescue ActiveRecord::RecordNotUnique
    MolliePayment.find_by!(mollie_payment_id: @data['id'])
  end

  def acquire_financial_processing_lease!
    user_id = financial_processing_user_id
    return unless user_id

    lease = AccountRequestLease.acquire_for_existing_user_id!(user_id: user_id)
    unless lease
      existing = MolliePayment.find_by(mollie_payment_id: @data['id'])
      return if existing&.user_id.nil? && existing&.fulfilled_at?

      raise TransientError, 'payment account disappeared during financial processing'
    end

    user = User.find_by(id: user_id)
    @account_eligible_for_fulfillment =
      !@suppress_entitlement &&
      user&.active? &&
      user.deletion_scheduled_for.nil?
    lease
  end

  def financial_processing_user_id
    existing = MolliePayment.find_by(mollie_payment_id: @data['id'])
    return existing.user_id if existing&.user_id
    return if existing

    if @data['sequenceType'] == 'recurring'
      remote_subscription_id = @data['subscriptionId'].to_s
      return recurring_subscription(remote_subscription_id)&.user_id
    end

    metadata = parsed_metadata
    local_id = metadata['wetwijzer_payment_id'].to_s
    return unless local_id.match?(/\A[1-9]\d*\z/)

    MolliePayment.find_by(id: local_id)&.user_id
  end

  def recurring_subscription(remote_subscription_id)
    return @recurring_subscription if defined?(@recurring_subscription)

    @recurring_subscription = Subscription.find_by(
      mollie_subscription_id: remote_subscription_id
    )
    return @recurring_subscription if @recurring_subscription

    anchor = MolliePayment.where(mollie_subscription_id: remote_subscription_id)
                          .where.not(user_id: nil)
                          .order(created_at: :desc)
                          .first
    @recurring_subscription = anchor&.subscription || anchor&.user&.subscription
    return @recurring_subscription if @recurring_subscription

    # Account erasure cancels the provider subscription and clears the live
    # pointer before it reconciles payments that Mollie accepted immediately
    # before cancellation. The immutable provider metadata still identifies
    # the exact local contract; use both ids together and let the full contract
    # validation below reject every other mismatch.
    metadata = parsed_metadata
    local_subscription_id = metadata['wetwijzer_subscription_id'].to_s
    local_user_id = metadata['user_id'].to_s
    return unless local_subscription_id.match?(/\A[1-9]\d*\z/) &&
                  local_user_id.match?(/\A[1-9]\d*\z/)

    candidate = Subscription.find_by(id: local_subscription_id)
    @recurring_subscription =
      candidate if candidate&.user_id.to_s == local_user_id
  end

  def validate_local_contract!(payment, allow_unadopted_remote_id: false)
    remote_id_matches = payment.mollie_payment_id == @data['id']
    unadopted = allow_unadopted_remote_id && payment.mollie_payment_id.blank?
    raise VerificationError, 'payment id mismatch' unless remote_id_matches || unadopted

    verify_amount!(payment.amount_cents, payment.currency)
    verify_remote_customer!(payment.mollie_customer_id) if payment.mollie_customer_id.present?

    metadata = parsed_metadata
    case payment.payment_type
    when 'credit_purchase'
      verify_metadata_value!(metadata, 'kind', 'credit_purchase')
      verify_metadata_value!(metadata, 'wetwijzer_payment_id', payment.id.to_s)
      verify_metadata_value!(metadata, 'user_id', retained_contract_id!(payment, :user).to_s)
      verify_metadata_value!(
        metadata,
        'purchase_id',
        retained_contract_id!(payment, :credit_purchase).to_s
      )
      raise VerificationError, 'wrong sequence type' unless @data['sequenceType'] == 'oneoff'
      raise VerificationError, 'credit purchase cannot belong to a customer' if @data['customerId'].present?
      raise VerificationError, 'credit purchase cannot belong to a subscription' if @data['subscriptionId'].present?
    when 'subscription_initial'
      verify_metadata_value!(metadata, 'kind', 'subscription_initial')
      verify_metadata_value!(metadata, 'wetwijzer_payment_id', payment.id.to_s)
      verify_metadata_value!(
        metadata,
        'wetwijzer_subscription_id',
        retained_contract_id!(payment, :subscription).to_s
      )
      verify_metadata_value!(metadata, 'user_id', retained_contract_id!(payment, :user).to_s)
      raise VerificationError, 'wrong sequence type' unless @data['sequenceType'] == 'first'
    when 'subscription_renewal'
      verify_metadata_value!(metadata, 'kind', 'subscription_renewal')
      verify_metadata_value!(
        metadata,
        'wetwijzer_subscription_id',
        retained_contract_id!(payment, :subscription).to_s
      )
      verify_metadata_value!(metadata, 'user_id', retained_contract_id!(payment, :user).to_s)
      raise VerificationError, 'wrong sequence type' unless @data['sequenceType'] == 'recurring'
      raise VerificationError, 'payment subscription id mismatch' unless @data['subscriptionId'] == payment.mollie_subscription_id
      subscription = payment.subscription || payment.user&.subscription
      if subscription&.mollie_subscription_id.present? &&
         @data['subscriptionId'] != subscription.mollie_subscription_id
        historical_generation = MolliePayment.where(
          subscription_id: subscription.id,
          mollie_subscription_id: @data['subscriptionId']
        ).exists?
        raise VerificationError, 'unknown historical subscription id' unless historical_generation
      end
    when 'donation'
      verify_metadata_value!(metadata, 'kind', 'donation')
      verify_metadata_value!(metadata, 'wetwijzer_payment_id', payment.id.to_s)
      raise VerificationError, 'wrong sequence type' unless @data['sequenceType'] == 'oneoff'
      raise VerificationError, 'donation cannot belong to a customer' if @data['customerId'].present?
      raise VerificationError, 'donation cannot belong to a subscription' if @data['subscriptionId'].present?
    else
      raise VerificationError, 'unknown local payment type'
    end
  end

  def apply_status!(payment)
    status = normalized_status
    attrs = {
      mollie_customer_id: @data['customerId'].presence || payment.mollie_customer_id,
      mollie_subscription_id: @data['subscriptionId'].presence || payment.mollie_subscription_id,
      provider_created_at: parse_time(@data['createdAt']) || payment.provider_created_at
    }

    if payment.status == 'paid' && status != 'paid'
      # A remote snapshot fetched earlier may finish processing after a newer
      # paid snapshot. Never lose the locally-observed paid state, even in the
      # narrow window before fulfillment has been reconciled.
      Rails.logger.info("[Mollie] Ignoring stale #{status} state for paid payment #{payment.id}")
    elsif TERMINAL_FAILURES.include?(payment.status)
      # Mollie's failure states are terminal. Replayed or out-of-order
      # snapshots must not reopen a failed/canceled/expired payment. A
      # first-seen recurring callback is inserted with its terminal provider
      # status before reaching this method, so still apply the subscription/
      # purchase consequence idempotently.
      Rails.logger.info("[Mollie] Ignoring #{status} state for terminal payment #{payment.id}")
      handle_unsuccessful!(payment, payment.status)
    elsif status == 'paid'
      attrs[:status] = 'paid'
      attrs[:paid_at] = parse_time(@data['paidAt']) || payment.paid_at || Time.current
      payment.update!(attrs)
      fulfill_paid!(payment) unless payment.fulfilled_at?
    elsif payment.fulfilled_at?
      # A paid payment never regresses because an older callback is replayed.
      Rails.logger.info("[Mollie] Ignoring stale #{status} state for fulfilled payment #{payment.id}")
    else
      payment.update!(attrs.merge(status: status))
      handle_unsuccessful!(payment, status)
    end
  end

  def fulfill_paid!(payment)
    paid_at = payment.paid_at || Time.current

    case payment.payment_type
    when 'credit_purchase'
      fulfill_credit_purchase!(payment)
    when 'subscription_initial'
      fulfill_subscription_initial!(payment, paid_at)
    when 'subscription_renewal'
      fulfill_subscription_renewal!(payment, paid_at)
    end

    if payment.donation?
      payment.update!(fulfilled_at: Time.current, invoice_state: 'not_required')
    else
      payment.update!(fulfilled_at: Time.current, invoice_state: 'pending')
      after_commit { MollieInvoiceJob.perform_later(payment) }
    end
  end

  def fulfill_credit_purchase!(payment)
    purchase = payment.credit_purchase
    raise TransientError, 'credit purchase is not available' unless purchase
    raise VerificationError, 'credit purchase belongs to another user' unless purchase.user_id == payment.user_id

    purchase.update!(
      mollie_payment_id: payment.mollie_payment_id,
      payment_method: 'mollie',
      currency: payment.currency
    )
    if account_eligible_for_fulfillment?
      purchase.complete!
      payment.update!(credits_granted: purchase.credits_granted)
    else
      # Provider money remains auditable and invoiceable, but a deletion fence
      # that won admission must never be bypassed by a late callback.
      purchase.update!(status: 'completed')
      payment.update!(credits_granted: 0)
    end
  end

  def fulfill_subscription_initial!(payment, paid_at)
    subscription = payment.subscription || payment.user&.subscription
    raise TransientError, 'subscription is not available' unless subscription

    period_start = [subscription.current_period_end, paid_at].compact.max
    period_end = period_start + 1.month
    unless account_eligible_for_fulfillment?
      payment.update!(
        service_period_start: period_start,
        service_period_end: period_end,
        credits_granted: 0
      )
      return
    end

    subscription.update!(
      tier: 'pro',
      status: 'active',
      payment_method: 'mollie',
      mollie_customer_id: payment.mollie_customer_id,
      mollie_first_payment_id: payment.mollie_payment_id,
      current_period_start: period_start,
      current_period_end: period_end,
      canceled_at: nil
    )
    payment.update!(service_period_start: period_start, service_period_end: period_end)
    subscription.refill_credits!
    payment.update!(credits_granted: Subscription::PRO_MONTHLY_CREDITS)

    after_commit do
      MollieSubscriptionProvisionJob.perform_later(payment) if payment.reload.refundable_amount_cents.positive?
    end
    after_commit do
      UserMailer.subscription_welcome(payment.user).deliver_later if payment.reload.refundable_amount_cents.positive? &&
                                                                     payment.user
    end
  end

  def fulfill_subscription_renewal!(payment, paid_at)
    subscription = payment.subscription || payment.user&.subscription
    raise TransientError, 'subscription is not available' unless subscription

    period_start = [subscription.current_period_end, paid_at].compact.max
    period_end = period_start + 1.month
    unless account_eligible_for_fulfillment?
      payment.update!(
        service_period_start: period_start,
        service_period_end: period_end,
        credits_granted: 0
      )
      return
    end

    current_remote_subscription = subscription.mollie_subscription_id == payment.mollie_subscription_id
    attrs = {
      tier: 'pro',
      payment_method: 'mollie',
      current_period_start: period_start,
      current_period_end: period_end
    }
    if current_remote_subscription
      attrs[:status] = 'active'
      attrs[:canceled_at] = nil
    end
    subscription.update!(attrs)
    payment.update!(service_period_start: period_start, service_period_end: period_end)
    subscription.refill_credits!
    payment.update!(credits_granted: Subscription::PRO_MONTHLY_CREDITS)
  end

  def handle_unsuccessful!(payment, status)
    return unless TERMINAL_FAILURES.include?(status)

    if payment.payment_type == 'credit_purchase'
      purchase = payment.credit_purchase
      purchase&.fail! if purchase&.pending?
      return
    end

    return unless payment.payment_type == 'subscription_renewal'

    subscription = payment.subscription || payment.user&.subscription
    return unless subscription
    return if subscription.status == 'canceled'
    return if subscription.mollie_subscription_id != payment.mollie_subscription_id
    return if newer_fulfilled_renewal_exists?(payment)

    subscription.update!(status: 'past_due')
    request_failure_notification!(payment)
  end

  def newer_fulfilled_renewal_exists?(payment)
    provider_created_at = payment.provider_created_at || parse_time(@data['createdAt'])
    return false unless provider_created_at

    MolliePayment.where(
      subscription_id: payment.subscription_id,
      payment_type: 'subscription_renewal',
      mollie_subscription_id: payment.mollie_subscription_id
    ).where.not(fulfilled_at: nil)
      .where('provider_created_at > ?', provider_created_at)
      .exists?
  end

  def request_failure_notification!(payment)
    return unless payment.payment_type == 'subscription_renewal'
    return unless payment.user
    return if payment.failure_notification_enqueued_at?

    subscription = payment.subscription || payment.user.subscription
    return unless subscription
    return if subscription.status == 'canceled'
    return if subscription.mollie_subscription_id != payment.mollie_subscription_id
    return if newer_fulfilled_renewal_exists?(payment)

    payment.update!(failure_notification_enqueued_at: Time.current)
    after_commit { MolliePaymentFailureNotificationJob.perform_later(payment) }
  end

  def apply_adjustments!(payment)
    refund_total = optional_money_cents(@data['amountRefunded'], payment.currency)
    chargeback_total = optional_money_cents(@data['amountChargedBack'], payment.currency)
    if refund_total > payment.amount_cents || chargeback_total > payment.amount_cents
      raise VerificationError, 'payment adjustment exceeds original amount'
    end

    record_adjustment!(payment, 'refund', refund_total, :refunded_amount_cents)
    chargeback_decreased = record_chargeback_transition!(payment, chargeback_total)
    reconcile_reversed_entitlements!(
      payment,
      chargeback_decreased: chargeback_decreased
    )
  end

  def record_chargeback_transition!(payment, cumulative_cents)
    ADJUSTMENT_CAS_ATTEMPTS.times do
      payment.reload
      previous = payment.charged_back_amount_cents.to_i
      if cumulative_cents >= previous
        if cumulative_cents == previous
          next unless clear_chargeback_reversal_candidate!(payment)
        else
          record_adjustment!(
            payment,
            'chargeback',
            cumulative_cents,
            :charged_back_amount_cents,
            clear_chargeback_candidate: true
          )
        end
        return false
      end

      unless chargeback_reversal_confirmation_ready?(payment, cumulative_cents)
        stage_chargeback_reversal_candidate!(payment, cumulative_cents)
        return false
      end

      delta = previous - cumulative_cents
      next unless compare_and_swap_adjustment_totals!(
        payment,
        counter_column: :charged_back_amount_cents,
        cumulative_cents: cumulative_cents,
        additional_updates: {
          chargeback_reversal_candidate_cents: nil,
          chargeback_reversal_candidate_at: nil
        }
      )

      adjustment = payment.adjustments.create!(
        adjustment_type: 'chargeback_reversal',
        cumulative_amount_cents: cumulative_cents,
        delta_amount_cents: delta,
        status: payment.donation? ? 'processed' : 'pending'
      )
      if !payment.donation?
        after_commit { MolliePaymentAdjustmentJob.perform_later(adjustment) }
      end
      return true
    end

    raise TransientError, 'chargeback total changed concurrently'
  end

  def record_adjustment!(payment, kind, cumulative_cents, counter_column,
                         clear_chargeback_candidate: false)
    ADJUSTMENT_CAS_ATTEMPTS.times do
      payment.reload
      previous = payment.public_send(counter_column).to_i
      return if cumulative_cents <= previous

      other_total = if kind == 'refund'
                      payment.charged_back_amount_cents.to_i
                    else
                      payment.refunded_amount_cents.to_i
                    end
      remaining_accountable = [payment.amount_cents - other_total - previous, 0].max
      delta = [cumulative_cents - previous, remaining_accountable].min
      timestamp_column = kind == 'refund' ? :refunded_at : :charged_back_at
      candidate_updates = if clear_chargeback_candidate
                            {
                              chargeback_reversal_candidate_cents: nil,
                              chargeback_reversal_candidate_at: nil
                            }
                          else
                            {}
                          end
      next unless compare_and_swap_adjustment_totals!(
        payment,
        counter_column: counter_column,
        cumulative_cents: cumulative_cents,
        timestamp_column: timestamp_column,
        additional_updates: candidate_updates
      )

      adjustment = if delta.positive?
                     payment.adjustments.create!(
                       adjustment_type: kind,
                       cumulative_amount_cents: cumulative_cents,
                       delta_amount_cents: delta,
                       status: payment.donation? ? 'processed' : 'pending'
                     )
                   end

      if adjustment && !payment.donation?
        after_commit { MolliePaymentAdjustmentJob.perform_later(adjustment) }
      end
      return adjustment
    end

    raise TransientError, "#{kind} total changed concurrently"
  end

  def chargeback_reversal_confirmation_ready?(payment, cumulative_cents)
    @confirm_chargeback_reversal &&
      payment.chargeback_reversal_candidate_cents == cumulative_cents &&
      payment.chargeback_reversal_candidate_at.present? &&
      payment.chargeback_reversal_candidate_at <=
        CHARGEBACK_REVERSAL_CONFIRMATION_DELAY.ago
  end

  def stage_chargeback_reversal_candidate!(payment, cumulative_cents)
    ADJUSTMENT_CAS_ATTEMPTS.times do
      payment.reload
      return if cumulative_cents >= payment.charged_back_amount_cents.to_i

      candidate_at = payment.chargeback_reversal_candidate_at
      if payment.chargeback_reversal_candidate_cents == cumulative_cents && candidate_at
        if candidate_at <= CHARGEBACK_REVERSAL_CONFIRMATION_DELAY.ago
          schedule_chargeback_reversal_confirmation(payment, candidate_at)
        end
        return
      end

      candidate_at = Time.current
      next unless compare_and_swap_adjustment_totals!(
        payment,
        additional_updates: {
          chargeback_reversal_candidate_cents: cumulative_cents,
          chargeback_reversal_candidate_at: candidate_at
        }
      )

      schedule_chargeback_reversal_confirmation(payment, candidate_at)
      return
    end

    raise TransientError, 'chargeback reversal candidate changed concurrently'
  end

  def schedule_chargeback_reversal_confirmation(payment, candidate_at)
    after_commit do
      MollieChargebackReversalConfirmationJob.schedule(
        payment,
        candidate_at: candidate_at
      )
    end
  end

  def clear_chargeback_reversal_candidate!(payment)
    return true unless payment.chargeback_reversal_candidate_at?

    compare_and_swap_adjustment_totals!(
      payment,
      additional_updates: {
        chargeback_reversal_candidate_cents: nil,
        chargeback_reversal_candidate_at: nil
      }
    )
  end

  def compare_and_swap_adjustment_totals!(payment, counter_column: nil, cumulative_cents: nil,
                                          timestamp_column: nil, additional_updates: {})
    now = Time.current
    expected_totals = {
      refunded_amount_cents: payment.refunded_amount_cents.to_i,
      charged_back_amount_cents: payment.charged_back_amount_cents.to_i,
      chargeback_reversal_candidate_cents: payment.chargeback_reversal_candidate_cents,
      chargeback_reversal_candidate_at: payment.chargeback_reversal_candidate_at
    }
    updates = additional_updates.merge(updated_at: now)
    updates[counter_column] = cumulative_cents if counter_column
    updates[timestamp_column] = now if timestamp_column

    claimed = MolliePayment.where(id: payment.id)
                           .where(expected_totals)
                           .update_all(updates)
    payment.reload if claimed == 1
    claimed == 1
  end

  def reconcile_reversed_entitlements!(payment, chargeback_decreased:)
    total_reversed = [
      payment.refunded_amount_cents.to_i + payment.charged_back_amount_cents.to_i,
      payment.amount_cents
    ].min
    granted = payment.credits_granted.to_i
    target_reversed = if total_reversed >= payment.amount_cents
                        granted
                      else
                        (granted * total_reversed) / payment.amount_cents
                      end
    credits_delta = target_reversed - payment.credits_reversed.to_i

    if credits_delta.positive?
      payment.user&.add_credits!(-credits_delta)
      payment.update!(credits_reversed: target_reversed)
    elsif credits_delta.negative? && chargeback_decreased
      # Only a provider-confirmed decrease of amountChargedBack may restore
      # credits. The target remains bounded by this payment's original grant,
      # so refunds and other payments' grants can never be restored here.
      payment.user&.add_credits!(-credits_delta)
      payment.update!(credits_reversed: target_reversed)
    end

    if total_reversed < payment.amount_cents
      restore_entitlement_after_chargeback_reversal!(payment) if chargeback_decreased
      return
    end

    if payment.payment_type == 'credit_purchase'
      payment.credit_purchase&.update!(status: 'refunded')
      return
    end
    return unless payment.payment_type.start_with?('subscription_')

    subscription = payment.subscription || payment.user&.subscription
    return unless subscription
    return unless current_billing_generation?(subscription, payment)
    return if payment.superseded_subscription_entitlement?
    return unless subscription.tier == 'pro'
    return if payment.entitlement_revoked_at? && !payment.entitlement_restored_at?

    payment.update!(
      entitlement_revoked_at: Time.current,
      entitlement_restored_at: nil,
      entitlement_prior_status: subscription.status,
      entitlement_prior_period_end: subscription.current_period_end
    )

    subscription.update!(
      tier: 'free',
      status: 'past_due',
      current_period_end: [subscription.current_period_end, Time.current].compact.min
    )
    expected_remote_id = subscription.mollie_subscription_id
    expected_first_payment_id = subscription.mollie_first_payment_id
    after_commit do
      MollieSubscriptionCancellationJob.perform_later(
        subscription,
        expected_mollie_subscription_id: expected_remote_id,
        expected_first_payment_id: expected_first_payment_id,
        expected_payment_id: payment.id
      )
    end
  end

  def restore_entitlement_after_chargeback_reversal!(payment)
    if payment.payment_type == 'credit_purchase'
      purchase = payment.credit_purchase
      purchase&.update!(status: 'completed') if payment.fulfilled_at? && purchase&.status == 'refunded'
      return
    end
    return unless payment.payment_type.start_with?('subscription_')
    return unless payment.entitlement_revoked_at?
    return if payment.entitlement_restored_at?

    subscription = payment.subscription || payment.user&.subscription
    return unless subscription

    unless current_billing_generation?(subscription, payment)
      # A replacement contract now owns access. Resolve the old payment's
      # reversal marker without mutating the newer billing generation.
      payment.update!(entitlement_restored_at: Time.current)
      return
    end
    if subscription.tier == 'pro'
      # A later paid renewal may already have restored this same remote
      # generation. Do not overwrite its status or shorten its paid period.
      payment.update!(entitlement_restored_at: Time.current)
      return
    end

    restorable_period_end = [
      payment.entitlement_prior_period_end,
      payment.service_period_end,
      subscription.current_period_end
    ].compact.max
    user = subscription.user
    if restorable_period_end.blank? ||
       restorable_period_end <= Time.current ||
       !user&.active? ||
       user.deletion_scheduled_for.present?
      payment.update!(entitlement_restored_at: Time.current)
      return
    end

    prior_status = payment.entitlement_prior_status
    restored_status = if subscription.mollie_subscription_id.blank?
                        # A blank provider pointer is ambiguous while an
                        # initial-subscription create may have succeeded
                        # remotely before its response was stored. Only a
                        # provider-confirmed/user-requested cancellation sets
                        # canceled_at. Otherwise restore the local contract to
                        # active so durable provisioning recovery can reconcile
                        # the remote generation by immutable metadata and adopt
                        # it without creating a duplicate.
                        subscription.canceled_at.present? ? 'canceled' : 'active'
                      elsif Subscription::STATUSES.include?(prior_status)
                        prior_status
                      else
                        'active'
                      end
    subscription.update!(
      tier: 'pro',
      status: restored_status,
      current_period_end: restorable_period_end,
      canceled_at: restored_status == 'active' ? nil : subscription.canceled_at
    )
    payment.update!(entitlement_restored_at: Time.current)
  end

  def current_billing_generation?(subscription, payment)
    if payment.payment_type == 'subscription_initial'
      return subscription.mollie_first_payment_id == payment.mollie_payment_id
    end

    current_remote_id = subscription.mollie_subscription_id
    return current_remote_id == payment.mollie_subscription_id if current_remote_id.present?

    initial_payment = MolliePayment.where(
      subscription_id: subscription.id,
      payment_type: 'subscription_initial',
      mollie_subscription_id: payment.mollie_subscription_id
    ).order(created_at: :desc).first
    initial_payment &&
      subscription.mollie_first_payment_id == initial_payment.mollie_payment_id
  end

  def verify_amount!(expected_cents, expected_currency)
    actual = amount_cents!(@data.fetch('amount'), expected_currency: expected_currency)
    raise VerificationError, 'payment amount mismatch' unless actual == expected_cents.to_i
  rescue KeyError
    raise VerificationError, 'payment amount is missing'
  end

  def verify_remote_customer!(expected_customer_id)
    return if expected_customer_id.blank?
    raise VerificationError, 'invalid expected customer id' unless expected_customer_id.match?(CUSTOMER_ID)
    raise VerificationError, 'payment customer mismatch' unless @data['customerId'] == expected_customer_id
  end

  def verify_metadata_value!(metadata, key, expected)
    raise VerificationError, "payment metadata #{key} mismatch" unless metadata[key].to_s == expected.to_s
  end

  def retained_contract_id!(payment, kind)
    contract_column = :"contract_#{kind}_id"
    association_column = :"#{kind}_id"
    value = if payment.has_attribute?(contract_column)
              payment.public_send(contract_column).presence
            end
    value ||= payment.public_send(association_column).presence
    value || raise(VerificationError, "payment #{kind} contract reference is missing")
  end

  def parsed_metadata
    case @data['metadata']
    when Hash
      @data['metadata'].deep_stringify_keys
    when String
      parsed = JSON.parse(@data['metadata'])
      raise VerificationError, 'payment metadata is not an object' unless parsed.is_a?(Hash)

      parsed.deep_stringify_keys
    else
      raise VerificationError, 'payment metadata is missing'
    end
  rescue JSON::ParserError
    raise VerificationError, 'payment metadata is invalid'
  end

  def amount_cents!(money, expected_currency:)
    currency = money.fetch('currency').to_s.upcase
    raise VerificationError, 'payment currency mismatch' unless currency == expected_currency.to_s.upcase

    value = money.fetch('value').to_s
    raise VerificationError, 'invalid payment amount' unless value.match?(/\A(?:0|[1-9]\d*)\.\d{2}\z/)

    decimal = BigDecimal(value, exception: false)
    raise VerificationError, 'invalid payment amount' unless decimal && decimal >= 0

    cents = decimal * 100
    cents.to_i
  rescue KeyError
    raise VerificationError, 'invalid money object'
  end

  def optional_money_cents(money, expected_currency)
    return 0 if money.blank?

    amount_cents!(money.deep_stringify_keys, expected_currency: expected_currency)
  end

  def normalized_status
    @data['status'].to_s
  end

  def parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def after_commit(&block)
    @post_commit << block
  end

  def account_eligible_for_fulfillment?
    @account_eligible_for_fulfillment != false
  end

  def run_post_commit
    @post_commit.each do |hook|
      hook.call
    rescue StandardError => e
      # The DB retains invoice_state/adjustment status as pending, and the
      # reconciliation task will enqueue missed durable work.
      Rails.logger.error("[Mollie] Post-commit enqueue failed: #{e.class}")
    end
  end
end
