# frozen_string_literal: true

module Search
  class ParliamentaryAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      return [] unless File.exist?(db_path)

      conditions = []
      params = []

      if query.present?
        sanitized = query.gsub('%', '\%').gsub('_', '\_')
        conditions << '(title LIKE ? OR dossier_number LIKE ?)'
        like_query = "%#{sanitized}%"
        params += [like_query, like_query]
      end

      if filters[:parliament].present?
        conditions << 'parliament = ?'
        params << filters[:parliament]
      end

      if filters[:year].present?
        conditions << "strftime('%Y', document_date) = ?"
        params << filters[:year].to_s
      end

      where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''
      sql = "SELECT id, title, parliament, dossier_number, document_date, language FROM documents #{where_clause} ORDER BY document_date DESC LIMIT ?"
      params << limit

      db.execute(sql, params).map do |row|
        lang_id = row[5].to_s.upcase.start_with?('F') ? 2 : 1
        {
          id: row[0],
          title: truncate(row[1], 80),
          subtitle: "#{parliament_label(row[2])} - #{row[3]} - #{row[4]}",
          url: "/parliamentary_work/chamber/#{row[0]}?language_id=#{lang_id}",
          source: source_name,
          score: 1.0
        }
      end
    rescue StandardError => e
      Rails.logger.error("ParliamentaryAdapter#search error: #{e.message}")
      []
    end

    def get_context(id)
      return nil unless File.exist?(db_path)

      row = db.execute(
        'SELECT id, title, parliament, dossier_number, document_date, content FROM documents WHERE id = ?',
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
    rescue StandardError => e
      Rails.logger.error("ParliamentaryAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :parliamentary
    end

    def source_label(locale = :nl)
      locale == :nl ? 'Parlementaire stukken' : 'Travaux parlementaires'
    end

    private

    def db
      @db ||= SQLite3::Database.new(db_path)
    end

    def db_path
      ENV.fetch('CHAMBER_DB') do
        Rails.env.production? ? '/mnt/shared/chamber.sqlite3' : Rails.root.join('storage', 'chamber.sqlite3').to_s
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
