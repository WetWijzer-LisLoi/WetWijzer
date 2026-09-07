# frozen_string_literal: true

require 'bigdecimal'

# Webhook handler for CoinGate cryptocurrency payments.
# Verifies and applies CoinGate payment callbacks:
#   1. Verify authenticity (token match + API double-check)
#   2. Route by order type (subscription vs credit purchase)
#   3. Update DB + grant access
#
# CoinGate sends POST callbacks with form-encoded params including:
#   id, order_id, status, price_amount, price_currency, token, etc.
#
# @see CoinGateService
module Webhooks
  class CoinGateController < ApplicationController
    VerificationError = Class.new(StandardError)
    TransientError = Class.new(StandardError)
    MUTABLE_PREPAID_STATUSES = %w[new pending confirming].freeze

    skip_before_action :verify_authenticity_token

    def create
      coingate_id = params[:id].to_s
      callback_status = params[:status].to_s
      token = params[:token]

      payment = CryptoPayment.find_by(coingate_order_id: coingate_id)
      unless payment
        Rails.logger.warn('[CoinGate] Callback received for an unknown order')
        head :ok # Return 200 to prevent retries
        return
      end

      unless CoinGateService.verify_token(token, payment.verification_token)
        Rails.logger.warn("[CoinGate] Token mismatch for payment #{payment.id}")
        head :ok
        return
      end

      # The callback body is only a wake-up signal. Fetch and apply the
      # authoritative order state; a provider/API failure must never grant
      # value based on caller-controlled form fields.
      verified_order = CoinGateService.new.get_order(coingate_id)
      verify_provider_contract!(payment, verified_order)
      verified_status = verified_order.fetch(:status).to_s
      unless CryptoPayment::STATUSES.include?(verified_status)
        raise VerificationError, 'CoinGate returned an unknown order status'
      end
      if callback_status.present? && callback_status != verified_status
        Rails.logger.info(
          "[CoinGate] Ignoring stale callback status for payment #{payment.id}"
        )
      end

      @post_commit_hooks = []
      handle_status_update(payment, verified_status)
      run_post_commit_hooks

      head :ok
    rescue CoinGateService::Error => e
      Rails.logger.error("[CoinGate] Authoritative API verification failed: #{e.class}")
      head :service_unavailable
    rescue VerificationError => e
      # Contract mismatches are immutable and retries cannot make them safe.
      Rails.logger.error("[CoinGate] Rejected provider order: #{e.message}")
      head :ok
    rescue TransientError => e
      Rails.logger.error("[CoinGate] Local payment processing deferred: #{e.class}")
      head :service_unavailable
    end

    private

    def verify_provider_contract!(payment, order)
      raise VerificationError, 'CoinGate order response is invalid' unless order.is_a?(Hash)
      unless order[:id].to_s == payment.coingate_order_id
        raise VerificationError, 'CoinGate order id mismatch'
      end
      unless order[:order_id].to_s == expected_merchant_order_id(payment, order[:order_id])
        raise VerificationError, 'CoinGate merchant order id mismatch'
      end
      unless order[:price_currency].to_s.upcase == 'EUR'
        raise VerificationError, 'CoinGate price currency mismatch'
      end
      if order[:receive_currency].present? &&
         order[:receive_currency].to_s.upcase != 'EUR'
        raise VerificationError, 'CoinGate settlement currency mismatch'
      end

      cents = exact_euro_cents(order[:price_amount])
      raise VerificationError, 'CoinGate order amount mismatch' unless cents == payment.amount_cents
    end

    def expected_merchant_order_id(payment, provider_order_id)
      return payment.merchant_order_id if payment.respond_to?(:merchant_order_id) &&
                                          payment.merchant_order_id.present?

      provider_order_id = provider_order_id.to_s
      case payment.payment_type
      when 'subscription'
        user_id = retained_crypto_contract_id(payment, :user)
        /\Asub_#{Regexp.escape(user_id.to_s)}_\d+\z/.match?(provider_order_id) &&
          provider_order_id
      when 'credit_purchase'
        purchase_id = retained_crypto_contract_id(payment, :credit_purchase)
        /\Acredit_#{Regexp.escape(purchase_id.to_s)}_\d+\z/.match?(provider_order_id) &&
          provider_order_id
      end || raise(VerificationError, 'CoinGate merchant order reference is missing')
    end

    def retained_crypto_contract_id(payment, kind)
      contract_column = :"contract_#{kind}_id"
      value = payment.public_send(contract_column) if payment.respond_to?(contract_column)
      value ||= payment.public_send(:"#{kind}_id")
      value || raise(VerificationError, "CoinGate #{kind} contract reference is missing")
    end

    def exact_euro_cents(value)
      decimal = BigDecimal(value.to_s, exception: false)
      cents = decimal && decimal * 100
      return unless cents && cents.frac.zero?

      cents.to_i
    end

    # Defer slow/non-critical side effects (emails, PDF invoice generation)
    # until after the grant transaction commits: they must not hold the
    # accounts write lock, and their failure must not roll back a grant.
    def post_commit(&block)
      @post_commit_hooks << block
    end

    def run_post_commit_hooks
      @post_commit_hooks.each do |hook|
        hook.call
      rescue StandardError => e
        Rails.logger.error("[CoinGate] Post-commit hook failed: #{e.class}")
      end
    end

    def handle_status_update(payment, status)
      case status
      when 'paid'
        handle_paid(payment)
      when 'refunded'
        handle_refunded(payment)
      when 'partially_refunded'
        handle_partial_refund(payment)
      when 'expired', 'canceled', 'invalid', 'pending', 'confirming'
        # Guarded update: never downgrade a paid payment. A late or replayed
        # pre-paid callback would otherwise reopen it, letting a replayed
        # 'paid' callback grant a second time.
        updated = CryptoPayment.where(id: payment.id, status: MUTABLE_PREPAID_STATUSES)
                               .update_all(status: status, updated_at: Time.current)
        Rails.logger.info("[CoinGate] Payment #{payment.id} marked as #{status}") if updated == 1
      else
        Rails.logger.info("[CoinGate] Unhandled status '#{status}' for payment #{payment.id}")
      end
    end

    def handle_paid(payment)
      AccountRecord.transaction do
        # Atomic idempotency claim: SQLite serializes writes, so under
        # concurrent duplicate callbacks exactly one guarded UPDATE flips the
        # status and performs the grant (a read-then-act check would let both
        # through). A grant failure rolls the claim back so a retry can re-run.
        claimed = CryptoPayment.where(id: payment.id, status: MUTABLE_PREPAID_STATUSES)
                               .update_all(status: 'paid', paid_at: Time.current,
                                           updated_at: Time.current) == 1
        unless claimed
          Rails.logger.info("[CoinGate] Payment #{payment.id} already paid, skipping duplicate callback")
          next
        end

        case payment.payment_type
        when 'subscription'
          activate_subscription(payment)
        when 'credit_purchase'
          complete_credit_purchase(payment)
        else
          raise VerificationError, 'unknown CoinGate payment type'
        end

        payment.update!(invoice_state: 'pending', invoice_error: nil)
        post_commit { CoinGateInvoiceJob.perform_later(payment) }
      end
    end

    # CoinGate refunded a paid order: claw back what it granted. Same atomic
    # guarded-claim pattern as handle_paid (only a 'paid' payment can move to
    # 'refunded', exactly once).
    def handle_refunded(payment)
      AccountRecord.transaction do
        claimed = CryptoPayment.where(id: payment.id, status: %w[paid partially_refunded])
                               .update_all(
                                 status: 'refunded',
                                 refunded_at: Time.current,
                                 refund_invoice_state: 'pending',
                                 refund_invoice_error: nil,
                                 updated_at: Time.current
                               ) == 1
        unless claimed
          Rails.logger.info("[CoinGate] Payment #{payment.id} not in 'paid' state, skipping refund callback")
          next
        end

        case payment.payment_type
        when 'credit_purchase'
          purchase = payment.credit_purchase
          if purchase&.completed?
            purchase.refund!
            Rails.logger.info("[CoinGate Refund] Clawed back #{purchase.credits_granted} credits for purchase #{purchase.id}")
          end
        when 'subscription'
          # Refunding a running subscription month needs a human decision
          # (pro-rating, abuse). Flag it loudly instead of auto-downgrading.
          Rails.logger.warn("[CoinGate Refund] Subscription payment #{payment.id} (user #{payment.user_id}) was refunded — review the subscription manually")
        end

        post_commit { CoinGateRefundInvoiceJob.perform_later(payment) }
      end
    end

    def handle_partial_refund(payment)
      changed = CryptoPayment.where(id: payment.id, status: 'paid')
                             .update_all(
                               status: 'partially_refunded',
                               updated_at: Time.current
                             )
      return unless changed == 1

      # CoinGate's order status does not expose an immutable cumulative refund
      # amount in the contract currently stored by WetWijzer. Do not guess at
      # proportional entitlements; keep the durable state visible for admin
      # review and allow a later full refund to complete automatically.
      Rails.logger.error(
        "[CoinGate Refund] Payment #{payment.id} was partially refunded and requires accounting review"
      )
    end

    def activate_subscription(payment)
      user = payment.user
      unless user && payment.contract_user_id == user.id
        raise TransientError, 'CoinGate subscription owner is unavailable'
      end

      subscription = user.subscription || user.create_subscription!(tier: 'free', status: 'active')

      # Crypto has no auto-renew: users pre-pay another month whenever they
      # like. Extend from the current paid-through date, not from "now", so a
      # renewal 10 days before expiry doesn't silently discard those 10 days.
      paid_through = [subscription.current_period_end, Time.current].compact.max

      subscription.update!(
        tier: 'pro',
        status: 'active',
        payment_method: 'crypto',
        current_period_start: paid_through,
        current_period_end: paid_through + 1.month
      )
      payment.update!(
        service_period_start: paid_through,
        service_period_end: paid_through + 1.month
      )

      # Grant monthly Pro credits
      subscription.refill_credits!
      post_commit { UserMailer.subscription_welcome(user).deliver_later }

      Rails.logger.info("[CoinGate] User #{user.id} upgraded to Pro via crypto (payment #{payment.id})")
    end

    def complete_credit_purchase(payment)
      purchase = payment.credit_purchase
      unless purchase&.pending? &&
             payment.contract_credit_purchase_id == purchase.id &&
             payment.contract_user_id == purchase.user_id
        raise TransientError, 'CoinGate credit purchase contract is unavailable'
      end

      purchase.complete!

      Rails.logger.info("[CoinGate] Credit purchase #{purchase.id} completed via crypto: #{purchase.credits_granted} credits for user #{purchase.user_id}")
    end
  end
end
