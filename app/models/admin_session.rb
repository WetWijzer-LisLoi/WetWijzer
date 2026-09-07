# frozen_string_literal: true

# Revocable, database-backed admin session (FBL-040).
#
# The browser cookie carries only an opaque random token; this row stores
# its SHA-256 digest with idle/absolute lifetimes, revocation, a
# recent-reauthentication stamp for destructive actions, and
# privacy-controlled evidence (hashed IP, truncated user agent). Created
# exclusively by the ADMIN_MFA_SESSIONS login flow.
class AdminSession < AccountRecord
  IDLE_LIFETIME = 30.minutes
  ABSOLUTE_LIFETIME = 12.hours
  REAUTH_WINDOW = 15.minutes
  TOKEN_BYTES = 32

  belongs_to :user

  scope :active, lambda {
    now = Time.current
    where(revoked_at: nil)
      .where(absolute_expires_at: now..)
      .where(last_seen_at: (now - IDLE_LIFETIME)..)
  }

  # Creates a session and returns [raw_token, session]. The raw token exists
  # only in the return value and the cookie.
  def self.issue!(user, ip: nil, user_agent: nil)
    raw = SecureRandom.hex(TOKEN_BYTES)
    session = create!(
      user: user,
      token_digest: digest(raw),
      last_seen_at: Time.current,
      absolute_expires_at: ABSOLUTE_LIFETIME.from_now,
      reauthenticated_at: Time.current,
      ip_hash: ip.present? ? Digest::SHA256.hexdigest("#{ip}:admin_session") : nil,
      user_agent: user_agent.to_s.presence&.truncate(255)
    )
    [raw, session]
  end

  # Resolves a raw cookie token to a live session, refreshing the idle
  # clock. Returns nil for unknown, revoked, idle-expired or absolutely
  # expired tokens.
  def self.authenticate(raw)
    return nil if raw.blank?

    session = active.find_by(token_digest: digest(raw))
    session&.touch_last_seen!
    session
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  def self.revoke_all_for(user_id)
    where(user_id: user_id, revoked_at: nil).update_all(revoked_at: Time.current)
  end

  def touch_last_seen!
    # Bounded write frequency; sub-minute activity does not need a row write.
    update_column(:last_seen_at, Time.current) if last_seen_at < 1.minute.ago
    self
  end

  def revoke!
    update_column(:revoked_at, Time.current)
  end

  def recently_reauthenticated?
    reauthenticated_at.present? && reauthenticated_at > REAUTH_WINDOW.ago
  end

  def mark_reauthenticated!
    update_column(:reauthenticated_at, Time.current)
  end
end
