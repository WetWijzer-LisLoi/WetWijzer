# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  before_action :require_authentication, except: [:pricing]
  before_action :set_subscription, only: %i[show cancel reactivate]

  def pricing
    @tiers = Subscription::TIER_CONFIG
    # The layout renders <title> from @title; without it the page shipped an
    # empty document title (axe: document-title).
    @title = t('pricing.title')
  end

  def show
    # A safe GET must not create account state. Legacy users without the normal
    # after-create subscription can still see the free-tier UI; checkout is a
    # CSRF-protected POST and persists the record if they act on it.
    @subscription ||= current_user.build_subscription(tier: 'free', status: 'active')
    @usage_this_month = begin
      ChatbotAnalytic.where(user_id: current_user.id)
                     .where('created_at >= ?', Date.current.beginning_of_month).count
    rescue StandardError => e
      Rails.logger.warn("[Subscriptions] Usage query failed: #{e.message}")
      0
    end
  end

  def checkout
    tier = params[:tier]
    interval = 'monthly'

    unless %w[pro].include?(tier)
      redirect_to pricing_path, alert: t('subscriptions.invalid_tier')
      return
    end

    unless MollieConfiguration.checkout_enabled?
      redirect_to pricing_path, alert: t('subscriptions.payment_unavailable', default: case I18n.locale
                                                                                       when :fr then 'Les paiements ne sont pas encore configurés. Veuillez réessayer plus tard.'
                                                                                       when :de then 'Zahlungen sind noch nicht konfiguriert. Bitte versuchen Sie es später erneut.'
                                                                                       when :en then 'Payments are not yet configured. Please try again later.'
                                                                                       else 'Betalingen zijn nog niet geconfigureerd. Probeer het later opnieuw.'
                                                                                       end)
      return
    end

    # Don't let an already-active Pro subscriber start a second subscription
    # (a double-click / second tab would create a duplicate and orphan the old one).
    if current_user.subscription&.pro? &&
       current_user.subscription&.status == 'active' &&
       current_user.subscription&.active?
      redirect_to subscription_path, notice: t('subscriptions.already_active', default: case I18n.locale
                                                                                        when :fr then 'Vous avez déjà un abonnement Pro actif.'
                                                                                        when :de then 'Sie haben bereits ein aktives Pro-Abonnement.'
                                                                                        when :en then 'You already have an active Pro subscription.'
                                                                                        else 'U hebt al een actief Pro-abonnement.'
                                                                                        end)
      return
    end

    subscription = current_user.subscription ||
                   current_user.create_subscription!(tier: 'free', status: 'active')
    if live_legacy_stripe_contract?(subscription)
      Rails.logger.error(
        "[Subscriptions] Refused Mollie checkout while legacy recurring billing is still live " \
        "for subscription #{subscription.id}"
      )
      redirect_to pricing_path,
                  alert: t(
                    'subscriptions.legacy_billing_active',
                    default: 'Your existing billing contract must be stopped before a new checkout can start. Please contact support.'
                  )
      return
    end

    if subscription.payment_method == 'mollie' && subscription.mollie_subscription_id.present?
      MollieSubscriptionCancellationService.new(subscription).cancel!
    end

    result = MollieCheckoutService.new(
      user: current_user,
      locale: I18n.locale,
      redirect_url: subscription_success_url,
      cancel_url: pricing_url
    ).create_subscription_first_payment(subscription)

    redirect_to result.fetch(:checkout_url), allow_other_host: true, status: :see_other
  rescue MollieCheckoutService::CheckoutError,
         MollieSubscriptionCancellationService::CancellationError => e
    Rails.logger.error("[Subscriptions] Mollie checkout failed: #{e.class}")
    redirect_to pricing_path, alert: t('subscriptions.payment_error')
  end

  # Crypto checkout via CoinGate
  def crypto_checkout
    tier = params[:tier]

    unless %w[pro].include?(tier)
      redirect_to pricing_path, alert: t('subscriptions.invalid_tier')
      return
    end

    service = CoinGateService.new
    unless service.configured?
      redirect_to pricing_path, alert: t('subscriptions.crypto_unavailable',
                                         default: case I18n.locale
                                                  when :fr then 'Les paiements crypto ne sont pas encore configurés.'
                                                  when :de then 'Krypto-Zahlungen sind noch nicht konfiguriert.'
                                                  when :en then 'Crypto payments are not yet configured.'
                                                  else 'Crypto-betalingen zijn nog niet geconfigureerd.'
                                                  end)
      return
    end

    price_config = Subscription::TIER_CONFIG[tier]
    price_eur = price_config[:price_monthly] / 100.0 # Convert cents to EUR

    token = CryptoPayment.generate_token
    order_id = "sub_#{current_user.id}_#{Time.current.to_i}"

    result = service.create_order(
      price_amount: price_eur,
      title: "WetWijzer Pro - #{I18n.locale.upcase}",
      description: t('subscriptions.crypto_description',
                     default: 'WetWijzer Pro subscription (1 month)'),
      order_id: order_id,
      callback_url: webhooks_coingate_url,
      success_url: crypto_subscription_success_url,
      cancel_url: pricing_url,
      token: token
    )

    # Store payment record for webhook verification
    current_user.crypto_payments.create!(
      coingate_order_id: result[:id].to_s,
      merchant_order_id: order_id,
      payment_type: 'subscription',
      status: 'new',
      verification_token: token,
      amount_cents: price_config[:price_monthly],
      payment_url: result[:payment_url]
    )

    redirect_to result[:payment_url], allow_other_host: true
  rescue CoinGateService::Error => e
    Rails.logger.error("CoinGate error: #{e.message}")
    redirect_to pricing_path, alert: t('subscriptions.payment_error')
  end

  def crypto_success
    redirect_to subscription_path, notice: t('subscriptions.crypto_payment_processing',
                                             default: case I18n.locale
                                                      when :fr then 'Votre paiement crypto est en cours de traitement.'
                                                      when :de then 'Ihre Krypto-Zahlung wird verarbeitet.'
                                                      when :en then 'Your crypto payment is being processed.'
                                                      else 'Je crypto-betaling wordt verwerkt.'
                                                      end)
  end

  def success
    payment = current_user.mollie_payments.find_by(
      checkout_token: params[:payment_token],
      payment_type: 'subscription_initial'
    )
    process_returned_payment(payment)

    if payment&.reload&.fulfilled_at?
      redirect_to subscription_path, notice: t('subscriptions.payment_success')
    else
      redirect_to subscription_path, notice: t(
        'subscriptions.payment_processing',
        default: case I18n.locale
                 when :fr then 'Votre paiement est encore en cours de vérification.'
                 when :de then 'Ihre Zahlung wird noch geprüft.'
                 when :en then 'Your payment is still being verified.'
                 else 'Uw betaling wordt nog geverifieerd.'
                 end
      )
    end
  end

  def cancel
    # A failed renewal can outlive the paid entitlement window while Mollie
    # still has a retryable/suspended recurring contract. Always let the user
    # stop that remote contract, even if pro? has already expired locally.
    cancellable_remote_contract = @subscription&.payment_method == 'mollie' &&
                                  @subscription&.mollie_subscription_id.present?
    unless @subscription && (@subscription.pro? || cancellable_remote_contract)
      redirect_to subscription_path, alert: t('subscriptions.nothing_to_cancel')
      return
    end

    # Store optional cancellation reason
    reason = params[:cancellation_reason]&.strip.presence
    @subscription.update(cancellation_reason: reason) if reason

    MollieSubscriptionCancellationService.new(@subscription).cancel!
    UserMailer.subscription_cancelled(current_user, reason).deliver_later
    redirect_to subscription_path, notice: t('subscriptions.canceled')
  rescue MollieSubscriptionCancellationService::CancellationError => e
    Rails.logger.error("[Subscriptions] Cancellation failed: #{e.class}")
    redirect_to subscription_path, alert: t('subscriptions.cancel_failed')
  end

  def reactivate
    # Reactivation itself is already a CSRF-protected POST. Run the same Mollie
    # checkout action directly instead of redirecting the browser with GET to
    # the deliberately POST-only checkout route.
    params[:tier] = 'pro'
    checkout
  end

  private

  def set_subscription
    @subscription = current_user.subscription
  end

  def process_returned_payment(payment)
    return unless payment&.mollie_payment_id.present?

    snapshot = MollieApiClient.new.get_payment(payment.mollie_payment_id)
    MolliePaymentProcessor.new(snapshot).process!
  rescue MollieApiClient::Error, MolliePaymentProcessor::TransientError => e
    Rails.logger.warn("[Subscriptions] Return verification deferred: #{e.class}")
  rescue MolliePaymentProcessor::VerificationError => e
    Rails.logger.error("[Subscriptions] Return verification rejected: #{e.message}")
  end

  def live_legacy_stripe_contract?(subscription)
    subscription.stripe_subscription_id.present? &&
      !(subscription.status == 'canceled' && subscription.canceled_at.present?)
  end
end
