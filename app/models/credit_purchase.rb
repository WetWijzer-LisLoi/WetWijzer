# frozen_string_literal: true

class CreditPurchase < AccountRecord
  belongs_to :user
  has_many :mollie_payments, dependent: :nullify
  has_many :crypto_payments, dependent: :nullify

  before_validation { self.currency = currency.to_s.upcase if has_attribute?(:currency) && currency.present? }

  PACKAGES = {
    'starter' => { price_cents: 299, pro_price_cents: 209, credits: 10, label: '10 credits' },  # €0.30/cr → Pro: €0.21/cr (30% off)
    'medium' => { price_cents: 499, pro_price_cents: 349, credits: 20, label: '20 credits' },   # €0.25/cr → Pro: €0.17/cr (30% off)
    'large' => { price_cents: 899, pro_price_cents: 629, credits: 50, label: '50 credits' }     # €0.18/cr → Pro: €0.13/cr (30% off)
  }.freeze

  # Pro subscribers get 15cr/month with their €2.99 plan (~€0.20/cr before other Pro benefits)
  # The 'starter' pack at €2.99 is a deliberate upsell anchor:
  # "10 credits for €2.99 vs 40 free credits/month with Pro"

  STATUSES = %w[pending completed failed refunded].freeze
  PAYMENT_METHODS = %w[mollie crypto stripe].freeze

  validates :package, presence: true, inclusion: { in: PACKAGES.keys }
  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :credits_granted, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :currency, inclusion: { in: %w[EUR] }, allow_blank: true

  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }

  def self.package_info(package_name)
    PACKAGES[package_name.to_s]
  end

  def complete!
    return if status == 'completed'

    transaction do
      update!(status: 'completed')
      user.add_credits!(credits_granted)
    end
  end

  def fail!
    update!(status: 'failed')
  end

  def refund!
    return unless status == 'completed'

    transaction do
      update!(status: 'refunded')
      # Claw back the FULL granted amount even if the user already spent part
      # of it: a negative balance is the correct financial state after a full
      # refund (deduct_credits! is all-or-nothing and would silently keep the
      # spent credits while the money goes back).
      user.add_credits!(-credits_granted)
    end
  end

  def price_euros
    amount_cents / 100.0
  end

  def completed?
    status == 'completed'
  end

  def pending?
    status == 'pending'
  end
end
