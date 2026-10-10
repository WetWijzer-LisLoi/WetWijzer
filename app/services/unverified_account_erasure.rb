# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

# Immediate, operator-requested erasure of an exact set of unverified accounts.
# Preparation is read-only and contains no addresses or confirmation tokens.
# Reusing a snapshot is safe: every target is checked again under the account
# lock, and accounts registered after preparation can never join that run.
class UnverifiedAccountErasure
  class InvalidSnapshot < ArgumentError; end
  class SnapshotTooLarge < StandardError; end
  class DeferredFinancialAccount < StandardError; end
  class DeferredAccountWork < StandardError; end

  class ErasureAndRecoveryFenceFailure < StandardError
    attr_reader :exceptions

    def initialize(erasure_error, fence_error)
      @exceptions = [erasure_error, fence_error]
      super('account erasure and its recovery fence failed')
    end
  end

  SNAPSHOT_VERSION = 1
  DEFAULT_BATCH_SIZE = 100
  MAX_BATCH_SIZE = 1_000
  MAX_TARGETS = 10_000
  COUNTS = %i[deleted already_gone now_verified protected deferred failed].freeze
  SNAPSHOT_KEYS = %w[version cutoff target_count targets sha256].freeze
  TARGET_KEYS = %w[id created_at].freeze

  def self.prepare(cutoff: Time.current, batch_size: DEFAULT_BATCH_SIZE)
    batch_size = validate_batch_size!(batch_size)
    cutoff = canonical_time(cutoff)
    raise InvalidSnapshot, 'cutoff must not be in the future' if Time.iso8601(cutoff) > Time.current

    targets = []
    after_id = 0
    scope = User.where(confirmed_at: nil).where('created_at <= ?', Time.iso8601(cutoff))
    loop do
      rows = scope.where('id > ?', after_id).reorder(:id).limit(batch_size).pluck(:id, :created_at)
      break if rows.empty?
      raise SnapshotTooLarge, 'snapshot exceeds the target limit' if targets.length + rows.length > MAX_TARGETS

      rows.each { |id, created_at| targets << { 'id' => id, 'created_at' => canonical_time(created_at) } }
      after_id = rows.last.first
    end

    snapshot = {
      'version' => SNAPSHOT_VERSION,
      'cutoff' => cutoff,
      'target_count' => targets.length,
      'targets' => targets
    }
    snapshot.merge('sha256' => snapshot_digest(snapshot))
  end

  def self.call!(snapshot:, batch_size: DEFAULT_BATCH_SIZE)
    new(snapshot: snapshot, batch_size: batch_size).call!
  end

  def initialize(snapshot:, batch_size: DEFAULT_BATCH_SIZE)
    @batch_size = self.class.validate_batch_size!(batch_size)
    @snapshot = self.class.validate_snapshot!(snapshot)
  end

  def call!
    result = COUNTS.to_h { |key| [key, 0] }.merge(exception_classes: {})
    @snapshot.fetch('targets').each_slice(@batch_size) do |targets|
      # Only materialize the bounded, explicit snapshot IDs. No live unverified
      # scope is evaluated during application, even when a new account appears.
      begin
        users = User.where(id: targets.map { |target| target.fetch('id') }).index_by(&:id)
      rescue StandardError => e
        result[:failed] += targets.length
        record_exception(result, e, count: targets.length)
        next
      end
      targets.each do |target|
        outcome = erase_target(target, users[target.fetch('id')])
        result[outcome] += 1
      rescue DeferredFinancialAccount, DeferredAccountWork,
             AccountErasureService::PendingFinancialWork, AccountErasureService::InFlightAccountWork => e
        result[:deferred] += 1
        record_exception(result, e)
      rescue ErasureAndRecoveryFenceFailure => e
        result[:failed] += 1
        e.exceptions.each { |error| record_exception(result, error) }
      rescue StandardError => e
        result[:failed] += 1
        record_exception(result, e)
      end
    end
    result
  end

  class << self
    def validate_batch_size!(batch_size)
      raise ArgumentError, "batch_size must be between 1 and #{MAX_BATCH_SIZE}" unless batch_size.is_a?(Integer) && batch_size.between?(1, MAX_BATCH_SIZE)

      batch_size
    end

    def canonical_time(value)
      value.to_time.utc.iso8601(6)
    rescue NoMethodError, ArgumentError, TypeError
      raise InvalidSnapshot, 'snapshot timestamps must be valid times'
    end

    def snapshot_digest(snapshot)
      payload = [snapshot.fetch('version'), snapshot.fetch('cutoff'), snapshot.fetch('target_count'),
                 snapshot.fetch('targets').map { |target| [target.fetch('id'), target.fetch('created_at')] }]
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def validate_snapshot!(snapshot)
      unless snapshot.is_a?(Hash) && snapshot.keys.all?(String) &&
             snapshot.keys.sort == SNAPSHOT_KEYS.sort &&
             snapshot['version'] == SNAPSHOT_VERSION && snapshot['targets'].is_a?(Array) &&
             snapshot['target_count'].is_a?(Integer) &&
             snapshot['target_count'] == snapshot['targets'].length && snapshot['target_count'] <= MAX_TARGETS
        raise InvalidSnapshot, 'snapshot shape or version is invalid'
      end

      cutoff = parse_snapshot_time!(snapshot['cutoff'])
      raise InvalidSnapshot, 'cutoff must not be in the future' if cutoff > Time.current

      previous_id = 0
      snapshot['targets'].each do |target|
        unless target.is_a?(Hash) && target.keys.all?(String) &&
               target.keys.sort == TARGET_KEYS.sort &&
               target['id'].is_a?(Integer) && target['id'] > previous_id
          raise InvalidSnapshot, 'snapshot targets must have unique ordered positive IDs'
        end

        created_at = parse_snapshot_time!(target['created_at'])
        raise InvalidSnapshot, 'snapshot target is newer than its cutoff' if created_at > cutoff

        previous_id = target['id']
      end
      raise InvalidSnapshot, 'snapshot integrity check failed' unless snapshot['sha256'].is_a?(String) && snapshot['sha256'] == snapshot_digest(snapshot)

      # Isolate the validated data from subsequent caller mutation. JSON also
      # keeps this format identical after a saved snapshot is read back.
      JSON.parse(JSON.generate(snapshot))
    end

    def parse_snapshot_time!(value)
      unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
        raise InvalidSnapshot, 'snapshot timestamps must use UTC microsecond precision'
      end

      time = Time.iso8601(value)
      raise InvalidSnapshot, 'snapshot timestamp is not canonical' unless canonical_time(time) == value

      time
    rescue ArgumentError
      raise InvalidSnapshot, 'snapshot timestamp is invalid'
    end
  end

  private

  def erase_target(target, user)
    return :already_gone unless user

    outcome = nil
    erasure_started = false
    failure_handled = false
    pending_error = nil
    user.with_lock do
      claim_account_write_lock!(user)

      if self.class.canonical_time(user.created_at) != target.fetch('created_at') || user.admin?
        outcome = :protected
      elsif user.confirmed_at.present?
        outcome = :now_verified
      else
        ensure_local_only_erasure!(user)
        # Keep the entire cross-database sweep and final User#destroy! inside
        # this SAME account lock. Confirmation before the lock is skipped;
        # confirmation afterwards cannot commit an update to a deleted row.
        erasure_started = true
        begin
          # Keep the user lock outside this savepoint. If an external database
          # fails, its committed erasures cannot roll back, but the accounts
          # changes can. Recover the fence before releasing the original lock.
          AccountRecord.transaction(requires_new: true) do
            AccountErasureService.call!(user, drain_timeout: 0)
          end
          outcome = :deleted
        rescue StandardError => e
          pending_error = e
          begin
            fence_locked_failed_erasure!(user, target)
          rescue StandardError => fence_error
            pending_error = ErasureAndRecoveryFenceFailure.new(e, fence_error)
          end
          failure_handled = true
        end
      end
    end
    raise pending_error if pending_error

    outcome
  rescue StandardError => e
    # A deletion between the bounded fetch and lock is an idempotent success.
    # Errors inside erasure must remain failures if the account still exists.
    return :already_gone if e.is_a?(ActiveRecord::RecordNotFound) && !User.exists?(target.fetch('id'))

    if erasure_started && !failure_handled
      begin
        fence_failed_erasure!(target)
      rescue StandardError => fence_error
        raise ErasureAndRecoveryFenceFailure.new(e, fence_error)
      end
    end
    raise
  end

  def claim_account_write_lock!(user)
    # SQLite drops SELECT FOR UPDATE. This no-op write claims its writer
    # lock before the fresh recheck; PostgreSQL already holds the row lock.
    return unless User.connection.adapter_name.match?(/sqlite/i)

    claimed = User.where(id: user.id).update_all('id = id')
    raise ActiveRecord::RecordNotFound unless claimed == 1

    user.reload
  end

  def fence_failed_erasure!(target)
    # Only unexpected failure of the OUTER transaction needs a fresh claim.
    # Ordinary cross-database failures are fenced under the original lock.
    user = User.find_by(id: target.fetch('id'))
    return unless user

    user.with_lock do
      claim_account_write_lock!(user)
      fence_locked_failed_erasure!(user, target)
    end
  end

  def fence_locked_failed_erasure!(user, target)
    user.reload
    return if self.class.canonical_time(user.created_at) != target.fetch('created_at') ||
              user.admin? || user.confirmed_at.present?

    user.update_columns(
      active: false, session_token: nil,
      confirmation_token: nil, reset_password_token: nil, reset_password_sent_at: nil,
      conversation_storage_consent: false, conversation_storage_consented_at: nil,
      encrypted_master_key: nil, key_derivation_salt: nil,
      deletion_reason: 'unconfirmed', deletion_scheduled_for: Time.current,
      deletion_final_warning_sent_at: nil, updated_at: Time.current
    )
  end

  def ensure_local_only_erasure!(user)
    subscriptions = Subscription.where(user_id: user.id).lock.to_a
    if subscriptions.any? { |subscription| financial_subscription?(subscription) } ||
       provider_reference?(user) || financial_records?(user.id)
      raise DeferredFinancialAccount, 'account requires separate financial review'
    end

    if AccountRequestLease.for_user_id(user.id).exists? ||
       BillingReservation.unsettled.where(user_id: user.id).exists?
      raise DeferredAccountWork, 'account has work in flight'
    end

    # Preserve the existing service's payment/invoice/refund fences even if its
    # checks grow beyond the conservative payment-history guard above.
    AccountErasureService.ensure_financial_work_settled!(user)
    user.association(:subscription).reset
  end

  def financial_subscription?(subscription)
    subscription.tier != 'free' || provider_reference?(subscription) ||
      (subscription.has_attribute?(:monthly_price_cents) && subscription[:monthly_price_cents].to_i.positive?)
  end

  def provider_reference?(record)
    record.attributes.any? do |column, value|
      (column == 'payment_method' || column.start_with?('mollie_', 'stripe_')) && value.present?
    end
  end

  def financial_records?(user_id)
    [MolliePayment, CryptoPayment, CreditPurchase, PlatformInvoice].any? do |model|
      scope = model.where(user_id: user_id)
      scope = scope.or(model.where(contract_user_id: user_id)) if model.column_names.include?('contract_user_id')
      scope.exists?
    end
  end

  def record_exception(result, error, count: 1)
    name = error.class.name
    result[:exception_classes][name] = result[:exception_classes].fetch(name, 0) + count
  end
end
