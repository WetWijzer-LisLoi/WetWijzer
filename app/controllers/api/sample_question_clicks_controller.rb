# frozen_string_literal: true

module Api
  class SampleQuestionClicksController < ApplicationController
    # No authentication required - this is anonymous tracking
    skip_before_action :verify_authenticity_token, only: [:create]

    # POST /api/sample_question_clicks
    # Body: { question: "...", category: "...", language: "nl" }
    # Returns 204 No Content (fire-and-forget from client)
    def create
      question = params[:question].to_s.strip
      category = params[:category].to_s.strip
      language = params[:language].to_s.strip.presence || 'nl'

      if question.blank? || category.blank?
        head :unprocessable_entity
        return
      end

      # Rate limit: max 30 clicks per minute per IP (prevents abuse)
      cache_key = "sq_click_rate:#{Digest::SHA256.hexdigest(request.remote_ip)[0..7]}"
      count = Rails.cache.fetch(cache_key, expires_in: 1.minute, raw: true) { 0 }
      if count.to_i >= 30
        head :too_many_requests
        return
      end
      Rails.cache.increment(cache_key)

      SampleQuestionClick.track!(
        question_text: question,
        category: category,
        language: language
      )

      head :no_content
    end
  end
end
