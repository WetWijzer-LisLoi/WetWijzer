# frozen_string_literal: true

# Generates one immutable accounting document for each provider adjustment:
# a credit note for refund/chargeback increases, or a positive corrected
# invoice for a confirmed chargeback reversal. Donations have no consideration
# and remain ledger-only adjustments.
class MolliePaymentAdjustmentJob < ApplicationJob
  queue_as :default

  PROCESSING_LEASE = 15.minutes
  COMPLETED_INVOICE_STATUSES = %w[generated sent peppol_sent].freeze

  retry_on InvoiceService::InvoiceError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(mollie_payment_adjustment)
    adjustment = mollie_payment_adjustment.reload
    claim_token = claim!(adjustment)
    return unless claim_token

    payment = adjustment.mollie_payment
    if payment.donation?
      complete_claim!(adjustment, claim_token, invoice_id: nil)
      return
    end

    original = PlatformInvoice.where(
      payment_provider: 'mollie',
      provider_payment_id: payment.mollie_payment_id
    ).where.not(invoice_type: 'credit_note').first
    raise InvoiceService::InvoiceError, 'original sales invoice is not available yet' unless original

    document = if adjustment.chargeback_reversal?
                 generate_chargeback_reversal_document(adjustment, original)
               else
                 generate_credit_note(adjustment, original)
               end
    completed = COMPLETED_INVOICE_STATUSES.include?(document.status)
    unless completed
      raise InvoiceService::InvoiceError,
            'adjustment document generation did not reach a completed state'
    end

    complete_claim!(adjustment, claim_token, invoice_id: document.id)
  rescue InvoiceService::InvoiceError => e
    fail_claim!(adjustment, claim_token, e)
    raise
  end

  # Aggregate charged-back amounts may cycle full -> zero more than once. Walk
  # prior chargeback deltas in order, consume all earlier reversal deltas, then
  # return the exact immutable credit notes affected by this reversal cycle.
  # Kept as a public class method so the admin regeneration path reconstructs
  # precisely the same legal references as the durable background job.
  def self.credit_notes_consumed_by_reversal!(adjustment)
    earlier = adjustment.mollie_payment.adjustments.where('id < ?', adjustment.id)
    already_reversed = earlier.where(adjustment_type: 'chargeback_reversal')
                               .sum(:delta_amount_cents)
    remaining = adjustment.delta_amount_cents
    documents = []

    earlier.where(adjustment_type: 'chargeback').order(:id).each do |chargeback|
      available = chargeback.delta_amount_cents
      skipped = [available, already_reversed].min
      available -= skipped
      already_reversed -= skipped
      next if available <= 0

      consumed = [available, remaining].min
      if consumed.positive?
        document = chargeback.invoice
        unless document&.credit_note? &&
               COMPLETED_INVOICE_STATUSES.include?(document.status)
          raise InvoiceService::InvoiceError,
                'chargeback credit note is not available for its reversal'
        end
        documents << document
        remaining -= consumed
      end
      break if remaining.zero?
    end

    unless remaining.zero?
      raise InvoiceService::InvoiceError,
            'chargeback reversal exceeds documented chargeback adjustments'
    end

    documents.uniq(&:id)
  end

  private

  def generate_credit_note(adjustment, original)
    reason = "Mollie #{adjustment.adjustment_type} (adjustment ##{adjustment.id})"
    credit_note = if adjustment.invoice_id.present?
                    PlatformInvoice.find(adjustment.invoice_id)
                  else
                    PlatformInvoice.find_by(
                      invoice_type: 'credit_note',
                      original_invoice_id: original.id,
                      refund_reason: reason
                    )
                  end

    InvoiceService.generate_credit_note(
      original_invoice: original,
      refund_amount_cents: adjustment.delta_amount_cents,
      reason: reason,
      credit_note: credit_note
    )
  end

  def generate_chargeback_reversal_document(adjustment, original)
    reason = "Mollie chargeback_reversal (adjustment ##{adjustment.id})"
    correction = if adjustment.invoice_id.present?
                   PlatformInvoice.find(adjustment.invoice_id)
                 else
                   PlatformInvoice.find_by(
                     invoice_type: 'chargeback_reversal',
                     original_invoice_id: original.id,
                     refund_reason: reason
                   )
                 end

    InvoiceService.generate_chargeback_reversal_document(
      original_invoice: original,
      adjustment: adjustment,
      referenced_credit_notes: self.class.credit_notes_consumed_by_reversal!(adjustment),
      correction_invoice: correction
    )
  end

  def claim!(adjustment)
    claim_token = Time.current
    base = MolliePaymentAdjustment.where(id: adjustment.id)
    unclaimed = base.where(status: %w[pending failed])
    expired = base.where(status: 'processing')
                  .where('updated_at <= ?', PROCESSING_LEASE.ago)
    claimed = unclaimed.or(expired).update_all(
      status: 'processing',
      error: nil,
      updated_at: claim_token
    )

    claim_token if claimed == 1
  end

  def complete_claim!(adjustment, claim_token, invoice_id:)
    claimed_adjustment(adjustment, claim_token).update_all(
      status: 'processed',
      invoice_id: invoice_id,
      error: nil,
      updated_at: Time.current
    ) == 1
  end

  def fail_claim!(adjustment, claim_token, error)
    return false unless adjustment && claim_token

    claimed_adjustment(adjustment, claim_token).update_all(
      status: 'failed',
      error: error.class.name,
      updated_at: Time.current
    ) == 1
  end

  def claimed_adjustment(adjustment, claim_token)
    MolliePaymentAdjustment.where(
      id: adjustment.id,
      status: 'processing',
      updated_at: claim_token
    )
  end
end
