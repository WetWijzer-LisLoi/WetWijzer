# frozen_string_literal: true

module LegalChatbot
  # Measured misstatements in residential lease notice answers (the candidate
  # QA of 15 real July catalogue questions, 2026-10-19), not a verifier of the
  # regional lease regimes: it decides neither the region nor any period. It
  # reads only the model's own prose; verbatim quotations of the law are
  # checked by the quote guard and are skipped here. No answer text is logged,
  # and passing does not verify an answer.
  #
  #   rental_counter_notice_assigned_to_landlord  "De verhuurder kan de
  #     huurovereenkomst met een kortere opzegtermijn van één maand beëindigen"
  #     (july-281): the one-month notice is the TENANT's counter-notice when
  #     the landlord gives notice (Flemish decree art. 20, par. 2); no regime
  #     gives the landlord a one-month notice.
  #   rental_short_lease_rule_for_long_lease  a nine-year lease question
  #     answered with the short-lease rule "na het eerste huurjaar, opzegging
  #     van drie maanden en een vergoeding van één maand" (july-281; Walloon
  #     decree art. 55, par. 6, labelled par. 5).
  class RentalNoticeGrounding
    VERSION = 1
    CONDITION_CODES = %w[rental_counter_notice_assigned_to_landlord rental_short_lease_rule_for_long_lease].freeze
    MAX_ANSWER_CHARS = 200_000
    MAX_QUESTION_CHARS = 12_000

    LEASE_PATTERN = /\b(?:huur\p{L}*|verhuur\p{L}*|bail\p{L}*|loyer\p{L}*|locat\p{L}*|lease\p{L}*|tenan\p{L}*|landlord\p{L}*|miet\p{L}*)\b/i
    NOTICE_PATTERN = /\b(?:opzeg\p{L}*|vooropzeg\p{L}*|beëindig\p{L}*|pr[ée]avis|cong[ée]s?|r[ée]sili\p{L}*|notice|terminat\p{L}*|kündig\p{L}*)\b/i
    LONG_LEASE_PATTERN = /\b(?:(?:9|negen)[-\s]?jar\p{L}*|9\s+jaar|negen\s+jaar|neuf\s+ans|9\s+ans|nine[-\s]years?|9[-\s]years?|langdurige?\s+huur\p{L}*)\b/i
    LANDLORD_PATTERN = /\b(?:verhuurder|bailleur|landlord|vermieter)\b/i
    TENANT_PATTERN = /\b(?:huurder|locataire|tenant|mieter)\b/i
    ONE_MONTH_NOTICE_PATTERN = /\b(?:opzeg(?:termijn|ging|gingstermijn)?\s+van\s+(?:één|een|1)\s+maand|(?:één|een|1)\s+maand\s+opzeg\p{L}*|pr[ée]avis\s+d['’]un\s+mois|one[-\s]month(?:'s)?\s+notice|notice\s+of\s+one\s+month)\b/i
    AFTER_FIRST_YEAR_PATTERN = /\b(?:na\s+het\s+eerste\s+(?:huur)?jaar|apr[èe]s\s+la\s+premi[èe]re\s+ann[ée]e|after\s+the\s+first\s+year)\b/i
    ONE_MONTH_COMPENSATION_PATTERN = /\b(?:vergoeding\p{L}*|indemnit[ée]\p{L}*|compensation)\b[^.\n]{0,40}\b(?:één|een|1|un|one)\s+(?:maand|mois|month)\b/i
    BLOCKQUOTE_LINE = /\A\s*(?:(?:[-*+]|\d{1,2}[.)])\s+)?>/
    # "De verhuurder kan NIET ... van één maand": the negation is correct.
    NEGATOR_PATTERN = /\b(?:niet|geen|nooit|not|never|cannot|pas|jamais)\b/i
    # An explicitly labelled short-lease comparison is not its application.
    SHORT_LEASE_LABEL_PATTERN = /\b(?:korte\s+duur|kortlopend\p{L}*|kortdurend\p{L}*|courte\s+dur[ée]e|short[-\s](?:term\s+)?leases?|drie\s+jaar\s+of\s+minder|(?:ten\s+hoogste|maximum)\s+(?:drie|3)\s+jaar|3\s+ans\s+(?:ou\s+moins|maximum))\b/i

    FEEDBACK = {
      'rental_counter_notice_assigned_to_landlord' => {
        'nl' => 'De opzegging van één maand is een tegenopzegging van de HUURDER, alleen nadat de verhuurder vervroegd opzegt op de gronden die het artikel noemt (Vlaanderen art. 20, § 2 bij art. 17 tot 19; Brussel art. 237, § 5 bij § 2 tot 4; Wallonië art. 55, § 5 bij § 2 tot 4), niet bij elke opzegging of het gewone einde; ken ze nooit aan de verhuurder toe en lees per regio in de verstrekte artikelen wie welke termijn heeft.',
        'fr' => 'Le préavis d’un mois est un contre-préavis du LOCATAIRE, seulement après un congé anticipé du bailleur pour les motifs que l’article cite (Flandre art. 20, § 2 avec art. 17 à 19 ; Bruxelles art. 237, § 5 avec §§ 2 à 4 ; Wallonie art. 55, § 5 avec §§ 2 à 4), pas pour tout congé ou l’échéance ordinaire ; ne l’attribuez jamais au bailleur et lisez, région par région, qui a quel délai dans les articles fournis.',
        'en' => 'The one-month notice is a TENANT counter-notice, only after the landlord gives early notice on the grounds the article names (Flanders art. 20(2) with arts. 17 to 19; Brussels art. 237(5) with (2) to (4); Wallonia art. 55(5) with (2) to (4)), not after every notice or the ordinary expiry; never attribute it to the landlord and read, region by region, who has which period in the supplied articles.'
      },
      'rental_short_lease_rule_for_long_lease' => {
        'nl' => 'De regel "na het eerste huurjaar, een opzegging van drie maanden en een vergoeding van één maand" geldt voor een huurovereenkomst van korte duur, niet voor een huurovereenkomst van negen jaar; pas voor negen jaar alleen de bepalingen voor die duur toe, met de juiste paragraaf.',
        'fr' => 'La règle « après la première année, un préavis de trois mois et une indemnité d’un mois » vaut pour un bail de courte durée, pas pour un bail de neuf ans ; pour neuf ans, appliquez seulement les dispositions de cette durée, avec le bon paragraphe.',
        'en' => 'The rule "after the first year, three months’ notice and one month’s compensation" applies to a short lease, not to a nine-year lease; for nine years apply only the provisions for that duration, with the correct paragraph.'
      }
    }.freeze

    def self.evaluate(answer, question, _sources)
      text = answer.to_s
      asked = question.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS || asked.length > MAX_QUESTION_CHARS
      return result(false, []) unless asked.match?(LEASE_PATTERN) && asked.match?(NOTICE_PATTERN)
      # Residential leases only, by the existing regime boundary: a freely
      # agreed notice in a bicycle or commercial lease is not this rule.
      return result(false, []) unless LegislationSearch.rental_regime(asked) == :residential

      lines = prose_lines(text)
      missing = []
      missing << 'rental_counter_notice_assigned_to_landlord' if lines.any? { |line| landlord_one_month_notice?(line) }
      if asked.match?(LONG_LEASE_PATTERN) &&
         lines.any? do |line|
           line.match?(AFTER_FIRST_YEAR_PATTERN) && line.match?(ONE_MONTH_COMPENSATION_PATTERN) &&
           !line.match?(SHORT_LEASE_LABEL_PATTERN)
         end
        missing << 'rental_short_lease_rule_for_long_lease'
      end
      result(true, missing)
    end

    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = %w[nl fr en].include?(language.to_s) ? language.to_s : 'en'
      header = { 'nl' => 'Herstel ook deze inhoudelijke fouten in de opzegregels:',
                 'fr' => 'Corrigez aussi ces erreurs de fond sur les congés :',
                 'en' => 'Also correct these substantive errors on notice rules:' }.fetch(lang)
      ([header] + codes.map { |code| "- #{FEEDBACK.fetch(code).fetch(lang)}" }).join("\n")
    end

    # The same reading as the withdrawal check: quotations dropped, inline
    # emphasis read as plain text, one line per item or sentence.
    def self.prose_lines(text)
      ConsumerWithdrawalGrounding.prose_lines(text)
    end

    # The actor of the one-month notice is the first party of its own clause,
    # else of its sentence, and it is the landlord without a negation between
    # them. "Als de verhuurder opzegt, kan de huurder een tegenopzegging van
    # één maand geven" and "De huurder kan, als de verhuurder opzegt, met een
    # opzegging van één maand vertrekken" are the tenant's; "De huurder kan
    # bezwaar maken wanneer de verhuurder ... opzegtermijn van één maand"
    # gives it to the landlord.
    CLAUSE_BOUNDARY_PATTERN = /[,;:]|\s(?:als|wanneer|indien|terwijl|omdat|doordat|nadat|zodra|maar|lorsque|quand|si|mais|when|if|while|because|but)\s/i
    def self.landlord_one_month_notice?(line)
      notice = ONE_MONTH_NOTICE_PATTERN.match(line)
      return false if notice.nil?

      before = line[0...notice.begin(0)]
      clause_start = before.to_enum(:scan, CLAUSE_BOUNDARY_PATTERN).map { Regexp.last_match.begin(0) }.last
      clause = clause_start ? before[clause_start..] : before
      scope = clause.match?(LANDLORD_PATTERN) || clause.match?(TENANT_PATTERN) ? clause : before
      landlord_at = scope =~ LANDLORD_PATTERN
      return false if landlord_at.nil?

      tenant_at = scope =~ TENANT_PATTERN
      return false if tenant_at && tenant_at < landlord_at

      !scope[landlord_at..].match?(NEGATOR_PATTERN)
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
