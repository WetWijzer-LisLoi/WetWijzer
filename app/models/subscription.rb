# frozen_string_literal: true

class Subscription < ApplicationRecord
  belongs_to :user


  TIERS = %w[free].freeze
  STATUSES = %w[active canceled].freeze

  # Credit costs per question type
  CREDIT_COSTS = {
    legislation: 5,
    jurisprudence: 7,
    parliamentary: 7,
    all: 10,
    custom: 8
  }.freeze

  # Initial credits for new users
  INITIAL_FREE_CREDITS = 25  # 5 questions to try

  TIER_CONFIG = {
    'free' => {
      price_monthly: 0,
      initial_credits: INITIAL_FREE_CREDITS,
      unlimited: false,
      api_access: false,
      priority_support: false
    }
  }.freeze

  validates :tier, presence: true, inclusion: { in: TIERS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  scope :active_paid, -> { where(status: 'active').where.not(tier: 'free') }

  def active?
    %w[active trialing].include?(status) && !expired?
  end

  def expired?
    return false if current_period_end.nil?
    
    current_period_end < Time.current
  end

  def free?
    tier == 'free'
  end

  def basic?
    tier == 'basic'
  end

  def pro?
    tier == 'pro'
  end

  # Alias for backwards compatibility
  def professional?
    pro?
  end

  def trialing?
    status == 'trialing'
  end

  # User is on professional trial (14-day free trial of professional tier)
  def trial?
    professional? && trialing?
  end

  def unlimited?
    TIER_CONFIG.dig(tier, :unlimited) || false
  end

  def initial_credits
    TIER_CONFIG.dig(tier, :initial_credits) || INITIAL_FREE_CREDITS
  end

  # All sources available to anyone with credits
  def jurisprudence_access?
    true
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

  def priority_support?
    TIER_CONFIG.dig(tier, :priority_support) || false
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

  def upgrade_to!(new_tier)
    update!(tier: new_tier, status: 'active')
  end
end
