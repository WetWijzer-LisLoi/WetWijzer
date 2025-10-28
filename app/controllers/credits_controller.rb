# frozen_string_literal: true

class CreditsController < ApplicationController
  before_action :require_login
  before_action :set_packages

  def index
    @credit_purchases = current_user.credit_purchases.recent.limit(10)
    @current_credits = current_user.credits
    @total_credits = current_user.total_available_credits
    @subscription = current_user.subscription
    @is_pro = current_user.pro?
  end

  def purchase
    package = params[:package]
    package_info = CreditPurchase.package_info(package)

    unless package_info
      flash[:error] = t('credits.invalid_package')
      return redirect_to credits_path
    end

    # Pre-check: Stripe must be configured before creating purchase records
    unless stripe_configured?
      flash[:error] = t('credits.payment_unavailable', default: if I18n.locale == :fr
                                                                  'Les paiements ne sont pas encore configurés. Veuillez réessayer plus tard.'
                                                                else
                                                                  'Betalingen zijn nog niet geconfigureerd. Probeer het later opnieuw.'
                                                                end)
      return redirect_to credits_path
    end

    # Pro subscribers get discounted pack prices
    actual_price = if current_user.pro? && package_info[:pro_price_cents]
                     package_info[:pro_price_cents]
                   else
                     package_info[:price_cents]
                   end

    # Create pending purchase record
    purchase = current_user.credit_purchases.create!(
      package: package,
      amount_cents: actual_price,
      credits_granted: package_info[:credits],
      status: 'pending'
    )

    # Create Stripe Checkout session
    session = create_stripe_session(purchase, package_info)

    if session
      purchase.update!(stripe_session_id: session.id)
      redirect_to session.url, allow_other_host: true
    else
      purchase.fail!
      flash[:error] = t('credits.payment_error')
      redirect_to credits_path
    end
  rescue StandardError => e
    Rails.logger.error("Credit purchase error: #{e.message}")
    flash[:error] = t('credits.payment_error')
    redirect_to credits_path
  end

  def success
    session_id = params[:session_id]
    purchase = current_user.credit_purchases.find_by(stripe_session_id: session_id)

    if purchase&.completed?
      # Credits already granted by Stripe webhook - just show confirmation
      flash[:success] = t('credits.purchase_success', credits: purchase.credits_granted)
    elsif purchase&.pending?
      # Webhook hasn't fired yet - tell user to wait
      flash[:notice] = t('credits.processing', default: 'Your payment is being processed. Credits will be added shortly.')
    else
      flash[:error] = t('credits.purchase_not_found')
    end

    redirect_to credits_path
  end

  def cancel
    flash[:notice] = t('credits.purchase_cancelled')
    redirect_to credits_path
  end

  # Crypto credit purchase via CoinGate
  def crypto_purchase
    package = params[:package]
    package_info = CreditPurchase.package_info(package)

    unless package_info
      flash[:error] = t('credits.invalid_package')
      return redirect_to credits_path
    end

    service = CoinGateService.new
    unless service.configured?
      flash[:error] = t('credits.crypto_unavailable',
                        default: case I18n.locale
                                 when :fr then 'Les paiements crypto ne sont pas encore configurés.'
                                 when :de then 'Krypto-Zahlungen sind noch nicht konfiguriert.'
                                 when :en then 'Crypto payments are not yet configured.'
                                 else 'Crypto-betalingen zijn nog niet geconfigureerd.'
                                 end)
      return redirect_to credits_path
    end

    # Pro subscribers get discounted pack prices (same as Stripe flow)
    actual_price = if current_user.pro? && package_info[:pro_price_cents]
                     package_info[:pro_price_cents]
                   else
                     package_info[:price_cents]
                   end
    price_eur = actual_price / 100.0

    # Create pending purchase record (same as Stripe flow)
    purchase = current_user.credit_purchases.create!(
      package: package,
      amount_cents: actual_price,
      credits_granted: package_info[:credits],
      status: 'pending'
    )

    token = CryptoPayment.generate_token
    order_id = "credit_#{purchase.id}_#{Time.current.to_i}"

    result = service.create_order(
      price_amount: price_eur,
      title: t("credits.packages.#{package}.name", default: "WetWijzer Credits - #{package}"),
      description: "#{package_info[:credits]} credits",
      order_id: order_id,
      callback_url: webhooks_coingate_url,
      success_url: credits_crypto_success_url,
      cancel_url: credits_cancel_url,
      token: token
    )

    # Link crypto payment to purchase
    current_user.crypto_payments.create!(
      coingate_order_id: result[:id].to_s,
      payment_type: 'credit_purchase',
      credit_purchase: purchase,
      status: 'new',
      verification_token: token,
      amount_cents: actual_price,
      payment_url: result[:payment_url]
    )

    redirect_to result[:payment_url], allow_other_host: true
  rescue CoinGateService::Error => e
    Rails.logger.error("CoinGate credit purchase error: #{e.message}")
    flash[:error] = t('credits.payment_error')
    redirect_to credits_path
  end

  def crypto_success
    flash[:notice] = t('credits.crypto_processing',
                       default: case I18n.locale
                                when :fr then 'Votre paiement crypto est en cours de traitement. Les crédits seront ajoutés sous peu.'
                                when :de then 'Ihre Krypto-Zahlung wird verarbeitet. Die Credits werden in Kürze hinzugefügt.'
                                when :en then 'Your crypto payment is being processed. Credits will be added shortly.'
                                else 'Je crypto-betaling wordt verwerkt. Credits worden binnenkort toegevoegd.'
                                end)
    redirect_to credits_path
  end

  private

  def require_login
    return if current_user

    flash[:error] = t('auth.login_required')
    redirect_to login_path
  end

  def set_packages
    is_pro = current_user&.pro?
    @packages = CreditPurchase::PACKAGES.map do |key, info|
      questions = info[:credits] / Subscription::CREDIT_COSTS[:legislation]
      effective_price = is_pro && info[:pro_price_cents] ? info[:pro_price_cents] : info[:price_cents]
      {
        id: key,
        name: t("credits.packages.#{key}.name"),
        description: t("credits.packages.#{key}.description"),
        price_cents: info[:price_cents],
        price_display: format_price(info[:price_cents]),
        pro_price_cents: info[:pro_price_cents],
        pro_price_display: info[:pro_price_cents] ? format_price(info[:pro_price_cents]) : nil,
        effective_price_display: format_price(effective_price),
        has_pro_discount: is_pro && info[:pro_price_cents].present?,
        credits: info[:credits],
        questions: questions,
        per_question: format_price(effective_price / questions)
      }
    end
  end

  def format_price(cents)
    euros = cents / 100
    remainder = cents % 100
    "€#{euros},#{remainder.to_s.rjust(2, '0')}"
  end

  def create_stripe_session(purchase, package_info)
    return nil unless stripe_configured?

    Stripe::Checkout::Session.create({
                                       line_items: [{
                                         price_data: {
                                           currency: 'eur',
                                           product_data: {
                                             name: t("credits.packages.#{purchase.package}.name"),
                                             description: t("credits.packages.#{purchase.package}.description")
                                           },
                                           unit_amount: purchase.amount_cents
                                         },
                                         quantity: 1
                                       }],
                                       mode: 'payment',
                                       success_url: credits_success_url(session_id: '{CHECKOUT_SESSION_ID}'),
                                       cancel_url: credits_cancel_url,
                                       customer_email: current_user.email,
                                       metadata: {
                                         user_id: current_user.id,
                                         purchase_id: purchase.id,
                                         credits: package_info[:credits]
                                       }
                                     })
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe session creation failed: #{e.message}")
    nil
  end

  def stripe_configured?
    ENV['STRIPE_SECRET_KEY'].present?
  end
end
