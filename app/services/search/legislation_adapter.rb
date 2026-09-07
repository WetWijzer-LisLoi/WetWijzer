# frozen_string_literal: true

module Search
  class LegislationAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      scope = Legislation.where(language_id: language_id(filters))

      if query.present?
        # Title lookup through legislation_fts (title-only index) instead of
        # the non-sargable LIKE '%q%' full scan that cost ~200-745ms on every
        # autocomplete keystroke (36ms via FTS, measured live). Tokens are
        # quoted to neutralize FTS operators; the token being typed gets a
        # prefix star. Numac stays a prefix LIKE on its index.
        if query.match?(/\A\d{4,}\z/)
          # Numacs are digit strings: probe the numac index via a bounded
          # rowid subquery. Range bounds instead of LIKE (no NOCASE
          # collation, so LIKE never uses the index) and a subquery because
          # the planner otherwise walks the whole language partition - this
          # unanalyzed DB costs plans badly (221ms -> 25ms measured).
          scope = scope.where(
            'rowid IN (SELECT rowid FROM legislation WHERE numac >= ? AND numac < ?)',
            query, "#{query}~"
          )
        else
          tokens = query.scan(/[[:alnum:]']+/)
          if tokens.any?
            fts_terms = tokens.map { |t| %("#{t}") }
            fts_terms[-1] += '*' unless query.end_with?(' ')
            scope = scope.where(
              'rowid IN (SELECT rowid FROM legislation_fts WHERE legislation_fts MATCH ?)',
              fts_terms.join(' ')
            )
          end
        end
      end

      scope = scope.where("strftime('%Y', date) = ?", filters[:year].to_s) if filters[:year].present?

      scope = scope.where(doc_type: filters[:type]) if filters[:type].present?

      scope.limit(limit).map do |law|
        {
          id: law.numac,
          title: truncate(law.title, 100),
          subtitle: format_date(law.date),
          url: "/laws/#{law.numac}?language_id=#{law.language_id}",
          source: source_name,
          score: 1.0
        }
      end
    rescue StandardError => e
      Rails.logger.error("LegislationAdapter#search error: #{e.message}")
      []
    end

    def get_context(numac)
      law = Legislation.find_by(
        numac: numac,
        language_id: language_id({})
      )
      return nil unless law

      content = law.content
      articles_text = content&.articles.presence || ''

      {
        id: numac,
        title: law.title,
        content: articles_text,
        metadata: {
          date_pub: law.date_pub,
          source: law.source,
          doc_type: law.doc_type
        }
      }
    rescue StandardError => e
      Rails.logger.error("LegislationAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :legislation
    end

    def source_label(locale = :nl)
      locale == :nl ? 'Wetgeving' : 'Législation'
    end

    private

    def language_id(filters)
      requested_language = filters[:lang].presence || options[:locale]
      %w[fr de].include?(requested_language.to_s.downcase) ? 2 : 1
    end

    def format_date(date)
      return '' if date.blank?

      date.is_a?(String) ? date : date.strftime('%d/%m/%Y')
    end
  end
end
