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

    # Owner default 2026-09-27 (to-do 6.7) made an incomplete-search answer
    # free. Owner policy 2026-10-18 replaced it for the ask path: a question is
    # charged once a paid AI request for it was sent, whatever the answer says
    # about its search; see browser_chat_work_dispatched?. The constant stays
    # for the analytics allowlist of historical rows, and the two helpers below
    # only for the retired deep-analysis code, which is unreachable (410).
    CHARGE_WAIVED_INCOMPLETE_SEARCH = 'retrieval_incomplete'

    def incomplete_search_answer?(result)
      result.is_a?(Hash) && result[:error].blank? && result[:retrieval_degraded].present?
    end

    # Retired deep-analysis path only (see above).
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
      reason:,
      receipt: nil
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

        # Proven non-delivery: the owner aborts. With dispatched paid work the
        # model keeps the single charge and records the delivery as aborted
        # (never completed); without it the credits return.
        reservation.abort_delivery!(token: delivery_token, reason: reason)
        mark_analytic_refunded!(analytic) if reservation.refunded?
        return {
          outcome: reservation.refunded? ? :refunded : :settled,
          credits_info: browser_chat_settlement_credits_info(reservation, analytic: analytic, user: user)
        }
      end

      credits_info = finish_undelivered_browser_chat!(
        reservation, receipt: receipt, analytic: analytic, user: user, reason: reason
      )
      {
        outcome: reservation.refunded? ? :refunded : :settled,
        credits_info: credits_info
      }
    end

    # Owner policy 2026-10-18: "charge once the provider request was sent".
    # One receipt per browser question, handed explicitly to every client that
    # can send a paid AI request. Its first dispatch is admitted under the
    # account's row lock (BillingReservation#admit_work_dispatch!), which
    # checks that the account is still active and asks this block, on the
    # locked account rather than the request's shared current_user (the
    # admission runs in the query thread), whether the request may still
    # start paid work: for a request admitted with a conversation claim, the
    # storage generation it was admitted under must be unchanged (a consent
    # regrant, even in the same mode, renews it and would fence the later
    # history write) and the claim must still be owned (a clear, consent or
    # key change fences it). The claim read is a chatbot-lane query made
    # while accounts locks are held, so its waits are bounded. An ordinary
    # ask without history or claim needs neither consent nor a generation.
    # Unbilled service requests get no receipt, so their semantics are
    # unchanged.
    def build_browser_provider_work_receipt(reservation, claim:, storage_generation: nil)
      return nil unless reservation&.browser_work_tracked?

      LegalChatbot::ProviderWorkReceipt.new(
        reservation: reservation,
        eligibility: lambda do |account|
          next true unless claim
          next false unless storage_generation && ConversationStorageBoundary.generation(account) == storage_generation

          ConversationStorageBoundary.bounded_chatbot_read { claim_owned_by?(account, claim) }
        end
      )
    end

    # The durable answer decides; the receipt's in-memory flag only spares a
    # read. A wrong `false` here is still safe: refund! re-reads the marker
    # under its row lock and settles dispatched work instead of refunding.
    def browser_chat_work_dispatched?(reservation, receipt)
      return false unless reservation&.browser_work_tracked?
      return true if receipt&.dispatched?

      reservation.reload_work_dispatch!
    rescue StandardError => e
      Rails.logger.error("Browser chatbot dispatch evidence unreadable: #{e.class}")
      false
    end

    # Ends a question that delivers no answer (an error result, an account or
    # claim fence, a pre-delivery failure) and returns its truthful
    # credits_info. Dispatched work keeps the single charge without inventing a
    # delivery; otherwise the reservation is released. Callers discard or roll
    # back any content first, independently of this decision.
    def finish_undelivered_browser_chat!(reservation, receipt:, analytic:, user:, reason:)
      return nil unless reservation

      if browser_chat_work_dispatched?(reservation, receipt)
        begin
          reservation.retain_work!
        rescue StandardError => e
          # The marker is durable: the stale reconciler settles the row (its
          # refund! cannot return dispatched work).
          Rails.logger.error("Browser chatbot work retention deferred: #{e.class}")
        end
      else
        refund_browser_chat_reservation!(reservation, analytic: analytic, reason: reason)
      end
      browser_chat_settlement_credits_info(reservation, analytic: analytic, user: user)
    end

    # What the client is told after any settlement decision: the reservation's
    # actual state, never an assumed refund. A dispatched row whose retention
    # was deferred is still charged.
    def browser_chat_settlement_credits_info(reservation, analytic:, user:)
      if reservation.settled? || (reservation.reserved? && reservation.work_dispatched?)
        project_browser_chat_analytic!(reservation, analytic) if reservation.settled?
        credit_balance_info(user, deducted: reservation.amount)
      else
        credit_balance_info(user, deducted: 0)
      end
    end

    WORK_CHARGE_NOTICES = {
      'nl' => ['De AI-verwerking voor deze vraag was al gestart; daarom is de prijs van deze vraag aangerekend (%<amount>s).',
               %w[credit credits]],
      'fr' => ["Le traitement par l'IA de cette question avait déjà commencé ; le prix de cette question a donc été débité (%<amount>s).",
               %w[crédit crédits]],
      'de' => ['Die KI-Verarbeitung dieser Frage hatte bereits begonnen; der Preis dieser Frage wurde daher abgebucht (%<amount>s).',
               %w[Credit Credits]],
      'en' => ['AI processing for this question had already started, so the price of this question was charged (%<amount>s).',
               %w[credit credits]]
    }.freeze

    def browser_chat_work_charge_notice(amount, language)
      template, units = WORK_CHARGE_NOTICES.fetch(language.to_s) { WORK_CHARGE_NOTICES.fetch('nl') }
      amount = amount.to_i
      singular = language.to_s == 'fr' ? amount < 2 : amount == 1
      format(template, amount: "#{amount} #{singular ? units[0] : units[1]}")
    end

    # A result payload shown as an error states the retained charge in the
    # text the client displays: the answer for a timeout, the error text
    # otherwise (and the answer too when it carries the same text). Code-only
    # error events carry :charge_notice instead, once, for the client's
    # localized sentence; the two never meet on one payload.
    def attach_work_charge_notice!(result, credits_info, language)
      return result unless result.is_a?(Hash) && credits_info && credits_info[:credits_deducted].to_i.positive?

      notice = browser_chat_work_charge_notice(credits_info[:credits_deducted], language)
      if result[:error] == 'timeout' || !result[:error].is_a?(String)
        result[:answer] = [result[:answer].presence, notice].compact.join("\n\n")
      else
        result[:error] = "#{result[:error]}\n\n#{notice}"
        result[:answer] = "#{result[:answer]}\n\n#{notice}" if result[:answer].is_a?(String) && result[:answer].present?
      end
      result
    end

    # The retained-charge sentence for a code-only error event or body, or
    # nothing when the credits came back.
    def browser_chat_charge_notice_field(credits_info, language)
      return {} unless credits_info && credits_info[:credits_deducted].to_i.positive?

      { charge_notice: browser_chat_work_charge_notice(credits_info[:credits_deducted], language) }
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
