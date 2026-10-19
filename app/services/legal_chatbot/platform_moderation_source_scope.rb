# frozen_string_literal: true

module LegalChatbot
  # A generic complaint or a privacy authority's appeal notice is not
  # evidence about a platform's moderation of accounts or content. Require
  # affirmative topical facts; use metadata only for selection, never quotes.
  module PlatformModerationSourceScope
    WINDOW_CHARS = 600
    WINDOW_STEP = 300
    DSA_PATTERN = %r{\b(?:dsa|digital services act|digitaledienstenverordening|2022\s*/\s*2065|gesetz uber digitale dienste|reglement sur les services numeriques)\b}u
    PLATFORM_PATTERN = /\b(?:online\s*platform\p{L}*|plateformes?\s+en\s+ligne|online[-\s]?plattform\p{L}*|intermediary\s+services?|tussenhandeldienst\p{L}*|services?\s+intermediaires?|vermittlungsdienst\p{L}*)\b/u
    SOCIAL_PLATFORM_PATTERN = /\b(?:sociale?\s+media(?:dienst\p{L}*)?|social\s+(?:media|networks?)|reseaux?\s+sociaux|soziale\p{L}*\s+(?:medien|netzwerk\p{L}*)|facebook|instagram|tiktok|youtube|twitter)\b/u
    ACCOUNT_PATTERN = /\b(?:accounts?|platformaccount\p{L}*|profiles?|profiel\p{L}*|comptes?|profil\p{L}*|konto\p{L}*|konten|nutzerkont\p{L}*)\b/u
    USER_PATTERN = /\b(?:gebruikers?|users?|utilisateur\p{L}*|nutzer\p{L}*)\b/u
    CONTENT_PATTERN = /\b(?:content|posts?|inhoud|berichten?|publicaties?|contenu\p{L}*|publication\p{L}*|inhalt\p{L}*|beitrag\p{L}*|beitrage)\b/u
    MODERATION_PATTERN = /\b(?:moderati\p{L}*|geblokkeer\p{L}*|blokk(?:eer|er)\p{L}*|geschorst|schors\p{L}*|verwijder\p{L}*|uitsluiting|block\p{L}*|bans?|banned|suspend\p{L}*|restrict\p{L}*|remov\p{L}*|delet\p{L}*|bloqu\p{L}*|suspendu\p{L}*|supprim\p{L}*|retrait|retir\p{L}*|exclusion|sperr\p{L}*|gesperrt|entfern\p{L}*|geloscht|losch\p{L}*|ausschluss)\b/u
    MODERATION_BASIS_PATTERN = /\b(?:inhoudsmoderatie|contentmoderatie|content\s+moderation|moderation\s+(?:des?|du)\s+contenu\p{L}*|inhaltsmoderation|community\s+(?:standards|guidelines|rules)|gemeenschapsrichtlijn\p{L}*|gebruiksvoorwaarden|gebruikersvoorwaarden|terms\s+of\s+(?:service|use)|conditions\s+d['’]utilisation|nutzungsbedingungen)\b/u
    DSA_REDRESS_PATTERN = /\b(?:inhoudsmoderatie|contentmoderatie|content\s+moderation|moderation\s+(?:des?|du)\s+contenu\p{L}*|inhaltsmoderation|motiveringsplicht|statement\s+of\s+reasons|begrundungspflicht|interne?\s+klacht\p{L}*|internal\s+complaint\p{L}*|traitement\s+interne\s+des\s+reclamations|systeme\s+interne\s+de\s+traitement\s+des\s+reclamations|intern\p{L}*\s+beschwerde\p{L}*|buitengerechtelijk\p{L}*\s+geschil\p{L}*|out.of.court\s+dispute\p{L}*|reglement\s+extrajudiciaire\s+des\s+litiges|aussergerichtlich\p{L}*\s+streitbeileg\p{L}*)\b/u
    PRIVACY_PATTERN = /\b(?:avg|gdpr|rgpd|dsgvo|persoonsgegevens|persoonlijke\s+gegevens|personal\s+(?:data|information)|donnees?\s+(?:a\s+caractere\s+)?personnelles?|personenbezogen\p{L}*\s+daten)\b/u
    # Parliamentary preparation is never authority for a redress answer. It is
    # admitted when it addresses the DSA itself or a complaint, appeal or
    # statement-of-reasons route, not merely moderation (2026-10-17 review of
    # a lapsed social-media bill shown beside DSA articles).
    PARLIAMENTARY_REDRESS_PATTERN = /\b(?:klacht\p{L}*|beroep\p{L}*|bezwaar\p{L}*|motiver\p{L}*|reclamation\p{L}*|recours|motivation\p{L}*|beschwerde\p{L}*|rechtsbehelf\p{L}*|begrundung\p{L}*|complaint\p{L}*|appeal\p{L}*|statement\s+of\s+reasons|redress)\b/u
    DATA_REQUEST_PATTERN = /\b(?:inzage|gegevenswissing|wissen|verwijdering\s+van\s+(?:mijn\s+)?gegevens|rectificatie|rechtmatigheid|verwerk\p{L}*|gebruikt|access|erasure|rectif\p{L}*|process\p{L}*|uses?|effacement|acces|traitement|traite|auskunft|loschung|berichtigung|verarbeit\p{L}*|verwend\p{L}*)\b/u

    def self.topic?(question)
      EuTopicIntent.plan(question)&.dig(:topic) == :platform_redress
    end

    def self.source_relevant?(source, question, context_numacs: [])
      return true unless topic?(question)
      return true if selected_source?(source, question.to_s, context_numacs)

      question_text = normalized(question)
      texts = %i[law_title title summary article_title full_text content article_text text].filter_map do |key|
        value = field(source, key)
        normalized(value) unless value.to_s.empty?
      end
      # A separately requested personal-data issue can use privacy evidence.
      # Merely containing account data does not request that distinct issue.
      return true if question_text.match?(PRIVACY_PATTERN) && question_text.match?(DATA_REQUEST_PATTERN) && texts.any? { |text| text.match?(PRIVACY_PATTERN) }

      topical = texts.any? do |text|
        text.split(/[.!?;]+/).any? do |clause|
          (0...clause.length).step(WINDOW_STEP).any? do |start|
            topical_clause?(clause[start, WINDOW_CHARS])
          end
        end
      end
      return topical unless topical && parliamentary?(source)

      texts.any? { |text| text.match?(DSA_PATTERN) || text.match?(DSA_REDRESS_PATTERN) || text.match?(PARLIAMENTARY_REDRESS_PATTERN) }
    end

    def self.parliamentary?(source)
      field(source, :source_kind).to_s == 'parliamentary' || field(source, :authority_kind).to_s == 'parliamentary_preparation' ||
        (!field(source, :dossier).to_s.empty? && !field(source, :document_number).to_s.empty?)
    end

    def self.topical_clause?(text)
      return true if text.match?(DSA_PATTERN) && text.match?(DSA_REDRESS_PATTERN)

      account = text.match?(ACCOUNT_PATTERN) || (text.match?(USER_PATTERN) && text.match?(MODERATION_BASIS_PATTERN))
      content = text.match?(CONTENT_PATTERN)
      return false unless (account || content) && text.match?(MODERATION_PATTERN)
      return true if text.match?(SOCIAL_PLATFORM_PATTERN)

      text.match?(PLATFORM_PATTERN) && (content || text.match?(MODERATION_BASIS_PATTERN))
    end

    def self.selected_source?(source, question, context_numacs)
      return true if %i[pinned viewed selected explicit].any? { |key| [true, 1, 'true', '1'].include?(field(source, key)) }

      identifiers = %i[case_number ecli numac].map { |key| field(source, key).to_s }.reject(&:empty?)
      return true if identifiers.any? do |identifier|
        question.match?(/(?<![[:alnum:]_:])#{Regexp.escape(identifier)}(?![[:alnum:]_:]|\.[[:alnum:]])/iu)
      end
      return true if Array(context_numacs).any? { |value| value.to_s == field(source, :numac).to_s && !value.to_s.empty? }

      dossier = field(source, :dossier).to_s
      number = field(source, :document_number).to_s
      !dossier.empty? && !number.empty? && question.match?(/(?<!\d)#{Regexp.escape("#{dossier}/#{number}")}(?!\d)/)
    end

    def self.normalized(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.gsub('ß', 'ss')
          .tr('’–—-', "'   ").gsub(/[[:space:]]+/, ' ')
    end

    def self.field(source, key)
      source[key] || source[key.to_s]
    end
    private_class_method :topical_clause?, :selected_source?, :parliamentary?, :normalized, :field
  end
end
