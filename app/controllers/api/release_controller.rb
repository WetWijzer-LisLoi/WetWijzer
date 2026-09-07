# frozen_string_literal: true

module Api
  class ReleaseController < ApplicationController
    def show
      response.headers['Cache-Control'] = 'no-store, max-age=0'
      render json: { release_sha: ChatbotQualityProvenance.release_sha }
    rescue ChatbotQualityProvenance::Unavailable
      render json: { error: 'release_unavailable' }, status: :service_unavailable
    end
  end
end
