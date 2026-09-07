# frozen_string_literal: true

module ChatbotRating
  # Validates and applies one rating update (RAT-004).
  #
  # Every PUT is a COMPLETE replacement snapshot: score and reason codes are
  # both required and together become the new state. That is what makes the
  # endpoint idempotent - re-sending the same payload changes nothing, and the
  # last successfully processed request wins - without any rating history or a
  # second row.
  class Submission
    INVALID_SCORE = 'invalid_score'
    INVALID_REASONS = 'invalid_reason_codes'
    NOT_PERSISTED = 'not_persisted'

    attr_reader :error_code

    def initialize(analytic:, score:, reason_codes:)
      @analytic = analytic
      @score = score
      @reason_codes = reason_codes
      @error_code = nil
    end

    def apply!
      return false unless valid?

      # The validated setter, never update_column/update_all: the reason
      # column is free-form text at the database level, and its allowlist
      # lives in the model validation. A blanket update would bypass it.
      @analytic.rating_score = @score
      @analytic.rating_reason_codes = @reason_codes
      @analytic.rated_at = Time.current
      @analytic.save!
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[ChatbotRating] rating rejected: #{e.class}")
      @error_code = NOT_PERSISTED
      false
    end

    def canonical_state
      { score: @analytic.rating_score, reason_codes: @analytic.rating_reason_codes }
    end

    private

    def valid?
      # Strict integer: 8.0, "8", true and [8] are refused rather than
      # coerced, so a client cannot store a value the control never offered.
      unless Configuration.valid_score?(@score)
        @error_code = INVALID_SCORE
        return false
      end

      # An array is required. A missing key and an explicit null are both
      # invalid, because a partial update would make the endpoint stateful.
      unless @reason_codes.is_a?(Array) && Configuration.valid_reason_codes?(@reason_codes)
        @error_code = INVALID_REASONS
        return false
      end

      true
    end
  end
end
