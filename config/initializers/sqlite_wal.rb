# frozen_string_literal: true

# Enable better SQLite concurrency so the app remains responsive during
# long-running operations. WAL allows concurrent readers during writes.
# Also set a reasonable `busy_timeout` and `synchronous` mode for throughput.
#
# IMPORTANT: These PRAGMAs must be applied per-connection, not just on the
# master process connection. In Puma cluster mode, each forked worker gets
# a new connection that needs its own PRAGMAs.
ActiveSupport.on_load(:active_record) do
  apply_sqlite_pragmas = lambda do |connection|
    raw = connection.respond_to?(:raw_connection) ? connection.raw_connection : connection
    raw.execute('PRAGMA journal_mode = WAL;')
    raw.execute('PRAGMA synchronous = NORMAL;')
    raw.execute('PRAGMA busy_timeout = 15000;')
  rescue StandardError => e
    Rails.logger.warn("SQLite PRAGMA setup skipped: #{e.class}: #{e.message}")
  end

  begin
    apply_sqlite_pragmas.call(ActiveRecord::Base.connection)
    Rails.logger.info('SQLite PRAGMAs applied: journal_mode=WAL, synchronous=NORMAL, busy_timeout=15000ms')

    # Apply PRAGMAs to every new connection checked out from the pool
    ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkout, :after do
      unless instance_variable_get(:@sqlite_pragmas_applied)
        apply_sqlite_pragmas.call(self)
        instance_variable_set(:@sqlite_pragmas_applied, true)
      end
    end
  rescue StandardError => e
    Rails.logger.warn("SQLite PRAGMA setup skipped: #{e.class}: #{e.message}")
  end
end
