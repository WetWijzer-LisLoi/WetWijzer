# frozen_string_literal: true

# One durable aggregate transition for a Mollie refund, chargeback, or
# chargeback reversal.
#
# Mollie exposes cumulative refunded/charged-back amounts. Recording both that
# cumulative value and its newly-observed delta makes repeated and out-of-order
# webhook delivery safe. A chargeback reversal creates a positive correction
# document that references both the original sales invoice and the credit note
# it reverses; the earlier credit note is never overwritten or deleted.
class MolliePaymentAdjustment < AccountRecord
  ADJUSTMENT_TYPES = %w[refund chargeback chargeback_reversal].freeze
  STATUSES = %w[pending processing processed failed].freeze

  belongs_to :mollie_payment, inverse_of: :adjustments
  belongs_to :invoice, class_name: 'PlatformInvoice', optional: true

  validates :adjustment_type, presence: true, inclusion: { in: ADJUSTMENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cumulative_amount_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :delta_amount_cents,
            numericality: { only_integer: true, greater_than: 0 }
  validate :positive_cumulative_amount_for_reversal_increases
  validate :delta_does_not_exceed_cumulative_amount

  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }

  def chargeback_reversal?
    adjustment_type == 'chargeback_reversal'
  end

  private

  def positive_cumulative_amount_for_reversal_increases
    return if chargeback_reversal?
    return if cumulative_amount_cents.to_i.positive?

    errors.add(:cumulative_amount_cents, 'must be greater than zero')
  end

  def delta_does_not_exceed_cumulative_amount
    return if chargeback_reversal?
    return if delta_amount_cents.blank? || cumulative_amount_cents.blank?
    return if delta_amount_cents <= cumulative_amount_cents

    errors.add(:delta_amount_cents, 'cannot exceed the cumulative amount')
  end
end
