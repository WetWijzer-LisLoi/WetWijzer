# frozen_string_literal: true

class AccountActivity < ApplicationRecord
  belongs_to :user

  ACTIONS = %w[
    login
    logout
    failed_login
    password_changed
    password_reset_requested
    password_reset_completed
    email_confirmed
    account_locked
    account_unlocked
    otp_enabled
    otp_disabled
    profile_updated
    account_deleted
  ].freeze

  validates :action, presence: true, inclusion: { in: ACTIONS }

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
