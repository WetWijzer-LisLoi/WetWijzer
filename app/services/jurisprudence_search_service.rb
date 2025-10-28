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
  DEFAULT_PER_PAGE = 20
  SearchResult = Struct.new(:results, :total_count, keyword_init: true)

  class << self
    # @param query [String, nil] Free-text search query
    # @param court [String, nil] Court name filter
    # @param year [String, nil] Year filter (YYYY)
    # @param locale [Symbol] :nl or :fr - determines language filter
    # @param page [Integer] Current page (1-indexed)
    # @param per_page [Integer] Results per page
    # @param sort [String] Sort order: date_desc, date_asc
    # @return [SearchResult] Struct with :results array and :total_count
    def search(query: nil, court: nil, year: nil, subject: nil, locale: I18n.locale,
               search_body: false, page: 1, per_page: DEFAULT_PER_PAGE, sort: 'date_desc')
      return SearchResult.new(results: [], total_count: 0) unless db_path_exists?

      db = connection
      conditions, bind_params = build_conditions(db, query, court, year, locale, subject: subject, search_body: search_body)

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''

      # Get total count
      count_sql = "SELECT COUNT(*) FROM cases #{where_clause}"
      total = db.get_first_value(count_sql, bind_params).to_i

      # Sorting
      order = case sort.to_s
              when 'date_asc' then 'decision_date ASC'
              else 'decision_date DESC'
              end

      # Pagination
      safe_page = [page.to_i, 1].max
      safe_per_page = per_page.to_i.clamp(1, 200)
      offset = (safe_page - 1) * safe_per_page

      sql = <<~SQL
        SELECT id, case_number, court, decision_date, summary
        FROM cases #{where_clause}
        ORDER BY #{order}
        LIMIT #{safe_per_page} OFFSET #{offset}
      SQL

      rows = db.execute(sql, bind_params).map do |row|
        { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], source: :jurisprudence }
      end

      SearchResult.new(results: rows, total_count: total)
    rescue StandardError => e
      Rails.logger.error("JurisprudenceSearchService error: #{e.message}")
      SearchResult.new(results: [], total_count: 0)
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
      rescue StandardError => e
        Rails.logger.warn("[JurisprudenceSearch] Operation failed: #{e.message}")
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
