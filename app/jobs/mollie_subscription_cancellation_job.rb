# frozen_string_literal: true

# Durable cancellation used for provider-originated full refunds/chargebacks.
class MollieSubscriptionCancellationJob < ApplicationJob
  queue_as :default

  retry_on MollieSubscriptionCancellationService::CancellationError,
           wait: :polynomially_longer,
           attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(subscription, expected_mollie_subscription_id:, expected_first_payment_id:,
              expected_payment_id:)
    subscription.reload
    return unless subscription.mollie_subscription_id == expected_mollie_subscription_id
    return unless subscription.mollie_first_payment_id == expected_first_payment_id

    # A chargeback can be reversed after this job was enqueued. Re-read the
    # originating payment immediately before provider I/O so that a stale job
    # cannot cancel a contract whose payment is chargeable again.
    payment = MolliePayment.find_by(
      id: expected_payment_id,
      subscription_id: subscription.id
    )
    return unless payment
    return unless payment.refundable_amount_cents.zero?
    return if payment.entitlement_restored_at?
    return if payment.superseded_subscription_entitlement?

    guard = lambda do |locked_subscription|
      cancellation_still_required?(
        locked_subscription,
        expected_payment_id: expected_payment_id,
        expected_mollie_subscription_id: expected_mollie_subscription_id,
        expected_first_payment_id: expected_first_payment_id
      )
    end
    MollieSubscriptionCancellationService.new(subscription, guard: guard).cancel!
  end

  private

  def cancellation_still_required?(subscription, expected_payment_id:,
                                   expected_mollie_subscription_id:,
                                   expected_first_payment_id:)
    return false unless subscription.mollie_subscription_id == expected_mollie_subscription_id
    return false unless subscription.mollie_first_payment_id == expected_first_payment_id

    payment = MolliePayment.find_by(
      id: expected_payment_id,
      subscription_id: subscription.id
    )
    payment &&
      payment.refundable_amount_cents.zero? &&
      !payment.entitlement_restored_at? &&
      !payment.superseded_subscription_entitlement?
  end
end
