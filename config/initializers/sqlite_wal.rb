# frozen_string_literal: true

# Enable better SQLite concurrency so the app remains responsive during
# long-running operations. WAL allows concurrent readers during writes.
#
# IMPORTANT: These PRAGMAs must be applied per-connection, not just on the
# master process connection. In Puma cluster mode, each forked worker gets
# a new connection that needs its own PRAGMAs.
#
# The statements, the measurements behind them and the adapter check live in
# SqlitePragmas. The checkout callback below fires for EVERY adapter, and four
# of this app's lanes are PostgreSQL - see the module for what that used to log.
require Rails.root.join('lib/sqlite_pragmas')

ActiveSupport.on_load(:active_record) do
  begin
    Rails.logger.info(SqlitePragmas.summary) if SqlitePragmas.apply(ActiveRecord::Base.connection)

    # Apply PRAGMAs to every new connection checked out from the pool. The flag
    # is set for non-SQLite adapters too, so a PostgreSQL connection asks the
    # question once instead of on every checkout.
    ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkout, :after do
      unless instance_variable_get(:@sqlite_pragmas_applied)
        SqlitePragmas.apply(self)
        instance_variable_set(:@sqlite_pragmas_applied, true)
      end
    end
  rescue StandardError => e
    Rails.logger.warn("SQLite PRAGMA setup skipped: #{e.class}: #{e.message}")
  end
end
