# frozen_string_literal: true

# WW-PRIV-10: one per-account boundary for every change to stored chatbot
# history and to the consent and key state that decides whether history may
# be stored. Each holder takes the account's row lock in the accounts
# database and keeps it only for the storage change itself, never across
# retrieval or provider work.
#
# A request captures the storage generation it was admitted under (the
# consent timestamp, renewed by every grant, and the zero-knowledge key
# material). A writer re-reads the locked account and writes only while the
# account is active, still consents and still has that generation; so a
# revoke and regrant cycle, or a switch of storage mode, fences work admitted
# before it, in standard storage too. Revocation takes the same lock, records
# the denial and deletes the history before it returns: a writer either
# committed before it (and its rows are deleted) or sees it and writes
# nothing.
#
# Accounts and chatbot history live in different databases; no transaction
# spans both. The lock orders the operations; the denial is committed in the
# accounts database even when the history deletion fails, so a retry can
# finish the cleanup while every writer stays fenced.
module ConversationStorageBoundary
  class Fenced < StandardError; end

  module_function

  # nil when the account does not consent.
  def generation(user)
    return nil unless user&.conversation_storage_consented?

    material = [user.conversation_storage_consented_at.utc.iso8601(6), user.key_derivation_salt,
                user.encrypted_master_key].join("\0")
    Digest::SHA256.hexdigest(material)
  end

  # The block's value, written under the lock; Fenced when the account no
  # longer allows storage under the generation the request was admitted with.
  def write(user, admitted:)
    User.transaction do
      account = User.lock.find_by(id: user.id)
      unless admitted && account&.active? && account.conversation_storage_consented? && generation(account) == admitted
        raise Fenced, 'conversation storage is no longer allowed for this request'
      end

      hold_write_gate!(account)
      yield account
    end
  end

  # A consent or key change, an explicit clear or deletion, serialized with
  # every writer and with the first paid dispatch of a question
  # (BillingReservation#admit_work_dispatch!, which takes the same gate).
  def change(user)
    User.transaction do
      account = User.lock.find(user.id)
      hold_write_gate!(account)
      yield account
    end
  end

  # The account's row lock is the gate on PostgreSQL (SELECT ... FOR UPDATE).
  # On SQLite that SELECT takes no lock at all; there the gate is the
  # database's single writer, which every holder takes the moment its
  # accounts transaction begins (the adapter's begin_db_transaction is BEGIN
  # IMMEDIATE) and keeps until it ends, so a second holder waits (the
  # adapter's busy timeout) or fails, never runs alongside. Nothing is
  # written merely to lock. A holder outside a transaction would hold no
  # gate at all, so that is refused.
  def hold_write_gate!(_account)
    connection = User.connection
    return unless connection.adapter_name.casecmp?('sqlite')
    return if connection.transaction_open?

    raise Fenced, 'the SQLite accounts gate is the open transaction; none is open'
  end

  # The limit of each wait the metadata admission of a question (its first
  # paid dispatch) makes: one for the lane connection acquisition below, and
  # separately one for the PostgreSQL row-lock wait of the accounts
  # transaction (BillingReservation.bound_lock_wait!) and one for the
  # statement and lock waits of the chatbot claim read (bounded_chatbot_read).
  # The admission as a whole is therefore bounded by the sum of its bounded
  # steps, not by this figure alone; each step is well inside the streaming
  # supervisor's patience, so a worker blocked in any of them ends on its
  # own and the request thread's settlement is not held behind it.
  METADATA_WAIT_LIMIT_MS = 5_000
  LANE_WAIT_SLICE_SECONDS = 0.25

  class LaneUnavailable < StandardError; end

  # Leases an accounts and a chatbot connection for the calling thread with a
  # bounded, cancellable wait, yields, and releases what it leased. The
  # pools' own checkout_timeout (30 s) would outlive the supervisor and, with
  # interrupts deferred over the admission, its kill; here the queue wait is
  # taken in short slices, each one re-reading the cancellation, and ends at
  # the limit. What is proven (test/controllers/api/chatbot_dispatch_fence_test.rb):
  # with every connection of a pool held elsewhere, a cancelled worker ends
  # at once and an uncancelled one at the limit, nothing is sent or charged,
  # and no lease is left behind. What is not: ActiveRecord's checkout(timeout)
  # bounds the wait in the pool's queue, not the framework's own connection
  # establishment, verification or maintenance once a connection is handed
  # over; those are not covered here and not claimed. A thread that already
  # holds a lane connection (the request thread of a JSON ask) keeps using it
  # and keeps it; nothing is acquired before a lock, so a refused acquisition
  # leaves no transaction behind. No pool, cap or configuration is changed:
  # this is one thread's own wait.
  def with_bounded_lane_connections(cancelled: nil, limit_ms: METADATA_WAIT_LIMIT_MS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (limit_ms / 1000.0)
    acquired = []
    begin
      [AccountRecord, ChatbotRecord].each do |lane|
        pool = lane.connection_pool
        next if pool.active_connection?

        attach_bounded_lease!(pool, deadline: deadline, cancelled: cancelled)
        acquired << pool
      end
      yield
    ensure
      acquired.each(&:release_connection)
    end
  end

  # One pool: wait in slices until a connection is checked out, the
  # cancellation is seen or the deadline passes, then make it the thread's
  # lease (what every ActiveRecord query on this thread uses) so the
  # admission's own reads and writes never wait for a checkout again.
  # release_connection (public) returns it. The lease registry is not public
  # API in ActiveRecord 8.1; this is the one private call, kept here.
  def attach_bounded_lease!(pool, deadline:, cancelled:)
    loop do
      raise LaneUnavailable, 'cancelled while waiting for a lane connection' if cancelled&.call == true

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise LaneUnavailable, 'lane connection wait limit reached' if remaining <= 0

      begin
        connection = pool.checkout([remaining, LANE_WAIT_SLICE_SECONDS].min)
      rescue ActiveRecord::ConnectionTimeoutError
        next
      end
      lease = pool.send(:connection_lease)
      lease.connection = connection
      lease.sticky = true
      return connection
    end
  end

  # A short chatbot-lane metadata read (the claim check) made while accounts
  # locks are held: on PostgreSQL its statement and row-lock waits are bounded
  # by SET LOCAL inside a chatbot transaction opened for it. On SQLite a read
  # never waits for a writer (WAL) beyond the adapter's busy timeout, and no
  # transaction is opened, since one would take the chatbot writer lock for a
  # read. The connection itself was leased by with_bounded_lane_connections,
  # so no checkout wait happens here.
  def bounded_chatbot_read(&)
    connection = ChatbotRecord.connection
    return yield unless connection.adapter_name.casecmp?('postgresql')

    ChatbotRecord.transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = #{METADATA_WAIT_LIMIT_MS}")
      connection.execute("SET LOCAL lock_timeout = #{METADATA_WAIT_LIMIT_MS}")
      yield
    end
  end
end
