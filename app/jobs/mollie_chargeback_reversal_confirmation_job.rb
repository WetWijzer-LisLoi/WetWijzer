# frozen_string_literal: true

# Confirms a possible chargeback reversal with a fresh provider read after a
# delay. Overlapping webhook lookups can finish out of order, so one lower
# amountChargedBack snapshot is never enough to restore money-backed access.
class MollieChargebackReversalConfirmationJob < ApplicationJob
  queue_as :default

  retry_on MolliePaymentProcessor::TransientError,
           MollieApiClient::NetworkError,
           MollieApiClient::InvalidResponseError,
           MollieApiClient::ApiError,
           wait: :polynomially_longer,
           attempts: 5
  discard_on ActiveJob::DeserializationError

  def self.schedule(payment, candidate_at:)
    due_at = candidate_at + MolliePaymentProcessor::CHARGEBACK_REVERSAL_CONFIRMATION_DELAY
    set(wait_until: [due_at, Time.current].max).perform_later(payment)
  end

  def perform(payment)
    payment.reload
    candidate_at = payment.chargeback_reversal_candidate_at
    return unless candidate_at

    due_at = candidate_at + MolliePaymentProcessor::CHARGEBACK_REVERSAL_CONFIRMATION_DELAY
    if due_at > Time.current
      self.class.schedule(payment, candidate_at: candidate_at)
      return
    end

    snapshot = MollieApiClient.new.get_payment(payment.mollie_payment_id)
    raise MollieApiClient::InvalidResponseError, 'Mollie returned the wrong payment resource' unless snapshot['id'] == payment.mollie_payment_id

    MolliePaymentProcessor.new(
      snapshot,
      confirm_chargeback_reversal: true
    ).process!
  end
end
