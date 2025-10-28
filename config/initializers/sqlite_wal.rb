# frozen_string_literal: true

# Enable better SQLite concurrency so the app remains responsive during
# long-running backfills. WAL allows concurrent readers during writes.
# Also set a reasonable `busy_timeout` and `synchronous` mode for throughput.
ActiveSupport.on_load(:active_record) do
  adapter = ActiveRecord::Base.connection.adapter_name.to_s.downcase
  if adapter.start_with?('sqlite')
    conn = ActiveRecord::Base.connection
    conn.execute('PRAGMA journal_mode = WAL;')
    conn.execute('PRAGMA synchronous = NORMAL;')
    conn.execute('PRAGMA busy_timeout = 5000;')
    Rails.logger.info('SQLite PRAGMAs applied: journal_mode=WAL, synchronous=NORMAL, busy_timeout=5000ms')
  end
rescue StandardError => e
  Rails.logger.warn("SQLite PRAGMA setup skipped: #{e.class}: #{e.message}")
end
