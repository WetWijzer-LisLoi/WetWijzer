# frozen_string_literal: true

# Tracks cryptocurrency payment orders from CoinGate.
# Links to either a Subscription (for Pro upgrades) or a CreditPurchase (for credit packs).
#
# Schema (migration needed):
#   t.references :user,            null: false
#   t.references :credit_purchase, null: true
#   t.string     :coingate_order_id
#   t.string     :payment_type      - "subscription" or "credit_purchase"
#   t.string     :status             - "new", "pending", "confirming", "paid", "expired", "canceled", "invalid"
#   t.string     :verification_token - Random token for webhook verification
#   t.integer    :amount_cents       - Price in EUR cents
#   t.string     :pay_currency       - Currency the user chose to pay with (BTC, ETH, etc.)
#   t.string     :pay_amount         - Amount in pay_currency
#   t.string     :payment_url        - CoinGate checkout URL
#   t.datetime   :paid_at
#   t.timestamps
class CryptoPayment < AccountRecord
  INVOICE_STATES = %w[pending processing completed failed not_required].freeze

  belongs_to :user, optional: true
  belongs_to :credit_purchase, optional: true
  belongs_to :refund_invoice, class_name: 'PlatformInvoice', optional: true

  STATUSES = %w[
    new pending confirming paid expired canceled invalid refunded partially_refunded
  ].freeze

  attr_readonly :merchant_order_id,
                :contract_user_id,
                :contract_credit_purchase_id

  before_validation :capture_contract_references, on: :create

  validates :coingate_order_id,
            presence: true,
            format: { with: /\A[1-9]\d*\z/ }
  validates :merchant_order_id,
            uniqueness: true,
            format: { with: /\A(?:sub|credit)_\d+_\d+\z/ },
            allow_blank: true
  validates :payment_type, presence: true, inclusion: { in: %w[subscription credit_purchase] }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :verification_token, presence: true
  validates :invoice_state, presence: true, inclusion: { in: INVOICE_STATES }
  validates :refund_invoice_state, presence: true, inclusion: { in: INVOICE_STATES }
  validate :contract_references_match_payment_type, on: :create

  scope :recent, -> { order(created_at: :desc) }

  def completed?
    status == 'paid'
  end

  # InvoiceService consumes a provider-neutral fulfilled-payment contract.
  def fulfilled_at?
    paid_at.present?
  end

  def pending?
    %w[new pending confirming].include?(status)
  end

  def failed?
    %w[expired canceled invalid].include?(status)
  end

  # Generate a secure random token for webhook verification.
  def self.generate_token
    SecureRandom.hex(32)
  end

  private

  def capture_contract_references
    self.contract_user_id ||= user_id
    self.contract_credit_purchase_id ||= credit_purchase_id
  end

  def contract_references_match_payment_type
    errors.add(:contract_user_id, 'must match the user') unless contract_user_id == user_id

    if payment_type == 'credit_purchase'
      unless contract_credit_purchase_id == credit_purchase_id
        errors.add(:contract_credit_purchase_id, 'must match the credit purchase')
      end
    elsif contract_credit_purchase_id.present?
      errors.add(:contract_credit_purchase_id, 'must be absent for subscriptions')
    end
  end
end
