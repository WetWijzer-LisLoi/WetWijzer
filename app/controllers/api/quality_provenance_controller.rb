# frozen_string_literal: true

module Api
  class QualityProvenanceController < ApplicationController
    include ServiceAuthentication

    before_action :require_v1_service_authentication!

    def show
      response.headers['Cache-Control'] = 'no-store, max-age=0'
      snapshot = ChatbotQualityProvenance.snapshot
      render json: {
        schema_version: 1,
        release_sha: snapshot.fetch(:release_sha),
        provenance_sha256: ChatbotQualityProvenance.snapshot_sha256(snapshot)
      }
    rescue ChatbotQualityProvenance::Unavailable
      render json: { error: 'provenance_unavailable' }, status: :service_unavailable
    end

    private

    def quality_capture_authentication_required?
      true
    end

    # Deliberately does NOT inherit the registry's fallback secret: this endpoint accepts
    # only its own dedicated secret, so a credential issued for anything else cannot reach it.
    def service_secret_for(_service)
      ENV.fetch('SERVICE_AUTH_SECRET', nil)
    end

    def require_v1_service_authentication!
      version = request.headers['X-Service-Auth-Version'].to_s
      return if version == ServiceAuthentication::AUTH_VERSION && authenticate_service_request

      response.headers['Cache-Control'] = 'no-store, max-age=0'
      render json: { error: 'unauthorized' }, status: :unauthorized
    end
  end
end
