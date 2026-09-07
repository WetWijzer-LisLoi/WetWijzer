# frozen_string_literal: true

require 'digest'
require 'fileutils'

# == Service Authentication
#
# HMAC-based service-to-service authentication for trusted first-party services.
# Replaces static passphrases with per-request signed authentication.
#
# Version 1 protocol (required for quality-evidence capture):
#   Headers:
#     X-Service-Auth-Version: "1"
#     X-Service-App:       "<service>"        (app identifier)
#     X-Service-Timestamp: "1716000000"        (Unix timestamp)
#     X-Service-Nonce:     "uuid-v4"           (unique per request)
#     X-Request-ID:        "uuid-v4"           (request identifier)
#     X-Service-Signature: "hex-hmac-sha256"
#
#   The signature is HMAC-SHA256(secret, canonical), where canonical is the
#   following newline-delimited byte string (the body digest is computed from
#   the exact HTTP request-body bytes, before JSON parsing):
#
#     wetwijzer-service-auth-v1
#     <UPPERCASE HTTP method>
#     <request path>
#     <SHA-256 hex of exact body bytes>
#     <X-Request-ID>
#     <X-Service-Timestamp>
#     <X-Service-Nonce>
#     <X-Service-App>
#
#   Validation:
#     1. All required headers must be present
#     2. App must be in TRUSTED_SERVICES
#     3. Timestamp must be within 5 minutes of server time
#     4. HMAC signature must match
#     5. Nonce must be claimed atomically (replay protection)
#
# Legacy requests without X-Service-Auth-Version retain the original
# "app|timestamp|nonce" signature solely for non-quality partner traffic.
# A request asking for quality evidence must use v1, so stripping/downgrading
# the version cannot turn a body-unbound legacy signature into a quality call.
#
# Configuration:
#
module ServiceAuthentication
  extend ActiveSupport::Concern

  TIMESTAMP_TOLERANCE = 300 # 5 minutes
  NONCE_TTL = 600           # 10 minutes (nonces expire from cache)
  AUTH_VERSION = '1'
  AUTH_DOMAIN = 'wetwijzer-service-auth-v1'
  HEADER_VALUE_PATTERN = /\A[!-~]{1,200}\z/
  SIGNATURE_PATTERN = /\A[0-9a-f]{64}\z/i
  TIMESTAMP_PATTERN = /\A[0-9]{1,20}\z/

  # The registry lost its only entry on 2026-08-08 when the third-party desktop integration
  # was removed. The endpoints it used to gate - the chatbot quality probe and the quality
  # provenance snapshot - are WetWijzer's OWN tooling and had merely borrowed that identity,
  # so they are re-registered here under a first-party one rather than deleted.
  #
  # They authenticate only when SERVICE_AUTH_SECRET is set. It is not set in production today,
  # so both endpoints answer 401 - which is already what they did once the old integration's
  # secrets left the environment. Set it to bring them back.
  TRUSTED_SERVICES = {
    'wetwijzer-quality' => {
      name: 'WetWijzer quality tooling',
      secret_env: 'SERVICE_AUTH_SECRET',
      fallback_env: 'SERVICE_AUTH_SECRET'
    }
  }.freeze

  private

  # Authenticate a service request via HMAC-signed headers.
  # Sets @service_app on success.
  # Returns true if authenticated, false otherwise.
  def authenticate_service_request
    auth_version = request.headers['X-Service-Auth-Version'].to_s.strip
    app_id       = request.headers['X-Service-App'].to_s.strip
    timestamp    = request.headers['X-Service-Timestamp'].to_s.strip
    nonce        = request.headers['X-Service-Nonce'].to_s.strip
    signature    = request.headers['X-Service-Signature'].to_s.strip

    # Quality captures are security-sensitive measurement records. They may
    # never fall back to the legacy body-unbound signature contract.
    return false if quality_capture_authentication_required? && auth_version != AUTH_VERSION
    return false unless auth_version.empty? || auth_version == AUTH_VERSION

    # Headers shared by both protocol versions.
    return false if [app_id, timestamp, nonce, signature].any?(&:blank?)
    return false unless timestamp.match?(TIMESTAMP_PATTERN)
    return false unless nonce.match?(HEADER_VALUE_PATTERN)
    return false unless signature.match?(SIGNATURE_PATTERN)

    # App must be trusted
    service = TRUSTED_SERVICES[app_id]
    return false unless service

    # Timestamp freshness (prevent replay of old requests)
    ts = Integer(timestamp, 10)
    return false if (service_authentication_now.to_i - ts).abs > TIMESTAMP_TOLERANCE

    # Verify HMAC signature
    secret = service_secret_for(service)
    return false if secret.blank?

    canonical = if auth_version == AUTH_VERSION
                  request_id = request.headers['X-Request-ID'].to_s.strip
                  return false unless request_id.match?(HEADER_VALUE_PATTERN)

                  service_auth_v1_canonical(
                    method: request.request_method,
                    path: request.path,
                    body: request.raw_post,
                    request_id: request_id,
                    timestamp: timestamp,
                    nonce: nonce,
                    app_id: app_id
                  )
                else
                  "#{app_id}|#{timestamp}|#{nonce}"
                end
    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, canonical)
    return false unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.downcase)

    # A read-then-write sequence has a race in which two identical requests can
    # both pass. Cache stores used here must provide atomic create-if-absent.
    nonce_key = "service_nonce:#{app_id}:#{nonce}"
    unless claim_service_nonce(nonce_key)
      Rails.logger.warn({ event: 'service_auth_nonce_replay', app: app_id, nonce: nonce }.to_json)
      return false
    end

    @service_app = app_id
    Rails.logger.info({ event: 'service_auth_success', app: app_id, auth_version: auth_version.presence || 'legacy' }.to_json)
    true
  rescue ArgumentError, TypeError
    false
  end

  def service_auth_v1_canonical(method:, path:, body:, request_id:, timestamp:, nonce:, app_id:)
    body_sha256 = Digest::SHA256.hexdigest(body.to_s.b)
    [
      AUTH_DOMAIN,
      method.to_s.upcase,
      path.to_s,
      body_sha256,
      request_id,
      timestamp,
      nonce,
      app_id
    ].join("\n")
  end

  def quality_capture_authentication_required?
    %w[1 true yes].include?(params[:quality_evidence].to_s.downcase)
  end

  def claim_service_nonce(nonce_key)
    cache = service_authentication_cache
    return false if cache.is_a?(ActiveSupport::Cache::NullStore)

    # ActiveSupport::Cache::FileStore implements `unless_exist` as
    # File.exist? followed by a write, which is not atomic. Production and
    # staging use FileStore, so serialize that check-and-write under one
    # cross-process file lock shared by all Puma workers on the host.
    if cache.is_a?(ActiveSupport::Cache::FileStore)
      claim_file_store_nonce(cache, nonce_key)
    else
      cache.write(
        nonce_key,
        true,
        expires_in: NONCE_TTL.seconds,
        unless_exist: true
      ) == true
    end
  rescue StandardError => error
    Rails.logger.error({
      event: 'service_auth_nonce_store_failure',
      error_class: error.class.name
    }.to_json)
    false
  end

  def claim_file_store_nonce(cache, nonce_key)
    lock_path = File.join(File.dirname(cache.cache_path), 'service_auth_nonce_claim.lock')
    FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
    File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock|
      return false unless lock.flock(File::LOCK_EX)

      # `read` removes an expired FileStore entry. The lock makes this
      # read-and-NX-write sequence one atomic claim across processes.
      return false if cache.read(nonce_key)

      cache.write(
        nonce_key,
        true,
        expires_in: NONCE_TTL.seconds,
        unless_exist: true
      ) == true
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  def service_authentication_cache
    Rails.cache
  end

  def service_authentication_now
    Time.current
  end

  def service_secret_for(service)
    ENV.fetch(service[:secret_env]) { ENV.fetch(service[:fallback_env], nil) }
  end

  def service_authenticated?
    @service_app.present?
  end
end
