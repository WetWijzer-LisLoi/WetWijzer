# frozen_string_literal: true

module ChatbotRating
  # Issues and resolves the per-answer rating capability (RAT-004).
  #
  # The token IS the authorization. The sequential analytic id is never used
  # for that: it is guessable, so an endpoint keyed on it would let anyone
  # enumerate and rate other people's answers. A signed id is unguessable,
  # purpose-scoped and expiring - and ownership is still checked on every
  # update, so a leaked token is not enough on its own.
  module Token
    module_function

    # Marks the row eligible and mints its token in ONE transaction.
    #
    # Both must succeed together. rating_ui_version is the admin dashboard's
    # response-rate DENOMINATOR - it means "this answer really did offer a
    # rating control" - so a row marked eligible whose token never reached the
    # browser would permanently understate the response rate. If signing or
    # the commit fails, the mark is rolled back and no token is returned.
    def issue!(analytic)
      return nil unless issuable?(analytic)

      token = nil
      AnalyticsRecord.transaction do
        analytic.update!(rating_ui_version: Configuration.ui_version)
        token = analytic.signed_id(purpose: Configuration.token_purpose,
                                   expires_in: Configuration.token_ttl)
        if token.blank?
          token = nil
          raise ActiveRecord::Rollback
        end
      end
      token
    rescue StandardError => e
      # Answer delivery never depends on this. Log the class only: an adapter
      # error message can carry the whole failing row.
      Rails.logger.warn("[ChatbotRating] token issuance skipped: #{e.class}")
      nil
    end

    # Every condition here is server-side. Nothing the browser sends can make
    # an answer rateable.
    def issuable?(analytic)
      return false unless Configuration.enabled?
      return false unless analytic.respond_to?(:persisted?) && analytic.persisted?
      return false if analytic.has_error
      # No owner means no one to check ownership against later, so the
      # capability would be bearer-only. Service/HMAC traffic is excluded
      # before this point by the caller, which is the authoritative guard.
      return false if analytic.user_id.blank?

      true
    end

    # Returns the analytic, or nil for a token that is invalid, tampered,
    # expired, or minted for a different purpose. The caller must not
    # distinguish those cases to the client: the endpoint answers 404 for all
    # of them so it cannot be used as an id oracle.
    def resolve(token)
      return nil if token.blank?

      ChatbotAnalytic.find_signed(token.to_s, purpose: Configuration.token_purpose)
    rescue StandardError
      nil
    end

    # An already-issued token stays usable after the flag is turned off, so a
    # rollback never strands a user mid-rating (plan 16.3). Note this does NOT
    # consult Configuration.enabled?.
    def rateable?(analytic)
      return false unless analytic
      return false unless analytic.rating_ui_version == Configuration.ui_version
      return false if analytic.has_error
      return false if analytic.user_id.blank?

      true
    end
  end
end
