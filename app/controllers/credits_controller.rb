# frozen_string_literal: true

class CreditsController < ApplicationController
  before_action :require_login
  before_action :set_packages

  def index
    @credit_purchases = current_user.credit_purchases.recent.limit(10)
    @current_credits = current_user.credits
    @subscription = current_user.subscription
  end

  def buy
    @current_credits = current_user.credits
  end

  def purchase
    package = params[:package]
    package_info = CreditPurchase.package_info(package)

    unless package_info
      flash[:error] = t('credits.invalid_package')
      return redirect_to credits_path
    end

    # Create pending purchase record
    purchase = current_user.credit_purchases.create!(
      package: package,
      amount_cents: package_info[:price_cents],
      credits_granted: package_info[:credits],
      status: 'pending'
    )

    # Create Stripe Checkout session
    session = create_stripe_session(purchase, package_info)

    if session
      purchase.update!(stripe_checkout_session_id: session.id)
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
    purchase = current_user.credit_purchases.find_by(stripe_checkout_session_id: session_id)

    if purchase&.pending?
      # Verify with Stripe that payment succeeded
      if verify_stripe_session(session_id)
        purchase.complete!
        flash[:success] = t('credits.purchase_success', credits: purchase.credits_granted)
      else
        flash[:error] = t('credits.verification_failed')
      end
    elsif purchase&.completed?
      flash[:notice] = t('credits.already_processed')
    else
      flash[:error] = t('credits.purchase_not_found')
    end

    redirect_to credits_path
  end

  def cancel
    flash[:notice] = t('credits.purchase_cancelled')
    redirect_to credits_path
  end

  private

  def require_login
    unless current_user
      flash[:error] = t('auth.login_required')
      redirect_to login_path
    end
  end

  def set_packages
    @packages = CreditPurchase::PACKAGES.map do |key, info|
      {
        id: key,
        name: t("credits.packages.#{key}.name"),
        description: t("credits.packages.#{key}.description"),
        price_cents: info[:price_cents],
        price_display: format_price(info[:price_cents]),
        credits: info[:credits],
        questions: info[:credits] / Subscription::CREDIT_COSTS[:legislation],
        per_question: format_price(info[:price_cents] / (info[:credits] / Subscription::CREDIT_COSTS[:legislation]))
      }
    end
  end

  def format_price(cents)
    "€#{cents / 100.0}"
  end

  def create_stripe_session(purchase, package_info)
    return nil unless stripe_configured?

    Stripe::Checkout::Session.create({
      payment_method_types: ['card', 'bancontact', 'ideal'],
      line_items: [{
        price_data: {
          currency: 'eur',
          product_data: {
            name: t("credits.packages.#{purchase.package}.name"),
            description: t("credits.packages.#{purchase.package}.description")
          },
          unit_amount: package_info[:price_cents]
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

  def verify_stripe_session(session_id)
    return false unless stripe_configured?

    session = Stripe::Checkout::Session.retrieve(session_id)
    session.payment_status == 'paid'
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe verification failed: #{e.message}")
    false
  end

  def stripe_configured?
    ENV['STRIPE_SECRET_KEY'].present?
  end
end
