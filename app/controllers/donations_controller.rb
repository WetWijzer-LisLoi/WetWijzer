# frozen_string_literal: true

# Anonymous, one-off donations completed on Mollie's hosted checkout.
#
# A browser return never proves payment. It carries only an opaque local token;
# the corresponding payment is fetched directly from Mollie and passed through
# the same immutable-contract verifier used by webhooks.
class DonationsController < ApplicationController
  RETURN_TOKEN = /\A[A-Za-z0-9_-]{40,64}\z/

  MESSAGES = {
    unavailable: {
      nl: 'Donaties zijn tijdelijk niet beschikbaar. Probeer het later opnieuw.',
      fr: 'Les dons sont temporairement indisponibles. Veuillez réessayer plus tard.',
      en: 'Donations are temporarily unavailable. Please try again later.',
      de: 'Spenden sind vorübergehend nicht verfügbar. Bitte versuchen Sie es später erneut.'
    },
    invalid_amount: {
      nl: 'Kies een van de aangeboden donatiebedragen.',
      fr: 'Choisissez l’un des montants de don proposés.',
      en: 'Choose one of the offered donation amounts.',
      de: 'Wählen Sie einen der angebotenen Spendenbeträge.'
    },
    checkout_error: {
      nl: 'De donatiebetaling kon niet worden gestart. Probeer het later opnieuw.',
      fr: 'Le paiement du don n’a pas pu être démarré. Veuillez réessayer plus tard.',
      en: 'The donation payment could not be started. Please try again later.',
      de: 'Die Spendenzahlung konnte nicht gestartet werden. Bitte versuchen Sie es später erneut.'
    },
    thank_you: {
      nl: 'Bedankt voor uw vrijwillige steun!',
      fr: 'Merci pour votre soutien volontaire !',
      en: 'Thank you for your voluntary support!',
      de: 'Vielen Dank für Ihre freiwillige Unterstützung!'
    },
    processing: {
      nl: 'Uw donatiebetaling wordt nog geverifieerd.',
      fr: 'Le paiement de votre don est encore en cours de vérification.',
      en: 'Your donation payment is still being verified.',
      de: 'Ihre Spendenzahlung wird noch geprüft.'
    },
    not_found: {
      nl: 'We konden deze donatiebetaling niet bevestigen.',
      fr: 'Nous n’avons pas pu confirmer ce paiement de don.',
      en: 'We could not confirm this donation payment.',
      de: 'Wir konnten diese Spendenzahlung nicht bestätigen.'
    },
    canceled: {
      nl: 'De donatiebetaling werd geannuleerd; er is niets aangerekend.',
      fr: 'Le paiement du don a été annulé ; aucun montant n’a été débité.',
      en: 'The donation payment was canceled; nothing was charged.',
      de: 'Die Spendenzahlung wurde abgebrochen; es wurde nichts berechnet.'
    }
  }.freeze

  def create
    amount_cents = Integer(params[:amount_cents], exception: false)
    unless MolliePayment::DONATION_AMOUNTS_CENTS.include?(amount_cents)
      redirect_to donation_page_path, alert: localized(:invalid_amount), status: :see_other
      return
    end

    unless MollieConfiguration.checkout_enabled?
      redirect_to donation_page_path, alert: localized(:unavailable), status: :see_other
      return
    end

    result = MollieCheckoutService.new(
      user: nil,
      locale: I18n.locale,
      redirect_url: donation_return_url,
      cancel_url: donation_cancel_url
    ).create_donation(amount_cents: amount_cents)

    redirect_to result.fetch(:checkout_url), allow_other_host: true, status: :see_other
  rescue MollieCheckoutService::CheckoutError, ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[Donations] Mollie checkout failed: #{e.class}")
    redirect_to donation_page_path, alert: localized(:checkout_error), status: :see_other
  end

  def complete
    payment = find_returned_payment
    process_returned_payment(payment)

    if payment&.reload&.fulfilled?
      redirect_to donation_page_path, notice: localized(:thank_you)
    elsif payment && %w[created open pending authorized].include?(payment.status)
      redirect_to donation_page_path, notice: localized(:processing)
    else
      redirect_to donation_page_path, alert: localized(:not_found)
    end
  end

  def cancel
    redirect_to donation_page_path, notice: localized(:canceled)
  end

  private

  def donation_page_path
    support_page_path(anchor: 'donate')
  end

  def localized(key)
    MESSAGES.fetch(key).fetch(I18n.locale.to_sym, MESSAGES.fetch(key).fetch(:nl))
  end

  def find_returned_payment
    token = params[:payment_token].to_s
    return unless token.match?(RETURN_TOKEN)

    MolliePayment.find_by(checkout_token: token, payment_type: 'donation')
  end

  def process_returned_payment(payment)
    return unless payment&.mollie_payment_id.present?

    snapshot = MollieApiClient.new.get_payment(payment.mollie_payment_id)
    MolliePaymentProcessor.new(snapshot).process!
  rescue MollieApiClient::Error, MolliePaymentProcessor::TransientError => e
    Rails.logger.warn("[Donations] Return verification deferred: #{e.class}")
  rescue MolliePaymentProcessor::VerificationError => e
    Rails.logger.error("[Donations] Return verification rejected: #{e.message}")
  end
end
