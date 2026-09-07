# frozen_string_literal: true

# Durable admission marker for account-bound work.
#
# Browser and partner-request acquisition is guarded by users.active. Financial
# callbacks may instead acquire a lease for an existing, already-fenced user so
# a provider payment that won the race with deletion can be recorded and
# invoiced without granting new access. Both forms use one accounts-database
# INSERT ... SELECT, so account erasure either sees the lease or removes the
# user before new work is admitted. Normal completion deletes the row; only
# rows older than the application's hard work ceiling plus generous grace are
# stale.
class AccountRequestLease < AccountRecord
  STALE_AFTER = 5.minutes

  belongs_to :user

  validates :lease_token, presence: true, uniqueness: true
  validates :acquired_at, presence: true

  scope :for_user_id, ->(user_id) { where(user_id: user_id) }

  class << self
    def acquire_for_session!(session_token:, now: Time.current)
      return nil if session_token.blank?

      connection = self.connection
      acquire_guarded!(
        user_predicate: "session_token = #{connection.quote(session_token)} AND active = #{connection.quoted_true}",
        now: now
      )
    end

    def acquire_for_active_user_id!(user_id:, now: Time.current)
      connection = self.connection
      acquire_guarded!(
        user_predicate: "id = #{connection.quote(Integer(user_id))} AND active = #{connection.quoted_true}",
        now: now
      )
    end

    def acquire_for_existing_user_id!(user_id:, now: Time.current)
      connection = self.connection
      acquire_guarded!(
        user_predicate: "id = #{connection.quote(Integer(user_id))}",
        now: now
      )
    end

    def reconcile_stale_for_user!(user_or_id, now: Time.current)
      user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
      for_user_id(user_id).where(acquired_at: ...(now - STALE_AFTER)).delete_all
    end

    private

    # On SQLite the database-level write lock serializes lease acquisition
    # against the erasure transaction for free. PostgreSQL locks rows, so
    # the SELECT side must take FOR UPDATE to block behind an in-flight
    # erasure claim (FOR UPDATE is a syntax error on SQLite).
    def row_lock_clause
      connection.adapter_name.match?(/sqlite/i) ? '' : ' FOR UPDATE'
    end

    def acquire_guarded!(user_predicate:, now:)
      lease_token = SecureRandom.uuid
      connection = self.connection
      quoted_leases = connection.quote_table_name(table_name)
      quoted_users = connection.quote_table_name(User.table_name)
      quoted_token = connection.quote(lease_token)
      quoted_now = connection.quote(now)

      inserted = connection.update(<<~SQL.squish, 'Acquire account request lease')
        INSERT INTO #{quoted_leases}
          (lease_token, user_id, acquired_at, created_at, updated_at)
        SELECT #{quoted_token}, id, #{quoted_now}, #{quoted_now}, #{quoted_now}
        FROM #{quoted_users}
        WHERE #{user_predicate}
        LIMIT 1#{row_lock_clause}
      SQL

      return nil unless inserted == 1

      find_by!(lease_token: lease_token)
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end

  def release!
    self.class.where(id: id, lease_token: lease_token).delete_all.positive?
  end
end
