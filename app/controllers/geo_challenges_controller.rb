# frozen_string_literal: true

# == GeoChallengesController
#
# Handles the ALTCHA proof-of-work challenge for non-EU visitors.
# - GET /geo-challenge       → renders the challenge page
# - POST /geo-challenge      → verifies the solution and sets the cookie
# - GET /altcha-challenge.json → returns a fresh challenge for the widget
#
class GeoChallengesController < ApplicationController
  # Don't enforce geo challenge on these pages (would cause redirect loop)
  skip_before_action :enforce_geo_challenge, raise: false

  # GET /geo-challenge
  def show
    @country = request.headers['X-Geo-Country'].to_s.upcase.presence || 'Unknown'
  end

  # POST /geo-challenge
  def create
    if AltchaService.verify_solution(params[:altcha])
      # Set signed cookie - valid for 24 hours
      cookies.signed[:geo_verified] = {
        value: 'verified',
        expires: 24.hours.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      Rails.logger.info("GeoChallenge: verified successfully from #{request.remote_ip} (#{request.headers['X-Geo-Country']})")

      # Redirect back to the original page
      return_path = cookies.signed[:geo_return_to].presence || root_path
      cookies.delete(:geo_return_to)

      redirect_to return_path
    else
      Rails.logger.warn("GeoChallenge: failed verification from #{request.remote_ip} (#{request.headers['X-Geo-Country']})")
      @error = true
      @country = request.headers['X-Geo-Country'].to_s.upcase.presence || 'Unknown'
      render :show, status: :unprocessable_entity
    end
  end

  # GET /altcha-challenge.json
  def challenge_json
    challenge = AltchaService.generate_challenge
    render json: challenge
  end
end
