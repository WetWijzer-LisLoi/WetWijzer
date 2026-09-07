# frozen_string_literal: true

# Centralizes the durable-work eligibility predicates used by the scheduled
# Mollie recovery job. Keeping these scopes together makes it less likely that
# a new work type is enqueued without its lifecycle and lease guards.
class MolliePendingWorkRecoveryScopes
  INVOICE_PAYMENT_TYPES = %w[
    credit_purchase
    subscription_initial
    subscription_renewal
  ].freeze

  # A provider create can crash before either local pointer is stored or after
  # only MolliePayment remembers the remote id. The live Subscription pointer
  # is therefore the completion marker. Keep both crash shapes eligible, and
  # also recover a confirmed chargeback reversal while some paid amount and
  # its original access period remain valid.
  def provisioning
    MolliePayment.joins(:user, :subscription)
                 .where(
                   payment_type: 'subscription_initial',
                   status: 'paid'
                 )
                 .where.not(fulfilled_at: nil)
                 .where.not(service_period_end: nil)
                 .where.not(mollie_payment_id: [nil, ''])
                 .where.not(mollie_customer_id: [nil, ''])
                 .where(
                   <<~SQL.squish
                     mollie_payments.refunded_amount_cents +
                     mollie_payments.charged_back_amount_cents <
                     mollie_payments.amount_cents
                   SQL
                 )
                 .where(
                   <<~SQL.squish
                     mollie_payments.entitlement_revoked_at IS NULL
                     OR mollie_payments.entitlement_restored_at IS NOT NULL
                   SQL
                 )
                 .where(
                   users: {
                     active: true,
                     deletion_scheduled_for: nil
                   },
                   subscriptions: {
                     tier: 'pro',
                     status: 'active',
                     payment_method: 'mollie',
                     mollie_subscription_id: [nil, '']
                   }
                 )
                 .where(
                   <<~SQL.squish
                     mollie_payments.subscription_id = subscriptions.id
                     AND mollie_payments.user_id = subscriptions.user_id
                     AND mollie_payments.mollie_customer_id = subscriptions.mollie_customer_id
                     AND mollie_payments.mollie_payment_id = subscriptions.mollie_first_payment_id
                   SQL
                 )
                 .where(
                   <<~SQL.squish,
                     mollie_payments.subscription_provisioning_started_at IS NULL
                     OR mollie_payments.subscription_provisioning_started_at <= ?
                   SQL
                   MollieSubscriptionProvisionJob::CLAIM_TTL.ago
                 )
  end

  def invoices
    base = MolliePayment.where(payment_type: INVOICE_PAYMENT_TYPES)
                        .where.not(fulfilled_at: nil)
    pending = base.where(invoice_state: %w[pending failed])
    stale = base.where(invoice_state: 'processing')
                .where(
                  'mollie_payments.updated_at <= ?',
                  MollieInvoiceJob::PROCESSING_LEASE.ago
                )

    pending.or(stale)
  end

  def adjustments
    base = MolliePaymentAdjustment.all
    pending = base.where(status: %w[pending failed])
    stale = base.where(status: 'processing')
                .where(
                  'mollie_payment_adjustments.updated_at <= ?',
                  MolliePaymentAdjustmentJob::PROCESSING_LEASE.ago
                )

    pending.or(stale)
  end

  # A full refund/chargeback revokes the local entitlement before provider I/O
  # and records entitlement_revoked_at on the originating payment. The initial
  # enqueue of MollieSubscriptionCancellationJob is best-effort, so this scope
  # is the durable outbox: it remains eligible until the current remote pointer
  # is cleared by a provider-confirmed cancellation.
  #
  # Bind the reversed payment to the current billing generation in SQL. Without
  # that guard, an old refunded payment could enqueue cancellation for a newer
  # replacement subscription which has not fulfilled a later payment yet.
  def cancellations
    base = MolliePayment.joins(:subscription)
                         .where(
                           payment_type: %w[subscription_initial subscription_renewal],
                           entitlement_restored_at: nil,
                           subscriptions: { payment_method: 'mollie' }
                         )
                         .where.not(entitlement_revoked_at: nil)
                         .where(
                           <<~SQL.squish
                             (
                               subscriptions.mollie_subscription_id IS NOT NULL
                               AND subscriptions.mollie_subscription_id != ''
                             )
                             OR subscriptions.status != 'canceled'
                           SQL
                         )
                         .where(
                           <<~SQL.squish
                             mollie_payments.refunded_amount_cents +
                             mollie_payments.charged_back_amount_cents >=
                             mollie_payments.amount_cents
                           SQL
                         )
                         .where(
                           <<~SQL.squish
                             (
                               mollie_payments.payment_type = 'subscription_initial'
                               AND mollie_payments.mollie_payment_id =
                                   subscriptions.mollie_first_payment_id
                             )
                             OR
                             (
                               mollie_payments.payment_type = 'subscription_renewal'
                               AND mollie_payments.mollie_subscription_id =
                                   subscriptions.mollie_subscription_id
                             )
                           SQL
                         )

    base
  end

  def chargeback_confirmations
    MolliePayment.where.not(mollie_payment_id: [nil, ''])
                 .where.not(chargeback_reversal_candidate_cents: nil)
                 .where.not(chargeback_reversal_candidate_at: nil)
                 .where(
                   'chargeback_reversal_candidate_at <= ?',
                   MolliePaymentProcessor::CHARGEBACK_REVERSAL_CONFIRMATION_DELAY.ago
                 )
                 .where(
                   'charged_back_amount_cents > chargeback_reversal_candidate_cents'
                 )
  end

  def notifications
    MolliePayment.joins(:user, :subscription)
                 .where(
                   payment_type: 'subscription_renewal',
                   status: MolliePaymentProcessor::TERMINAL_FAILURES,
                   failure_notification_sent_at: nil,
                   subscriptions: { status: 'past_due' }
                 )
                 .where.not(failure_notification_enqueued_at: nil)
                 .where(
                   'mollie_payments.failure_notification_enqueued_at <= ?',
                   Time.current
                 )
                 .where(
                   'mollie_payments.mollie_subscription_id = subscriptions.mollie_subscription_id'
                 )
                 .where(
                   <<~SQL.squish
                     mollie_payments.provider_created_at IS NULL
                     OR NOT EXISTS (
                         SELECT 1
                         FROM mollie_payments newer_mollie_payments
                         WHERE newer_mollie_payments.subscription_id = mollie_payments.subscription_id
                           AND newer_mollie_payments.payment_type = 'subscription_renewal'
                           AND newer_mollie_payments.mollie_subscription_id =
                               mollie_payments.mollie_subscription_id
                           AND newer_mollie_payments.fulfilled_at IS NOT NULL
                           AND newer_mollie_payments.provider_created_at >
                               mollie_payments.provider_created_at
                     )
                   SQL
                 )
  end
end
