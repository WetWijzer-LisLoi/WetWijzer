# frozen_string_literal: true

module ChatbotRating
  # Single source of truth for every constant the 10-star rating feature shares
  # between the server, the rating API and the browser control.
  #
  # Implements section 7.3 of
  # docs/ops/chatbot-rating-implementation-plan-2026-08-27.md (RAT-001).
  #
  # Two rules this object exists to enforce:
  #
  # 1. The reason allowlist, the score range and the maximum reason count are
  #    declared ONCE. The API validates against these; the browser renders from
  #    the same list delivered server-side. Drift between the two is how an
  #    allowlist quietly stops being one.
  #
  # 2. `enabled?` gates ISSUANCE only. Turning the flag off stops new rating
  #    tokens and hides new controls, but a token already issued into an open
  #    page stays valid until it expires - the update endpoint must keep
  #    accepting it (plan sections 7.1 and 16.3). Never gate the update path on
  #    this flag.
  module Configuration
    ENV_FLAG = 'CHATBOT_STAR_RATINGS'

    UI_VERSION = 'stars_v1'
    TOKEN_PURPOSE = :chatbot_rating
    TOKEN_TTL = 30.days

    MINIMUM_SCORE = 1
    MAXIMUM_SCORE = 10
    SCORE_RANGE = (MINIMUM_SCORE..MAXIMUM_SCORE)

    MAXIMUM_REASONS = 3

    # An explicit truthy allowlist rather than ActiveModel's boolean cast,
    # which treats "no" as TRUE (its false list covers off/false/0/"" only).
    # Anything unrecognised leaves the feature off, so a typo in the operator
    # environment cannot switch issuance on.
    TRUE_VALUES = %w[true t yes y on 1].freeze

    # Stable database codes. Never renumber, reword the CODE, or reuse a
    # retired code for a different meaning - stored rows keep these strings.
    # Display copy lives in the locale layer, not here.
    REASON_CODES = %w[
      incorrect
      incomplete
      weak_sources
      unclear
      too_long
      too_slow
      clear_practical
      complete
      strong_sources
      fast
    ].freeze

    module_function

    # Issuance gate only. See the note above: this must never guard an update.
    def enabled?
      TRUE_VALUES.include?(ENV.fetch(ENV_FLAG, nil).to_s.strip.downcase)
    end

    def ui_version
      UI_VERSION
    end

    def token_purpose
      TOKEN_PURPOSE
    end

    def token_ttl
      TOKEN_TTL
    end

    def score_range
      SCORE_RANGE
    end

    def valid_score?(value)
      # Integer only, on purpose: 8.0, "8", true and [8] are rejected rather
      # than coerced, so a sloppy client cannot write a value the UI never
      # offered (plan section 7.2).
      value.is_a?(Integer) && SCORE_RANGE.cover?(value)
    end

    def reason_codes
      REASON_CODES
    end

    def maximum_reasons
      MAXIMUM_REASONS
    end

    def valid_reason_codes?(values)
      return false unless values.is_a?(Array)
      return false if values.size > MAXIMUM_REASONS
      return false unless values.all?(String)
      return false unless values.uniq.size == values.size

      values.all? { |code| REASON_CODES.include?(code) }
    end
  end
end
