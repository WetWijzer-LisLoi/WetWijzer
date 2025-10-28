# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  before_action :require_authentication, except: [:pricing]
  before_action :set_subscription, only: [:show, :cancel, :reactivate]

  def pricing
    @tiers = Subscription::TIER_CONFIG
  end

  def show
    @usage_this_month = current_user.chatbot_usages.this_month.sum(:query_count)
  end

  def checkout
    tier = params[:tier]
    interval = params[:interval] || 'monthly'
    
    unless %w[professional].include?(tier)
      redirect_to pricing_path, alert: t('subscriptions.invalid_tier')
      return
    end

    # Create Stripe checkout session
    session = create_stripe_checkout(tier, interval)
    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe error: #{e.message}")
    redirect_to pricing_path, alert: t('subscriptions.payment_error')
  end

  def success
    # Stripe webhook will update the subscription
    redirect_to subscription_path, notice: t('subscriptions.payment_success')
  end

  def cancel
    unless @subscription&.professional?
      redirect_to subscription_path, alert: t('subscriptions.nothing_to_cancel')
      return
    end
    
    if @subscription.cancel!
      # Cancel in Stripe too
      if @subscription.stripe_subscription_id.present?
        Stripe::Subscription.cancel(@subscription.stripe_subscription_id)
      end
      redirect_to subscription_path, notice: t('subscriptions.canceled')
    else
      redirect_to subscription_path, alert: t('subscriptions.cancel_failed')
    end
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe cancel error: #{e.message}")
    redirect_to subscription_path, alert: t('subscriptions.cancel_failed')
  end

  def reactivate
    redirect_to checkout_path(tier: 'professional')
  end

  private

  def set_subscription
    @subscription = current_user.subscription
  end

  def create_stripe_checkout(tier, interval)
    price_id = stripe_price_id(tier, interval)
    trial_days = Subscription::TIER_CONFIG.dig(tier, :trial_days) || 0
    
    checkout_params = {
      customer_email: current_user.email,
      payment_method_types: ['card', 'bancontact', 'ideal'],
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
    
    # Add 14-day free trial for new subscriptions
    if trial_days > 0 && !current_user.subscription&.professional?
      checkout_params[:subscription_data] = { trial_period_days: trial_days }
    end
    
    Stripe::Checkout::Session.create(checkout_params)
  end

  def stripe_price_id(tier, interval)
    # Price IDs from Stripe Products dashboard
    case [tier, interval]
    when ['professional', 'monthly']
      ENV.fetch('STRIPE_PRICE_PROFESSIONAL_MONTHLY') { raise "Missing STRIPE_PRICE_PROFESSIONAL_MONTHLY" }
    when ['professional', 'yearly']
      ENV.fetch('STRIPE_PRICE_PROFESSIONAL_YEARLY') { raise "Missing STRIPE_PRICE_PROFESSIONAL_YEARLY" }
    else
      raise "Unknown tier/interval: #{tier}/#{interval}"
    end
  end
end
