# frozen_string_literal: true

module Api
  # Browser-chat billing lifecycle: stale-row reconciliation, up-front credit
  # reservation, delivery tokens, settlement, retained-charge resolution and
  # the idempotent refund path. Extracted verbatim from Api::ChatbotController
  # (FBL-060 step 2) as a concern so every method keeps its name and receiver:
  # the white-box billing matrix stubs these names on the controller instance
  # and stays authoritative. Collaborators still provided by the controller:
  # request (billing correlation id) and credit_balance_info.
  module BrowserChatBilling
    extend ActiveSupport::Concern

    BROWSER_BILLING_APP_PREFIX = 'browser_chatbot:'
    BROWSER_BILLING_REQUEST_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

    private

    # Keep revenue/credit dashboards consistent with the user's restored
    # balance when an answer fails after analytics were already created.
    def mark_analytic_refunded!(analytic)
      analytic&.update_columns(credits_deducted: 0)
    rescue StandardError => e
      Rails.logger.error("Failed to mark chatbot analytic as refunded: #{e.class}")
    end

    # The accounts ledger is already settled at the delivery boundary.
    # Analytics is only an idempotent projection; an outage leaves the durable
    # marker pending for the recurring/next-admission reconciler.
    def project_browser_chat_analytic!(reservation, analytic)
      return true unless reservation

      return true if reservation.project_analytics!(analytic: analytic)

      raise BillingReservation::ReconciliationIncomplete,
            'settled browser reservation analytics marker was not persisted'
    rescue StandardError => e
      Rails.logger.error("Browser chatbot billing projection deferred: #{e.class}")
      begin
        BillingAnalyticsReconciliationJob.perform_later(reservation.id)
      rescue StandardError => enqueue_error
        Rails.logger.error("Browser chatbot billing projection enqueue failed: #{enqueue_error.class}")
      end
      false
    end

    # `BillingReservation` predates the browser billing flow, but it is
    # the shared accounts-backed delivery ledger. The reservation row and the
    # guarded balance deduction commit together before any provider work.
    def reserve_browser_chat_credits!(user, amount:, intelligence:, model:)
      BillingReservation.reserve_credits!(
        user: user,
        amount: amount,
        app: browser_chat_billing_app,
        intelligence_level: intelligence,
        model: model
      )
    end

    def browser_chat_billing_app
      request_id = request.request_id.to_s
      raise ArgumentError, 'invalid request id for browser billing correlation' unless request_id.match?(BROWSER_BILLING_REQUEST_ID_PATTERN)

      "#{BROWSER_BILLING_APP_PREFIX}#{request_id}"
    end

    # Refund is intentionally safe to call from a local error branch and again
    # from an outer rescue. The model owns the atomic state transition and
    # inverse balance mutation, while this helper keeps analytics non-billable.
    def refund_browser_chat_reservation!(reservation, analytic:, reason:)
      return false unless reservation&.credit?

      refunded = reservation.refund!(reason: reason)
      mark_analytic_refunded!(analytic) if reservation.refunded?
      refunded
    end

    # Owner default 2026-09-27 (to-do 6.7): an answer that tells the user its
    # search was incomplete costs no credit. The orchestrator marks such a
    # result with :retrieval_degraded (apply_retrieval_notice!), whatever the
    # reason: a source that ran into the shared deadline, a semantic leg that
    # gave up, a raising search or a full worker pool all deliver an answer
    # with the notice, and the user cannot tell them apart. A hard failure
    # (result[:error]: a timeout of the whole ask, a blocked response, a
    # provider exception) is a different thing and keeps its own refund path.
    CHARGE_WAIVED_INCOMPLETE_SEARCH = 'retrieval_incomplete'

    def incomplete_search_answer?(result)
      result.is_a?(Hash) && result[:error].blank? && result[:retrieval_degraded].present?
    end

    # Ask path: releases the durable reservation while it is still `reserved`
    # and no delivery has begun (refund! would SETTLE a pending delivery, see
    # BillingReservation#refund!), then marks the result. Returns true when the
    # charge fell away, false when there was nothing to waive or the release
    # did not happen, in which case the charge stands as before. Idempotent
    # through refund!, so a retry cannot credit the user twice.
    def waive_browser_chat_charge_for_incomplete_search!(reservation, result, user:, language:)
      return false unless reservation&.credit? && incomplete_search_answer?(result)

      reservation.refund!(reason: CHARGE_WAIVED_INCOMPLETE_SEARCH)
      unless reservation.refunded?
        Rails.logger.warn('Browser chatbot charge for an incomplete search could not be released; the charge stands')
        return false
      end

      mark_charge_waived_for_incomplete_search!(result, user: user, language: language)
      true
    end

    # What both paths (ask and deep analysis) tell the client once the credit
    # is back: the marker the analytics row records (log_analytic reads it off
    # the result), the note inside the notice paragraph, and a credits_info
    # that deducts nothing and says why.
    def mark_charge_waived_for_incomplete_search!(result, user:, language:)
      result[:charge_waived] = CHARGE_WAIVED_INCOMPLETE_SEARCH
      result[:answer] = LegalChatbot::Orchestrator.with_free_answer_note(result[:answer], language)
      result[:credits_info] = credit_balance_info(user, deducted: 0, charge_waived: CHARGE_WAIVED_INCOMPLETE_SEARCH)
      result
    end

    # Durable standard history is itself delivery because another request can
    # retrieve it immediately. Once committed, retain both history and charge
    # even if the later transport fails. Only ZK/no-history work, or a typed
    # pre-commit absence, may owner-abort; commit-unknown outcomes are retained.
    def resolve_failed_browser_chat_delivery!(
      reservation,
      analytic:,
      conversation:,
      delivery_receipt:,
      persistence_outcome:,
      delivery_accepted:,
      delivery_token:,
      delivery_abort_allowed:,
      user:,
      reason:
    )
      if reservation.settled?
        return {
          outcome: :settled,
          credits_info: credit_balance_info(user, deducted: reservation.amount)
        }
      end

      if delivery_accepted
        return retain_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          delivery_token: delivery_token,
          user: user,
          warning: 'accepted response delivery'
        )
      end

      # A streaming write may have delivered bytes before raising. Preserve the
      # stored answer and charge before attempting any compensating history
      # rollback; removing history here could charge for an unusable result.
      if delivery_token.present? && !delivery_abort_allowed
        return retain_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          delivery_token: delivery_token,
          user: user,
          warning: 'delivery outcome ambiguous'
        )
      end

      rollback_outcome = if delivery_receipt && conversation
                           conversation.rollback_exchange_under_receipt!(delivery_receipt)
                         elsif persistence_outcome == :absent
                           :absent
                         else
                           :not_applicable
                         end

      if delivery_receipt && !%i[rolled_back absent].include?(rollback_outcome)
        return retain_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          delivery_token: delivery_token,
          user: user,
          warning: "retained history=#{rollback_outcome}"
        )
      end

      if delivery_token.present?
        standard_history_unproven = conversation &&
                                    !conversation.zero_knowledge? &&
                                    delivery_receipt.nil? &&
                                    persistence_outcome != :absent
        if standard_history_unproven
          return retain_browser_chat_delivery!(
            reservation,
            analytic: analytic,
            delivery_token: delivery_token,
            user: user,
            warning: 'history outcome unknown'
          )
        end

        refunded = reservation.abort_delivery!(token: delivery_token, reason: reason)
        mark_analytic_refunded!(analytic) if reservation.refunded?
        return {
          outcome: refunded ? :refunded : :settled,
          credits_info: credit_balance_info(user, deducted: refunded ? 0 : reservation.amount)
        }
      end

      refund_browser_chat_reservation!(reservation, analytic: analytic, reason: reason)
      if reservation.settled?
        {
          outcome: :settled,
          credits_info: credit_balance_info(user, deducted: reservation.amount)
        }
      else
        {
          outcome: :refunded,
          credits_info: credit_balance_info(user, deducted: 0)
        }
      end
    end

    def begin_browser_chat_delivery!(reservation)
      return nil unless reservation

      token = reservation.begin_delivery!
      return token if token.present?

      raise BillingReservation::RefundFailed,
            'browser chatbot delivery intent could not persist'
    end

    def settle_browser_chat_reservation!(reservation, delivery_token: nil)
      return true unless reservation

      token = delivery_token.presence || begin_browser_chat_delivery!(reservation)
      return true if reservation.complete_delivery!(token: token)

      raise BillingReservation::RefundFailed, 'browser chatbot reservation could not settle'
    end

    def retain_browser_chat_delivery!(reservation, analytic:, delivery_token:, user:, warning:)
      begin
        settled = settle_browser_chat_reservation!(reservation, delivery_token: delivery_token)
        project_browser_chat_analytic!(reservation, analytic) if settled
      rescue StandardError => e
        # begin_delivery! already committed the owner-scoped pending state. The
        # global stale reconciler completes it after transient accounts errors.
        Rails.logger.error("Browser chatbot accepted settlement deferred: #{e.class}")
      end
      Rails.logger.warn("Browser chatbot charge retained after #{warning}")

      {
        outcome: :settled,
        credits_info: credit_balance_info(user, deducted: reservation.amount)
      }
    end

    # A killed worker can leave a durable row in `reserved`. Reconcile only the
    # authenticated account, in a bounded batch, before admitting more provider
    # work. Any accounts-database failure is fail-closed.
    def reconcile_browser_chat_billing!(user)
      BillingReservation.reconcile_stale_for_user!(user)
      BillingReservation.reconcile_settled_browser_analytics_for_user!(user)
      user.reload
      true
    rescue StandardError => e
      Rails.logger.error("Browser chatbot billing reconciliation unavailable: #{e.class}")
      false
    end

    def browser_chat_billing_unavailable_payload
      {
        error: 'billing_reconciliation_unavailable',
        code: 'billing_reconciliation_unavailable'
      }
    end

    def browser_chat_account_active?(user)
      user.reload.active?
    rescue ActiveRecord::RecordNotFound
      false
    end

    def browser_chat_account_fenced_payload(credits_info: nil)
      {
        error: 'account_inactive',
        code: 'account_inactive',
        credits_info: credits_info
      }.compact
    end
  end
end
