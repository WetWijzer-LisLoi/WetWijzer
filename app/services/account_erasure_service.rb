# frozen_string_literal: true

# Permanently erases an account and every user-linked record that lives outside
# the accounts database. Cross-database transactions are not atomic, so this
# operation is intentionally ordered and idempotent:
#
# 1. stop recurring billing and confirm that no provider subscription remains;
# 2. require every accepted payment, invoice, and adjustment to be settled;
# 3. fence the account and revoke conversation storage consent;
# 4. drain requests admitted before the fence;
# 5. erase records from the chatbot, analytics, and primary databases;
# 6. destroy the account and its normal dependent records.
#
# A provider cancellation error raises before the account is changed. Once
# billing is safely stopped, any later cleanup error raises before
# User#destroy!, leaving a disabled account that can be retried safely instead
# of an apparently deleted account with orphaned conversation or analytics data.
class AccountErasureService
  class InFlightAccountWork < StandardError; end
  class PendingFinancialWork < StandardError; end

  DRAIN_TIMEOUT = 10.seconds
  DRAIN_POLL_INTERVAL = 0.05.seconds

  ANALYTICS_MODELS = [
    ChatbotAnalytic,
    ChatbotFeedback,
    ChatbotReport,
    UsageLog
  ].freeze

  PRIMARY_TABLES = %w[
    partner_auth_codes
    partner_usage_logs
    subscriptions
    account_activities
    chatbot_feedbacks
    saved_answers
    credit_purchases
    chatbot_usages
    partner_bookmarks
    jurisprudence_access_logs
  ].freeze

  PRIMARY_USER_TABLE = 'users'

  def self.call!(user, **options)
    new(user, **options).call!
  end

  def self.ensure_financial_work_settled!(user)
    new(user).send(:ensure_financial_work_settled!)
  end

  def initialize(
    user,
    drain_timeout: DRAIN_TIMEOUT,
    drain_poll_interval: DRAIN_POLL_INTERVAL,
    monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    sleeper: ->(seconds) { sleep(seconds) },
    mollie_client: nil
  )
    @user = user
    @user_id = Integer(user.id)
    @drain_timeout = Float(drain_timeout)
    @drain_poll_interval = Float(drain_poll_interval)
    @monotonic_clock = monotonic_clock
    @sleeper = sleeper
    @mollie_client = mollie_client
  end

  def call!
    cancel_recurring_billing!
    fence_account_and_verify_financial_work!
    drain_in_flight_account_work!
    erase_chatbot_conversations!
    erase_analytics_records!
    erase_primary_records!
    erase_account_reservations!
    erase_accounts_child_rows!
    destroy_account_after_final_financial_check!
    true
  end

  private

  # A provider cancellation failure must stop erasure before any local billing
  # reference is removed. Calling the service for every subscription also
  # fences an as-yet-unprovisioned first Mollie payment: the cancellation
  # service serializes with the provision job and marks the local subscription
  # canceled even when no remote subscription exists yet.
  def cancel_recurring_billing!
    subscription = @user.subscription
    return unless subscription

    client = mollie_client if subscription.mollie_customer_id.present?
    MollieSubscriptionCancellationService.new(subscription, client: client || MollieApiClient.new).cancel!
    reconcile_remote_mollie_payments!(subscription, client) if client
  end

  # A recurring payment can be accepted by Mollie just before its subscription
  # is canceled and reach our webhook later. Read the complete current customer
  # page after cancellation, while the account is still active, so every
  # already-created provider payment becomes a durable local row before the
  # deletion fence performs its financial check.
  def reconcile_remote_mollie_payments!(subscription, client)
    response = client.list_customer_payments(subscription.mollie_customer_id)
    payments = response.dig('_embedded', 'payments')
    unless payments.is_a?(Array)
      raise MollieSubscriptionCancellationService::CancellationError,
            'Mollie payment reconciliation returned an invalid collection'
    end
    if response.dig('_links', 'next', 'href').present?
      raise MollieSubscriptionCancellationService::CancellationError,
            'Mollie payment reconciliation is incomplete'
    end

    payments.each do |snapshot|
      next unless payment_snapshot_belongs_to_subscription?(snapshot, subscription)

      # The provider money must remain auditable and invoiceable, but a renewal
      # found only after cancellation must never reactivate the contract or
      # refill an account that is about to be erased.
      MolliePaymentProcessor.new(snapshot, suppress_entitlement: true).process!
    end
  rescue MollieApiClient::ApiError => e
    return if e.http_status == 404

    raise MollieSubscriptionCancellationService::CancellationError,
          'Mollie payment reconciliation could not be confirmed'
  rescue MollieApiClient::Error
    raise MollieSubscriptionCancellationService::CancellationError,
          'Mollie payment reconciliation could not be confirmed'
  end

  def payment_snapshot_belongs_to_subscription?(snapshot, subscription)
    return false unless snapshot.is_a?(Hash)

    existing = MolliePayment.find_by(mollie_payment_id: snapshot['id'].to_s)
    return existing.contract_subscription_id == subscription.id if existing

    metadata = snapshot['metadata']
    metadata.is_a?(Hash) &&
      metadata['wetwijzer_subscription_id'].to_s == subscription.id.to_s &&
      metadata['user_id'].to_s == @user_id.to_s
  end

  def mollie_client
    @mollie_client ||= MollieApiClient.new
  end

  # Financial records outlive the account, but their invoice and adjustment
  # snapshots still need the user/purchase data while they are being created.
  # Fail closed and let the scheduled Mollie recovery jobs finish before a
  # later erasure retry nullifies those associations.
  def ensure_financial_work_settled!
    return unless @user.respond_to?(:mollie_payments)

    payments = MolliePayment.where(user_id: @user_id)
    unsettled_payment = payments.where(
      status: MolliePaymentProcessor::PRE_PAID_STATUSES
    ).or(
      payments.where(status: 'paid', fulfilled_at: nil)
    ).exists?
    unsettled_invoice = payments.where.not(fulfilled_at: nil)
                                .where.not(invoice_state: %w[completed not_required])
                                .exists?
    unsettled_adjustment = MolliePaymentAdjustment.joins(:mollie_payment)
                                                  .where(mollie_payments: { user_id: @user_id })
                                                  .where.not(status: 'processed')
                                                  .exists?
    unsettled_chargeback_confirmation = payments.where.not(
      chargeback_reversal_candidate_cents: nil
    ).exists?
    crypto_payments = CryptoPayment.where(user_id: @user_id)
    unsettled_crypto_order = crypto_payments.where(
      status: %w[new pending confirming]
    ).exists?
    unsettled_crypto_invoice = crypto_payments.where(status: %w[paid refunded partially_refunded])
                                              .where.not(invoice_state: 'completed')
                                              .exists?
    unsettled_crypto_refund = crypto_payments.where(status: 'refunded')
                                             .where.not(refund_invoice_state: 'completed')
                                             .exists?
    partial_crypto_refund = crypto_payments.where(status: 'partially_refunded').exists?
    return unless unsettled_payment ||
                  unsettled_invoice ||
                  unsettled_adjustment ||
                  unsettled_chargeback_confirmation ||
                  unsettled_crypto_order ||
                  unsettled_crypto_invoice ||
                  unsettled_crypto_refund ||
                  partial_crypto_refund

    raise PendingFinancialWork,
          "account #{@user_id} still has payment, invoice, adjustment, refund, or chargeback work in flight"
  end

  # Intent creation obtains the same accounts-database write lock before it
  # checks whether the account is active. Fencing and the financial check in
  # one short transaction therefore have only two outcomes: an earlier intent
  # is observed and the fence rolls back, or the fence commits and no later
  # checkout can create a new intent from a stale account read.
  def fence_account_and_verify_financial_work!
    AccountRecord.transaction do
      @user.lock! if @user.respond_to?(:lock!)
      fence_account!
      ensure_financial_work_settled!
    end
  end

  def fence_account!
    @user.update_columns(
      active: false,
      conversation_storage_consent: false,
      conversation_storage_consented_at: nil,
      encrypted_master_key: nil,
      key_derivation_salt: nil,
      session_token: nil,
      updated_at: Time.current
    )
  end

  def drain_in_flight_account_work!
    deadline = @monotonic_clock.call + @drain_timeout

    loop do
      # These reconcilers only release work older than their five-minute stale
      # threshold. Fresh provider/request work is never force-deleted.
      AccountRequestLease.reconcile_stale_for_user!(@user_id)
      BillingReservation.reconcile_stale_for_user!(@user)
      return true unless in_flight_account_work?

      remaining = deadline - @monotonic_clock.call
      if remaining <= 0
        raise InFlightAccountWork,
              "account #{@user_id} still has an authenticated request or billing reservation in flight"
      end

      @sleeper.call([@drain_poll_interval, remaining].min)
    end
  end

  def in_flight_account_work?
    AccountRequestLease.for_user_id(@user_id).exists? ||
      BillingReservation.unsettled.where(user_id: @user_id).exists?
  end

  def erase_chatbot_conversations!
    connection = ChatbotConversation.connection
    return unless connection.data_source_exists?(ChatbotConversation.table_name)

    relation = ChatbotConversation.where(user_id: @user_id.to_s)
    relation.delete_all
    raise 'Chatbot conversation erasure was incomplete' if relation.exists?
  end

  def erase_analytics_records!
    ANALYTICS_MODELS.each do |model|
      next unless model.connection.data_source_exists?(model.table_name)

      relation = model.where(user_id: @user_id)
      relation.delete_all
      raise "#{model.table_name} erasure was incomplete" if relation.exists?
    end
  end

  def erase_primary_records!
    connection = ApplicationRecord.connection
    PRIMARY_TABLES.each do |table|
      erase_table_rows!(connection, table)
    end

    # The accounts split deliberately left the old primary tables in place so
    # installations could migrate without a destructive data move. Remove the
    # legacy user only after every possible primary-database child row.
    erase_table_rows!(connection, PRIMARY_USER_TABLE, user_column: 'id')
  end

  # The billing ledger is explicitly erased only after every reserved row has
  # drained or been proven stale; settled/refunded history can then be removed.
  def erase_account_reservations!
    connection = AccountRecord.connection
    erase_table_rows!(connection, 'billing_reservations')
  end

  # Accounts-database children that reference users but have neither a
  # dependent: :destroy association nor any other cleanup. On SQLite the
  # dangling rows merely lingered; on PostgreSQL the foreign keys are
  # enforced unconditionally, so leaving them makes the FINAL @user.destroy!
  # raise - after the chatbot, analytics and primary erasures have already
  # committed to three other databases with no transaction spanning them.
  # That would leave a fenced, key-destroyed shell that can never be deleted
  # and whose data is already gone (found by the 2026-08-19 deletion audit;
  # email_outbox_entries arms as soon as DURABLE_TRANSACTIONAL_EMAIL is on).
  ACCOUNTS_CHILD_TABLES = %w[email_outbox_entries admin_sessions].freeze

  def erase_accounts_child_rows!
    connection = AccountRecord.connection
    ACCOUNTS_CHILD_TABLES.each { |table| erase_table_rows!(connection, table) }
  end

  # The earlier fence/check prevents new browser checkout, but a financial
  # callback may legitimately enter after the fence to preserve a provider-paid
  # renewal. Claim the user row (SQLite: the database write lock; PG: the
  # row lock, which lease acquisition's FOR UPDATE respects - see
  # AccountRequestLease#row_lock_clause), re-check both leases and financial
  # work, and destroy the account in the same final transaction. A callback
  # therefore either finishes first and blocks deletion, or can no longer
  # acquire a lease because the user row is gone.
  def destroy_account_after_final_financial_check!
    unless @user.respond_to?(:persisted?) && @user.persisted?
      @user.destroy!
      return
    end

    AccountRecord.transaction do
      claimed = User.where(id: @user_id).update_all(updated_at: Time.current)
      raise ActiveRecord::RecordNotFound unless claimed == 1

      @user.reload
      if in_flight_account_work?
        raise InFlightAccountWork,
              "account #{@user_id} admitted account work after its deletion fence"
      end
      ensure_financial_work_settled!
      @user.destroy!
    end
  end

  def erase_table_rows!(connection, table, user_column: 'user_id')
    return unless connection.data_source_exists?(table)

    quoted_table = connection.quote_table_name(table)
    quoted_user_column = connection.quote_column_name(user_column)
    quoted_user_id = connection.quote(@user_id)
    condition = "#{quoted_user_column} = #{quoted_user_id}"
    begin
      connection.delete("DELETE FROM #{quoted_table} WHERE #{condition}", 'Account erasure')
    rescue ActiveRecord::StatementInvalid => e
      # A legacy table can outlive its parent. The accounts split (593026f4,
      # 2026-05-31) moved `users` out of the primary database but left the
      # empty partner_* tables behind, whose FK still names `users`. SQLite
      # resolves FK parents while PREPARING any DML on the child, so even a
      # zero-row DELETE raises "no such table: main.users" - which aborted the
      # whole erasure and made admin user deletion fail in production.
      #
      # Tolerating that is safe ONLY when the table holds nothing for this
      # user. Anything else must still fail loudly: silently skipping a table
      # that holds rows would leave personal data behind (GDPR).
      raise unless e.message.match?(/no such table/i)
      raise if rows_present?(connection, quoted_table, condition)

      Rails.logger.warn(
        "[AccountErasure] skipped #{table}: it holds no rows for this user and its foreign-key parent is missing"
      )
      return
    end

    raise "#{table} erasure was incomplete" if rows_present?(connection, quoted_table, condition)
  end

  def rows_present?(connection, quoted_table, condition)
    connection.select_value(
      "SELECT 1 FROM #{quoted_table} WHERE #{condition} LIMIT 1",
      'Verify account erasure'
    ).present?
  end
end
