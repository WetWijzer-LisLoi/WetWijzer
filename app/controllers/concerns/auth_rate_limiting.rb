# frozen_string_literal: true

# Attempt limits for the auth endpoints: sign-in, registration, password
# reset, admin sign-in and 2FA. Not a replacement for the Rack::Attack
# throttles in front (config/initializers/rack_attack.rb); these catch
# application-level brute force.
#
# WW-SEC-02: every limit is an atomic AtomicCacheCounter reservation in a
# fixed window (the old read-then-write let parallel requests through), keyed
# by a keyed digest, never a raw address or email. Sign-in and admin sign-in
# also count per submitted email and 2FA per pending account, the same for an
# address with or without an account, so spreading guesses over addresses
# does not help against one identity. A store that cannot count denies. A
# null store is the test and development "no limits" setting; production
# runs a file store (test/security/auth_attempt_limits_test.rb pins it).
module AuthRateLimiting
  extend ActiveSupport::Concern

  ATTEMPT_KEY_PREFIX = 'auth-attempts:v1'
  ATTEMPT_DIGEST_SALT = 'auth-attempt-digest v1'

  private

  # True when this attempt is over its limit. A clock window by default;
  # bucketed: false counts for the value's whole life instead, for a value
  # that is itself short-lived (a pending sign-in), so no window boundary can
  # restart its count.
  def attempt_limited?(scope, value, limit:, window:, bucketed: true)
    return false if Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

    parts = [ATTEMPT_KEY_PREFIX, scope, window.to_i, auth_attempt_digest(scope, value)]
    parts << (Time.current.to_i / window.to_i) if bucketed
    AtomicCacheCounter.try_reserve!(parts.join(':'), limit: limit, expires_in: window).nil?
  rescue AtomicCacheCounter::Unavailable
    true
  end

  def auth_attempt_digest(scope, value)
    @auth_attempt_key ||= Rails.application.key_generator.generate_key(ATTEMPT_DIGEST_SALT, 32)
    OpenSSL::HMAC.hexdigest('SHA256', @auth_attempt_key, "#{scope}:#{value}")
  end

  # The per-address limit, as the registration limiter calls it.
  def ip_rate_limited?(key_prefix, limit:, window:)
    attempt_limited?(key_prefix, request.remote_ip, limit: limit, window: window)
  end

  # The submitted email, normalized; anything that is not a string counts as
  # one empty identity rather than escaping the count.
  def submitted_auth_email
    params[:email].is_a?(String) ? params[:email].strip.downcase : ''
  end

  # Login: 10 attempts per 15 minutes per IP, and per submitted email
  def rate_limit_login!
    return unless ip_rate_limited?('auth:login', limit: 10, window: 15.minutes) ||
                  attempt_limited?('auth:login:email', submitted_auth_email, limit: 10, window: 15.minutes)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many login attempts. Please try again later.')
    render :new, status: :too_many_requests
  end

  # Registration is admitted by RegistrationAdmissionPolicy (WW-ABUSE-01),
  # with atomic counters; its old non-atomic limiter lived here.

  # Password reset: 5 per hour per IP
  def rate_limit_password_reset!
    return unless ip_rate_limited?('auth:reset', limit: 5, window: 1.hour)

    flash.now[:notice] = t('auth.reset_email_sent')
    render :new, status: :ok
  end

  # Admin login: 5 attempts per 15 minutes per IP, and per submitted email (strictest)
  def rate_limit_admin_login!
    return unless ip_rate_limited?('auth:admin', limit: 5, window: 15.minutes) ||
                  attempt_limited?('auth:admin:email', submitted_auth_email, limit: 5, window: 15.minutes)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many login attempts. Please try again later.')
    render :new, status: :too_many_requests
  end

  # 2FA verification: 10 attempts per 15 minutes per IP, and per pending
  # account. Without this the TOTP / backup-code check could be brute-forced
  # within the pending-2FA cookie window.
  def rate_limit_2fa!
    return unless ip_rate_limited?('auth:2fa', limit: 10, window: 15.minutes) ||
                  attempt_limited?('auth:2fa:account', PendingSecondFactor.account_id(cookies.encrypted[:pending_2fa_user_id]),
                                   limit: 10, window: 15.minutes)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many attempts. Please try again later.')
    redirect_to login_path, status: :see_other
  end
end
