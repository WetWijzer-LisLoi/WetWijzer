# frozen_string_literal: true

module LegalChatbot
  # Formats search results as source citations for the UI.
  # Converts internal search result formats into the structured
  # source objects expected by the chatbot response.
  class SourceFormatter
    include TextProcessing

    # language_id => the card's language badge; 3 is a binding German
    # original, which only the German site's chatbot retrieves.
    SOURCE_LANGUAGE_LABELS = { 1 => 'NL', 2 => 'FR', 3 => 'DE' }.freeze
    SOURCE_METADATA_KEYS = %i[source_kind authority_kind authority jurisdiction document_type legal_status
                              status version_date publication_date effective_date end_date is_abolished
                              source_language judicial_kind document_date edition_date historical].freeze

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
        language_id = article.respond_to?(:language_id) ? article.language_id : article[:language_id]

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
          # (including staging) and deep-links to the retrieved article. A
          # binding German original (language 3, gesetzguide only) opens the
          # German text of the page.
          url: numac.present? ? "/laws/#{numac}#{german_language_query(language_id)}#{extract_article_anchor(article_title)}" : nil,
          language: SOURCE_LANGUAGE_LABELS[language_id.to_i]
        }.merge(source_metadata(article, source_kind: 'legislation', authority_kind: 'legislation'))
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
          type: JurisprudenceSearch.source_metadata(case_number: ecli)[:authority_kind] == 'advisory' ? 'ADVIES' : 'RECHTSPRAAK',
          ecli: ecli,
          court: court_name,
          date: c[:decision_date],
          url: internal_url || c[:url],
          language: SOURCE_LANGUAGE_LABELS[c[:language_id].to_i],
          relevance: c[:similarity]&.round(2)
        }.merge(JurisprudenceSearch.source_metadata(case_number: ecli, court: court_name))
          .merge(source_metadata(c))
      end
    end

    # Format parliamentary results as source citations.
    # Keys must match ParliamentarySearch#search output:
    # {parliament, dossier, document_number, title, url, similarity}
    def format_parliamentary(documents)
      metadata_formatter = ParliamentarySearch.new(embedding_service: nil, language: @language)
      documents.map do |doc|
        {
          type: 'PARLEMENTAIR',
          title: doc[:title],
          parliament: doc[:parliament],
          dossier: doc[:dossier],
          document_number: doc[:document_number],
          url: doc[:url],
          relevance: doc[:similarity]&.round(2)
        }.merge(metadata_formatter.source_metadata(doc))
      end
    end

    # Format sealed official external legislation. Keep each article in the
    # display title because the browser source renderer de-duplicates cards by
    # title before it considers article metadata.
    def format_authoritative(articles)
      # A reviewed finite excerpt and the imported complete article may use
      # the same exact official unit URL. Keep both as guard/context evidence,
      # but show one card, preferring the verified complete representation.
      grouped = articles.group_by do |article|
        kind = article[:kind] || (article[:article_number].present? ? 'article' : nil)
        number = article[:unit_number] || article[:article_number]
        kind && number.present? ? [article[:url], kind, number.to_s] : article.object_id
      end
      display_articles = grouped.values.map do |rows|
        rows.find { |row| row[:source] == EuCorpus::SOURCE && EuCorpus.verified_record?(row) } || rows.first
      end
      display_articles.filter_map do |article|
        if article[:source] == EuCorpus::SOURCE
          next unless EuCorpus.verified_record?(article)

          type = if article[:source_kind] == 'jurisprudence'
                   article[:judicial_kind] == 'advocate_general_opinion' ? 'ADVIES' : 'RECHTSPRAAK'
                 elsif article[:kind] == 'recital'
                   'OVERWEGING'
                 else
                   'WETGEVING'
                 end
          next {
            type: type, source: EuCorpus::SOURCE, celex: article[:celex], ecli: article[:ecli],
            title: article[:title], law_title: article[:title], article_title: article[:article_title],
            url: article[:url], language: article[:language].upcase, source_kind: article[:source_kind],
            kind: article[:kind], unit_number: article[:unit_number], document_type: article[:document_type],
            edition_date: article[:edition_date], legal_status: article[:legal_status], correction_status: article[:correction_status],
            correction_observed_at: article[:correction_observed_at], correction_verification: article[:correction_verification],
            historical: article[:historical], source_notice: article[:historical] ? article[:title] : nil,
            excerpt: article[:article_text].to_s.gsub(/\s+/, ' ').strip[0, 201]
          }
        end
        display_title = article[:title].presence ||
                        "#{article[:law_title]} — #{article[:article_title]}"
        {
          type: article[:source] == 'official_guidance' ? 'INFO' : 'WETGEVING',
          law_title: display_title,
          title: display_title,
          url: article[:url],
          language: article[:language],
          excerpt: article[:article_text].to_s.gsub(/\s+/, ' ').strip[0, 201]
        }
      end
    end

    # Combine multiple source types into a single list.
    # Fisconet and regional results use their own services' format_sources:
    # their result shapes have no numac/law_title, so format_legislation
    # would silently drop them.
    def format_all(legislation: [], jurisprudence: [], parliamentary: [])
      sources = []
      sources.concat(format_legislation(legislation)) if legislation.any?
      sources.concat(format_jurisprudence(jurisprudence)) if jurisprudence.any?
      sources.concat(format_parliamentary(parliamentary)) if parliamentary.any?
      sources
    end

    private

    # Preserve known metadata; never manufacture applicability from a version
    # or publication date. Records without those columns remain supported.
    def source_metadata(record, **defaults)
      SOURCE_METADATA_KEYS.each_with_object(defaults) do |key, metadata|
        value = if record.respond_to?(key)
                  record.public_send(key)
                elsif record.is_a?(Hash)
                  record[key]
                end
        metadata[key] = value unless value.nil?
      end
    end

    # "?language_id=3" for a binding German original, whose card opens the
    # German text of the law page on gesetzguide; '' for NL and FR.
    def german_language_query(language_id)
      language_id == GermanArticleSearch::GERMAN_LANGUAGE_ID ? "?language_id=#{language_id}" : ''
    end
  end
end
