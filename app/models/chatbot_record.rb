# frozen_string_literal: true

# Abstract base for the standalone chatbot database (FBL-050). The
# connection comes from config/database.yml's chatbot entry - which
# preserves CHATBOT_DATABASE_PATH in live environments and the per-process
# CHATBOT_TEST_DATABASE isolation in tests - instead of the ad-hoc
# establish_connection that used to live inside ChatbotConversation.
class ChatbotRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :chatbot, reading: :chatbot }

  # WAL for concurrent read/write, as before. The database may not exist yet
  # during asset precompile; that is fine.
  #
  # Only when this lane is actually SQLite. On PostgreSQL the statement is not
  # merely useless, it is invalid SQL, and it logged a StatementInvalid warning
  # on every boot - noise that made the deploy log harder to read at exactly
  # the moment a deploy log matters.
  begin
    if connection.adapter_name.to_s.match?(/sqlite/i)
      connection.execute('PRAGMA journal_mode=WAL')
    end
  rescue StandardError => e
    Rails.logger.warn("[ChatbotRecord] WAL setup skipped: #{e.class}") if defined?(Rails)
  end
end
