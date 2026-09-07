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
      @db ||= open_corpus_db(db_path)
    end

    def db_path
      # storage/chamber.sqlite3 is a symlink to the real corpus on the server,
      # exactly as every other adapter resolves its database. The production
      # branch used to name /mnt/shared/chamber.sqlite3, a mount retired in the
      # 2026-08 migration, so SQLite3::Database.new raised on a path that had
      # not existed for months, the rescue turned it into [], and the site-wide
      # search box returned zero parliamentary results while looking healthy.
      ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    end

    def parliament_label(code)
      case code
      # 'chamber' is what the corpus stores for the federal Chamber (56,978 of
      # its rows); only one retired writer ever used 'kamer'. Without this the
      # label fell through to the raw code and the search results said
      # "chamber" - visible on every federal result now that parliamentary
      # search works again.
      when 'chamber', 'kamer' then 'Kamer'
      when 'senate', 'senaat' then 'Senaat'
      when 'vlaams' then 'Vlaams Parlement'
      when 'brussels' then 'Brussels Parlement'
      when 'waals' then 'Waals Parlement'
      else code
      end
    end
  end
end
