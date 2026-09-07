# frozen_string_literal: true

module Retention
  # The unverified-account lifecycle and due-deletion purge, extracted from
  # rake users:cleanup_unverified for FBL-030 so a durable job can own it
  # (this sweep previously had NO scheduler at all: nothing purged accounts
  # whose 30-day grace period had passed unless somebody ran the rake task
  # by hand).
  #
  # Timeline (unchanged; the periods are the legal owner's):
  #   24h unconfirmed -> first warning
  #   6d  unconfirmed -> final warning
  #   7d  unconfirmed -> deletion scheduled (deletion_scheduled_for = now)
  #   user-requested deletions get a warning <= 1 day before their date
  #   past deletion_scheduled_for -> AccountErasureService.call!
  #
  # Erasure goes exclusively through AccountErasureService.call!, which
  # keeps every financial-work fence (PendingFinancialWork,
  # InFlightAccountWork); a fenced account is counted and left for the next
  # sweep, never forced. Batches are bounded, failures are per-user and
  # never abort the sweep, and the returned counts carry no email address
  # or other PII - unlike the rake task this replaces, which printed raw
  # emails into the journal.
  class AccountDeletionSweepService
    DEFAULT_BATCH_SIZE = 200

    def self.call(batch_size: DEFAULT_BATCH_SIZE, now: Time.current)
      new(batch_size: batch_size, now: now).call
    end

    def initialize(batch_size: DEFAULT_BATCH_SIZE, now: Time.current)
      @batch_size = Integer(batch_size)
      raise ArgumentError, 'batch_size must be positive' unless @batch_size.positive?

      @now = now
    end

    def call
      result = {
        first_warnings: 0, final_warnings: 0, scheduled: 0,
        deletion_warnings: 0, purged: 0, fenced: 0, failed: 0
      }

      send_first_warnings(result)
      send_final_warnings(result)
      schedule_expired(result)
      send_deletion_warnings(result)
      purge_due(result)

      result[:remaining_unverified] = User.where(confirmed_at: nil).count
      result[:oldest_due_deletion_at] =
        User.where.not(deletion_scheduled_for: nil)
            .where(deletion_scheduled_for: ...@now)
            .minimum(:deletion_scheduled_for)
      result
    end

    private

    def each_bounded(scope, &)
      scope.reorder(:id).limit(@batch_size).each(&)
    end

    def guard(result, user)
      yield
    rescue StandardError => e
      result[:failed] += 1
      Rails.logger.error("[RETENTION] account sweep step failed for user id=#{user.id}: #{e.class}")
    end

    def send_first_warnings(result)
      scope = User.where(confirmed_at: nil)
                  .where(created_at: ...24.hours.before(@now))
                  .where(unverified_warning_sent_at: nil)
      each_bounded(scope) do |user|
        guard(result, user) do
          UserMailer.unverified_warning(user, :first).deliver_later
          user.update_column(:unverified_warning_sent_at, @now)
          result[:first_warnings] += 1
        end
      end
    end

    def send_final_warnings(result)
      scope = User.where(confirmed_at: nil)
                  .where(created_at: ...6.days.before(@now))
                  .where.not(unverified_warning_sent_at: nil)
                  .where(unverified_final_warning_sent_at: nil)
      each_bounded(scope) do |user|
        guard(result, user) do
          UserMailer.unverified_warning(user, :final).deliver_later
          user.update_column(:unverified_final_warning_sent_at, @now)
          result[:final_warnings] += 1
        end
      end
    end

    def schedule_expired(result)
      scope = User.where(confirmed_at: nil)
                  .where(created_at: ...7.days.before(@now))
                  .where(deletion_scheduled_for: nil)
      each_bounded(scope) do |user|
        guard(result, user) do
          user.update_columns(
            deletion_scheduled_for: @now,
            deletion_reason: 'unconfirmed',
            active: false
          )
          result[:scheduled] += 1
        end
      end
    end

    def send_deletion_warnings(result)
      scope = User.where(deletion_reason: 'user_requested')
                  .where.not(deletion_scheduled_for: nil)
                  .where(deletion_final_warning_sent_at: nil)
                  .where(deletion_scheduled_for: @now..1.day.after(@now))
      each_bounded(scope) do |user|
        guard(result, user) do
          UserMailer.deletion_final_warning(user).deliver_now
          user.update_column(:deletion_final_warning_sent_at, @now)
          result[:deletion_warnings] += 1
        end
      end
    end

    def purge_due(result)
      scope = User.where.not(deletion_scheduled_for: nil)
                  .where(deletion_scheduled_for: ...@now)
      each_bounded(scope) do |user|
        email = user.email
        locale = user.locale || 'nl'
        reason = user.deletion_reason || 'unknown'
        begin
          AccountErasureService.call!(user)
          UserMailer.deletion_completed(email, locale).deliver_now if reason == 'user_requested'
          result[:purged] += 1
        rescue AccountErasureService::PendingFinancialWork,
               AccountErasureService::InFlightAccountWork => e
          # The fence is doing its job; the account stays for a later sweep.
          result[:fenced] += 1
          Rails.logger.info("[RETENTION] purge deferred for user id=#{user.id}: #{e.class}")
        rescue StandardError => e
          result[:failed] += 1
          Rails.logger.error("[RETENTION] purge failed for user id=#{user.id}: #{e.class}")
        end
      end
    end
  end
end
