# frozen_string_literal: true

# Searches the jurisprudence SQLite database for case law matching user criteria.
# Extracted from LawsFiltering concern to follow the same service pattern as
# LawSearchService and FisconetSearchService.
#
# Uses FTS5 when available, falls back to LIKE queries.
#
# @example
#   JurisprudenceSearchService.search(query: "discrimination", court: "Cass", year: "2024", locale: :fr)
class JurisprudenceSearchService
  DEFAULT_LIMIT = 20

  class << self
    # @param query [String, nil] Free-text search query
    # @param court [String, nil] Court name filter
    # @param year [String, nil] Year filter (YYYY)
    # @param locale [Symbol] :nl or :fr — determines language filter
    # @param limit [Integer] Max results
    # @return [Array<Hash>] Array of result hashes with :id, :case_number, :court, :decision_date, :summary, :source
    def search(query: nil, court: nil, year: nil, subject: nil, locale: I18n.locale, limit: DEFAULT_LIMIT, search_body: false)
      return [] unless db_path_exists?

      db = connection
      conditions, bind_params = build_conditions(db, query, court, year, locale, subject: subject, search_body: search_body)

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''
      sql = <<~SQL
        SELECT id, case_number, court, decision_date, summary
        FROM cases #{where_clause}
        ORDER BY decision_date DESC
        LIMIT #{limit.to_i}
      SQL

      db.execute(sql, bind_params).map do |row|
        { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], source: :jurisprudence }
      end
    rescue StandardError => e
      Rails.logger.error("JurisprudenceSearchService error: #{e.message}")
      []
    end

    private

    def db_path
      @db_path ||= ENV.fetch('JURISPRUDENCE_SOURCE_DB') { Rails.root.join('storage', 'jurisprudence.db').to_s }
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
        db.execute('SELECT 1 FROM cases_fts LIMIT 0')
        true
      rescue StandardError
        false
      end
    end

    def build_conditions(db, query, court, year, locale, subject: nil, search_body: false)
      conditions = []
      bind_params = []

      if query.present?
        fts_query = query.gsub(/["']/, '').strip
        if fts5_available?(db)
          # FTS5 always searches the full index (includes full_text)
          conditions << 'cases.id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?)'
          bind_params << fts_query
        elsif search_body
          # LIKE fallback with body search enabled
          conditions << '(case_number LIKE ? OR court LIKE ? OR full_text LIKE ?)'
          bind_params += ["%#{query}%", "%#{query}%", "%#{query}%"]
        else
          # LIKE fallback without body search (fast, title-only)
          conditions << '(case_number LIKE ? OR court LIKE ?)'
          bind_params += ["%#{query}%", "%#{query}%"]
        end
      end

      if court.present?
        conditions << 'court LIKE ?'
        bind_params << "%#{court}%"
      end

      if year.present?
        conditions << 'decision_date LIKE ?'
        bind_params << "#{year}-%"
      end

      if subject.present?
        conditions << 'subject_matter LIKE ?'
        bind_params << "%#{subject}%"
      end

      conditions << language_condition(locale)

      [conditions, bind_params]
    end

    def language_condition(locale)
      if locale.to_sym == :fr
        "(language_id = 2 OR case_number LIKE '%-FR')"
      else
        "(language_id = 1 OR case_number LIKE '%-NL')"
      end
    end
  end
end
