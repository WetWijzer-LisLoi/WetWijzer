# frozen_string_literal: true

# Durably generates the legally required sales invoice for one fulfilled
# Mollie payment. InvoiceService also enforces a provider-payment uniqueness
# key, making retries and duplicate job delivery safe.
class MollieInvoiceJob < ApplicationJob
  queue_as :default

  PROCESSING_LEASE = 15.minutes
  COMPLETED_INVOICE_STATUSES = %w[generated sent peppol_sent].freeze

  retry_on InvoiceService::InvoiceError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(mollie_payment)
    payment = mollie_payment.reload
    claim_token = claim!(payment)
    return unless claim_token

    invoice = case payment.payment_type
              when 'credit_purchase'
                InvoiceService.generate_for_credit_purchase(
                  user: payment.user,
                  purchase: payment.credit_purchase,
                  payment: payment
                )
              when 'subscription_initial', 'subscription_renewal'
                InvoiceService.generate_for_subscription_payment(
                  user: payment.user,
                  payment: payment
                )
              end
    unless invoice && COMPLETED_INVOICE_STATUSES.include?(invoice.status)
      raise InvoiceService::InvoiceError, 'invoice generation did not reach a completed state'
    end

    complete_claim!(payment, claim_token)
  rescue InvoiceService::InvoiceError => e
    fail_claim!(payment, claim_token, e)
    raise
  end

  private

  def claim!(payment)
    claim_token = Time.current
    base = MolliePayment.where(id: payment.id).where.not(fulfilled_at: nil)
    unclaimed = base.where(invoice_state: %w[pending failed])
    expired = base.where(invoice_state: 'processing')
                  .where('updated_at <= ?', PROCESSING_LEASE.ago)
    claimed = unclaimed.or(expired).update_all(
      invoice_state: 'processing',
      invoice_error: nil,
      updated_at: claim_token
    )

    claim_token if claimed == 1
  end

  def complete_claim!(payment, claim_token)
    claimed_payment(payment, claim_token).update_all(
      invoice_state: 'completed',
      invoice_error: nil,
      updated_at: Time.current
    ) == 1
  end

  def fail_claim!(payment, claim_token, error)
    return false unless payment && claim_token

    claimed_payment(payment, claim_token).update_all(
      invoice_state: 'failed',
      invoice_error: error.class.name,
      updated_at: Time.current
    ) == 1
  end

  def claimed_payment(payment, claim_token)
    MolliePayment.where(
      id: payment.id,
      invoice_state: 'processing',
      updated_at: claim_token
    )
  end
end
