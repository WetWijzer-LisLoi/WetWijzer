# frozen_string_literal: true

module Search
  class ParliamentaryAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      return [] unless File.exist?(db_path)

      conditions = []
      params = []

      if query.present?
        conditions << "(title LIKE ? OR dossier_number LIKE ? OR extracted_text LIKE ?)"
        like_query = "%#{query}%"
        params += [like_query, like_query, like_query]
      end

      if filters[:parliament].present?
        conditions << "parliament = ?"
        params << filters[:parliament]
      end

      if filters[:year].present?
        conditions << "strftime('%Y', date) = ?"
        params << filters[:year].to_s
      end

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ""
      sql = "SELECT id, title, parliament, dossier_number, date FROM documents #{where_clause} ORDER BY date DESC LIMIT ?"
      params << limit

      db.execute(sql, params).map do |row|
        {
          id: row[0],
          title: truncate(row[1], 80),
          subtitle: "#{parliament_label(row[2])} - #{row[3]} - #{row[4]}",
          url: "/parlementair/#{row[0]}",
          source: source_name,
          score: 1.0
        }
      end
    rescue => e
      Rails.logger.error("ParliamentaryAdapter#search error: #{e.message}")
      []
    end

    def get_context(id)
      return nil unless File.exist?(db_path)

      row = db.execute(
        "SELECT id, title, parliament, dossier_number, date, extracted_text FROM documents WHERE id = ?",
        [id]
      ).first
      return nil unless row

      {
        id: row[0],
        title: row[1],
        content: row[5],
        metadata: {
          parliament: row[2],
          dossier_number: row[3],
          date: row[4]
        }
      }
    rescue => e
      Rails.logger.error("ParliamentaryAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :parliamentary
    end

    def source_label(locale = :nl)
      locale == :fr ? 'Travaux parlementaires' : 'Parlementaire stukken'
    end

    private

    def db
      @db ||= SQLite3::Database.new(db_path)
    end

    def db_path
      ENV.fetch('PARLIAMENTARY_DB') do
        Rails.env.production? ? '/mnt/shared/parliamentary.sqlite3' : Rails.root.join('storage', 'parliamentary.sqlite3').to_s
      end
    end

    def parliament_label(code)
      case code
      when 'kamer' then 'Kamer'
      when 'senaat' then 'Senaat'
      when 'vlaams' then 'Vlaams Parlement'
      when 'brussels' then 'Brussels Parlement'
      when 'waals' then 'Waals Parlement'
      else code
      end
    end
  end
end
