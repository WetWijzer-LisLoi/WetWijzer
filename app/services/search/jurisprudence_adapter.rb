# frozen_string_literal: true

module Search
  class JurisprudenceAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      conditions = []
      params = []

      if query.present?
        sanitized = query.gsub('%', '\%').gsub('_', '\_')
        conditions << '(case_number LIKE ? OR court LIKE ? OR full_text LIKE ?)'
        like_query = "%#{sanitized}%"
        params += [like_query, like_query, like_query]
      end

      build_filters(filters, conditions, params)

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''
      sql = "SELECT id, case_number, court, decision_date, language_id FROM cases #{where_clause} ORDER BY decision_date DESC LIMIT ?"
      params << limit

      db.execute(sql, params).map do |row|
        lang_id = row[4].to_s == '2' ? 2 : 1
        {
          id: row[0],
          title: truncate(row[1], 60),
          subtitle: "#{row[2]} - #{row[3]}",
          url: "/jurisprudence/#{row[1]}?language_id=#{lang_id}",
          source: source_name,
          score: 1.0
        }
      end
    rescue StandardError => e
      Rails.logger.error("JurisprudenceAdapter#search error: #{e.message}")
      []
    end

    def get_context(id)
      row = db.execute(
        'SELECT id, case_number, court, decision_date, full_text FROM cases WHERE id = ?',
        [id]
      ).first
      return nil unless row

      {
        id: row[0],
        title: "#{row[2]} - #{row[1]}",
        content: row[4],
        metadata: {
          case_number: row[1],
          court: row[2],
          decision_date: row[3]
        }
      }
    rescue StandardError => e
      Rails.logger.error("JurisprudenceAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :jurisprudence
    end

    def source_label(locale = :nl)
      locale == :nl ? 'Rechtspraak' : 'Jurisprudence'
    end

    private

    def db
      @db ||= SQLite3::Database.new(db_path)
    end

    def db_path
      ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
        Rails.root.join('storage', 'jurisprudence.db').to_s
      end
    end

    def build_filters(filters, conditions, params)
      if filters[:court].present?
        conditions << 'court LIKE ?'
        params << "%#{filters[:court]}%"
      end

      if filters[:year].present?
        conditions << 'decision_date LIKE ?'
        params << "#{filters[:year]}-%"
      end

      if filters[:date_from].present?
        conditions << 'decision_date >= ?'
        params << filters[:date_from]
      end

      if filters[:date_to].present?
        conditions << 'decision_date <= ?'
        params << filters[:date_to]
      end

      return unless filters[:lang].present?

      # DB uses integer language_id: 1=NL, 2=FR. Also check ECLI suffix as fallback.
      conditions << if filters[:lang].to_s.upcase == 'FR' || filters[:lang] == '2'
                      "(language_id = 2 OR case_number LIKE '%-FR')"
                    else
                      "(language_id = 1 OR case_number LIKE '%-NL')"
                    end
    end
  end
end
