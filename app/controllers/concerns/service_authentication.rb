# frozen_string_literal: true

# == Service Authentication
#
# HMAC-based service-to-service authentication for trusted partner apps (e.g. Praxis).
# Replaces static passphrases with per-request signed authentication.
#
# Protocol:
#   Headers:
#     X-Service-App:       "praxis"           (app identifier)
#     X-Service-Timestamp: "1716000000"        (Unix timestamp)
#     X-Service-Nonce:     "uuid-v4"           (unique per request)
#     X-Service-Signature: "hex-hmac-sha256"   (HMAC of "app|timestamp|nonce")
#
#   The signature is computed as:
#     HMAC-SHA256(secret, "#{app}|#{timestamp}|#{nonce}")
#
#   Validation:
#     1. All 4 headers must be present
#     2. App must be in TRUSTED_SERVICES
#     3. Timestamp must be within 5 minutes of server time
#     4. HMAC signature must match
#     5. Nonce must not have been used before (replay protection)
#
# Configuration:
#   ENV['PRAXIS_SERVICE_SECRET'] - shared secret for Praxis (falls back to PRAXIS_SSO_SECRET)
#
module ServiceAuthentication
  extend ActiveSupport::Concern

  TIMESTAMP_TOLERANCE = 300 # 5 minutes
  NONCE_TTL = 600           # 10 minutes (nonces expire from cache)

  TRUSTED_SERVICES = {
    'praxis' => {
      name: 'Praxis Legal',
      secret_env: 'PRAXIS_SERVICE_SECRET',
      fallback_env: 'PRAXIS_SSO_SECRET'
    }
  }.freeze

  private

  # Authenticate a service request via HMAC-signed headers.
  # Sets @service_app on success.
  # Returns true if authenticated, false otherwise.
  def authenticate_service_request
    app_id    = request.headers['X-Service-App'].to_s.strip
    timestamp = request.headers['X-Service-Timestamp'].to_s.strip
    nonce     = request.headers['X-Service-Nonce'].to_s.strip
    signature = request.headers['X-Service-Signature'].to_s.strip

    # All headers required
    return false if [app_id, timestamp, nonce, signature].any?(&:blank?)

    # App must be trusted
    service = TRUSTED_SERVICES[app_id]
    return false unless service

    # Timestamp freshness (prevent replay of old requests)
    ts = timestamp.to_i
    return false if (Time.current.to_i - ts).abs > TIMESTAMP_TOLERANCE

    # Verify HMAC signature
    secret = service_secret_for(service)
    return false if secret.blank?

    canonical = "#{app_id}|#{timestamp}|#{nonce}"
    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, canonical)
    return false unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)

    # Nonce replay protection (cache-based)
    nonce_key = "service_nonce:#{app_id}:#{nonce}"
    if Rails.cache.read(nonce_key)
      Rails.logger.warn({ event: 'service_auth_nonce_replay', app: app_id, nonce: nonce }.to_json)
      return false
    end
    Rails.cache.write(nonce_key, true, expires_in: NONCE_TTL.seconds)

    @service_app = app_id
    Rails.logger.info({ event: 'service_auth_success', app: app_id }.to_json)
    true
  end

  def service_secret_for(service)
    ENV.fetch(service[:secret_env]) { ENV.fetch(service[:fallback_env], nil) }
  end

  def service_authenticated?
    @service_app.present?
  end
end
