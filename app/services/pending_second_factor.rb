# frozen_string_literal: true

# WW-SEC-12: a pending second-factor sign-in, between the password step and
# the code. Its cookie value is "account:nonce:binding": the binding is a
# keyed digest of the account's current credentials (password digest and
# second-factor secret, never written to the cookie themselves), so a
# password reset, a password change or a new factor between the two steps
# voids the challenge. Only the newest challenge per account and purpose is
# live, and completing one consumes it, exactly once: a copied cookie cannot
# finish a second sign-in, before or after the first.
#
# Completion is one serialized boundary (WW-SEC-12 refinement). Issue,
# complete and cancel all hold the account's row lock while they read or
# change the challenge state. Under that lock completion reloads the
# account, checks the binding against its current credentials, checks that
# this is still the newest challenge, lets the caller check the account and
# the code, claims the challenge once, and lets the caller write the session.
# The caller publishes the session cookie only after that. A credential
# change that commits first voids the challenge; one that commits later
# revokes the new session through the credential-change callbacks on User.
#
# Follow-up (Codex inbox 2026-10-07 18:15 CEST):
#
# - Issuing is bound to the password that was actually verified. The caller
#   passes the account object it authenticated; under the lock its
#   credential fingerprint must still match the account's, so a password
#   reset that commits between the password check and the challenge leaves
#   the old password's proof with nothing to show. The account must also
#   still be active, enrolled and, by purpose, confirmed or an admin.
# - The newest-only and once-only state is durable: one row per account and
#   purpose in the accounts database (PendingSecondFactorChallenge), changed
#   only under the account lock. A cancellation at logout deletes exactly
#   its challenge's row, so a cache outage can no longer lose it, and a
#   failure to delete is raised, never reported as done. The cache keeps only
#   the attempt budgets.
module PendingSecondFactor
  LIFETIME = 5.minutes
  PURPOSES = %w[user admin].freeze
  KEY_SALT = 'pending-second-factor v1'
  KEY_PREFIX = 'pending-second-factor:v1'
  FORMAT = /\A(?<id>\d{1,12}):(?<nonce>\h{32}):(?<binding>\h{64})\z/

  # status is :completed, :wrong_code (the challenge stays live) or :refused.
  Outcome = Struct.new(:status, :user)

  class << self
    # The cookie value for a new pending sign-in, or nil when no challenge may
    # be issued: the credentials changed since the caller verified the
    # password on +user+, or the account may not receive this challenge.
    def issue(user, purpose:, now: Time.current)
      purpose = purpose.to_s
      raise ArgumentError, "unknown second-factor purpose: #{purpose}" unless PURPOSES.include?(purpose)

      verified = credential_fingerprint(user)
      serialized(user.id) do |account|
        next nil unless secure_compare(credential_fingerprint(account), verified) && eligible?(purpose, account)

        nonce = SecureRandom.hex(16)
        challenge = PendingSecondFactorChallenge.find_or_initialize_by(user_id: account.id, purpose: purpose)
        challenge.update!(nonce_digest: digest(nonce), expires_at: now + LIFETIME)
        "#{account.id}:#{nonce}:#{binding(purpose, account, nonce)}"
      end
    end

    # [account, nonce] when the value names the newest live challenge for this
    # purpose, issued against the account's current credentials; else nil.
    # A read for pre-checks only: completion decides again under the lock.
    def resolve(value, purpose:, now: Time.current)
      purpose = purpose.to_s
      parts = parse(value)
      return nil unless parts && PURPOSES.include?(purpose)

      user = User.find_by(id: parts[:id])
      return nil unless user && current?(purpose, user, parts, now)

      [user, parts[:nonce]]
    end

    # The completion boundary. verify is called with the locked account and
    # answers true (the code is right), false (a wrong code) or :refused (the
    # account may not sign in now); finish is called with the locked account
    # after the claim and writes the session.
    def complete(value, purpose:, verify:, finish:, now: Time.current)
      purpose = purpose.to_s
      parts = parse(value)
      return Outcome.new(:refused) unless parts && PURPOSES.include?(purpose)

      outcome = serialized(parts[:id]) do |account|
        next Outcome.new(:refused, account) unless current?(purpose, account, parts, now)

        verdict = verify.call(account)
        next Outcome.new(:refused, account) if verdict == :refused
        next Outcome.new(:wrong_code, account) unless verdict

        # Still these credentials and still the newest challenge at the moment
        # it is claimed.
        account.reload
        next Outcome.new(:refused, account) unless current?(purpose, account, parts, now)
        next Outcome.new(:refused, account) unless claim!(purpose, account, parts[:nonce])

        finish.call(account)
        Outcome.new(:completed, account)
      end
      outcome || Outcome.new(:refused)
    end

    # Ends exactly the challenge this value names (logout, another sign-in,
    # a refused step); a newer challenge of the same account stays live.
    # true when a live challenge ended, false when there was none. A database
    # failure is raised: the caller reports it and keeps its cookie.
    def cancel(value, purpose:)
      purpose = purpose.to_s
      parts = parse(value)
      return false unless parts && PURPOSES.include?(purpose)

      serialized(parts[:id]) { |account| claim!(purpose, account, parts[:nonce]) } || false
    end

    # Deletes expired challenge rows (the daily scrub); returns how many.
    def purge_expired!(now: Time.current)
      connection = PendingSecondFactorChallenge.connection
      return 0 unless connection.table_exists?(PendingSecondFactorChallenge.table_name)

      PendingSecondFactorChallenge.where(expires_at: ...now).delete_all
    end

    # The account a value names, for the per-account attempt limit; no check.
    def account_id(value)
      value.to_s[/\A\d{1,12}(?=:)/]
    end

    private

    def parse(value)
      FORMAT.match(value.to_s)
    end

    # The account row lock, then the block. nil when the account is gone.
    def serialized(id)
      User.transaction do
        account = User.lock.find_by(id: id)
        account && yield(account)
      end
    end

    def current?(purpose, user, parts, now)
      secure_compare(binding(purpose, user, parts[:nonce]), parts[:binding]) &&
        live_challenge(purpose, user, parts[:nonce]).where('expires_at > ?', now).exists?
    end

    # Once only, and only this challenge: its row goes if it is still the
    # newest one for the account and purpose.
    def claim!(purpose, user, nonce)
      live_challenge(purpose, user, nonce).delete_all == 1
    end

    def live_challenge(purpose, user, nonce)
      PendingSecondFactorChallenge.where(user_id: user.id, purpose: purpose, nonce_digest: digest(nonce))
    end

    # WW-ABUSE-01: an abuse-suspended account is never active (a database
    # constraint), and is refused here by name as well.
    def eligible?(purpose, account)
      return false unless account.active? && account.otp_enabled? && account.activatable?

      purpose == 'admin' ? account.admin? : account.confirmed?
    end

    # The credentials a password check proves, as one keyed digest. Taken
    # from the object the caller authenticated, it pins that proof to the
    # password digest that was checked, not to whatever a reload finds.
    def credential_fingerprint(user)
      OpenSSL::HMAC.hexdigest('SHA256', key, [KEY_PREFIX, 'credentials', user.password_digest, user.otp_secret].join('|'))
    end

    def binding(purpose, user, nonce)
      material = [KEY_PREFIX, purpose, user.id, nonce, user.password_digest, user.otp_secret].join('|')
      OpenSSL::HMAC.hexdigest('SHA256', key, material)
    end

    def digest(nonce)
      OpenSSL::HMAC.hexdigest('SHA256', key, "nonce|#{nonce}")
    end

    def key
      @key ||= Rails.application.key_generator.generate_key(KEY_SALT, 32)
    end

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected.to_s, actual.to_s)
    end
  end
end
