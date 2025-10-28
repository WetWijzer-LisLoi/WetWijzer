# frozen_string_literal: true

Stripe.api_key = ENV.fetch('STRIPE_SECRET_KEY', nil)

# Stripe configuration for WetWijzer subscriptions
Rails.application.config.stripe = {
  publishable_key: ENV.fetch('STRIPE_PUBLISHABLE_KEY', nil),
  webhook_secret: ENV.fetch('STRIPE_WEBHOOK_SECRET', nil),
  prices: {
    professional: ENV.fetch('STRIPE_PROFESSIONAL_PRICE_ID', nil),
    enterprise: ENV.fetch('STRIPE_ENTERPRISE_PRICE_ID', nil)
  }
}
