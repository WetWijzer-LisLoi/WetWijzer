# frozen_string_literal: true

class AccountActivity < AccountRecord
  belongs_to :user

  attribute :metadata, :json

  ACTIONS = %w[
    registered
    login
    logout
    failed_login
    sso_login
    password_changed
    password_reset_requested
    password_reset_completed
    email_confirmed
    account_locked
    account_unlocked
    account_reactivated
    otp_enabled
    otp_disabled
    profile_updated
    account_deleted
    data_exported
    credits_added
    credits_removed
    credits_set_by_admin
    tier_changed_by_admin
    deactivated_by_admin
    reactivated_by_admin
    deletion_cancelled_by_admin
    verification_resent_by_admin
    permanently_deleted_by_admin
    pro_credits_granted
    rate_limits_cleared
  ].freeze

  # Legacy TEXT snapshots may deserialize repaired raw values as a scalar.
  # Keep callers on the declared Hash contract without deleting those bytes.
  def metadata
    value = super
    value.is_a?(Hash) ? value : {}
  end

  # Virtual accessor for details stored in the metadata JSON column
  def details
    metadata.is_a?(Hash) ? metadata['details'] : nil
  end

  def details=(value)
    self.metadata = (metadata || {}).merge('details' => value)
  end

  validates :action, presence: true, inclusion: { in: ACTIONS }
  # Canonical brand code or nil - mirrored by the database CHECK constraint.
  # site_brand is deliberately NOT encrypted: the four codes are not PII, and
  # the admin filters and period aggregates need plain SQL equality on them.
  validates :site_brand, inclusion: { in: SiteBrand::KEYS }, allow_nil: true

  # Encrypt PII at rest (GDPR - IP addresses are personal data)
  encrypts :ip_address
  encrypts :user_agent

  scope :recent, -> { order(created_at: :desc).limit(50) }

  # site_brand is keyword-only BEHIND the positional metadata argument, so the
  # existing positional callers (admin actions, sessions) stay untouched.
  # Normalization is loud on purpose: an invalid non-null internal code raises
  # in SiteBrand.normalize_code rather than being silently rewritten to nil -
  # the caller passed something that is not a brand, and burying that would
  # hide exactly the bug the canonical vocabulary exists to prevent. An absent
  # brand stays nil, which stores NULL: "not recorded", never a default.
  def self.log(user, action, request = nil, metadata = {}, site_brand: nil)
    create!(
      user: user,
      action: action,
      ip_address: request&.remote_ip,
      user_agent: request&.user_agent&.truncate(500),
      metadata: metadata.presence,
      site_brand: SiteBrand.normalize_code(site_brand)
    )
  end
end
