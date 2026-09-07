# frozen_string_literal: true

# Recovers CoinGate invoice/credit-note jobs whose original post-commit enqueue
# was lost or whose processing lease expired.
class CoinGatePendingWorkReconciliationJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_SIZE = 25
  MAX_BATCH_SIZE = 100

  def perform(batch_size: DEFAULT_BATCH_SIZE)
    size = Integer(batch_size)
    raise ArgumentError, 'batch_size is invalid' unless size.between?(1, MAX_BATCH_SIZE)

    result = { invoices: 0, refunds: 0 }
    enqueue_scope(invoice_scope, CoinGateInvoiceJob, size) { result[:invoices] += 1 }
    enqueue_scope(refund_scope, CoinGateRefundInvoiceJob, size) { result[:refunds] += 1 }
    result
  rescue TypeError, ArgumentError
    raise ArgumentError, 'batch_size is invalid'
  end

  private

  def invoice_scope
    base = CryptoPayment.where(status: %w[paid refunded partially_refunded])
                        .where.not(paid_at: nil)
    base.where(invoice_state: %w[pending failed]).or(
      base.where(invoice_state: 'processing')
          .where('updated_at <= ?', CoinGateInvoiceJob::PROCESSING_LEASE.ago)
    )
  end

  def refund_scope
    base = CryptoPayment.where(status: 'refunded')
    base.where(refund_invoice_state: %w[pending failed]).or(
      base.where(refund_invoice_state: 'processing')
          .where('updated_at <= ?', CoinGateRefundInvoiceJob::PROCESSING_LEASE.ago)
    )
  end

  def enqueue_scope(scope, job_class, size)
    scope.reorder(updated_at: :asc, id: :asc).limit(size).each do |payment|
      job_class.perform_later(payment)
      yield
    end
  end
end
