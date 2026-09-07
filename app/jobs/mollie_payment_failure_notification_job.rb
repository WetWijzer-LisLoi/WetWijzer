# frozen_string_literal: true

# Sends one failed-renewal notification from the durable Mollie payment
# outbox marker. Both repeated webhooks and duplicate job delivery are safe.
class MolliePaymentFailureNotificationJob < ApplicationJob
  queue_as :default

  PROCESSING_LEASE = 15.minutes

  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(mollie_payment)
    payment = mollie_payment.reload
    claim_token = claim!(payment)
    return unless claim_token

    payment.reload
    unless deliverable?(payment)
      release_claim!(payment, claim_token)
      return
    end

    UserMailer.payment_failed(payment.user).deliver_later if payment.user
    complete_claim!(payment, claim_token)
  rescue StandardError
    release_claim!(payment, claim_token)
    raise
  end

  private

  def claim!(payment)
    now = Time.current
    claim_token = now + PROCESSING_LEASE
    claimable = MolliePayment.where(
      id: payment.id,
      payment_type: 'subscription_renewal',
      status: MolliePaymentProcessor::TERMINAL_FAILURES,
      failure_notification_sent_at: nil
    ).where.not(failure_notification_enqueued_at: nil)
    claimed = claimable.where('failure_notification_enqueued_at <= ?', now)
                       .update_all(
                         failure_notification_enqueued_at: claim_token,
                         updated_at: now
                       )

    claim_token if claimed == 1
  end

  def deliverable?(payment)
    user = payment.user
    subscription = payment.subscription || user&.subscription
    return false unless subscription&.status == 'past_due'
    return false unless subscription.mollie_subscription_id == payment.mollie_subscription_id

    !newer_fulfilled_renewal_exists?(payment)
  end

  def complete_claim!(payment, claim_token)
    claimed_payment(payment, claim_token).update_all(
      failure_notification_sent_at: Time.current,
      updated_at: Time.current
    ) == 1
  end

  def release_claim!(payment, claim_token)
    return false unless payment && claim_token

    now = Time.current
    claimed_payment(payment, claim_token).update_all(
      failure_notification_enqueued_at: now,
      updated_at: now
    ) == 1
  end

  def claimed_payment(payment, claim_token)
    MolliePayment.where(
      id: payment.id,
      failure_notification_enqueued_at: claim_token,
      failure_notification_sent_at: nil
    )
  end

  def newer_fulfilled_renewal_exists?(payment)
    return false unless payment.provider_created_at

    newer = MolliePayment.where(
      subscription_id: payment.subscription_id,
      payment_type: 'subscription_renewal',
      mollie_subscription_id: payment.mollie_subscription_id
    ).where.not(fulfilled_at: nil)
    newer.where('provider_created_at > ?', payment.provider_created_at).exists?
  end
end
