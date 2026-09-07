# frozen_string_literal: true

class User < AccountRecord
  has_secure_password

  has_one :subscription, dependent: :destroy

  has_many :account_activities, dependent: :destroy
  has_many :saved_answers, dependent: :destroy
  has_many :bookmarks, dependent: :destroy
  has_many :credit_purchases, dependent: :destroy
  has_many :platform_invoices, dependent: :nullify # keep invoices for accounting, just unlink user
  # Provider transaction ledgers outlive account erasure for refunds,
  # chargebacks, and statutory accounting; only the live user link is removed.
  has_many :crypto_payments, dependent: :nullify
  has_many :mollie_payments, dependent: :nullify
  has_many :account_request_leases, dependent: :restrict_with_exception

  # Cross-database records cannot use dependent associations. Every permanent
  # deletion path must go through AccountErasureService, which fences the
  # account and removes chatbot, analytics, and primary-database records before
  # destroying this row.

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
  # Canonical brand codes or nil, mirrored by database CHECK constraints.
  validates :registration_brand, inclusion: { in: SiteBrand::KEYS }, allow_nil: true
  validates :last_sign_in_brand, inclusion: { in: SiteBrand::KEYS }, allow_nil: true
  # The original registration brand is a historical fact. Once the row exists
  # no ordinary update may change it - INCLUDING "backfilling" a null: a null
  # means "not recorded", and inventing a value later would forge history.
  # This is the application write boundary; update_columns and raw SQL bypass
  # it by design, which the admin tooling must simply never do.
  validate :registration_brand_is_immutable, on: :update

  def registration_brand_is_immutable
    return unless registration_brand_changed?

    errors.add(:registration_brand, 'is recorded at account creation and cannot change')
  end
  private :registration_brand_is_immutable

  # Encrypt PII at rest (GDPR Art. 32 - security of processing)
  # deterministic: login lookups + uniqueness. fixed: false so rotation
  # re-encrypts under the NEWEST key (FBL-011).
  encrypts :email, deterministic: { fixed: false }, downcase: true
  encrypts :name
  encrypts :last_sign_in_ip
  # 2FA material is as sensitive as a password: a leaked DB/backup let anyone
  # regenerate live TOTP codes and read unused backup codes. Encrypt at rest
  # like the other PII. support_unencrypted_data=true reads existing plaintext
  # transparently, so already-enrolled users keep working.
  encrypts :otp_secret
  encrypts :otp_backup_codes

  DISPOSABLE_DOMAINS = %w[
    mailinator.com guerrillamail.com tempmail.com throwaway.email yopmail.com
    sharklasers.com guerrillamailblock.com grr.la trashmail.com 10minutemail.com
    temp-mail.org dispostable.com maildrop.cc mailnesia.com getnada.com
    mohmal.com fake-box.com emailondeck.com trash-mail.com tmpmail.net
  ].freeze

  before_save :downcase_email
  after_create :create_default_subscription


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
    subscription&.pro? ? 'pro' : 'free'
  end

  # Returns true if user has Pro access (paid subscription or admin)
  def pro?
    admin? || subscription&.pro? || false
  end

  # NOTE: has_credits?(amount) is defined in the CHATBOT ACCESS & CREDITS
  # section below (L166). It accepts an optional amount parameter.


  # Legacy capability used by non-model feature gates and older UI state.
  # Chatbot model access must always use LegalChatbotService.model_allowed?;
  # this predicate does not let purchased credits bypass a model's :pro tier.
  def advanced_intelligence_access?
    pro? || has_credits?
  end

  # ============================================
  # CHATBOT ACCESS & CREDITS
  # ============================================

  def can_use_chatbot?
    return false unless active?
    return true if admin?

    has_credits? || subscription&.active?
  end

  # has_credits? - see multi-pool implementation below (line ~303)

  def default_credit_cost
    Subscription::CREDIT_COSTS[:legislation]
  end

  def credit_cost_for(source_type)
    Subscription::CREDIT_COSTS[source_type.to_sym] || default_credit_cost
  end

  def add_credits!(amount)
    updated = self.class.where(id: id).update_all(
      [
        'credits = credits + ?, credit_balance_version = credit_balance_version + 1, updated_at = ?',
        amount,
        Time.current
      ]
    )
    raise ActiveRecord::RecordNotFound, 'user disappeared during credit adjustment' if updated.zero?

    reload
  end

  # Administrative balance replacement still participates in the same
  # monotonic version stream as purchases, grants, charges, and refunds. This
  # prevents an older chatbot response from restoring a pre-adjustment balance
  # in another tab.
  def set_credits!(amount)
    updated = self.class.where(id: id).update_all(
      [
        'credits = ?, credit_balance_version = credit_balance_version + 1, updated_at = ?',
        amount,
        Time.current
      ]
    )
    raise ActiveRecord::RecordNotFound, 'user disappeared during credit adjustment' if updated.zero?

    reload
  end

  def deduct_credits!(amount)
    updated = self.class.where(id: id)
                  .where('credits >= ?', amount)
                  .update_all(
                    [
                      'credits = credits - ?, credit_balance_version = credit_balance_version + 1, updated_at = ?',
                      amount,
                      Time.current
                    ]
                  )
    return false if updated.zero?

    reload
    true
  end



  # ============================================
  # CREDIT DEDUCTION
  # ============================================

  # Deduct credits from the unified pool.
  # Returns hash with deduction details, or false if insufficient.
  # Uses a guarded UPDATE (credits >= amount in the WHERE clause) — the only
  # race-free primitive on SQLite, where with_lock is a no-op because Arel
  # silently drops FOR UPDATE. Two concurrent deductions can no longer both
  # pass the balance check and drive the balance negative.
  def deduct_credits_with_priority!(amount, intelligence: nil) # rubocop:disable Lint/UnusedMethodArgument
    updated = self.class.where(id: id)
                  .where('credits >= ?', amount)
                  .update_all(
                    [
                      'credits = credits - ?, credit_balance_version = credit_balance_version + 1, updated_at = ?',
                      amount,
                      Time.current
                    ]
                  )
    return false if updated.zero?

    reload
    increment_usage!
    { credits_used: amount, credits_remaining: credits.to_i }
  end

  # Total available credits. Clamped at zero: a refund claw-back can leave the
  # raw credits column negative (the true financial state), but "available to
  # spend" is never less than nothing — and user-facing UI/API read this.
  def total_available_credits
    [credits.to_i, 0].max
  end

  # Check if user has enough credits
  def has_credits?(amount = nil)
    amount ||= default_credit_cost
    credits.to_i >= amount
  end

  def use_credits_for_question!(source_type = :legislation)
    cost = credit_cost_for(source_type)
    return false unless has_credits?(cost)

    deduct_credits_with_priority!(cost, intelligence: 'smart')
  end

  # Source entitlement for the chatbot (owner decision 2026-09-04): legislation
  # is open to every account; case law and parliamentary documents via the
  # chatbot are Pro-only. Credits never substitute for Pro here; the credit
  # check happens separately in the existing question flow.
  def can_access_source?(source_type)
    return true if admin?
    return true if source_type.to_sym == :legislation

    case source_type.to_sym
    when :jurisprudence
      subscription&.jurisprudence_access? || false
    when :parliamentary
      subscription&.parliamentary_access? || false
    when :all, :custom
      # Every multi-source set contains a Pro source.
      pro?
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
  rescue StandardError => e
    Rails.logger.warn("[User] Operation failed: #{e.message}")
    0
  end

  def today_query_count
    ChatbotAnalytic.where(user_id: id)
                   .where('created_at >= ?', Date.current.beginning_of_day).count
  rescue StandardError => e
    Rails.logger.warn("[User] Operation failed: #{e.message}")
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
  # DEEP ANALYSIS (Premium AI - GPT-5.6 Luna/Terra/Sol, GPT-5, Claude Opus)
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

  # Reserve a quota slot and its durable identity before provider I/O. The
  # reservation carries the quota month and generation, so a late failure from
  # the previous month can never decrement the newly reset month's counter.
  def reserve_deep_analysis!(app: nil, model: nil)
    2.times do
      reset_deep_analyses_if_needed!
      provision_deep_analysis_quota!
      reload

      reset_at = deep_analyses_reset_at
      return nil unless reset_at

      quota_month = reset_at.in_time_zone.strftime('%Y-%m')
      quota_generation = deep_analysis_quota_generation.to_i
      reservation = BillingReservation.reserve_deep_quota!(
        user: self,
        quota_month: quota_month,
        quota_generation: quota_generation,
        app: app,
        model: model
      )
      return reservation if reservation

      # A month-boundary reset can race the guarded reservation. Retry only
      # when the generation actually changed; a stable generation means the
      # current quota is genuinely exhausted.
      reload
      break if deep_analysis_quota_generation.to_i == quota_generation
    end

    nil
  end

  def release_deep_analysis_reservation!(reservation, reason: 'provider_failure')
    return false unless reservation.is_a?(BillingReservation)
    return false unless reservation.user_id == id && reservation.deep_quota?

    released = reservation.refund!(reason: reason)
    reload
    released
  end

  def use_deep_analysis!(**)
    reserve_deep_analysis!(**)
  end

  def reset_deep_analyses_if_needed!
    month_start = Time.current.beginning_of_month
    limit = DEEP_ANALYSIS_LIMITS[current_tier] || 0

    now = Time.current
    updated = self.class.where(id: id)
                  .where('deep_analyses_reset_at IS NULL OR deep_analyses_reset_at < ?', month_start)
                  .update_all(
                    [
                      'deep_analyses_used = 0, monthly_deep_limit = ?, deep_analyses_reset_at = ?, ' \
                      'deep_analysis_quota_generation = COALESCE(deep_analysis_quota_generation, 0) + 1, ' \
                      'updated_at = ?',
                      limit,
                      now,
                      now
                    ]
                  )
    reload if updated == 1
    updated == 1
  end

  # Grant deep analysis quota. The predicate makes concurrent first-use
  # provisioning idempotent.
  def provision_deep_analysis_quota!(tier = nil)
    tier ||= current_tier
    limit = DEEP_ANALYSIS_LIMITS[tier] || 0
    updated = self.class.where(id: id, monthly_deep_limit: [nil, 0]).update_all(
      monthly_deep_limit: limit,
      updated_at: Time.current
    )
    reload if updated == 1
    monthly_deep_limit.to_i
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
      conversation_storage_consented_at: nil,
      encrypted_master_key: nil,
      key_derivation_salt: nil
    )
  end

  # ============================================
  # UI PREFERENCES (server-side, replaces localStorage)
  # Stores all client UI settings: theme, sidebar, article display,
  # widget layout, chatbot settings. No localStorage used anywhere.
  # Legal basis: Art. 6(1)(b) - necessary for service delivery
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

  # Merge a subset of preferences (partial update).
  #
  # FBL-042: the merge happens INSIDE SQLite via json_patch (RFC 7396), so
  # two browser tabs saving different keys concurrently can no longer lose
  # each other's writes the way read-merge-write did. A JSON null deletes
  # its key, per the RFC. The total blob stays bounded.
  def merge_ui_prefs!(updates)
    # Deep-normalized through JSON so nested symbol keys behave exactly
    # like the SQLite branch's to_json (review finding: stringify_keys is
    # shallow and made the branches diverge on nested symbols).
    patch = JSON.parse(updates.to_json)
    if merge_prefs_with_sql_json_patch?
      self.class.where(id: id).update_all(
        ["ui_preferences = json_patch(COALESCE(ui_preferences, '{}'), ?)", patch.to_json]
      )
    else
      # W7 portability: PostgreSQL has no json_patch. A row lock gives the
      # same two-tabs-cannot-lose-each-other guarantee, and the RFC 7396
      # semantics (a JSON null deletes its key, objects merge recursively)
      # are applied in Ruby. On SQLite the lock clause is a no-op and the
      # single-writer transaction serializes anyway, so this branch is
      # exercisable (and tested) on both adapters.
      self.class.transaction do
        # Lock a FRESH row handle: reload_ui_preferences leaves this
        # instance's attribute dirty by design, and with_lock refuses
        # instances with unpersisted changes.
        locked = self.class.lock.find_by(id: id)
        if locked
          current = JSON.parse(locked.ui_preferences.presence || '{}')
          merged = self.class.rfc7396_merge(current, patch)
          self.class.where(id: id).update_all(ui_preferences: JSON.generate(merged))
        end
        # A deleted row is a no-op on the SQLite branch (update_all matches
        # nothing); find_by mirrors that instead of raising RecordNotFound.
      end
    end
    @_ui_prefs = nil
    reload_ui_preferences
    raise ActiveRecord::RecordInvalid.new(self), 'ui_preferences exceed the size cap' if (ui_preferences || '').bytesize > UiPreferenceSchema::MAX_TOTAL_BYTES

    ui_prefs
  end

  def reload_ui_preferences
    self.ui_preferences = self.class.where(id: id).pick(:ui_preferences)
  end

  def merge_prefs_with_sql_json_patch?
    self.class.connection.adapter_name.match?(/sqlite/i)
  end

  # RFC 7396 JSON merge patch: null deletes, nested objects merge, anything
  # else replaces. Mirrors SQLite's json_patch exactly.
  def self.rfc7396_merge(target, patch)
    return patch unless patch.is_a?(Hash)

    result = target.is_a?(Hash) ? target.dup : {}
    patch.each do |key, value|
      if value.nil?
        result.delete(key)
      elsif value.is_a?(Hash)
        result[key] = rfc7396_merge(result[key], value)
      else
        result[key] = value
      end
    end
    result
  end

  # Get a single preference value with default
  def ui_pref(key, default = nil)
    ui_prefs[key.to_s] || default
  end

  # FBL-040: a password or 2FA change invalidates every admin session
  # immediately; a stolen admin cookie cannot outlive a credential reset.
  after_update_commit :revoke_admin_sessions_on_credential_change

  private

  def downcase_email
    self.email = email.downcase
  end

  def create_default_subscription
    create_subscription!(tier: 'free', status: 'active')
    # NOTE: Signup bonus credits are granted in RegistrationsController (STARTER_CREDITS = 5),
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

  def revoke_admin_sessions_on_credential_change
    return unless saved_change_to_password_digest? || saved_change_to_otp_secret?
    return unless self.class.connection.table_exists?(:admin_sessions)

    AdminSession.revoke_all_for(id)
  end
end
