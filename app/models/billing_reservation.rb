# frozen_string_literal: true

# Durable chatbot-request accounting in the accounts database. The legacy class
# name is retained because partner and browser traffic share the same ledger.
# The reservation row and matching credit/quota mutation always commit in one
# transaction, so settlement/refund transitions can be retried after exceptions.
class BillingReservation < AccountRecord
  # Renamed from PartnerBillingReservation on 2026-08-08: this was never partner-specific -
  # it backs WetWijzer\'s own billing. The TABLE keeps its original name so the
  # rename needs no migration and touches no data.

  class ReservationUnavailable < StandardError; end
  class RefundFailed < StandardError; end
  class ReconciliationIncomplete < StandardError; end

  # LegalChatbotService has a hard 180-second ceiling. Five minutes leaves a
  # generous scheduler/logging grace while still recovering abandoned rows on
  # the user's next partner request.
  STALE_AFTER = 5.minutes
  RECONCILIATION_BATCH_SIZE = 25
  GLOBAL_RECONCILIATION_BATCH_SIZE = 100
  ANALYTICS_RECONCILIATION_BATCH_SIZE = 100
  BROWSER_APP_PREFIX = 'browser_chatbot:'
  BROWSER_APP_LIKE_PATTERN = "#{ActiveRecord::Base.sanitize_sql_like(BROWSER_APP_PREFIX)}%"

  CREDIT_KIND = 'credits'
  DEEP_QUOTA_KIND = 'deep_quota'
  INCLUDED_QUOTA_KIND = 'included_quota'
  KINDS = [CREDIT_KIND, DEEP_QUOTA_KIND, INCLUDED_QUOTA_KIND].freeze

  RESERVED_STATUS = 'reserved'
  SETTLED_STATUS = 'settled'
  REFUNDED_STATUS = 'refunded'
  STATUSES = [RESERVED_STATUS, SETTLED_STATUS, REFUNDED_STATUS].freeze

  DELIVERY_PENDING_STATE = 'pending'
  DELIVERY_COMPLETED_STATE = 'completed'
  DELIVERY_ABORTED_STATE = 'aborted'
  DELIVERY_STATES = [DELIVERY_PENDING_STATE, DELIVERY_COMPLETED_STATE, DELIVERY_ABORTED_STATE].freeze

  belongs_to :user

  before_validation :assign_reservation_token, on: :create

  validates :reservation_token, presence: true, uniqueness: true
  validates :reservation_kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :delivery_state, inclusion: { in: DELIVERY_STATES }, allow_nil: true
  validates :delivery_token, :delivery_started_at, presence: true, if: -> { delivery_state.present? }
  validates :quota_month, format: { with: /\A\d{4}-(?:0[1-9]|1[0-2])\z/ }, if: :quota_limited?
  validates :quota_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, if: :deep_quota?
  validates :intelligence_level, presence: true, if: :included_quota?

  scope :unsettled, -> { where(status: RESERVED_STATUS) }
  scope :settled_credits, -> { where(status: SETTLED_STATUS, reservation_kind: CREDIT_KIND) }
  scope :browser_chat, -> { where("app LIKE ? ESCAPE '\\'", BROWSER_APP_LIKE_PATTERN) }
  scope :awaiting_analytics_projection, -> { where(analytics_projected_at: nil) }

  def self.reconcile_stale_for_user!(user, now: Time.current)
    relation = stale_reconciliation_scope(now: now).where(user_id: user.id)
    reservation_ids = relation.limit(RECONCILIATION_BATCH_SIZE).pluck(:id)

    reconciled = reservation_ids.count do |reservation_id|
      reservation = find(reservation_id)
      if reservation.included_quota? || reservation.delivery_pending?
        reservation.settle!
      else
        reservation.refund!(reason: 'stale_unsettled_reconciliation')
      end
    end

    # Never let a user start more provider work while an older unresolved
    # backlog remains. The bounded batch prevents one request from doing
    # unbounded cleanup; a later retry continues with the next batch.
    if relation.exists?
      raise ReconciliationIncomplete,
            "more than #{RECONCILIATION_BATCH_SIZE} stale partner reservations require reconciliation"
    end

    user.reload if reconciled.positive?
    reconciled
  end

  # Periodic bounded recovery for idle accounts. Each reservation performs its
  # own idempotent CAS/transaction, so one failed row does not roll back rows
  # already repaired. A remaining backlog is reported and left for the next
  # scheduled batch rather than making the job unbounded.
  def self.reconcile_stale!(now: Time.current, limit: GLOBAL_RECONCILIATION_BATCH_SIZE)
    limit = Integer(limit)
    raise ArgumentError, 'reconciliation limit must be positive' unless limit.positive?

    relation = stale_reconciliation_scope(now: now)
    reservation_ids = relation.limit(limit).pluck(:id)
    reconciled = 0
    failed = 0

    reservation_ids.each do |reservation_id|
      reservation = find_by(id: reservation_id)
      next unless reservation&.reserved?

      outcome = if reservation.included_quota? || reservation.delivery_pending?
                  reservation.settle!
                else
                  reservation.refund!(reason: 'global_stale_reconciliation')
                end
      reconciled += 1 if outcome
    rescue StandardError => e
      failed += 1
      Rails.logger.error(
        "Stale billing reservation reconciliation failed " \
        "(reservation_id=#{reservation_id}, error=#{e.class})"
      )
    end

    {
      selected: reservation_ids.length,
      reconciled: reconciled,
      failed: failed,
      backlog: relation.exists?
    }
  end

  # Deterministically rebuild the analytics projection from the accounts
  # ledger. The projected marker lives beside the authoritative settlement, so
  # a crash after either database write is safe to retry without duplication.
  def self.reconcile_settled_browser_analytics!(limit: ANALYTICS_RECONCILIATION_BATCH_SIZE)
    reservation_ids = settled_credits.browser_chat.awaiting_analytics_projection
                                     .order(:settled_at, :id)
                                     .limit(limit)
                                     .pluck(:id)
    project_analytics_reservation_ids!(reservation_ids)
  end

  def self.reconcile_settled_browser_analytics_for_user!(user, limit: RECONCILIATION_BATCH_SIZE)
    relation = settled_credits.browser_chat.awaiting_analytics_projection
                              .where(user_id: user.id)
                              .order(:settled_at, :id)
    reservation_ids = relation.limit(limit).pluck(:id)
    projected = project_analytics_reservation_ids!(reservation_ids)

    if relation.exists?
      raise ReconciliationIncomplete,
            "more than #{limit} settled browser reservations require analytics projection"
    end

    projected
  end

  # Revenue/reporting callers that need the authoritative amount should use the
  # settled ledger rather than trusting the eventually consistent projection.
  def self.settled_credit_total(from: nil, to: nil, browser_only: false, user: nil)
    relation = settled_credits
    relation = relation.browser_chat if browser_only
    relation = relation.where(user_id: user.id) if user
    relation = relation.where(settled_at: from...) if from
    relation = relation.where(settled_at: ...to) if to
    relation.sum(:amount)
  end

  def self.reserve_credits!(user:, amount:, app:, intelligence_level:, model:)
    amount = Integer(amount)
    raise ArgumentError, 'credit reservation amount must be positive' unless amount.positive?

    transaction do
      reservation = create!(
        user: user,
        reservation_kind: CREDIT_KIND,
        amount: amount,
        app: app,
        intelligence_level: intelligence_level,
        model: model
      )

      # Account erasure fences active=false in this same database. Put that
      # fence and the balance predicate in the deduction's single guarded UPDATE
      # so admission cannot race between a separate active? read and mutation.
      updated = User.where(id: user.id, active: true)
                    .where('credits >= ?', amount)
                    .update_all(
                      [
                        'credits = credits - ?, credit_balance_version = credit_balance_version + 1, updated_at = ?',
                        amount,
                        Time.current
                      ]
                    )
      unless updated == 1
        raise ReservationUnavailable, 'insufficient credits'
      end

      user.reload
      user.increment_usage!
      reservation
    end
  rescue ReservationUnavailable
    nil
  end

  def self.reserve_deep_quota!(user:, quota_month:, quota_generation:, app:, model:)
    month_start, next_month_start = quota_window(quota_month)

    transaction do
      reservation = create!(
        user: user,
        reservation_kind: DEEP_QUOTA_KIND,
        app: app,
        model: model,
        quota_month: quota_month,
        quota_generation: quota_generation
      )

      updated = User.where(id: user.id, active: true, deep_analysis_quota_generation: quota_generation)
                    .where(deep_analyses_reset_at: month_start...next_month_start)
                    .where('COALESCE(deep_analyses_used, 0) < COALESCE(monthly_deep_limit, 0)')
                    .update_all(
                      [
                        'deep_analyses_used = COALESCE(deep_analyses_used, 0) + 1, updated_at = ?',
                        Time.current
                      ]
                    )
      raise ReservationUnavailable, 'deep-analysis quota unavailable' unless updated == 1

      user.reload
      reservation
    end
  rescue ReservationUnavailable
    nil
  end

  # Monthly partner inclusion is an admitted-attempt ledger, not a refundable
  # result counter. One guarded INSERT ... SELECT both verifies active=true and
  # enforces the per-user/month/intelligence limit. Every admitted row counts,
  # regardless of app or terminal status, so cache loss, provider failure and a
  # killed worker can never grant the slot again.
  def self.reserve_included_quota!(user:, limit:, quota_month:, app:, intelligence_level:, model:, now: Time.current)
    user_id = Integer(user.id)
    limit = Integer(limit)
    intelligence_level = intelligence_level.to_s
    raise ArgumentError, 'included quota intelligence level is required' if intelligence_level.blank?

    quota_window(quota_month)
    return nil unless limit.positive?

    reservation_token = SecureRandom.uuid
    connection = self.connection
    reservations = connection.quote_table_name(table_name)
    users = connection.quote_table_name(User.table_name)
    values = {
      token: connection.quote(reservation_token),
      kind: connection.quote(INCLUDED_QUOTA_KIND),
      status: connection.quote(RESERVED_STATUS),
      app: connection.quote(app.to_s),
      intelligence: connection.quote(intelligence_level),
      model: connection.quote(model.to_s),
      month: connection.quote(quota_month.to_s),
      now: connection.quote(now),
      user_id: connection.quote(user_id),
      limit: connection.quote(limit)
    }

    inserted = connection.update(<<~SQL.squish, 'Reserve included partner quota')
      INSERT INTO #{reservations}
        (reservation_token, user_id, reservation_kind, status, amount, app,
         intelligence_level, model, quota_month, quota_generation, created_at, updated_at)
      SELECT #{values[:token]}, users.id, #{values[:kind]}, #{values[:status]}, 0,
             #{values[:app]}, #{values[:intelligence]}, #{values[:model]},
             #{values[:month]},
             (
               SELECT COALESCE(MAX(included_slot.quota_generation), 0) + 1
               FROM #{reservations} included_slot
               WHERE included_slot.user_id = users.id
                 AND included_slot.reservation_kind = #{values[:kind]}
                 AND included_slot.quota_month = #{values[:month]}
                 AND included_slot.intelligence_level = #{values[:intelligence]}
             ),
             #{values[:now]}, #{values[:now]}
      FROM #{users} users
      WHERE users.id = #{values[:user_id]} AND users.active = #{connection.quoted_true}
        AND (
          SELECT COUNT(*)
          FROM #{reservations} included
          WHERE included.user_id = users.id
            AND included.reservation_kind = #{values[:kind]}
            AND included.quota_month = #{values[:month]}
            AND included.intelligence_level = #{values[:intelligence]}
        ) < #{values[:limit]}
      LIMIT 1
    SQL

    return nil unless inserted == 1

    find_by!(reservation_token: reservation_token)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def self.included_quota_used(user:, quota_month:, intelligence_level:)
    where(
      user_id: user.id,
      reservation_kind: INCLUDED_QUOTA_KIND,
      quota_month: quota_month.to_s,
      intelligence_level: intelligence_level.to_s
    ).count
  end

  # Begin an owner-scoped delivery before any answer/history persistence. A
  # killed worker leaves a durable `pending` row which generic recovery settles
  # rather than refunding a possibly delivered or retrievable answer. Only the
  # holder of the random token may abort after proving non-delivery.
  def begin_delivery!(now: Time.current)
    token = delivery_token.presence || SecureRandom.uuid
    transitioned = self.class.where(
      id: id,
      status: RESERVED_STATUS,
      delivery_state: nil,
      delivery_token: nil
    ).update_all(
      delivery_state: DELIVERY_PENDING_STATE,
      delivery_token: token,
      delivery_started_at: now,
      updated_at: now
    )
    if transitioned == 1
      self.delivery_state = DELIVERY_PENDING_STATE
      self.delivery_token = token
      self.delivery_started_at = now
      self.updated_at = now
      return token
    end

    persisted_status, persisted_state, persisted_token, persisted_started_at = self.class.where(id: id).pick(
      :status,
      :delivery_state,
      :delivery_token,
      :delivery_started_at
    )
    self.status = persisted_status if persisted_status
    self.delivery_state = persisted_state
    self.delivery_token = persisted_token
    self.delivery_started_at = persisted_started_at
    return token if persisted_token == token &&
                    [RESERVED_STATUS, SETTLED_STATUS].include?(persisted_status) &&
                    [DELIVERY_PENDING_STATE, DELIVERY_COMPLETED_STATE].include?(persisted_state)

    nil
  end

  def complete_delivery!(token:, now: Time.current)
    token = token.to_s
    raise RefundFailed, 'delivery token is required' if token.blank?

    transitioned = self.class.where(
      id: id,
      status: RESERVED_STATUS,
      delivery_state: DELIVERY_PENDING_STATE,
      delivery_token: token
    ).update_all(
      status: SETTLED_STATUS,
      delivery_state: DELIVERY_COMPLETED_STATE,
      settled_at: now,
      updated_at: now
    )
    if transitioned == 1
      self.status = SETTLED_STATUS
      self.delivery_state = DELIVERY_COMPLETED_STATE
      self.delivery_token = token
      self.settled_at = now
      self.updated_at = now
      return true
    end

    persisted_status, persisted_state, persisted_token = self.class.where(id: id).pick(
      :status,
      :delivery_state,
      :delivery_token
    )
    self.status = persisted_status if persisted_status
    self.delivery_state = persisted_state
    self.delivery_token = persisted_token
    persisted_status == SETTLED_STATUS &&
      persisted_state == DELIVERY_COMPLETED_STATE &&
      ActiveSupport::SecurityUtils.secure_compare(persisted_token.to_s, token)
  end

  # The caller chooses its delivery boundary (the browser flow settles only
  # after render/write succeeds). Calling settle! again is harmless; a
  # reservation already refunded cannot settle.
  def settle!
    settled_time = Time.current
    transitioned = self.class.where(id: id, status: RESERVED_STATUS).update_all(
      [
        'status = ?, settled_at = ?, delivery_state = CASE WHEN delivery_state = ? THEN ? ELSE delivery_state END, updated_at = ?',
        SETTLED_STATUS,
        settled_time,
        DELIVERY_PENDING_STATE,
        DELIVERY_COMPLETED_STATE,
        settled_time
      ]
    )
    if transitioned == 1
      self.status = SETTLED_STATUS
      self.delivery_state = DELIVERY_COMPLETED_STATE if delivery_state == DELIVERY_PENDING_STATE
      self.settled_at = settled_time
      self.updated_at = settled_time
      return true
    end

    # A zero-row CAS may be an idempotent retry. Only that path needs a read;
    # never let a fallible reload after a successful commit turn delivery into
    # an apparent settlement failure.
    persisted_status = self.class.where(id: id).pick(:status)
    self.status = persisted_status if persisted_status
    persisted_status == SETTLED_STATUS
  end

  # The state transition and inverse balance/quota mutation share one accounts
  # transaction. If the inverse mutation raises before commit, the row remains
  # `reserved`, making a later refund! call safe and necessary. After commit,
  # further calls are no-ops and can never apply a second refund.
  def refund!(reason: nil)
    # Included attempts are intentionally non-refundable once admitted. Treat a
    # generic refund/recovery call as terminal settlement, never slot release.
    return settle! if included_quota?
    refunded_time = nil
    persisted_status = nil
    persisted_delivery_state = nil
    persisted_delivery_token = nil
    retained_delivery = false
    retained_settled_at = nil
    outcome = self.class.transaction do
      persisted_status, persisted_delivery_state, persisted_delivery_token = self.class.where(id: id).lock.pick(
        :status,
        :delivery_state,
        :delivery_token
      )

      case persisted_status
      when REFUNDED_STATUS
        true
      when SETTLED_STATUS
        false
      when RESERVED_STATUS
        if persisted_delivery_state == DELIVERY_PENDING_STATE
          settled_time = Time.current
          transitioned = self.class.where(
            id: id,
            status: RESERVED_STATUS,
            delivery_state: DELIVERY_PENDING_STATE,
            delivery_token: persisted_delivery_token
          ).update_all(
            status: SETTLED_STATUS,
            delivery_state: DELIVERY_COMPLETED_STATE,
            settled_at: settled_time,
            updated_at: settled_time
          )
          raise RefundFailed, 'delivery intent changed during settlement' unless transitioned == 1

          retained_delivery = true
          retained_settled_at = settled_time
          next false
        end

        unless persisted_delivery_state.nil? && persisted_delivery_token.nil?
          raise RefundFailed, "invalid reserved delivery state: #{persisted_delivery_state.inspect}"
        end

        refunded_time = Time.current
        transitioned = self.class.where(
          id: id,
          status: RESERVED_STATUS,
          delivery_state: nil,
          delivery_token: nil
        ).update_all(
          status: REFUNDED_STATUS,
          refunded_at: refunded_time,
          refund_reason: reason.to_s.first(100).presence,
          updated_at: refunded_time
        )
        raise RefundFailed, 'reservation state changed during refund' unless transitioned == 1

        credit? ? apply_credit_refund! : apply_deep_quota_release!
        true
      else
        raise RefundFailed, "unknown reservation state: #{persisted_status.inspect}"
      end
    end

    if outcome
      self.status = REFUNDED_STATUS
      self.refunded_at = refunded_time if refunded_time
      self.refund_reason = reason.to_s.first(100).presence if refunded_time
      self.updated_at = refunded_time if refunded_time
    elsif persisted_status == SETTLED_STATUS
      self.status = SETTLED_STATUS
    elsif retained_delivery
      self.status = SETTLED_STATUS
      self.delivery_state = DELIVERY_COMPLETED_STATE
      self.settled_at = retained_settled_at
    end
    outcome
  end

  # Exact inverse for a proven persistence/render failure. The random owner
  # token prevents stale instances, generic rescues and other requests from
  # clearing a pending delivery that may already be user-visible.
  def abort_delivery!(token:, reason: nil)
    token = token.to_s
    raise RefundFailed, 'delivery token is required' if token.blank?

    refunded_time = nil
    persisted_status = nil
    outcome = self.class.transaction do
      persisted_status, persisted_state, persisted_token = self.class.where(id: id).lock.pick(
        :status,
        :delivery_state,
        :delivery_token
      )

      case persisted_status
      when REFUNDED_STATUS
        persisted_state == DELIVERY_ABORTED_STATE &&
          ActiveSupport::SecurityUtils.secure_compare(persisted_token.to_s, token)
      when SETTLED_STATUS
        false
      when RESERVED_STATUS
        unless persisted_state == DELIVERY_PENDING_STATE &&
               ActiveSupport::SecurityUtils.secure_compare(persisted_token.to_s, token)
          raise RefundFailed, 'delivery intent is not owned by this abort token'
        end

        refunded_time = Time.current
        transitioned = self.class.where(
          id: id,
          status: RESERVED_STATUS,
          delivery_state: DELIVERY_PENDING_STATE,
          delivery_token: token
        ).update_all(
          status: REFUNDED_STATUS,
          delivery_state: DELIVERY_ABORTED_STATE,
          refunded_at: refunded_time,
          refund_reason: reason.to_s.first(100).presence,
          updated_at: refunded_time
        )
        raise RefundFailed, 'delivery state changed during failed-delivery refund' unless transitioned == 1

        credit? ? apply_credit_refund! : apply_deep_quota_release!
        true
      else
        raise RefundFailed, "unknown reservation state: #{persisted_status.inspect}"
      end
    end

    if outcome
      self.status = REFUNDED_STATUS
      self.delivery_state = DELIVERY_ABORTED_STATE
      self.delivery_token = token
      self.refunded_at = refunded_time if refunded_time
      self.refund_reason = reason.to_s.first(100).presence if refunded_time
      self.updated_at = refunded_time if refunded_time
    elsif persisted_status == SETTLED_STATUS
      self.status = SETTLED_STATUS
    end
    outcome
  end

  def project_analytics!(analytic: nil)
    unless credit? && settled? && app.to_s.start_with?(BROWSER_APP_PREFIX)
      raise ArgumentError, 'only settled browser credit reservations can be projected'
    end
    return true if analytics_projected_at.present?

    projection_lease = AccountRequestLease.acquire_for_active_user_id!(user_id: user_id)
    return false unless projection_lease

    begin
      ChatbotAnalytic.project_settled_billing_reservation!(self, analytic: analytic)

      projected_time = Time.current
      transitioned = self.class.where(
        id: id,
        status: SETTLED_STATUS,
        analytics_projected_at: nil
      ).update_all(analytics_projected_at: projected_time, updated_at: projected_time)
      if transitioned == 1
        self.analytics_projected_at = projected_time
        self.updated_at = projected_time
        return true
      end

      persisted_status, persisted_projection = self.class.where(id: id).pick(:status, :analytics_projected_at)
      self.status = persisted_status if persisted_status
      self.analytics_projected_at = persisted_projection if persisted_projection
      persisted_status == SETTLED_STATUS && persisted_projection.present?
    ensure
      projection_lease.release!
    end
  end

  def credit?
    reservation_kind == CREDIT_KIND
  end

  def deep_quota?
    reservation_kind == DEEP_QUOTA_KIND
  end

  def included_quota?
    reservation_kind == INCLUDED_QUOTA_KIND
  end

  def delivery_accepted?
    delivery_pending?
  end

  def delivery_pending?
    reserved? && delivery_state == DELIVERY_PENDING_STATE && delivery_token.present?
  end

  def quota_limited?
    deep_quota? || included_quota?
  end

  def reserved?
    status == RESERVED_STATUS
  end

  def settled?
    status == SETTLED_STATUS
  end

  def refunded?
    status == REFUNDED_STATUS
  end

  private

  def self.stale_reconciliation_scope(now: Time.current)
    cutoff = now - STALE_AFTER
    unsettled.where(
      '(delivery_state IS NULL AND created_at < :cutoff) OR ' \
      '(delivery_state = :pending AND delivery_started_at < :cutoff)',
      cutoff: cutoff,
      pending: DELIVERY_PENDING_STATE
    ).order(Arel.sql('COALESCE(delivery_started_at, created_at) ASC'), :id)
  end

  private_class_method :stale_reconciliation_scope

  def self.project_analytics_reservation_ids!(reservation_ids)
    reservation_ids.count do |reservation_id|
      find(reservation_id).project_analytics!
    end
  end

  private_class_method :project_analytics_reservation_ids!

  def self.quota_window(quota_month)
    month = Date.strptime(quota_month.to_s, '%Y-%m')
    month_start = Time.zone.local(month.year, month.month, 1).beginning_of_day
    [month_start, month_start.next_month]
  rescue Date::Error
    raise ArgumentError, "invalid quota month: #{quota_month.inspect}"
  end

  private_class_method :quota_window

  def assign_reservation_token
    self.reservation_token ||= SecureRandom.uuid
  end

  def apply_credit_refund!
    refund_user = User.find_by(id: user_id)
    raise RefundFailed, 'reservation user no longer exists' unless refund_user

    refund_user.add_credits!(amount)
  end

  def apply_deep_quota_release!
    month_start, next_month_start = self.class.send(:quota_window, quota_month)
    current_state = User.where(id: user_id).pick(:deep_analysis_quota_generation, :deep_analyses_reset_at)
    return unless current_state

    current_generation, current_reset_at = current_state
    return unless current_generation.to_i == quota_generation.to_i
    return unless current_reset_at && current_reset_at >= month_start && current_reset_at < next_month_start

    updated = User.where(id: user_id, deep_analysis_quota_generation: quota_generation)
                  .where(deep_analyses_reset_at: month_start...next_month_start)
                  .where('COALESCE(deep_analyses_used, 0) > 0')
                  .update_all(
                    [
                      'deep_analyses_used = deep_analyses_used - 1, updated_at = ?',
                      Time.current
                    ]
                  )
    raise RefundFailed, 'deep-analysis quota release underflow' unless updated == 1
  end
end
