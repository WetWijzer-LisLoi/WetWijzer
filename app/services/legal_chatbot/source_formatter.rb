# frozen_string_literal: true

module LegalChatbot
  # Formats search results as source citations for the UI.
  # Converts internal search result formats into the structured
  # source objects expected by the chatbot response.
  class SourceFormatter
    include TextProcessing

    def initialize(language: 'nl')
      @language = language
    end

    # Format legislation articles as source citations.
    #
    # Deliberately NO relevance floor here: the input has already passed the
    # orchestrator's apply_legislation_quality_filters (the single production
    # floor), and repaired-citation articles carry similarity 0.0 by design.
    # A second floor at format time would silently drop those from the source
    # cards while the answer still cites them, breaking answer/anchor parity.
    def format_legislation(articles)
      articles.filter_map do |article|
        numac = article.respond_to?(:numac) ? article.numac : article[:numac]
        law_title = article.respond_to?(:law_title) ? article.law_title : article[:law_title]
        article_title = article.respond_to?(:article_title) ? article.article_title : article[:article_title]

        # Skip articles with no identifiable source
        next nil if numac.blank? && law_title.blank?

        # Fallback to NUMAC as title when law_title is nil
        law_title = "Wetgeving #{numac}" if law_title.blank? && numac.present?

        {
          type: 'WETGEVING',
          numac: numac,
          # The streaming and server-rendered source cards use these keys.
          law_title: law_title,
          article_title: article_title,
          # Keep the original formatter keys for compatibility with consumers
          # that still read the formatter's pre-source-card schema.
          title: law_title,
          article: article_title,
          # A site-relative path keeps links on the active brand/environment
          # (including staging) and deep-links to the retrieved article.
          url: numac.present? ? "/laws/#{numac}#{extract_article_anchor(article_title)}" : nil,
          language: if (article.respond_to?(:language_id) ? article.language_id : article[:language_id]) == 1
                      'NL'
                    else
                      'FR'
                    end
        }
      end
    end

    # Format jurisprudence results as source citations
    def format_jurisprudence(cases)
      cases.map do |c|
        ecli = c[:case_number]
        court_name = c[:court]

        # Resolve court name from ECLI if unknown
        if court_name.nil? || court_name == 'Unknown'
          if ecli.to_s.start_with?('ECLI:BE:')
            court_code = ecli.split(':')[2]
            court_name = JurisprudenceSearch::COURT_NAME_MAP[court_code] || court_code
          elsif ecli.to_s.start_with?('RvS-')
            court_name = 'Raad van State'
          end
        end

        internal_url = ecli.present? ? "/jurisprudence/#{ecli}" : nil

        {
          type: 'RECHTSPRAAK',
          ecli: ecli,
          court: court_name,
          date: c[:decision_date],
          url: internal_url || c[:url],
          language: c[:language_id] == 1 ? 'NL' : 'FR',
          relevance: c[:similarity]&.round(2)
        }
      end
    end

    # Format parliamentary results as source citations.
    # Keys must match ParliamentarySearch#search output:
    # {parliament, dossier, document_number, title, url, similarity}
    def format_parliamentary(documents)
      documents.map do |doc|
        {
          type: 'PARLEMENTAIR',
          title: doc[:title],
          parliament: doc[:parliament],
          dossier: doc[:dossier],
          document_number: doc[:document_number],
          url: doc[:url],
          relevance: doc[:similarity]&.round(2)
        }
      end
    end

    # Format sealed official external legislation. Keep each article in the
    # display title because the browser source renderer de-duplicates cards by
    # title before it considers article metadata.
    def format_authoritative(articles)
      articles.map do |article|
        display_title = article[:title].presence ||
                        "#{article[:law_title]} — #{article[:article_title]}"
        {
          type: 'WETGEVING',
          law_title: display_title,
          title: display_title,
          url: article[:url],
          language: article[:language],
          excerpt: article[:article_text].to_s.gsub(/\s+/, ' ').strip[0, 201]
        }
      end
    end

    # Combine multiple source types into a single list.
    # Fisconet and regional results use their own services' format_sources —
    # their result shapes have no numac/law_title, so format_legislation
    # would silently drop them.
    def format_all(legislation: [], jurisprudence: [], parliamentary: [])
      sources = []
      sources.concat(format_legislation(legislation)) if legislation.any?
      sources.concat(format_jurisprudence(jurisprudence)) if jurisprudence.any?
      sources.concat(format_parliamentary(parliamentary)) if parliamentary.any?
      sources
    end
  end
end
