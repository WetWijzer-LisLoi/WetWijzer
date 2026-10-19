# frozen_string_literal: true

module LegalChatbot
  # Builds LLM context from multi-source search results.
  # Combines legislation, jurisprudence, parliamentary, regional,
  # and fisconet results into a structured context string.
  class ContextBuilder
    include TextProcessing

    def initialize(language: 'nl')
      @language = language
    end

    # Build context from legislation articles
    def build_legislation_context(articles)
      articles.map.with_index do |article, index|
        <<~CONTEXT
          [Bron #{index + 1}]
          Wet: #{ensure_utf8(article.respond_to?(:law_title) ? article.law_title : article[:law_title])}
          NUMAC: #{article.respond_to?(:numac) ? article.numac : article[:numac]}
          #{ensure_utf8(article.respond_to?(:article_title) ? article.article_title : article[:article_title])}: #{ensure_utf8(article.respond_to?(:article_text) ? article.article_text : article[:article_text])}
        CONTEXT
      end.join("\n---\n")
    end

    # Build context from jurisprudence results (external DB format)
    def build_jurisprudence_context(cases, question: nil, max_chars: 2000)
      cases.map.with_index do |c, index|
        lang_label = actual_source_language(c)
        text = source_passages(c, question, max_chars)

        <<~CONTEXT
          [Bron #{index + 1} - #{case_source_label(c[:case_number])} (#{lang_label})]
          #{case_identity_lines(c[:case_number], c[:court]).join("\n")}
          Datum: #{c[:decision_date]}

          #{text}
        CONTEXT
      end.join("\n---\n")
    end

    # Build combined context from multiple source types
    def build_combined(articles, cases, offset: 0, question: nil, max_chars: 2000)
      parts = []
      law_label = @language == 'fr' ? 'LOI' : 'WET'
      juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'

      articles.each_with_index do |article, index|
        lang_label = if article.respond_to?(:language_id)
                       article.language_id == 1 ? 'NL' : 'FR'
                     else
                       'NL'
                     end
        parts << <<~CONTEXT
          [Bron #{offset + index + 1} - #{law_label} (#{lang_label})]
          Wet: #{article.respond_to?(:law_title) ? article.law_title : article[:law_title]}
          NUMAC: #{article.respond_to?(:numac) ? article.numac : article[:numac]}
          #{article.respond_to?(:article_title) ? article.article_title : article[:article_title]}: #{article.respond_to?(:article_text) ? article.article_text : article[:article_text]}
        CONTEXT
      end

      cases.each_with_index do |c, index|
        lang_label = actual_source_language(c)
        case_number = c.respond_to?(:case_number) ? c.case_number : c[:case_number]
        court = c.respond_to?(:court) ? c.court : c[:court]
        parts << <<~CONTEXT
          [Bron #{offset + articles.size + index + 1} - #{case_source_label(case_number, juris_label)} (#{lang_label})]
          #{case_identity_lines(case_number, court).join("\n")}
          Datum: #{c.respond_to?(:decision_date) ? c.decision_date : c[:decision_date]}

          #{source_passages(c, question, max_chars)}
        CONTEXT
      end

      parts.join("\n---\n")
    end

    private

    def source_record_field(record, key)
      return record.public_send(key) if record.respond_to?(key)
      return record[key] || record[key.to_s] if record.is_a?(Hash)

      nil
    end

    def actual_source_language(record)
      explicit = source_record_field(record, :source_language).to_s.downcase
      return explicit.upcase if %w[nl fr de en].include?(explicit)

      { 1 => 'NL', 2 => 'FR', 3 => 'DE' }[source_record_field(record, :language_id).to_i] || 'unknown'
    end

    def source_passages(record, question, max_chars)
      text = source_record_field(record, :full_text).presence || source_record_field(record, :chunk_text)
      SourcePassageExcerpt.excerpt(ensure_utf8(text), question, max_chars: max_chars,
                                                                summary: ensure_utf8(source_record_field(record, :summary)))
    end

    # An advisory opinion of the Council's Legislation section is not case law,
    # and must not reach the model under a case-law label with an "ECLI" and a
    # "Hof" - see LegalChatbot::AdvisoryOpinions.
    def case_source_label(case_number, default = nil)
      return AdvisoryOpinions.source_label(@language) if AdvisoryOpinions.advisory?(case_number)

      default || (@language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK')
    end

    def case_identity_lines(case_number, court)
      return AdvisoryOpinions.context_header(case_number, court, @language) if AdvisoryOpinions.advisory?(case_number)

      ["ECLI: #{case_number}", "Hof: #{court}"]
    end
  end
end
