# frozen_string_literal: true

module LegalChatbot
  # Sol's judgment retest on 1.1.95 (2026-11-23, wetwijzer-1.1.95-judgment-retest.json): questions that name one
  # Constitutional Court judgment (41/2009, 46/2019) got the Belgian State Gazette's extracts of other judgments as
  # legislation cards ("Uittreksel uit arrest nr. 72/2026", "35/2010", "116/2015"), found by their words. The titles,
  # read in the corpus on 2026-11-23: "Uittreksel uit arrest nr. 72/2026 van 18 juni 2026" and "Extrait de l'arrêt
  # n° 72/2026 du 18 juin 2026". An extract stays when the question names its judgment or names no judgment of that
  # court.
  module JudgmentExtractScope
    EXTRACT = %r{(?:uittreksel\s+uit\s+(?:het\s+)?arrest|extrait\s+de\s+l['’]arr[êe]t)\s+(?:nr\.?|n[°º]\.?)?\s*(\d{1,3})/((?:19|20)\d{2})(?!\d)}iu

    module_function

    def source_relevant?(article, question)
      found = title(article).match(EXTRACT)
      return true unless found

      named = JurisprudenceSearch.named_references(question.to_s).map(&:first).grep(/\AECLI:BE:GHCC:/)
      return true if named.empty?

      named.include?(format('ECLI:BE:GHCC:%<year>s:ARR.%<number>03d', year: found[2], number: found[1].to_i))
    end

    def title(article)
      return '' unless article.is_a?(Hash)

      (article[:law_title] || article['law_title'] || article[:title] || article['title']).to_s
    end
    private_class_method :title
  end
end
