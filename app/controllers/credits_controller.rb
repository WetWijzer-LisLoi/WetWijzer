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

    unless MollieConfiguration.checkout_enabled?
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
      status: 'pending',
      payment_method: 'mollie',
      currency: 'EUR'
    )

    result = MollieCheckoutService.new(
      user: current_user,
      locale: I18n.locale,
      redirect_url: credits_success_url,
      cancel_url: credits_cancel_url
    ).create_credit_purchase(purchase)
    purchase.update!(mollie_payment_id: result.fetch(:payment).mollie_payment_id)

    redirect_to result.fetch(:checkout_url), allow_other_host: true, status: :see_other
  rescue MollieCheckoutService::CheckoutError, ActiveRecord::ActiveRecordError => e
    purchase&.fail! if purchase&.pending?
    Rails.logger.error("[Credits] Mollie checkout failed: #{e.class}")
    flash[:error] = t('credits.payment_error')
    redirect_to credits_path
  end

  def success
    payment = current_user.mollie_payments.find_by(
      checkout_token: params[:payment_token],
      payment_type: 'credit_purchase'
    )
    process_returned_payment(payment)
    purchase = payment&.credit_purchase&.reload

    if purchase&.completed?
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

    # Pro subscribers get discounted pack prices
    actual_price = if current_user.pro? && package_info[:pro_price_cents]
                     package_info[:pro_price_cents]
                   else
                     package_info[:price_cents]
                   end
    price_eur = actual_price / 100.0

    # Create pending purchase record
    purchase = current_user.credit_purchases.create!(
      package: package,
      amount_cents: actual_price,
      credits_granted: package_info[:credits],
      status: 'pending',
      payment_method: 'crypto',
      currency: 'EUR'
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
      merchant_order_id: order_id,
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

  def process_returned_payment(payment)
    return unless payment&.mollie_payment_id.present?

    snapshot = MollieApiClient.new.get_payment(payment.mollie_payment_id)
    MolliePaymentProcessor.new(snapshot).process!
  rescue MollieApiClient::Error, MolliePaymentProcessor::TransientError => e
    Rails.logger.warn("[Credits] Return verification deferred: #{e.class}")
  rescue MolliePaymentProcessor::VerificationError => e
    Rails.logger.error("[Credits] Return verification rejected: #{e.message}")
  end
end
