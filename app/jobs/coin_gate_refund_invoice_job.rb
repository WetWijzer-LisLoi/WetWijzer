# frozen_string_literal: true

# Generates one full credit note for a provider-verified CoinGate refund. The
# original invoice snapshot survives account erasure, so a later refund remains
# bookable even when user and purchase associations have been nullified.
class CoinGateRefundInvoiceJob < ApplicationJob
  queue_as :default

  PROCESSING_LEASE = 15.minutes
  COMPLETED_INVOICE_STATUSES = %w[generated sent peppol_sent].freeze

  retry_on InvoiceService::InvoiceError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(crypto_payment)
    payment = crypto_payment.reload
    claim_token = claim!(payment)
    return unless claim_token

    original = PlatformInvoice.where(
      payment_provider: 'crypto',
      provider_payment_id: payment.coingate_order_id
    ).where.not(invoice_type: 'credit_note').first
    raise InvoiceService::InvoiceError, 'CoinGate original invoice is unavailable' unless original

    reason = "CoinGate refund (payment ##{payment.id})"
    credit_note = PlatformInvoice.find_by(
      original_invoice_id: original.id,
      refund_reason: reason,
      invoice_type: 'credit_note'
    )
    credit_note = InvoiceService.generate_credit_note(
      original_invoice: original,
      refund_amount_cents: payment.amount_cents,
      reason: reason,
      credit_note: credit_note
    )
    unless COMPLETED_INVOICE_STATUSES.include?(credit_note.status)
      raise InvoiceService::InvoiceError, 'CoinGate credit note did not reach a completed state'
    end

    complete_claim!(payment, claim_token, credit_note.id)
  rescue InvoiceService::InvoiceError => e
    fail_claim!(payment, claim_token, e)
    raise
  end

  private

  def claim!(payment)
    token = Time.current
    base = CryptoPayment.where(id: payment.id, status: 'refunded')
    unclaimed = base.where(refund_invoice_state: %w[pending failed])
    expired = base.where(refund_invoice_state: 'processing')
                  .where('updated_at <= ?', PROCESSING_LEASE.ago)
    claimed = unclaimed.or(expired).update_all(
      refund_invoice_state: 'processing',
      refund_invoice_error: nil,
      updated_at: token
    )
    token if claimed == 1
  end

  def complete_claim!(payment, token, invoice_id)
    claimed_payment(payment, token).update_all(
      refund_invoice_state: 'completed',
      refund_invoice_id: invoice_id,
      refund_invoice_error: nil,
      updated_at: Time.current
    ) == 1
  end

  def fail_claim!(payment, token, error)
    return false unless payment && token

    claimed_payment(payment, token).update_all(
      refund_invoice_state: 'failed',
      refund_invoice_error: error.class.name,
      updated_at: Time.current
    ) == 1
  end

  def claimed_payment(payment, token)
    CryptoPayment.where(
      id: payment.id,
      refund_invoice_state: 'processing',
      updated_at: token
    )
  end
end
