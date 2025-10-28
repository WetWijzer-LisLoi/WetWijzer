# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  before_action :require_authentication, except: [:pricing]
  before_action :set_subscription, only: %i[show cancel reactivate]

  def pricing
    @tiers = Subscription::TIER_CONFIG
  end

  def show
    # Auto-create free subscription for legacy users who don't have one
    @subscription ||= current_user.create_subscription!(tier: 'free', status: 'active') unless @subscription
    @usage_this_month = begin
      ChatbotAnalytic.where(user_id: current_user.id)
                     .where('created_at >= ?', Date.current.beginning_of_month).count
    rescue StandardError
      0
    end
  end

  def checkout
    tier = params[:tier]
    interval = params[:interval] || 'monthly'

    unless %w[pro].include?(tier)
      redirect_to pricing_path, alert: t('subscriptions.invalid_tier')
      return
    end

    # Pre-check: Stripe must be configured
    unless ENV['STRIPE_SECRET_KEY'].present?
      redirect_to pricing_path, alert: t('subscriptions.payment_unavailable', default: case I18n.locale
                                                                                       when :fr then 'Les paiements ne sont pas encore configurés. Veuillez réessayer plus tard.'
                                                                                       when :de then 'Zahlungen sind noch nicht konfiguriert. Bitte versuchen Sie es später erneut.'
                                                                                       when :en then 'Payments are not yet configured. Please try again later.'
                                                                                       else 'Betalingen zijn nog niet geconfigureerd. Probeer het later opnieuw.'
                                                                                       end)
      return
    end

    # Create Stripe checkout session
    session = create_stripe_checkout(tier, interval)
    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe error: #{e.message}")
    redirect_to pricing_path, alert: t('subscriptions.payment_error')
  end

  # Crypto checkout via CoinGate — same flow as Stripe but for crypto payments
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
      title: "WetWijzer Pro — #{I18n.locale.upcase}",
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
    # Stripe webhook will update the subscription
    redirect_to subscription_path, notice: t('subscriptions.payment_success')
  end

  def cancel
    unless @subscription&.pro?
      redirect_to subscription_path, alert: t('subscriptions.nothing_to_cancel')
      return
    end

    # Store optional cancellation reason
    reason = params[:cancellation_reason]&.strip.presence
    @subscription.update(cancellation_reason: reason) if reason

    if @subscription.cancel!
      # Cancel in Stripe too
      Stripe::Subscription.cancel(@subscription.stripe_subscription_id) if @subscription.stripe_subscription_id.present?

      # Send cancellation email
      UserMailer.subscription_cancelled(current_user, reason).deliver_later

      redirect_to subscription_path, notice: t('subscriptions.canceled')
    else
      redirect_to subscription_path, alert: t('subscriptions.cancel_failed')
    end
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe cancel error: #{e.message}")
    redirect_to subscription_path, alert: t('subscriptions.cancel_failed')
  end

  def reactivate
    redirect_to checkout_path(tier: 'pro')
  end

  private

  def set_subscription
    @subscription = current_user.subscription
  end

  def create_stripe_checkout(tier, interval)
    price_id = stripe_price_id(tier, interval)

    checkout_params = {
      customer_email: current_user.email,
      line_items: [{
        price: price_id,
        quantity: 1
      }],
      mode: 'subscription',
      success_url: subscription_success_url,
      cancel_url: pricing_url,
      metadata: {
        user_id: current_user.id,
        tier: tier,
        interval: interval
      },
      allow_promotion_codes: true,
      billing_address_collection: 'required',
      tax_id_collection: { enabled: true }
    }

    Stripe::Checkout::Session.create(checkout_params)
  end

  def stripe_price_id(tier, interval)
    # Price IDs from Stripe Products dashboard (monthly only)
    case [tier, interval]
    when %w[pro monthly]
      ENV.fetch('STRIPE_PROFESSIONAL_PRICE_ID') { raise 'Missing STRIPE_PROFESSIONAL_PRICE_ID' }
    else
      raise "Unknown tier/interval: #{tier}/#{interval}"
    end
  end
end
