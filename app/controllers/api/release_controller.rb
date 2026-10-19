# frozen_string_literal: true

module Api
  class ReleaseController < ApplicationController
    # The exact deployed commit (the independent authority) and, additively,
    # the application version from the one VERSION source. A version source
    # that cannot be read is reported as such, never invented.
    def show
      response.headers['Cache-Control'] = 'no-store, max-age=0'
      render json: { release_sha: ChatbotQualityProvenance.release_sha }.merge(version_field)
    rescue ChatbotQualityProvenance::Unavailable
      render json: { error: 'release_unavailable' }, status: :service_unavailable
    end

    private

    def version_field
      { version: WetWijzer::Version.string }
    rescue WetWijzer::Version::Invalid
      { version: nil, version_error: 'version_unavailable' }
    end
  end
end
