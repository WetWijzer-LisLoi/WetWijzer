# frozen_string_literal: true

class Subscription < AccountRecord
  belongs_to :user

  TIERS = %w[free pro].freeze
  STATUSES = %w[active canceled past_due incomplete].freeze

  # Credit costs per question type (varies by AI model tier)
  CREDIT_COSTS = {
    legislation: 1,
    jurisprudence: 1,
    parliamentary: 1,
    all: 1,
    custom: 1
  }.freeze

  # Initial credits for new users (= first month's free allocation)
  INITIAL_FREE_CREDITS = 10 # One-time signup bonus (separate from User::WEEKLY_FREE_CREDITS weekly allowance)
  PRO_MONTHLY_CREDITS = 30 # 30 credits/month for Pro subscribers (€2.99 = €0.10/cr)

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
  scope :active_paid, -> { where(status: 'active', tier: 'pro') }
  scope :cancelled_pro_expired, lambda {
    where(tier: 'pro', status: 'canceled')
      .where('current_period_end < ?', Time.current)
  }

  def active?
    status == 'active' && !expired?
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

    # Lazy downgrade: if cancelled and period expired, auto-downgrade to free
    if status == 'canceled' && expired?
      update_columns(tier: 'free')
      Rails.logger.info("[Subscription] Auto-downgraded user #{user_id} to free (period ended)")
      return false
    end

    true
  end

  def unlimited?
    TIER_CONFIG.dig(tier, :unlimited) || false
  end

  def initial_credits
    TIER_CONFIG.dig(tier, :initial_credits) || INITIAL_FREE_CREDITS
  end

  def jurisprudence_access?
    pro?
  end

  def parliamentary_access?
    true
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

    # Grant monthly Pro credits to the PRO pool (not the permanent purchased pool!)
    # pro_credits_balance resets monthly and doesn't accumulate.
    user.update_columns(
      pro_credits_balance: PRO_MONTHLY_CREDITS,
      pro_credits_refilled_at: Time.current
    )
    Rails.logger.info("Refilled #{PRO_MONTHLY_CREDITS} Pro monthly credits for user #{user.id} (Pro subscription)")
  end

  def upgrade_to_pro!
    update!(tier: 'pro', status: 'active')
  end

  # Batch expire all cancelled Pro subs whose paid period has ended.
  # Called daily by rake subscriptions:expire_cancelled
  def self.expire_cancelled!
    expired = cancelled_pro_expired.update_all(tier: 'free')
    Rails.logger.info("[Subscription] Batch expired #{expired} cancelled Pro subscriptions") if expired.positive?
    expired
  end
end
