# frozen_string_literal: true

module LegalChatbot
  # The same data-protection law can contain both commercial GDPR remedies
  # and a separate law-enforcement regime. Its whole-law title, or criminal
  # exceptions in a single article, cannot prove that article's parent scope.
  # Only the stored TOC's title and explicit article membership do so here.
  module TelemarketingLawEnforcementScope
    DATA_PATTERN = /\b(?:persoonsgegevens|personal\s+data|donn[ée]es\s+(?:[àa]\s+caract[èe]re\s+)?personnel(?:le)?s?|personenbezogene\p{L}*\s+Daten)\b/iu
    PROCESSING_PATTERN = /\b(?:verwerk\p{L}*|traitement\p{L}*|processing|Verarbeitung\p{L}*)\b/iu
    AUTHORITY_PATTERN = /\b(?:bevoegde\s+overheden|autorités\s+compétentes|competent\s+authorities|zust[äa]ndige\p{L}*\s+Beh[öo]rden)\b/iu
    CRIMINAL_PURPOSE_PATTERN = /\b(?:strafbare\s+feiten|tenuitvoerlegging\s+van\s+straffen|infractions\s+p[ée]nales|ex[ée]cution\s+de\s+sanctions\s+p[ée]nales|criminal\s+offen[cs]es|execution\s+of\s+(?:criminal\s+)?penalties|Straftaten|Strafvollstreckung)\b/iu
    TITLE_START_PATTERN = /\A\s*(?:TITEL|TITRE|TITLE)\s+(?:\d+(?:er)?|[IVXLCDM]+)\s*\./iu
    TITLE_BOUNDARY_PATTERN = /\A\s*(?:TITEL|TITRE|TITLE)\b/iu
    CHILD_START_PATTERN = /\A\s*(?:HOOFDSTUK|CHAPITRE|CHAPTER|AFDELING|SECTION|ONDERTITEL|SOUS[-\s]TITRE)\b/iu
    POLICE_ROLE_PATTERN = /\b(?:police|politie\p{L}*|politione\p{L}*|law[-\s]enforcement|criminal\s+(?:investigation|proceedings|justice)|strafrechtelijk\p{L}*\s+(?:onderzoek|procedure)|procureur\p{L}*|minist[èe]re\s+public|Polizei\p{L}*|Strafverfolgung\p{L}*)\b/iu
    DATA_REQUEST_PATTERN = /\b(?:persoonsgegevens|politiegegevens|gegevens|data|donn[ée]es|Daten|Polizeidaten|databank|database|files?|dossiers?|register\p{L}*|Akten)\b/iu
    RIGHTS_REQUEST_PATTERN = /\b(?:access|eras\p{L}*|delet\p{L}*|processing|rights?|privacy|toegang|inzage|wis(?:sen|sing)|verwijder\p{L}*|verwerk\p{L}*|rechten|acc[èe]s|effac\p{L}*|supprim\p{L}*|suppress\p{L}*|traitement\p{L}*|droits?|Auskunft|Zugang|l[öo]sch\p{L}*|Verarbeitung\p{L}*|Rechte\p{L}*)\b/iu
    REQUEST_PATTERN = /\A\s*(?:(?:and|also|en|ook|et|aussi|und|auch)\s+)?(?:what|which|how|can|could|wat|welk\p{L}*|hoe|kan|quel\p{L}*|comment|pouvez|was|welch\p{L}*|wie|kann)\b|\b(?:I\s+(?:also\s+)?(?:ask|want\s+to\s+know)|ik\s+(?:vraag|wil\s+weten)|je\s+(?:demande|veux\s+savoir)|ich\s+(?:frage|m[öo]chte\s+wissen)|explain|compare|vergelijk\p{L}*|explique\p{L}*|compar\p{L}*|erkl[äa]r\p{L}*|vergleich\p{L}*)\b/iu

    class Resolver
      def initialize
        @tocs = {}
      end

      # At the normal list boundaries this is one bounded query, not one
      # lookup per article. Empty/missing metadata is cached for this resolver
      # too, so a later citation-repair pass cannot repeatedly fetch it.
      def preload(articles)
        identities = Array(articles).filter_map { |article| TelemarketingLawEnforcementScope.identity(article) }.uniq
        missing = identities.reject { |identity| @tocs.key?(identity) }
        return if missing.empty?

        rows = Content.where(legislation_numac: missing.map(&:first).uniq,
                             language_id: missing.map(&:last).uniq)
                      .pluck(:legislation_numac, :language_id, :toc)
        rows.each { |numac, language_id, toc| @tocs[[numac, language_id]] = toc }
        missing.each { |identity| @tocs[identity] = nil unless @tocs.key?(identity) }
      rescue StandardError => e
        Rails.logger.warn("[Telemarketing parent scope] metadata unavailable: #{e.class}")
        missing&.each { |identity| @tocs[identity] = nil }
      end

      def parent_title(article)
        identity = TelemarketingLawEnforcementScope.identity(article)
        return unless identity

        preload([article]) unless @tocs.key?(identity)
        TelemarketingLawEnforcementScope.parent_title(@tocs[identity], article[:article_title] || article['article_title'])
      end
    end

    def self.identity(article)
      title = (article[:law_title] || article['law_title'] || article[:title] || article['title']).to_s
      return unless title.match?(DATA_PATTERN) && title.match?(PROCESSING_PATTERN)
      return unless plain_number(article[:article_title] || article['article_title'])

      numac = (article[:numac] || article['numac']).to_s
      language_id = Integer(article[:language_id] || article['language_id'], exception: false)
      return unless numac.match?(/\A[0-9A-Z]{10}\z/i) && [1, 2].include?(language_id)

      [numac, language_id]
    end

    def self.plain_number(title)
      match = title.to_s.match(/\A\s*Art(?:ikel|icle)?\.?\s*(\d+)\.?\s*\z/i)
      match && match[1].to_i
    end

    def self.parent_title(toc, article_title)
      number = plain_number(article_title)
      return if number.nil? || toc.to_s.empty?

      scope = nil
      collecting_title = false
      matches = []
      toc.to_s.each_line do |line|
        line = line.strip
        if line.match?(TITLE_START_PATTERN)
          scope = line
          collecting_title = true
        elsif line.match?(TITLE_BOUNDARY_PATTERN)
          # Never carry a proved title into a later, malformed title block.
          scope = nil
          collecting_title = false
        elsif (articles = line.match(/\AArt(?:ikel|icle)?s?\.?\s+(.+)\z/i))
          collecting_title = false
          tokens = articles[1].split(',').map(&:strip)
          # Ambiguous, suffixed or malformed membership is not a licence to
          # infer an article's applicability from a neighbouring number.
          next unless tokens.all? { |token| token.match?(/\A\d+(?:\s*[-–]\s*\d+)?\z/) }

          member = tokens.any? do |token|
            endpoints = token.split(/\s*[-–]\s*/).map(&:to_i)
            endpoints.one? ? endpoints.first == number : endpoints.first <= endpoints.last && (endpoints.first..endpoints.last).cover?(number)
          end
          matches << scope if member && scope
        elsif line.match?(CHILD_START_PATTERN)
          collecting_title = false
        elsif collecting_title && !line.empty?
          scope = "#{scope} #{line}"
        end
      end
      matches.one? ? matches.first : nil
    end

    def self.law_enforcement_title?(title)
      text = title.to_s
      text.match?(DATA_PATTERN) && text.match?(PROCESSING_PATTERN) &&
        text.match?(AUTHORITY_PATTERN) && text.match?(CRIMINAL_PURPOSE_PATTERN)
    end

    def self.police_data_requested?(question)
      return true if question.match?(%r{\b2016\s*/\s*680\b})

      question.split(/[.!?;\n]+/).any? do |clause|
        clause.match?(POLICE_ROLE_PATTERN) && clause.match?(DATA_REQUEST_PATTERN) &&
          clause.match?(RIGHTS_REQUEST_PATTERN) && clause.match?(REQUEST_PATTERN)
      end
    end

    def self.source_relevant?(article, question, resolver: nil)
      question = question.to_s
      return true unless TelemarketingPrivacyIntent.topic?(question)
      return true if article[:pinned] || article['pinned']

      numac = (article[:numac] || article['numac']).to_s
      return true if !numac.empty? && question.downcase.include?(numac.downcase)
      return true if police_data_requested?(question)

      title = (resolver || Resolver.new).parent_title(article)
      !law_enforcement_title?(title)
    end
  end
end
