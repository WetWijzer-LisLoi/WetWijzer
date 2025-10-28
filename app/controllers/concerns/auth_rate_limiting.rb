# frozen_string_literal: true

# IP-based rate limiting for auth endpoints (login, registration, password reset, admin login).
# Uses Rails.cache (in-memory per worker) for fast lockouts.
# Not a replacement for nginx-level rate limiting but catches application-level brute force.
module AuthRateLimiting
  extend ActiveSupport::Concern

  private

  # Generic IP rate limiter using Rails.cache
  # @param key_prefix [String] e.g. 'login', 'register', 'password_reset'
  # @param limit [Integer] max attempts per window
  # @param window [ActiveSupport::Duration] time window
  # @return [Boolean] true if rate limited (should block), false if OK
  def ip_rate_limited?(key_prefix, limit:, window:)
    key = "#{key_prefix}:#{request.remote_ip}"
    count = Rails.cache.read(key).to_i

    if count >= limit
      true
    else
      Rails.cache.write(key, count + 1, expires_in: window)
      false
    end
  end

  # Login: 10 attempts per 15 minutes per IP
  def rate_limit_login!
    return unless ip_rate_limited?('auth:login', limit: 10, window: 15.minutes)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many login attempts. Please try again later.')
    render :new, status: :too_many_requests
  end

  # Registration: 5 per hour per IP
  def rate_limit_registration!
    return unless ip_rate_limited?('auth:register', limit: 5, window: 1.hour)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many attempts. Please try again later.')
    render :new, status: :too_many_requests
  end

  # Password reset: 5 per hour per IP
  def rate_limit_password_reset!
    return unless ip_rate_limited?('auth:reset', limit: 5, window: 1.hour)

    flash.now[:notice] = t('auth.reset_email_sent')
    render :new, status: :ok
  end

  # Admin login: 5 attempts per 15 minutes per IP (strictest)
  def rate_limit_admin_login!
    return unless ip_rate_limited?('auth:admin', limit: 5, window: 15.minutes)

    flash.now[:alert] = t('auth.too_many_attempts', default: 'Too many login attempts. Please try again later.')
    render :new, status: :too_many_requests
  end
end
