# frozen_string_literal: true

# Durable local intent and fulfillment ledger for every Mollie payment.
#
# The record is created before provider I/O. checkout_token identifies the
# browser return without trusting query-string provider data, while
# idempotency_key is reused for every retry of the same remote creation call.
class MolliePayment < AccountRecord
  DONATION_AMOUNTS_CENTS = [300, 500, 1_000, 2_500].freeze
  PAYMENT_TYPES = %w[subscription_initial subscription_renewal credit_purchase donation].freeze
  STATUSES = %w[created open pending authorized paid canceled expired failed refunded charged_back].freeze
  SEQUENCE_TYPES = %w[oneoff first recurring].freeze
  INVOICE_STATES = %w[pending processing completed failed not_required].freeze
  TERMINAL_STATUSES = %w[canceled expired failed refunded charged_back].freeze

  belongs_to :user, optional: true
  belongs_to :subscription, optional: true
  belongs_to :credit_purchase, optional: true
  has_many :adjustments,
           class_name: 'MolliePaymentAdjustment',
           inverse_of: :mollie_payment,
           dependent: :restrict_with_exception

  attr_readonly :contract_user_id,
                :contract_subscription_id,
                :contract_credit_purchase_id

  before_validation :normalize_currency
  before_validation :generate_checkout_token, on: :create
  before_validation :generate_idempotency_key, on: :create
  before_validation :capture_contract_references, on: :create
  before_validation :generate_subscription_idempotency_key,
                    on: :create,
                    if: :subscription_initial?

  validates :payment_type, presence: true, inclusion: { in: PAYMENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, presence: true, inclusion: { in: %w[EUR] }
  validates :checkout_token, presence: true, uniqueness: true
  validates :idempotency_key, presence: true, uniqueness: true
  validates :subscription_idempotency_key, uniqueness: true, allow_blank: true
  validates :mollie_payment_id, uniqueness: true, allow_blank: true
  validates :sequence_type, inclusion: { in: SEQUENCE_TYPES }, allow_blank: true
  validates :refunded_amount_cents,
            :charged_back_amount_cents,
            :credits_granted,
            :credits_reversed,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :chargeback_reversal_candidate_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true
  validates :invoice_state, presence: true, inclusion: { in: INVOICE_STATES }
  validate :credit_purchase_matches_payment_type, on: :create
  validate :subscription_matches_payment_type, on: :create
  validate :contract_references_match_payment_type, on: :create
  # This is an enduring financial contract, not merely a checkout-time shape:
  # no later internal update may turn a donation into consideration, attach it
  # to an account, or make it invoiceable.
  validate :donation_contract_is_reward_free
  validate :adjustment_totals_do_not_exceed_payment
  validate :reversed_credits_do_not_exceed_grant
  validate :chargeback_reversal_candidate_is_consistent
  validate :service_period_is_ordered

  scope :recent, -> { order(created_at: :desc) }
  scope :unfulfilled_paid, -> { where(status: 'paid', fulfilled_at: nil) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def paid?
    status == 'paid' && paid_at.present?
  end

  def fulfilled?
    fulfilled_at.present?
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def refunded?
    refunded_amount_cents.to_i.positive?
  end

  def charged_back?
    charged_back_amount_cents.to_i.positive?
  end

  def refundable_amount_cents
    [amount_cents.to_i - refunded_amount_cents.to_i - charged_back_amount_cents.to_i, 0].max
  end

  def amount_matches?(remote_amount_cents:, remote_currency:)
    amount_cents == remote_amount_cents.to_i && currency == remote_currency.to_s.upcase
  end

  def superseded_subscription_entitlement?
    return false unless subscription_id.present?
    return false unless payment_type.start_with?('subscription_')

    candidates = self.class.where(
      subscription_id: subscription_id,
      payment_type: %w[subscription_initial subscription_renewal]
    ).where.not(id: id)
      .where.not(fulfilled_at: nil)

    if service_period_end.present?
      return true if candidates.where('service_period_end > ?', service_period_end).exists?
    end
    return false unless provider_created_at.present?

    candidates.where('provider_created_at > ?', provider_created_at).exists?
  end

  def subscription_initial?
    payment_type == 'subscription_initial'
  end

  def donation?
    payment_type == 'donation'
  end

  private

  def normalize_currency
    self.currency = currency.to_s.upcase.presence
  end

  def generate_checkout_token
    self.checkout_token ||= SecureRandom.urlsafe_base64(32)
  end

  def generate_idempotency_key
    self.idempotency_key ||= SecureRandom.uuid
  end

  def generate_subscription_idempotency_key
    self.subscription_idempotency_key ||= SecureRandom.uuid
  end

  def capture_contract_references
    self.contract_user_id ||= user_id
    self.contract_subscription_id ||= subscription_id
    self.contract_credit_purchase_id ||= credit_purchase_id
  end

  def credit_purchase_matches_payment_type
    if payment_type == 'credit_purchase'
      errors.add(:credit_purchase, :blank) unless credit_purchase
    elsif credit_purchase_id.present?
      errors.add(:credit_purchase, 'must be absent for this payment type')
    end
  end

  def subscription_matches_payment_type
    if subscription_initial?
      errors.add(:subscription, :blank) unless subscription
      errors.add(:user, 'must own the subscription') if subscription && user_id != subscription.user_id
      errors.add(:subscription_idempotency_key, :blank) if subscription_idempotency_key.blank?
    elsif payment_type == 'credit_purchase' && subscription_id.present?
      errors.add(:subscription, 'must be absent for credit payments')
    end
  end

  def donation_contract_is_reward_free
    return unless donation?

    errors.add(:amount_cents, 'is not an offered donation amount') unless DONATION_AMOUNTS_CENTS.include?(amount_cents)
    errors.add(:user, 'must be absent for anonymous donations') if user_id.present?
    errors.add(:subscription, 'must be absent for donations') if subscription_id.present?
    errors.add(:credit_purchase, 'must be absent for donations') if credit_purchase_id.present?
    errors.add(:contract_user_id, 'must be absent for donations') if contract_user_id.present?
    errors.add(:contract_subscription_id, 'must be absent for donations') if contract_subscription_id.present?
    if contract_credit_purchase_id.present?
      errors.add(:contract_credit_purchase_id, 'must be absent for donations')
    end
    errors.add(:sequence_type, 'must be oneoff for donations') unless sequence_type == 'oneoff'
    errors.add(:invoice_state, 'must be not_required for donations') unless invoice_state == 'not_required'
  end

  def contract_references_match_payment_type
    case payment_type
    when 'credit_purchase'
      errors.add(:contract_user_id, 'must match the user') unless contract_user_id == user_id
      unless contract_credit_purchase_id == credit_purchase_id
        errors.add(:contract_credit_purchase_id, 'must match the credit purchase')
      end
      errors.add(:contract_subscription_id, 'must be absent') if contract_subscription_id.present?
    when 'subscription_initial', 'subscription_renewal'
      errors.add(:contract_user_id, 'must match the user') unless contract_user_id == user_id
      unless contract_subscription_id == subscription_id
        errors.add(:contract_subscription_id, 'must match the subscription')
      end
      if contract_credit_purchase_id.present?
        errors.add(:contract_credit_purchase_id, 'must be absent')
      end
    end
  end

  def adjustment_totals_do_not_exceed_payment
    return if amount_cents.blank?

    errors.add(:refunded_amount_cents, 'cannot exceed the payment amount') if refunded_amount_cents.to_i > amount_cents
    return unless charged_back_amount_cents.to_i > amount_cents

    errors.add(:charged_back_amount_cents, 'cannot exceed the payment amount')
  end

  def service_period_is_ordered
    return if service_period_start.blank? || service_period_end.blank?
    return if service_period_end > service_period_start

    errors.add(:service_period_end, 'must be after the service period start')
  end

  def reversed_credits_do_not_exceed_grant
    return unless credits_reversed.to_i > credits_granted.to_i

    errors.add(:credits_reversed, 'cannot exceed the credits granted by this payment')
  end

  def chargeback_reversal_candidate_is_consistent
    candidate_present = chargeback_reversal_candidate_cents.present?
    timestamp_present = chargeback_reversal_candidate_at.present?
    unless candidate_present == timestamp_present
      errors.add(:chargeback_reversal_candidate_cents, 'must be paired with its observation time')
      return
    end
    return unless candidate_present && amount_cents.present?
    return if chargeback_reversal_candidate_cents < charged_back_amount_cents.to_i &&
              chargeback_reversal_candidate_cents <= amount_cents

    errors.add(:chargeback_reversal_candidate_cents, 'must be below the recorded chargeback total')
  end
end
