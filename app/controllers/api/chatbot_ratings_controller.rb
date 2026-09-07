# frozen_string_literal: true

module Api
  # PUT /api/chatbot/rating - the single rating resource for one answer
  # (RAT-004).
  #
  # A focused controller rather than another action on ChatbotController, so
  # the authorization chain is small enough to read in one screen and testable
  # on its own. It inherits ChatbotBaseController for the established CSRF
  # policy and JSON failure shape.
  #
  # The client may send exactly three things: the signed token, an integer
  # score, and the complete array of reason codes. It asserts NOTHING about
  # the model, provider, parameters, language or identity - every one of those
  # is server-observed and would be trivially forgeable if accepted here.
  class ChatbotRatingsController < ChatbotBaseController
    # Deliberately no HMAC/service exemption: this capability is browser-only.
    # ChatbotBaseController skips CSRF for verified service requests, which is
    # correct for the ask path but must not extend here, so a service request
    # that somehow reaches this action still fails ownership below.
    def update
      return unauthorized unless current_user

      analytic = ChatbotRating::Token.resolve(rating_params[:rating_token])
      return not_found unless authorized?(analytic)

      submission = ChatbotRating::Submission.new(
        analytic: analytic,
        score: rating_params[:score],
        reason_codes: rating_params[:reason_codes]
      )
      return unprocessable(submission.error_code) unless submission.apply!

      render json: { success: true, **submission.canonical_state }
    end

    private

    # Strong parameters drop everything else. A request carrying question,
    # answer, model or analytic_id is accepted and those values are simply
    # never read - they cannot reach storage.
    def rating_params
      params.permit(:rating_token, :score, reason_codes: [])
    end

    def authorized?(analytic)
      return false unless ChatbotRating::Token.rateable?(analytic)

      # Ownership on EVERY update, not just at issuance. Logging out or
      # revoking a session therefore ends the capability, and a token that
      # leaks to another account is useless.
      analytic.user_id == current_user.id
    end

    # One response for invalid, expired, wrong-purpose, wrong-owner and
    # ineligible. Distinguishing them would turn this endpoint into an oracle
    # for which analytics rows exist and who owns them.
    def not_found
      render json: { error: 'not_found' }, status: :not_found
    end

    def unauthorized
      render json: { error: 'authentication_required' }, status: :unauthorized
    end

    def unprocessable(code)
      render json: { error: code || 'invalid_rating' }, status: :unprocessable_entity
    end
  end
end
