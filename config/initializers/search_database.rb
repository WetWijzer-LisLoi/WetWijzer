# frozen_string_literal: true

# Attach the separate search database (FTS5 + ngram indexes) to the primary
# SQLite connection on boot. This is for the LawSearchService and other
# services that use qualified table references like `search.articles_fts`.
#
# NOTE: The LegalChatbotService uses a standalone SQLite3::Database connection
# for FTS queries - it does NOT use this ATTACH at all.
#
# IMPORTANT: We only ATTACH on the master connection at boot. For Puma cluster
# mode, the chatbot uses standalone connections. The checkout callback was
# removed because ATTACH inside a checkout triggers "cannot start a transaction
# within a transaction" errors that permanently poison worker connections.

Rails.application.config.after_initialize do
  search_db_path = ENV.fetch('SEARCH_DB_PATH', nil)
  search_db_path ||= Rails.root.join('storage', 'search.sqlite3').to_s

  # Skip attach when running write tasks (ngram refresh, etc.) - SQLite transactions
  # lock ALL attached databases and the search DB may not be writable by the cron user.
  next if ENV['SKIP_SEARCH_ATTACH'] == '1'

  next unless File.exist?(search_db_path)

  begin
    conn = ActiveRecord::Base.connection
    conn.raw_connection.execute("ATTACH DATABASE '#{search_db_path}' AS search")
    Rails.logger.info("[SearchDB] Attached #{search_db_path} as 'search'")
  rescue StandardError => e
    if e.message.include?('already')
      Rails.logger.info('[SearchDB] Already attached')
    else
      Rails.logger.warn("[SearchDB] Failed to attach search DB: #{e.message}")
    end
  end
end
