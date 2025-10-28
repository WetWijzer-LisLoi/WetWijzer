# frozen_string_literal: true

class AccountActivity < AccountRecord
  belongs_to :user

  ACTIONS = %w[
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
  ].freeze

  # Virtual accessor for details stored in the metadata JSON column
  def details
    metadata.is_a?(Hash) ? metadata['details'] : nil
  end

  def details=(value)
    self.metadata = (metadata || {}).merge('details' => value)
  end

  validates :action, presence: true, inclusion: { in: ACTIONS }

  # Encrypt PII at rest (GDPR — IP addresses are personal data)
  encrypts :ip_address
  encrypts :user_agent

  scope :recent, -> { order(created_at: :desc).limit(50) }
  scope :logins, -> { where(action: %w[login failed_login]) }
  scope :security_events, -> { where(action: %w[password_changed password_reset_completed otp_enabled otp_disabled account_locked]) }

  def self.log(user, action, request = nil, metadata = {})
    create!(
      user: user,
      action: action,
      ip_address: request&.remote_ip,
      user_agent: request&.user_agent&.truncate(500),
      metadata: metadata.presence
    )
  end
end
