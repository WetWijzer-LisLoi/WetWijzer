# frozen_string_literal: true

module Search
  class LegislationAdapter < BaseAdapter
    def search(query, filters: {}, limit: 10)
      scope = Legislation.where(language_id: language_id(filters))
      
      if query.present?
        scope = scope.where("title LIKE ? OR numac LIKE ?", "%#{query}%", "%#{query}%")
      end

      if filters[:year].present?
        scope = scope.where("strftime('%Y', date) = ?", filters[:year].to_s)
      end

      if filters[:type].present?
        scope = scope.where(doc_type: filters[:type])
      end

      scope.limit(limit).map do |law|
        {
          id: law.numac,
          title: truncate(law.title, 100),
          subtitle: format_date(law.date),
          url: "/wet/#{law.numac}",
          source: source_name,
          score: 1.0
        }
      end
    rescue => e
      Rails.logger.error("LegislationAdapter#search error: #{e.message}")
      []
    end

    def get_context(numac)
      law = Legislation.find_by(numac: numac)
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
    rescue => e
      Rails.logger.error("LegislationAdapter#get_context error: #{e.message}")
      nil
    end

    def source_name
      :legislation
    end

    def source_label(locale = :nl)
      locale == :fr ? 'Législation' : 'Wetgeving'
    end

    private

    def language_id(filters)
      filters[:lang] == 'FR' ? 2 : 1
    end

    def format_date(date)
      return '' if date.blank?
      date.is_a?(String) ? date : date.strftime('%d/%m/%Y')
    end
  end
end
