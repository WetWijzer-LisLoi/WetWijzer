# frozen_string_literal: true

# One signed-in device of a reader (owner, 2026-11-18): signing out on one
# device no longer signs out the others.
#
# The session cookie holds COOKIE_PREFIX plus an opaque random token; this row
# stores only its SHA-256 digest. The row is bound to the account's session
# token (users.session_token) by account_token_digest, so clearing or
# replacing that token (password or second-factor change, suspension,
# deactivation, erasure, a sign-out from a pre-2026-11-18 cookie) still ends
# every device at once. A cookie without the prefix is a pre-2026-11-18
# cookie that holds the account token itself; those stay valid until their
# own signed expiry, at most thirty days.
class UserSession < AccountRecord
  # The longest cookie ("remember me"). The signed cookie carries its own
  # expiry, which ends a two-hour session on time; this bounds the row.
  LIFETIME = 30.days
  COOKIE_PREFIX = 'd1:'
  TOKEN_BYTES = 32

  belongs_to :user

  scope :expired, -> { where(expires_at: ..Time.current) }

  class << self
    # Creates the row inside the caller's transaction and returns the cookie
    # value. The raw token exists only in that value and the cookie.
    def issue!(user, account_token)
      raise ArgumentError, 'account token required' if account_token.blank?

      raw = SecureRandom.urlsafe_base64(TOKEN_BYTES)
      now = Time.current
      create!(user_id: user.id, token_digest: digest(raw), account_token_digest: digest(account_token),
              expires_at: now + LIFETIME)
      purge_expired_for!(user.id, now)
      "#{COOKIE_PREFIX}#{raw}"
    end

    # The device token inside a cookie value, or nil for a pre-2026-11-18
    # cookie (which holds the account token itself).
    def device_token(cookie_value)
      value = cookie_value.to_s
      return nil unless value.start_with?(COOKIE_PREFIX)

      value.delete_prefix(COOKIE_PREFIX).presence
    end

    # The account token a device cookie stands for: nil when the row is gone
    # (signed out), expired, the account is inactive, or the account token
    # was cleared or replaced since this device signed in.
    def account_token_for(raw, now: Time.current)
      return nil if raw.blank?

      row = where(expires_at: now..).find_by(token_digest: digest(raw))
      return nil unless row

      account_token = User.where(id: row.user_id, active: true).pick(:session_token)
      return nil if account_token.blank?
      return nil unless ActiveSupport::SecurityUtils.secure_compare(row.account_token_digest, digest(account_token))

      account_token
    end

    # Signing out this device only.
    def revoke!(raw)
      return 0 if raw.blank?

      where(token_digest: digest(raw)).delete_all
    end

    def purge_expired!
      expired.delete_all
    end

    def digest(raw)
      Digest::SHA256.hexdigest(raw.to_s)
    end

    private

    # Keeps one account's dead rows from piling up between daily scrubs.
    def purge_expired_for!(user_id, now)
      where(user_id: user_id, expires_at: ..now).delete_all
    end
  end
end
