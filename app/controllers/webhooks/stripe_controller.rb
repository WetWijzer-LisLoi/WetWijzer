# frozen_string_literal: true

module Webhooks
  class StripeController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      payload = request.body.read
      sig_header = request.env['HTTP_STRIPE_SIGNATURE']
      endpoint_secret = ENV.fetch('STRIPE_WEBHOOK_SECRET', nil)

      begin
        event = Stripe::Webhook.construct_event(payload, sig_header, endpoint_secret)
      rescue JSON::ParserError
        render json: { error: 'Invalid payload' }, status: :bad_request
        return
      rescue Stripe::SignatureVerificationError
        render json: { error: 'Invalid signature' }, status: :bad_request
        return
      end

      handle_event(event)
      render json: { received: true }
    end

    private

    def handle_event(event)
      case event.type
      when 'checkout.session.completed'
        handle_checkout_completed(event.data.object)
      when 'customer.subscription.created'
        handle_subscription_created(event.data.object)
      when 'customer.subscription.updated'
        handle_subscription_updated(event.data.object)
      when 'customer.subscription.deleted'
        handle_subscription_deleted(event.data.object)
      when 'invoice.paid'
        handle_invoice_paid(event.data.object)
      when 'invoice.payment_failed'
        handle_payment_failed(event.data.object)
      else
        Rails.logger.info("Unhandled Stripe event: #{event.type}")
      end
    end

    def handle_checkout_completed(session)
      # Check if this is a credit purchase or subscription
      purchase_id = session.metadata['purchase_id']
      
      if purchase_id.present?
        handle_credit_purchase(session, purchase_id)
      else
        handle_subscription_checkout(session)
      end
    end

    def handle_credit_purchase(session, purchase_id)
      purchase = CreditPurchase.find_by(id: purchase_id)
      return unless purchase&.pending?

      purchase.update!(stripe_payment_intent_id: session.payment_intent)
      purchase.complete!
      
      Rails.logger.info("Credit purchase #{purchase_id} completed: #{purchase.credits_granted} credits for user #{purchase.user_id}")
    end

    def handle_subscription_checkout(session)
      user_id = session.metadata['user_id']
      tier = session.metadata['tier']
      user = User.find_by(id: user_id)
      
      return unless user

      user.subscription.update!(
        tier: tier,
        status: 'active',
        stripe_customer_id: session.customer,
        stripe_subscription_id: session.subscription,
        current_period_start: Time.current,
        current_period_end: 1.month.from_now
      )

      # Grant initial monthly credits for new subscription
      user.subscription.refill_credits!

      Rails.logger.info("User #{user_id} upgraded to #{tier}")
    end

    def handle_subscription_created(subscription)
      update_subscription_from_stripe(subscription)
    end

    def handle_subscription_updated(subscription)
      update_subscription_from_stripe(subscription)
    end

    def handle_subscription_deleted(subscription)
      sub = Subscription.find_by(stripe_subscription_id: subscription.id)
      sub&.update!(status: 'canceled', canceled_at: Time.current)
    end

    def handle_invoice_paid(invoice)
      sub = Subscription.find_by(stripe_customer_id: invoice.customer)
      return unless sub

      sub.update!(
        status: 'active',
        current_period_start: Time.at(invoice.period_start),
        current_period_end: Time.at(invoice.period_end)
      )

      # Send PEPPOL e-invoice for Belgian B2B compliance (mandatory since Jan 1, 2026)
      send_peppol_invoice(invoice, sub.user)
    end

    def send_peppol_invoice(stripe_invoice, user)
      return unless user && ENV['STORECOVE_API_KEY'].present?
      
      PeppolInvoiceService.new.send_invoice(stripe_invoice, user)
    rescue PeppolInvoiceService::PeppolError => e
      Rails.logger.error("PEPPOL invoice failed for user #{user.id}: #{e.message}")
      # Don't fail the webhook - PEPPOL is secondary to payment processing
    rescue StandardError => e
      Rails.logger.error("PEPPOL invoice error: #{e.message}")
    end

    def handle_payment_failed(invoice)
      sub = Subscription.find_by(stripe_customer_id: invoice.customer)
      sub&.update!(status: 'past_due')
    end

    def update_subscription_from_stripe(stripe_sub)
      sub = Subscription.find_by(stripe_subscription_id: stripe_sub.id)
      return unless sub

      sub.update!(
        status: map_stripe_status(stripe_sub.status),
        current_period_start: Time.at(stripe_sub.current_period_start),
        current_period_end: Time.at(stripe_sub.current_period_end)
      )
    end

    def map_stripe_status(stripe_status)
      case stripe_status
      when 'active' then 'active'
      when 'trialing' then 'trialing'
      when 'past_due' then 'past_due'
      when 'canceled', 'unpaid' then 'canceled'
      else 'incomplete'
      end
    end
  end
end
