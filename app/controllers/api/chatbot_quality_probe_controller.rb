# frozen_string_literal: true

require 'digest'
require 'openssl'

module Api
  # Narrow live-browser quality probes. These endpoints expose no PII and can
  # neither ask the model nor mutate a user's balance. The service-only actions
  # require the body-bound v1 HMAC contract with no legacy-secret fallback.
  class ChatbotQualityProbeController < ApplicationController
    include ServiceAuthentication

    RATE_LIMIT_PURPOSE = 'live_browser_matrix_rate_limit_v1'
    RATE_LIMIT_TTL = 2.minutes
    RESERVATION_LOOKBACK = 30.minutes
    MAX_RESERVATION_CANDIDATES = 500
    REQUEST_ID_SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    ARM_TOKEN_PATTERN = /\A[A-Za-z0-9_-]{43}\z/
    SAFE_REFUND_REASON_PATTERN = /\A[a-zA-Z0-9_.:-]{1,100}\z/
    GENERAL_BURST_LIMIT = ::Api::ChatbotController::PER_IP_BURST_LIMIT

    skip_forgery_protection only: %i[arm_rate_limit cleanup_rate_limit reservation_audit]
    before_action :require_session_user!, only: :credit_state
    before_action :require_v1_service_authentication!, except: :credit_state

    def credit_state
      user = current_user.reload
      no_store!
      render json: {
        schema_version: 1,
        credits_remaining: user.total_available_credits.to_i,
        balance_version: user.credit_balance_version.to_i,
        account_fingerprint: account_fingerprint(user.id)
      }
    end

    def arm_rate_limit
      return render_bad_probe_request unless exact_json_body('purpose' => RATE_LIMIT_PURPOSE)

      cache = quality_probe_cache
      ip = request.remote_ip.to_s
      rate_key = general_burst_key(ip)
      prior = cache.read(rate_key)
      return render_probe_conflict('rate_limit_counter_not_clean') unless prior.nil? || prior.to_i.zero?

      token = SecureRandom.urlsafe_base64(32, false)
      token_digest = Digest::SHA256.hexdigest(token)
      arm_key = rate_limit_arm_key(token_digest)
      arm = {
        'ip_digest' => ip_digest(ip),
        'rate_key_digest' => Digest::SHA256.hexdigest(rate_key),
        'prior_missing' => prior.nil?,
        'prior_count' => prior.to_i
      }

      return render_probe_conflict('rate_limit_arm_collision') unless cache.write(
        arm_key, arm, expires_in: RATE_LIMIT_TTL, unless_exist: true
      ) == true

      unless cache.write(rate_key, GENERAL_BURST_LIMIT, expires_in: 1.minute)
        cache.delete(arm_key)
        return render_probe_unavailable('rate_limit_arm_failed')
      end

      no_store!
      render json: {
        schema_version: 1,
        armed: true,
        arm_token: token,
        expected_http_status: 429,
        expected_retry_after_seconds: 60
      }
    end

    def cleanup_rate_limit
      body = exact_json_object(%w[purpose arm_token])
      return render_bad_probe_request unless body && body['purpose'] == RATE_LIMIT_PURPOSE

      token = body['arm_token'].to_s
      return render_bad_probe_request unless token.match?(ARM_TOKEN_PATTERN)

      cache = quality_probe_cache
      arm_key = rate_limit_arm_key(Digest::SHA256.hexdigest(token))
      arm = cache.read(arm_key)
      return render_probe_conflict('rate_limit_arm_missing') unless arm.is_a?(Hash)

      ip = request.remote_ip.to_s
      return render_probe_conflict('rate_limit_arm_origin_mismatch') unless arm['ip_digest'] == ip_digest(ip)

      rate_key = general_burst_key(ip)
      return render_probe_conflict('rate_limit_arm_key_mismatch') unless arm['rate_key_digest'] == Digest::SHA256.hexdigest(rate_key)

      observed_count = quality_probe_cache.read(rate_key).to_i
      return render_probe_conflict('rate_limit_probe_counter_out_of_bounds') unless [
        GENERAL_BURST_LIMIT,
        GENERAL_BURST_LIMIT + 1
      ].include?(observed_count)

      consumed = observed_count == GENERAL_BURST_LIMIT + 1

      restored = if arm['prior_missing']
                   cache.delete(rate_key)
                   true
                 else
                   cache.write(rate_key, arm['prior_count'].to_i, expires_in: 1.minute)
                 end
      return render_probe_unavailable('rate_limit_cleanup_failed') unless restored

      cache.delete(arm_key)
      no_store!
      render json: { schema_version: 1, cleaned: true, consumed: consumed }
    end

    def reservation_audit
      body = exact_json_object(%w[request_id_sha256])
      request_sha = body&.fetch('request_id_sha256', '').to_s.downcase
      return render_bad_probe_request unless request_sha.match?(REQUEST_ID_SHA256_PATTERN)

      matches = recent_browser_reservations.select do |reservation|
        raw_request_id = reservation.app.to_s.delete_prefix('browser_chatbot:')
        candidate_sha = Digest::SHA256.hexdigest(raw_request_id)
        ActiveSupport::SecurityUtils.secure_compare(candidate_sha, request_sha)
      end

      no_store!
      return render json: { schema_version: 1, found: false, request_id_sha256: request_sha } if matches.empty?
      return render_probe_conflict('reservation_audit_not_unique') unless matches.one?

      reservation = matches.first
      reason = reservation.refund_reason.to_s
      safe_reason = if reason.match?(SAFE_REFUND_REASON_PATTERN)
                      reason
                    elsif reason.present?
                      'redacted'
                    end
      render json: {
        schema_version: 1,
        found: true,
        request_id_sha256: request_sha,
        reservation_token_sha256: Digest::SHA256.hexdigest(reservation.reservation_token.to_s),
        account_fingerprint: account_fingerprint(reservation.user_id),
        reservation_kind: reservation.reservation_kind,
        status: reservation.status,
        amount: reservation.amount.to_i,
        intelligence: reservation.intelligence_level.to_s,
        model: reservation.model.to_s,
        refund_reason: safe_reason,
        created_at: reservation.created_at&.utc&.iso8601(3),
        settled_at: reservation.settled_at&.utc&.iso8601(3),
        refunded_at: reservation.refunded_at&.utc&.iso8601(3)
      }
    end

    private

    def require_session_user!
      return if current_user

      no_store!
      render json: { error: 'login_required' }, status: :unauthorized
    end

    def require_v1_service_authentication!
      version = request.headers['X-Service-Auth-Version'].to_s
      return if version == ServiceAuthentication::AUTH_VERSION && authenticate_service_request

      no_store!
      render json: { error: 'unauthorized' }, status: :unauthorized
    end

    def quality_capture_authentication_required?
      true
    end

    def service_secret_for(_service)
      ENV.fetch('SERVICE_AUTH_SECRET', nil)
    end

    def exact_json_body(expected)
      body = exact_json_object(expected.keys)
      body == expected
    end

    def exact_json_object(expected_keys)
      return unless request.media_type == 'application/json'

      body = JSON.parse(request.raw_post)
      return unless body.is_a?(Hash) && body.keys.sort == expected_keys.sort

      body
    rescue JSON::ParserError
      nil
    end

    def general_burst_key(ip)
      ::Api::ChatbotController.windowed_rate_limit_key(
        "chatbot_burst:#{ip}",
        expires_in: 1.minute
      )
    end

    def rate_limit_arm_key(token_digest)
      "quality_browser_rate_limit_arm:#{token_digest}"
    end

    def ip_digest(ip)
      OpenSSL::HMAC.hexdigest('SHA256', quality_probe_identity_secret, "quality-probe-ip-v1\0#{ip}")
    end

    def account_fingerprint(user_id)
      OpenSSL::HMAC.hexdigest(
        'SHA256',
        quality_probe_identity_secret,
        "quality-probe-account-v1\0#{user_id}"
      )
    end

    def quality_probe_identity_secret
      Rails.application.secret_key_base
    end

    def quality_probe_cache
      Rails.cache
    end

    def recent_browser_reservations
      BillingReservation
        .browser_chat
        .where(reservation_kind: BillingReservation::CREDIT_KIND)
        .where(created_at: RESERVATION_LOOKBACK.ago..Time.current)
        .order(created_at: :desc, id: :desc)
        .limit(MAX_RESERVATION_CANDIDATES)
        .to_a
    end

    def render_bad_probe_request
      no_store!
      render json: { error: 'invalid_probe_request' }, status: :bad_request
    end

    def render_probe_conflict(code)
      no_store!
      render json: { error: code }, status: :conflict
    end

    def render_probe_unavailable(code)
      no_store!
      render json: { error: code }, status: :service_unavailable
    end

    def no_store!
      response.headers['Cache-Control'] = 'no-store, max-age=0'
    end
  end
end
