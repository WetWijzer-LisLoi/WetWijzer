# frozen_string_literal: true

class User < AccountRecord
  has_secure_password

  has_one :subscription, dependent: :destroy

  has_many :account_activities, dependent: :destroy
  has_many :saved_answers, dependent: :destroy
  has_many :bookmarks, dependent: :destroy
  has_many :credit_purchases, dependent: :destroy
  has_many :platform_invoices, dependent: :nullify # keep invoices for accounting, just unlink user
  has_many :crypto_payments, dependent: :destroy

  # Cross-database associations (analytics.sqlite3) — cannot use dependent: :destroy
  # Cleanup handled in Admin::UsersController#destroy via direct SQL
  # Tables: chatbot_analytics, chatbot_feedbacks, chatbot_reports (AnalyticsRecord)
  # Tables not yet migrated: partner_usage_logs, partner_bookmarks (Praxis API integration)

  MAX_FAILED_ATTEMPTS = 5
  LOCKOUT_DURATION = 15.minutes

  attr_accessor :terms_accepted

  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, if: -> { new_record? || password.present? }
  validates :terms_accepted, acceptance: { accept: ['1', true] }, on: :create
  validate :password_complexity, if: -> { new_record? || password.present? }
  validate :email_domain_not_disposable, on: :create

  # Encrypt PII at rest (GDPR Art. 32 — security of processing)
  encrypts :email, deterministic: true, downcase: true # deterministic: login lookups + uniqueness
  encrypts :name
  encrypts :last_sign_in_ip

  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com tempmail.com throwaway.email yopmail.com
    sharklasers.com guerrillamailblock.com grr.la trashmail.com 10minutemail.com
    temp-mail.org dispostable.com maildrop.cc mailnesia.com getnada.com
    mohmal.com fake-box.com emailondeck.com trash-mail.com tmpmail.net
  ].freeze

  before_save :downcase_email
  after_create :create_default_subscription
  after_initialize :set_default_weekly_credits, if: :new_record?

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

  # Returns true if user has Pro access (paid subscription or admin)
  def pro?
    admin? || current_tier == 'pro'
  end

  # Returns true if user has purchased credits (vs only free weekly allowance).
  # Purchased credits unlock genius intelligence level; free credits are smart-only.
  def has_purchased_credits?
    credits.to_i.positive?
  end

  # Returns true if user can access advanced intelligence levels (genius/mastermind).
  # Pro subscribers, admins, or users with purchased credits get access.
  # Note: 'omniscient' tier requires pro? check separately (tier: :subscriber).
  def advanced_intelligence_access?
    pro? || has_purchased_credits?
  end

  # ============================================
  # CHATBOT ACCESS & CREDITS
  # ============================================

  def can_use_chatbot?
    return false unless active?
    return true if admin?

    has_credits? || subscription&.active?
  end

  # has_credits? — see multi-pool implementation below (line ~303)

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

  # ============================================
  # WEEKLY FREE CREDITS (3 per week for everyone)
  # ============================================
  WEEKLY_FREE_CREDITS = 3

  def weekly_credits_remaining
    refill_weekly_credits_if_needed!
    weekly_free_credits_balance || 0
  end

  def use_weekly_free_credit!
    return false unless can_use_weekly_free_credits?

    refill_weekly_credits_if_needed!
    return false if (weekly_free_credits_balance || 0) <= 0

    decrement!(:weekly_free_credits_balance, 1)
    increment_usage!
    true
  end

  def can_use_weekly_free_credits?
    refill_weekly_credits_if_needed!
    (weekly_free_credits_balance || 0).positive?
  end

  def refill_weekly_credits_if_needed!
    last_refill = weekly_credits_refilled_at || created_at
    return if last_refill >= 7.days.ago

    update_columns(
      weekly_free_credits_balance: WEEKLY_FREE_CREDITS,
      weekly_credits_refilled_at: Time.current
    )
  end

  # ============================================
  # PRO MONTHLY CREDITS (30/month for Pro subscribers, no accumulation)
  # Columns: pro_credits_balance, pro_credits_refilled_at
  # ============================================
  PRO_MONTHLY_CREDITS = Subscription::PRO_MONTHLY_CREDITS

  def pro_credits_remaining
    return 0 unless pro?

    refill_pro_credits_if_needed!
    self[:pro_credits_balance] || 0
  end

  def use_pro_credit!(amount = 1)
    return false unless pro?

    refill_pro_credits_if_needed!
    balance = self[:pro_credits_balance] || 0
    return false if balance < amount

    update_column(:pro_credits_balance, balance - amount)
    increment_usage!
    true
  end

  def can_use_pro_credits?(amount = 1)
    return false unless pro?

    refill_pro_credits_if_needed!
    (self[:pro_credits_balance] || 0) >= amount
  end

  def refill_pro_credits_if_needed!
    return unless pro?

    last_refill = self[:pro_credits_refilled_at] || created_at
    return if last_refill >= Time.current.beginning_of_month

    # Reset to PRO_MONTHLY_CREDITS (no accumulation)
    update_columns(
      pro_credits_balance: PRO_MONTHLY_CREDITS,
      pro_credits_refilled_at: Time.current
    )
    reload
  end

  # ============================================
  # CREDIT PRIORITY DEDUCTION (free → pro → purchased)
  # ============================================

  # Deduct credits using priority: weekly free → pro monthly → purchased
  # Returns hash with deduction details, or false if insufficient
  # Wrapped in a transaction with row-level lock to prevent TOCTOU race conditions
  def deduct_credits_with_priority!(amount, intelligence: nil)
    with_lock do # rubocop:disable Metrics/BlockLength
      # For free credits: usable on 'smart' tier only (4-tier model: smart/genius/mastermind/omniscient)
      if intelligence.nil? || intelligence == 'smart'
        # Try weekly free credits first (1 at a time)
        remaining = amount
        free_used = 0
        while remaining.positive? && can_use_weekly_free_credits?
          decrement!(:weekly_free_credits_balance, 1)
          free_used += 1
          remaining -= 1
        end

        if remaining <= 0
          increment_usage!
          return { type: :free, free_used: free_used, pro_used: 0, purchased_used: 0 }
        end
      else
        remaining = amount
        free_used = 0
      end

      # Try Pro monthly credits
      pro_used = 0
      if pro? && can_use_pro_credits?(1)
        pro_balance = self[:pro_credits_balance] || 0
        pro_deduct = [remaining, pro_balance].min
        if pro_deduct.positive?
          update_column(:pro_credits_balance, pro_balance - pro_deduct)
          pro_used = pro_deduct
          remaining -= pro_deduct
        end
      end

      if remaining <= 0
        increment_usage!
        return { type: :pro, free_used: free_used, pro_used: pro_used, purchased_used: 0 }
      end

      # Finally, purchased credits
      if credits >= remaining
        decrement!(:credits, remaining)
        purchased_used = remaining
        increment_usage!
        return { type: :purchased, free_used: free_used, pro_used: pro_used, purchased_used: purchased_used }
      end

      # Not enough credits total — roll back any partial deductions
      increment!(:weekly_free_credits_balance, free_used) if free_used.positive?
      update_column(:pro_credits_balance, (self[:pro_credits_balance] || 0) + pro_used) if pro_used.positive?
      false
    end
  end

  # Total available credits across all pools
  def total_available_credits
    weekly_credits_remaining + pro_credits_remaining + credits.to_i
  end

  # Check if user has enough credits across all pools (free + pro + purchased)
  def has_credits?(amount = nil)
    amount ||= default_credit_cost
    total_available_credits >= amount
  end

  def use_credits_for_question!(source_type = :legislation)
    cost = credit_cost_for(source_type)
    return false unless has_credits?(cost)

    deduct_credits_with_priority!(cost, intelligence: 'smart')
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
    # Usage tracked via ChatbotAnalytic (per-query records)
  end

  def weekly_usage_count
    ChatbotAnalytic.where(user_id: id)
                   .where('created_at >= ?', 7.days.ago.beginning_of_day).count
  rescue StandardError
    0
  end

  def today_query_count
    ChatbotAnalytic.where(user_id: id)
                   .where('created_at >= ?', Date.current.beginning_of_day).count
  rescue StandardError
    0
  end

  def total_credits_purchased
    credit_purchases.completed.sum(:credits_granted)
  end

  def remaining_credits
    credits
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
    update!(failed_attempts: 0) if failed_attempts.positive?
  end

  # Session activity tracking
  def touch_activity!
    update_column(:last_activity_at, Time.current) if last_activity_at.nil? || last_activity_at < 5.minutes.ago
  end

  def session_expired?(timeout = 2.hours)
    last_activity_at.nil? || last_activity_at < timeout.ago
  end

  # ============================================
  # DEEP ANALYSIS (Premium AI — o4-mini, GPT-5, Claude Opus)
  # Monthly quota, auto-resets on 1st of month
  # ============================================

  DEEP_ANALYSIS_LIMITS = {
    'free' => 0,
    'pro' => 15
  }.freeze

  def deep_analyses_remaining
    reset_deep_analyses_if_needed!
    limit = monthly_deep_limit.to_i
    used = deep_analyses_used.to_i
    [limit - used, 0].max
  end

  def can_use_deep_analysis?
    deep_analyses_remaining.positive?
  end

  def use_deep_analysis!
    reset_deep_analyses_if_needed!
    return false unless can_use_deep_analysis?

    increment!(:deep_analyses_used)
    true
  end

  def reset_deep_analyses_if_needed!
    last_reset = deep_analyses_reset_at || created_at
    return if last_reset >= Time.current.beginning_of_month

    limit = DEEP_ANALYSIS_LIMITS[current_tier] || 0

    update_columns(
      deep_analyses_used: 0,
      monthly_deep_limit: limit,
      deep_analyses_reset_at: Time.current
    )
  end

  # Grant deep analysis quota
  def provision_deep_analysis_quota!(tier = nil)
    tier ||= current_tier
    limit = DEEP_ANALYSIS_LIMITS[tier] || 0
    update!(monthly_deep_limit: limit) if monthly_deep_limit.to_i.zero?
  end

  # ============================================
  # CONVERSATION STORAGE CONSENT (GDPR Art. 6(1)(a))
  # Legal queries may contain sensitive personal data.
  # Users must explicitly consent before conversations are persisted server-side.
  # ============================================

  def conversation_storage_consented?
    conversation_storage_consent? && conversation_storage_consented_at.present?
  end

  def grant_conversation_storage_consent!
    update!(
      conversation_storage_consent: true,
      conversation_storage_consented_at: Time.current
    )
  end

  def revoke_conversation_storage_consent!
    update!(
      conversation_storage_consent: false,
      conversation_storage_consented_at: nil
    )
  end

  # ============================================
  # UI PREFERENCES (server-side, replaces localStorage)
  # Stores all client UI settings: theme, sidebar, article display,
  # widget layout, chatbot settings. No localStorage used anywhere.
  # Legal basis: Art. 6(1)(b) — necessary for service delivery
  # ============================================

  def ui_prefs
    @_ui_prefs ||= JSON.parse(ui_preferences || '{}')
  rescue JSON::ParserError
    {}
  end

  def ui_prefs=(hash)
    @_ui_prefs = nil
    self.ui_preferences = hash.to_json
  end

  # Merge a subset of preferences (partial update)
  def merge_ui_prefs!(updates)
    current = ui_prefs
    current.merge!(updates.stringify_keys)
    update!(ui_preferences: current.to_json)
    @_ui_prefs = nil
    current
  end

  # Get a single preference value with default
  def ui_pref(key, default = nil)
    ui_prefs[key.to_s] || default
  end

  private

  def downcase_email
    self.email = email.downcase
  end

  def set_default_weekly_credits
    self.weekly_free_credits_balance = WEEKLY_FREE_CREDITS
  end

  def create_default_subscription
    create_subscription!(tier: 'free', status: 'active')
    # NOTE: Signup bonus credits are granted in RegistrationsController (STARTER_CREDITS = 10),
    # NOT here. This prevents double-granting when the model callback fires.
  end

  def password_complexity
    return if password.blank?

    errors.add(:password, I18n.t('auth.password_needs_uppercase')) unless password.match?(/[A-Z]/)
    errors.add(:password, I18n.t('auth.password_needs_lowercase')) unless password.match?(/[a-z]/)
    errors.add(:password, I18n.t('auth.password_needs_digit')) unless password.match?(/\d/)
  end

  def email_domain_not_disposable
    return if email.blank?

    domain = email.split('@').last&.downcase
    return unless DISPOSABLE_DOMAINS.include?(domain)

    errors.add(:email, I18n.t('auth.disposable_email'))
  end
end
