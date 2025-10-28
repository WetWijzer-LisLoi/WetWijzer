# frozen_string_literal: true

# Sends notification to compliance team when a GDPR takedown request is submitted
class GdprTakedownMailer < ApplicationMailer
  default to: 'privacy@wetwijzer.be'

  def new_request(takedown_request)
    @request = takedown_request
    mail(
      subject: "[GDPR Takedown] Verwijderingsverzoek #{@request.ecli} — #{@request.name}",
      from: 'noreply@wetwijzer.be'
    )
  end
end
