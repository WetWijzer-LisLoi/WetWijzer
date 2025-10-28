# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password

  has_one :subscription, dependent: :destroy
  has_many :chatbot_usages, dependent: :destroy
  has_many :account_activities, dependent: :destroy
  has_many :saved_answers, dependent: :destroy
  has_many :credit_purchases, dependent: :destroy

  MAX_FAILED_ATTEMPTS = 5
  LOCKOUT_DURATION = 30.minutes

  attr_accessor :terms_accepted

  validates :email, presence: true, 
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, if: -> { new_record? || password.present? }
  validates :terms_accepted, acceptance: { accept: ['1', true] }, on: :create

  before_save :downcase_email
  after_create :create_trial_subscription

  scope :active, -> { where(active: true) }
  scope :confirmed, -> { where.not(confirmed_at: nil) }

  def confirmed?
    confirmed_at.present?
  end

  def confirm!
    update!(confirmed_at: Time.current, confirmation_token: nil)
  end

  def generate_confirmation_token!
    update!(
      confirmation_token: SecureRandom.urlsafe_base64(32),
      confirmation_sent_at: Time.current
    )
    confirmation_token
  end

  def generate_reset_token!
    update!(
      reset_password_token: SecureRandom.urlsafe_base64(32),
      reset_password_sent_at: Time.current
    )
    reset_password_token
  end

  def generate_session_token!
    token = SecureRandom.urlsafe_base64(32)
    update!(session_token: token)
    token
  end

  def clear_session_token!
    update!(session_token: nil)
  end

  def current_tier
    subscription&.tier || 'free'
  end

  # ============================================
  # CHATBOT ACCESS & CREDITS
  # ============================================

  def can_use_chatbot?
    return false unless active?
    return true if admin?
    
    has_credits? || subscription&.active?
  end

  def has_credits?(amount = nil)
    amount ||= default_credit_cost
    credits >= amount
  end

  def default_credit_cost
    Subscription::CREDIT_COSTS[:legislation]
  end

  def credit_cost_for(source_type)
    Subscription::CREDIT_COSTS[source_type.to_sym] || default_credit_cost
  end

  def add_credits!(amount)
    increment!(:credits, amount)
  end

  def deduct_credits!(amount)
    return false if credits < amount
    decrement!(:credits, amount)
    true
  end

  def use_credits_for_question!(source_type = :legislation)
    cost = credit_cost_for(source_type)
    return false unless has_credits?(cost)
    
    deduct_credits!(cost)
    increment_usage!
    true
  end

  def can_access_source?(source_type)
    return true if admin?
    return true if source_type.to_sym == :legislation
    
    case source_type.to_sym
    when :jurisprudence
      subscription&.jurisprudence_access? || has_credits?(credit_cost_for(:jurisprudence))
    when :parliamentary
      subscription&.parliamentary_access? || has_credits?(credit_cost_for(:parliamentary))
    when :all, :custom
      has_credits?(credit_cost_for(source_type))
    else
      has_credits?
    end
  end

  def can_access_jurisprudence?
    can_access_source?(:jurisprudence)
  end

  def can_access_parliamentary?
    can_access_source?(:parliamentary)
  end

  def increment_usage!
    usage = chatbot_usages.find_or_create_by!(usage_date: Date.current)
    usage.increment!(:query_count)
  end

  def today_query_count
    chatbot_usages.find_by(usage_date: Date.current)&.query_count || 0
  end

  def total_credits_purchased
    credit_purchases.completed.sum(:credits_granted)
  end

  def remaining_credits
    credits
  end

  # Legacy compatibility
  def remaining_free_queries
    credits / default_credit_cost
  end

  def within_free_trial_limit?
    has_credits?
  end

  def trial_days_remaining
    return 0 unless subscription&.trial_ends_at
    [(subscription.trial_ends_at.to_date - Date.current).to_i, 0].max
  end

  def trial_active?
    subscription&.status == 'trialing' && trial_days_remaining > 0
  end

  # Account lockout
  def locked?
    locked_until.present? && locked_until > Time.current
  end

  def lock_account!
    update!(locked_until: LOCKOUT_DURATION.from_now)
  end

  def unlock_account!
    update!(locked_until: nil, failed_attempts: 0)
  end

  def record_failed_login!
    increment!(:failed_attempts)
    lock_account! if failed_attempts >= MAX_FAILED_ATTEMPTS
  end

  def reset_failed_attempts!
    update!(failed_attempts: 0) if failed_attempts > 0
  end

  # Session activity tracking
  def touch_activity!
    update_column(:last_activity_at, Time.current) if last_activity_at.nil? || last_activity_at < 5.minutes.ago
  end

  def session_expired?(timeout = 2.hours)
    last_activity_at.nil? || last_activity_at < timeout.ago
  end

  private

  def downcase_email
    self.email = email.downcase
  end

  def create_trial_subscription
    sub = create_subscription!(tier: 'free', status: 'active')
    # Grant initial free credits (never expire)
    add_credits!(sub.initial_credits)
  end
end
