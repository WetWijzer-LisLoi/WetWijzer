# frozen_string_literal: true

module LegalChatbot
  # A vehicle-light accident query must not acquire health grants, sovereign
  # debt or a toy recall through words such as "cars", "rate" or "sunlight".
  # Only positively identified title families are excluded. Unknown metadata,
  # genuine mixed requests and deliberate source selections stay available.
  module VehicleHeadlightGlareSourceScope
    VEHICLE_PATTERN = /\b(?:cars?|SUVs?|automobiles?|voitures?|auto\p{L}*|wagens?|vehicles?|v[ée]hicules?|Fahrzeug\p{L}*|PKW|headlights?|koplamp\p{L}*|phares?|Scheinwerfer\p{L}*)\b/iu
    GLARE_PATTERN = /\b(?:verblind\p{L}*|[ée]bloui\p{L}*|dazzl\p{L}*|glare|blind(?:ed|ing)?|flashbang\p{L}*|blend\p{L}*|geblendet|concentrated\s+sunlight|geconcentreerd\s+zonlicht|lumi[èe]re\s+solaire\s+concentr[ée]e|konzentriert\p{L}*\s+Sonnenlicht|poorly\s+adjusted|mal\s+r[ée]gl[ée]\p{L}*|slecht\s+afgesteld\p{L}*|falsch\s+eingestellt\p{L}*)\b/iu
    HEADLIGHT_PATTERN = /\b(?:head[-\s]?lights?|high[-\s]?beams?|dipped\s+(?:lights?|beams?)|low[-\s]?beams?|koplamp\p{L}*|grootlicht\p{L}*|dimlicht\p{L}*|phares?|feux\s+(?:de\s+)?(?:route|croisement)|Scheinwerfer\p{L}*|Fernlicht|Abblendlicht|lights?|lampen|lumi[èe]res?)\b/iu
    LIGHT_METAPHOR_PATTERN = /\b(?:concentrated\s+sunlight|geconcentreerd\s+zonlicht|lumi[èe]re\s+solaire\s+concentr[ée]e|konzentriert\p{L}*\s+Sonnenlicht|poorly\s+adjusted|mal\s+r[ée]gl[ée]\p{L}*|slecht\s+afgesteld\p{L}*|falsch\s+eingestellt\p{L}*)\b/iu
    LEGAL_OR_ACCIDENT_PATTERN = /\b(?:accident\p{L}*|crash\p{L}*|collision\p{L}*|ongeval\p{L}*|botsing\p{L}*|aanrijding\p{L}*|Unfall\p{L}*|Unf[äa]ll\p{L}*|Versicherung\p{L}*|verzeker\p{L}*|insurance|assurance\p{L}*|aansprakelijk\p{L}*|schuld|fault|liab\p{L}*|responsabilit[ée]\p{L}*|Haftung\p{L}*|Schuld|verkeersregel\p{L}*|wegcode|road\s+(?:rules?|code)|code\s+de\s+la\s+route|Stra[ßs]enverkehr\p{L}*|legal|l[ée]gal\p{L}*|allowed|permitted|mag|mogen|toegestaan|autoris[ée]\p{L}*|erlaubt|zul[äa]ssig)\b/iu

    # The live question describes lights metaphorically rather than naming
    # headlights. Vehicle + glare/misalignment + a legal/accident question is
    # sufficient when lights or that metaphor are named; ordinary sunlight
    # glare, "cars" or "sunglasses" on their own are not a headlight intent.
    QUESTION_PATTERN = /\A(?=.*(?:#{VEHICLE_PATTERN.source}))(?=.*(?:#{GLARE_PATTERN.source}))(?=.*(?:#{HEADLIGHT_PATTERN.source}|#{LIGHT_METAPHOR_PATTERN.source}))(?=.*(?:#{LEGAL_OR_ACCIDENT_PATTERN.source})).*\z/imxu
    LIABILITY_SUBJECT_PATTERN = /\b(?:accident\p{L}*|crash\p{L}*|collision\p{L}*|ongeval\p{L}*|botsing\p{L}*|aanrijding\p{L}*|Unfall\p{L}*|Unf[äa]ll\p{L}*|Versicherung\p{L}*|verzeker\p{L}*|insurance|assurance\p{L}*|aansprakelijk\p{L}*|schuld|fault|liab\p{L}*|responsabilit[ée]\p{L}*|Haftung\p{L}*|Schuld|schadevergoed\p{L}*|compensation|indemni\p{L}*|Schadenersatz\p{L}*)\b/iu
    LIABILITY_QUESTION_PATTERN = /\A(?=#{QUESTION_PATTERN.source})(?=.*(?:#{LIABILITY_SUBJECT_PATTERN.source})).*\z/imxu

    WHO_ORGANISATION_PATTERN = Regexp.union(
      /\b(?:wereld\s*gezondheidsorganisatie|world\s+health\s+organi[sz]ation|organisation\s+mondiale\s+de\s+la\s+sant[ée]|Weltgesundheitsorganisation)\b/iu,
      /\b(?:WHO|OMS)\b/u
    ).freeze
    GRANT_PATTERN = /\b(?:subsid\p{L}*|subvention\p{L}*|grants?|funding|Zusch[üu]ss\p{L}*|F[öo]rdermittel|financiering\p{L}*|financement\p{L}*)\b/iu
    STATE_ISSUER_PATTERN = /\b(?:Belgische\s+Staat|[ÉE]tat\s+belge|Belgian\s+State|belgischen?\s+Staat|staatslening\p{L}*|staatsobligatie\p{L}*|government\s+bonds?|sovereign\s+(?:bonds?|debt)|Staatsanleih\p{L}*|emprunts?\s+d['’][ÉE]tat|obligations?\s+d['’][ÉE]tat)\b/iu
    BOND_INSTRUMENT_PATTERN = /\b(?:obligati\p{L}*|staatsobligatie\p{L}*|bonds?|(?:Staats)?Anleih\p{L}*|emprunts?|staatslening\p{L}*|lening|OLO|FRN)\b/iu
    ISSUE_PATTERN = /\b(?:uitgifte|[ée]mission\p{L}*|issu(?:e|ance|ing)|Emission\p{L}*|Ausgabe|floating\s+rate|lineaire\s+obligaties|obligations?\s+lin[ée]aires?)\b/iu
    TOY_PATTERN = /\b(?:speelgoed|toys?|jouets?|Spielzeug\p{L}*)\b/iu
    RECALL_PATTERN = /\b(?:uit\s+de\s+handel\s+nemen|terugroep\p{L}*|recalls?|withdraw\p{L}*|retrait\p{L}*|rappel\p{L}*|R[üu]ckruf\p{L}*|Marktr[üu]cknahme)\b|\b(?:verbod|ban|interdiction|Verbot)\b.{0,100}\b(?:markt|market|march[ée]|Markt)\b/imu
    NEGATED_RECALL_PATTERN = /\b(?:without\s+(?:a\s+)?(?:recall|withdrawal)|no\s+recall|zonder\s+(?:een\s+)?terugroep\p{L}*|sans\s+(?:un\s+)?(?:rappel|retrait)|(?:kein\p{L}*|ohne)\s+R[üu]ckruf)\b/iu
    REQUEST_PATTERN = /\b(?:vraag\p{L}*|bespreek|uitleg|demande\p{L}*|explique\p{L}*|ask\p{L}*|explain\p{L}*|discuss\p{L}*|frage\p{L}*|erkl[äa]r\p{L}*)\b|\A\s*(?:wat|welk\p{L}*|hoe|quel\p{L}*|comment|what|which|how|can|is|was|welch\p{L}*|wie|ist)\b|\?/iu

    OLD_ROADCODE_END = Date.new(2027, 6, 1).freeze
    BOOK_SIX_START = Date.new(2025, 1, 1).freeze
    POSTPONEMENT_START = Date.new(2026, 7, 16).freeze
    INCIDENT_PATTERN = /\b(?:accident\p{L}*|crash\p{L}*|collision\p{L}*|ongeval\p{L}*|ongeluk\p{L}*|botsing\p{L}*|aanrijding\p{L}*|Unfall\p{L}*|Unf[äa]ll\p{L}*)\b/iu
    MONTHS = {
      'january' => 1, 'januari' => 1, 'janvier' => 1, 'januar' => 1,
      'february' => 2, 'februari' => 2, 'février' => 2, 'fevrier' => 2, 'februar' => 2,
      'march' => 3, 'maart' => 3, 'mars' => 3, 'märz' => 3, 'maerz' => 3,
      'april' => 4, 'avril' => 4, 'may' => 5, 'mei' => 5, 'mai' => 5,
      'june' => 6, 'juni' => 6, 'juin' => 6, 'july' => 7, 'juli' => 7, 'juillet' => 7,
      'august' => 8, 'augustus' => 8, 'août' => 8, 'aout' => 8,
      'september' => 9, 'septembre' => 9, 'october' => 10, 'oktober' => 10, 'octobre' => 10,
      'november' => 11, 'novembre' => 11, 'december' => 12, 'décembre' => 12, 'decembre' => 12, 'dezember' => 12
    }.freeze
    MONTH_SOURCE = Regexp.union(MONTHS.keys).source.freeze
    DATE_TOKEN_SOURCE = "(?:(?:19|20)\\d{2}-\\d{1,2}-\\d{1,2}|\\d{1,2}[./-]\\d{1,2}[./-](?:19|20)\\d{2}|\\d{1,2}(?:st|nd|rd|th|er|e|\\.)?\\s*(?:#{MONTH_SOURCE})\\s+(?:19|20)\\d{2}|(?:#{MONTH_SOURCE})\\s+\\d{1,2}(?:st|nd|rd|th)?[,]?\\s+(?:19|20)\\d{2}|(?:19|20)\\d{2})".freeze
    # A date must describe the incident itself. A vehicle's purchase/model year,
    # an insurance claim date or an unrelated law date does not select a regime.
    INCIDENT_DATE_AFTER = /#{INCIDENT_PATTERN.source}\s*(?:(?:happened|occurred|took\s+place|was|will\s+(?:happen|occur)|were\s+to\s+happen|gebeurde|plaatsvond|vond(?:\s+plaats)?|zal\s+plaatsvinden|est\s+survenu|s['’]est\s+produit|a\s+eu\s+lieu|survenu|aura\s+lieu|ereignete\s+sich|geschah|stattfand|fand|wird\s+stattfinden)\s+)?(?:on|in|of|dated|op|van|du|de|le|en|am|im|vom)?\s*(?:(?:the\s+year|het\s+jaar|l['’]ann[ée]e|Jahr)\s+)?(?<incident_date>#{DATE_TOKEN_SOURCE})(?![\p{L}\d])/iu
    INCIDENT_DATE_BEFORE = /(?<![\p{L}\d])(?<incident_date>#{DATE_TOKEN_SOURCE})[\s,:]+(?:(?:the|my|our|a|an|de|het|mijn|een|un|une|mon|notre|der|die|das|mein|ein\p{L}*)\s+|l['’])?(?:car\s+|auto\s+|voiture\s+|Auto[-\s]?)?#{INCIDENT_PATTERN.source}/iu

    def self.topic?(question)
      question.to_s.match?(QUESTION_PATTERN)
    end

    def self.liability_topic?(question)
      question.to_s.match?(LIABILITY_QUESTION_PATTERN)
    end

    def self.roadcode_applicable?(question, as_of: Date.current)
      topic?(question) && incident_date_range(question, as_of).last < OLD_ROADCODE_END
    end

    def self.book_six_applicable?(question, as_of: Date.current)
      liability_topic?(question) && incident_date_range(question, as_of).first >= BOOK_SIX_START
    end

    def self.temporal_companion_applicable?(question, as_of: Date.current)
      return false unless topic?(question) && as_of.to_date >= POSTPONEMENT_START

      first, last = incident_date_range(question, as_of)
      first >= POSTPONEMENT_START && last < OLD_ROADCODE_END
    end

    def self.source_relevant?(article, question, context_numacs: [])
      question = question.to_s
      return true unless topic?(question)
      return true if selected_source?(article, question, context_numacs)

      # Do not classify from an incidental phrase in the legal body. These
      # unrelated source families are positively identified by their titles.
      title = (field(article, :law_title) || field(article, :title)).to_s
      return requested_family?(question) { |clause| who_grant?(clause) } if who_grant?(title)
      if sovereign_bond_issue?(title)
        return requested_family?(question) { |clause| clause.match?(STATE_ISSUER_PATTERN) && clause.match?(BOND_INSTRUMENT_PATTERN) }
      end
      return requested_family?(question) { |clause| toy_recall?(clause) } if toy_recall?(title)

      true
    end

    def self.admit?(article, question:, context_numacs: [])
      source_relevant?(article, question, context_numacs: context_numacs)
    end

    class << self
      alias relevant? source_relevant?
    end

    def self.who_grant?(text)
      text.match?(WHO_ORGANISATION_PATTERN) && text.match?(GRANT_PATTERN)
    end

    def self.sovereign_bond_issue?(text)
      text.match?(STATE_ISSUER_PATTERN) && text.match?(BOND_INSTRUMENT_PATTERN) && text.match?(ISSUE_PATTERN)
    end

    def self.toy_recall?(text)
      text.match?(TOY_PATTERN) && text.gsub(NEGATED_RECALL_PATTERN, '').match?(RECALL_PATTERN)
    end

    def self.incident_date_range(question, as_of)
      [INCIDENT_DATE_AFTER, INCIDENT_DATE_BEFORE].each do |pattern|
        question.to_s.scan(pattern) do
          range = parsed_date_range(Regexp.last_match[:incident_date])
          return range if range
        end
      end
      [as_of.to_date, as_of.to_date]
    end

    def self.parsed_date_range(text)
      if text.match?(/\A(?:19|20)\d{2}\z/)
        year = text.to_i
        return [Date.new(year, 1, 1), Date.new(year, 12, 31)]
      end

      date = if (match = text.match(/\A((?:19|20)\d{2})-(\d{1,2})-(\d{1,2})\z/))
               Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
             elsif (match = text.match(%r{\A(\d{1,2})[./-](\d{1,2})[./-]((?:19|20)\d{2})\z}))
               Date.new(match[3].to_i, match[2].to_i, match[1].to_i)
             elsif (match = text.match(/\A(\d{1,2})(?:st|nd|rd|th|er|e|\.)?\s*(#{MONTH_SOURCE})\s+((?:19|20)\d{2})\z/iu))
               Date.new(match[3].to_i, MONTHS.fetch(match[2].downcase), match[1].to_i)
             elsif (match = text.match(/\A(#{MONTH_SOURCE})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+((?:19|20)\d{2})\z/iu))
               Date.new(match[3].to_i, MONTHS.fetch(match[1].downcase), match[2].to_i)
             end
      [date, date] if date
    rescue ArgumentError
      nil
    end

    def self.requested_family?(question)
      question.split(/[.!;\n]+/).any? do |clause|
        clause.match?(REQUEST_PATTERN) && yield(clause)
      end
    end

    def self.selected_source?(article, question, context_numacs)
      return true if %i[pinned viewed selected explicit].any? { |key| truthy?(field(article, key)) }

      numac = field(article, :numac).to_s
      return false if numac.empty?
      return true if Array(context_numacs).any? { |value| value.to_s.casecmp?(numac) }

      question.match?(/(?<![[:alnum:]])#{Regexp.escape(numac)}(?![[:alnum:]])/iu)
    end

    def self.truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end

    def self.field(article, key)
      if article.respond_to?(:key?) && article.key?(key)
        article[key]
      elsif article.respond_to?(:key?) && article.key?(key.to_s)
        article[key.to_s]
      elsif article.respond_to?(key)
        article.public_send(key)
      end
    end

    private_class_method :who_grant?, :sovereign_bond_issue?, :toy_recall?, :requested_family?,
                         :selected_source?, :truthy?, :field, :incident_date_range, :parsed_date_range
  end
end
