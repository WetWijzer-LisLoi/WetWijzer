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
    def build_jurisprudence_context(cases)
      cases.map.with_index do |c, index|
        lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
        source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
        text = c[:summary].present? ? c[:summary] : c[:full_text].to_s[0, 2000]

        <<~CONTEXT
          [Bron #{index + 1} - #{source_label} (#{lang_label})]
          ECLI: #{c[:case_number]}
          Hof: #{c[:court]}
          Datum: #{c[:decision_date]}

          #{text}
        CONTEXT
      end.join("\n---\n")
    end

    # Build combined context from multiple source types
    def build_combined(articles, cases, offset: 0)
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
        lang_label = if (c.respond_to?(:language_id) ? c.language_id : c[:language_id]) == 1
                       'NL'
                     else
                       'FR'
                     end
        parts << <<~CONTEXT
          [Bron #{offset + articles.size + index + 1} - #{juris_label} (#{lang_label})]
          ECLI: #{c.respond_to?(:case_number) ? c.case_number : c[:case_number]}
          Hof: #{c.respond_to?(:court) ? c.court : c[:court]}
          Datum: #{c.respond_to?(:decision_date) ? c.decision_date : c[:decision_date]}

          #{c.respond_to?(:chunk_text) ? c.chunk_text : c[:summary] || c[:full_text].to_s[0, 2000]}
        CONTEXT
      end

      parts.join("\n---\n")
    end
  end
end
