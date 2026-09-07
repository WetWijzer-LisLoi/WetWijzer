# frozen_string_literal: true

require 'fileutils'

# Small fail-closed counter primitive for admission controls stored in
# Rails.cache. Redis/Memcached keep their native atomic counters. FileStore
# needs a stable, separate flock because its value file is replaced on write;
# locking that replaceable inode does not serialize all Puma processes.
class AtomicCacheCounter
  class Unavailable < StandardError; end

  Reservation = Struct.new(:key, :value, :limit, :amount, :expires_in, keyword_init: true)

  PROCESS_MUTEX = Mutex.new
  FILE_LOCK_NAME = '.wetwijzer-atomic-cache-counter.lock'

  class << self
    def increment!(key, amount: 1, expires_in:)
      amount = positive_integer!(amount, 'amount')
      expires_in = positive_integer!(expires_in, 'expires_in')

      mutate!(key, amount, expires_in: expires_in)
    end

    # Atomically admits at most +limit+ reservations. nil means the quota was
    # already full; cache failures raise Unavailable and callers must deny the
    # operation rather than proceeding without accounting.
    def try_reserve!(key, limit:, amount: 1, expires_in:)
      limit = Integer(limit)
      amount = positive_integer!(amount, 'amount')
      expires_in = positive_integer!(expires_in, 'expires_in')
      raise ArgumentError, 'limit must not be negative' if limit.negative?

      cache = Rails.cache
      value = if file_store?(cache)
                with_file_store_lock(cache) do
                  current = Integer(cache.read(key) || 0)
                  next nil if current + amount > limit

                  updated = current + amount
                  raise Unavailable, 'cache write failed' unless cache.write(key, updated, expires_in: expires_in)

                  updated
                end
              else
                updated = native_mutate!(cache, key, amount, expires_in: expires_in)
                if updated > limit
                  # The increment is the serialization point. Roll it back
                  # before telling the caller to use its overage path.
                  native_mutate!(cache, key, -amount, expires_in: expires_in)
                  nil
                else
                  updated
                end
              end

      return nil if value.nil?

      Reservation.new(
        key: key,
        value: value,
        limit: limit,
        amount: amount,
        expires_in: expires_in
      )
    rescue Unavailable
      raise
    rescue StandardError => error
      log_failure(error)
      raise Unavailable, 'cache counter unavailable'
    end

    private

    def mutate!(key, amount, expires_in:)
      cache = Rails.cache
      value = if file_store?(cache)
                with_file_store_lock(cache) do
                  updated = [Integer(cache.read(key) || 0) + amount, 0].max
                  raise Unavailable, 'cache write failed' unless cache.write(key, updated, expires_in: expires_in)

                  updated
                end
              else
                native_mutate!(cache, key, amount, expires_in: expires_in)
              end
      Integer(value)
    rescue Unavailable
      raise
    rescue StandardError => error
      log_failure(error)
      raise Unavailable, 'cache counter unavailable'
    end

    def native_mutate!(cache, key, amount, expires_in:)
      # MemoryStore and some adapter implementations do not create a missing
      # key on increment. Establish the TTL/value without overwriting a
      # concurrent creator; the following native mutation is the serialization
      # point for stores whose increment/decrement primitive is atomic.
      cache.write(key, 0, expires_in: expires_in, unless_exist: true)
      updated = if amount.negative?
                  cache.decrement(key, -amount, expires_in: expires_in)
                else
                  cache.increment(key, amount, expires_in: expires_in)
                end
      raise Unavailable, 'cache mutation returned no value' if updated.nil?

      updated = Integer(updated)
      return updated unless updated.negative?

      # Some stores initialize a missing decrement below zero. Clamp it while
      # preserving any concurrent positive increments.
      corrected = cache.increment(key, -updated, expires_in: expires_in)
      raise Unavailable, 'cache underflow correction failed' if corrected.nil?

      Integer(corrected)
    end

    def with_file_store_lock(cache)
      PROCESS_MUTEX.synchronize do
        # Keep the stable lock outside FileStore's own directory: cache.clear
        # is allowed to remove every file below cache_path.
        lock_directory = File.dirname(cache.cache_path)
        FileUtils.mkdir_p(lock_directory)
        lock_path = File.join(lock_directory, FILE_LOCK_NAME)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          raise Unavailable, 'cache lock unavailable' unless lock.flock(File::LOCK_EX)

          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end
    end

    def file_store?(cache)
      cache.is_a?(ActiveSupport::Cache::FileStore)
    end

    def positive_integer!(value, name)
      integer = if value.is_a?(ActiveSupport::Duration)
                  value.to_i
                else
                  Integer(value)
                end
      raise ArgumentError, "#{name} must be positive" unless integer.positive?

      integer
    end

    def log_failure(error)
      Rails.logger.error("Atomic cache counter unavailable: #{error.class}: #{error.message}")
    end
  end
end
