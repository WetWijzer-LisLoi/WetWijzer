# frozen_string_literal: true

# Durably generates the sales invoice for a provider-verified CoinGate payment.
# The provider order id is the accounting idempotency key, so a lost enqueue or
# duplicate callback cannot allocate a second invoice.
class CoinGateInvoiceJob < ApplicationJob
  queue_as :default

  PROCESSING_LEASE = 15.minutes
  COMPLETED_INVOICE_STATUSES = %w[generated sent peppol_sent].freeze

  retry_on InvoiceService::InvoiceError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(crypto_payment)
    payment = crypto_payment.reload
    claim_token = claim!(payment)
    return unless claim_token

    user = payment.user
    raise InvoiceService::InvoiceError, 'CoinGate invoice user is unavailable' unless user

    invoice = case payment.payment_type
              when 'credit_purchase'
                purchase = payment.credit_purchase
                raise InvoiceService::InvoiceError, 'CoinGate credit purchase is unavailable' unless purchase

                InvoiceService.generate_for_credit_purchase(
                  user: user,
                  purchase: purchase,
                  payment: payment,
                  payment_provider: 'crypto',
                  provider_payment_id: payment.coingate_order_id
                )
              when 'subscription'
                InvoiceService.generate_for_subscription_payment(
                  user: user,
                  payment: payment,
                  payment_provider: 'crypto',
                  provider_payment_id: payment.coingate_order_id
                )
              end
    unless invoice && COMPLETED_INVOICE_STATUSES.include?(invoice.status)
      raise InvoiceService::InvoiceError, 'CoinGate invoice did not reach a completed state'
    end

    complete_claim!(payment, claim_token)
  rescue InvoiceService::InvoiceError => e
    fail_claim!(payment, claim_token, e)
    raise
  end

  private

  def claim!(payment)
    token = Time.current
    base = CryptoPayment.where(id: payment.id)
                        .where.not(paid_at: nil)
                        .where(status: %w[paid refunded partially_refunded])
    unclaimed = base.where(invoice_state: %w[pending failed])
    expired = base.where(invoice_state: 'processing')
                  .where('updated_at <= ?', PROCESSING_LEASE.ago)
    claimed = unclaimed.or(expired).update_all(
      invoice_state: 'processing',
      invoice_error: nil,
      updated_at: token
    )
    token if claimed == 1
  end

  def complete_claim!(payment, token)
    claimed_payment(payment, token).update_all(
      invoice_state: 'completed',
      invoice_error: nil,
      updated_at: Time.current
    ) == 1
  end

  def fail_claim!(payment, token, error)
    return false unless payment && token

    claimed_payment(payment, token).update_all(
      invoice_state: 'failed',
      invoice_error: error.class.name,
      updated_at: Time.current
    ) == 1
  end

  def claimed_payment(payment, token)
    CryptoPayment.where(id: payment.id, invoice_state: 'processing', updated_at: token)
  end
end
