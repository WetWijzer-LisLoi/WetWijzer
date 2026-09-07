# frozen_string_literal: true

class Subscription < AccountRecord
  belongs_to :user
  has_many :mollie_payments, dependent: :nullify

  TIERS = %w[free pro].freeze
  STATUSES = %w[active canceled past_due incomplete].freeze
  PAYMENT_METHODS = %w[mollie crypto stripe].freeze

  # Credit costs per question type (varies by AI model tier)
  CREDIT_COSTS = {
    legislation: 1,
    jurisprudence: 1,
    parliamentary: 1,
    all: 1,
    custom: 1
  }.freeze

  # Initial credits for new users (= first month's free allocation)
  INITIAL_FREE_CREDITS = 5 # One-time signup bonus
  PRO_MONTHLY_CREDITS = 40 # monthly free credits for Pro (15 -> 40 on 2026-08-18, owner pricing decision)

  TIER_CONFIG = {
    'free' => {
      price_monthly: 0,
      initial_credits: INITIAL_FREE_CREDITS,
      unlimited: false,
      api_access: false,
      model_tier: :free
    },
    'pro' => {
      price_monthly: 299,  # €2.99
      initial_credits: PRO_MONTHLY_CREDITS,
      monthly_credits: PRO_MONTHLY_CREDITS,
      unlimited: false,
      api_access: true,
      model_tier: :pro
    }
  }.freeze

  validates :tier, presence: true, inclusion: { in: TIERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true

  # Non-renewing Pro subscriptions whose paid period has ended. A failed
  # renewal is entitled through the already-paid period just like a voluntary
  # cancellation, but neither state may retain Pro indefinitely afterwards.
  scope :nonrenewing_pro_expired, lambda {
    where(tier: 'pro', status: %w[canceled past_due])
      .where.not(current_period_end: nil)
      .where(current_period_end: ...Time.current)
  }

  def active?
    return false if expired?
    return true if status == 'active'

    # Stopping renewal does not revoke an already-paid period. A canceled Pro
    # subscription remains entitled until the recorded period end, after which
    # expire_cancelled! (or pro?'s lazy fallback) downgrades it to Free.
    status == 'canceled' && tier == 'pro' && current_period_end.present?
  end

  def expired?
    return false if current_period_end.nil?

    current_period_end < Time.current
  end

  def free?
    tier == 'free'
  end

  def pro?
    return false unless tier == 'pro'

    entitled = if status == 'active'
                 !expired?
               elsif %w[canceled past_due].include?(status)
                 current_period_end.present? && !expired?
               else
                 false
               end
    return true if entitled

    # Lazy cleanup complements the daily expiry job. Do not rewrite an
    # expired-but-still-remotely-active row here; provider reconciliation must
    # determine whether a renewal callback is merely late.
    if %w[canceled past_due].include?(status) && current_period_end.present? && expired?
      update_columns(tier: 'free', updated_at: Time.current)
      Rails.logger.info("[Subscription] Auto-downgraded user #{user_id} to free (paid period ended)")
    end

    false
  end

  def unlimited?
    TIER_CONFIG.dig(tier, :unlimited) || false
  end

  # Kept as a compatibility predicate for older clients and views. Priority
  # support is no longer sold on either tier.
  def priority_support?
    false
  end

  def initial_credits
    TIER_CONFIG.dig(tier, :initial_credits) || INITIAL_FREE_CREDITS
  end

  def jurisprudence_access?
    pro?
  end

  def parliamentary_access?
    pro?
  end

  def credit_cost_for(source_type)
    CREDIT_COSTS[source_type.to_sym] || CREDIT_COSTS[:legislation]
  end

  def api_access?
    TIER_CONFIG.dig(tier, :api_access) || false
  end

  def model_tier
    TIER_CONFIG.dig(tier, :model_tier) || :free
  end

  def can_use_model?(model)
    LegalChatbotService.model_allowed?(model, model_tier)
  end

  def available_models
    LegalChatbotService.models_for_tier(model_tier)
  end

  def can_use_profile?(profile)
    LegalChatbotService.profile_exists?(profile)
  end

  def available_profiles
    LegalChatbotService.all_profiles
  end

  def monthly_price_cents
    TIER_CONFIG.dig(tier, :price_monthly) || 0
  end

  def monthly_price_euros
    monthly_price_cents / 100.0
  end

  def cancel!
    update!(status: 'canceled', canceled_at: Time.current)
  end

  def reactivate!
    update!(status: 'active', canceled_at: nil)
  end

  def refill_credits!
    return unless pro?

    # Grant monthly Pro credits to the unified credits pool
    user.add_credits!(PRO_MONTHLY_CREDITS)
    Rails.logger.info("Added #{PRO_MONTHLY_CREDITS} monthly Pro credits for user #{user.id} (Pro subscription, new balance: #{user.credits})")
  end

  def upgrade_to_pro!
    update!(tier: 'pro', status: 'active')
  end

  # Batch expire all cancelled Pro subs whose paid period has ended.
  # Called daily by rake subscriptions:expire_cancelled
  def self.expire_cancelled!
    expired = nonrenewing_pro_expired.update_all(tier: 'free', updated_at: Time.current)
    Rails.logger.info("[Subscription] Batch expired #{expired} non-renewing Pro subscriptions") if expired.positive?
    expired
  end
end
