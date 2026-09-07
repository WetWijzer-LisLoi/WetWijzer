# frozen_string_literal: true

module Api
  class SampleQuestionClicksController < ApplicationController
    # FBL-043: normal same-origin CSRF applies. sendBeacon cannot set
    # headers, so the client puts authenticity_token in the JSON body,
    # which Rails accepts. Rate limiting is Rack::Attack's
    # 'sample-clicks/ip' throttle (atomic store), replacing the racy
    # fetch-then-increment cache counter that lived here.

    # POST /api/sample_question_clicks
    # Body: { question: "...", category: "...", language: "nl",
    #         authenticity_token: "..." }
    # Returns 204 No Content (fire-and-forget from client)
    def create
      SampleQuestionClick.track!(
        question_text: params[:question],
        category: params[:category],
        language: params[:language].presence || 'nl'
      )
      head :no_content
    rescue SampleQuestionClick::InvalidClick => e
      render json: { error: { code: e.message } }, status: :unprocessable_entity
    rescue StandardError => e
      # Tracking is best-effort; never bubble storage errors to the client.
      Rails.logger.warn("[SampleQuestionClick] tracking failed: #{e.class}")
      head :no_content
    end
  end
end
