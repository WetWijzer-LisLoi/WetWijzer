# frozen_string_literal: true

module Search
  class JurisprudenceAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      conditions = []
      params = []

      if query.present?
        conditions << "(case_number LIKE ? OR court LIKE ? OR full_text LIKE ?)"
        like_query = "%#{query}%"
        params += [like_query, like_query, like_query]
      end

      build_filters(filters, conditions, params)

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""
      sql = "SELECT id, case_number, court, decision_date FROM cases #{where_clause} ORDER BY decision_date DESC LIMIT ?"
      params << limit

      db.execute(sql, params).map do |row|
        {
          id: row[0],
          title: truncate(row[1], 60),
          subtitle: "#{row[2]} - #{row[3]}",
          url: "/rechtspraak/#{row[0]}",
          source: source_name,
          score: 1.0
        }
      end
    rescue => e
      Rails.logger.error("JurisprudenceAdapter#search error: #{e.message}")
      []
    end

    def get_context(id)
      row = db.execute(
        "SELECT id, case_number, court, decision_date, full_text FROM cases WHERE id = ?",
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
    rescue => e
      Rails.logger.error("JurisprudenceAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :jurisprudence
    end

    def source_label(locale = :nl)
      locale == :fr ? 'Jurisprudence' : 'Rechtspraak'
    end

    private

    def db
      @db ||= SQLite3::Database.new(db_path)
    end

    def db_path
      ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
        Rails.env.production? ? '/mnt/HC_Volume_103359050/embeddings/jurisprudence.db' : Rails.root.join('storage', 'jurisprudence.db').to_s
      end
    end

    def build_filters(filters, conditions, params)
      if filters[:court].present?
        conditions << "court LIKE ?"
        params << "%#{filters[:court]}%"
      end

      if filters[:year].present?
        conditions << "decision_date LIKE ?"
        params << "#{filters[:year]}-%"
      end

      if filters[:date_from].present?
        conditions << "decision_date >= ?"
        params << filters[:date_from]
      end

      if filters[:date_to].present?
        conditions << "decision_date <= ?"
        params << filters[:date_to]
      end

      if filters[:lang].present?
        conditions << "language_id = ?"
        params << filters[:lang]
      end
    end
  end
end
