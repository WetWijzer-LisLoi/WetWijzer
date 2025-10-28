# frozen_string_literal: true

# Searches the parliamentary SQLite database for documents matching user criteria.
# Extracted from LawsFiltering concern to follow the same service pattern as
# LawSearchService, FisconetSearchService, and JurisprudenceSearchService.
#
# Uses FTS5 when available, falls back to LIKE queries.
#
# @example
#   ParliamentarySearchService.search(query: "klimaat", parliament: "Kamer", year: "2024")
class ParliamentarySearchService
  DEFAULT_LIMIT = 20

  class << self
    # @param query [String, nil] Free-text search query
    # @param parliament [String, nil] Parliament name filter
    # @param year [String, nil] Year filter (YYYY)
    # @param limit [Integer] Max results
    # @return [Array<Hash>] Array of result hashes
    def search(query: nil, parliament: nil, year: nil, doc_type: nil, lang: nil, limit: DEFAULT_LIMIT, search_body: false)
      return [] unless db_path_exists?

      db = connection
      conditions, bind_params = build_conditions(db, query, parliament, year, doc_type: doc_type, lang: lang, search_body: search_body)

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''
      sql = <<~SQL
        SELECT id, title, parliament, dossier_number, document_date, document_number, substr(content, 1, 120)
        FROM documents #{where_clause}
        ORDER BY document_date DESC
        LIMIT #{limit.to_i}
      SQL

      db.execute(sql, bind_params).map do |row|
        display_title = row[1].presence || row[5].presence || row[3]
        content_preview = row[6].to_s.strip.gsub(/\s+/, ' ').presence
        {
          id: row[0], title: display_title, parliament: row[2], dossier_number: row[3],
          date: row[4], document_number: row[5], content_preview: content_preview, source: :parliamentary
        }
      end
    rescue StandardError => e
      Rails.logger.error("ParliamentarySearchService error: #{e.message}")
      []
    end

    private

    def db_path
      @db_path ||= ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    end

    def db_path_exists?
      File.exist?(db_path)
    end

    def connection
      @connection ||= SQLite3::Database.new(db_path)
    end

    def fts5_available?(db)
      return @fts5_available unless @fts5_available.nil?

      @fts5_available = begin
        db.execute('SELECT 1 FROM documents_fts LIMIT 0')
        true
      rescue StandardError
        false
      end
    end

    def build_conditions(db, query, parliament, year, doc_type: nil, lang: nil, search_body: false)
      conditions = []
      bind_params = []

      if query.present?
        if fts5_available?(db)
          # FTS5 always searches the full index (includes content)
          conditions << 'id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)'
          bind_params << query
        elsif search_body
          # LIKE fallback with body search enabled
          conditions << '(title LIKE ? OR content LIKE ? OR dossier_number LIKE ?)'
          bind_params += ["%#{query}%", "%#{query}%", "%#{query}%"]
        else
          # LIKE fallback without body search (fast, title-only)
          conditions << '(title LIKE ? OR dossier_number LIKE ?)'
          bind_params += ["%#{query}%", "%#{query}%"]
        end
      end

      if parliament.present?
        conditions << 'parliament = ?'
        bind_params << parliament
      end

      if year.present?
        conditions << "strftime('%Y', document_date) = ?"
        bind_params << year.to_s
      end

      if doc_type.present?
        conditions << 'document_type = ?'
        bind_params << doc_type
      end

      if lang.present?
        conditions << 'language = ?'
        bind_params << lang
      end

      [conditions, bind_params]
    end
  end
end
