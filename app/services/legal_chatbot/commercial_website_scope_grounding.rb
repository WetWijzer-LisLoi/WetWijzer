# frozen_string_literal: true

module LegalChatbot
  # Scope errors of the commercial-website answer, the r47 stage A row A3
  # (root 2026-10-19 23:27:12 to 23:36:18), each read against its own retained
  # unit:
  #   website_identification_exempted  (XII.10): the agreed B2B derogation
  #     and the e-mail-only exception cover only XII.6, § 1, 8°, XII.7, § 1,
  #     XII.8 and XII.9 (1° and 2°); no identification duty falls away.
  #   website_xii6_8_called_identification  (XII.6): § 1, 8° is the subscribed
  #     codes of conduct and their electronic consultation, not identification.
  #   website_cookie_rule_conditioned_on_personal_data  (art. 10/2 of the law
  #     of 30 July 2018): the rule governs storing or reading INFORMATION on
  #     terminal equipment, so it is never conditional on personal data.
  # A clause asserts; a co-occurrence does not. An explicit correction ("Niet
  # juist: ..."), a negated exemption ("vervalt niet", "vervalt ... niet",
  # "never exempt") and "niet alleen ... persoonsgegevens" pass. A section
  # heading's condition applies only to its own section. Passing does not
  # verify an answer.
  class CommercialWebsiteScopeGrounding
    VERSION = 1
    CONDITION_CODES = %w[website_identification_exempted website_xii6_8_called_identification
                         website_cookie_rule_conditioned_on_personal_data].freeze
    XII10 = { numac: '2013A11134', article: 'XII.10' }.freeze
    XII6 = { numac: '2013A11134', article: 'XII.6' }.freeze
    TERMINAL_STORAGE = { numac: '2018040581', article: '10/2' }.freeze
    XII10_EVIDENCE = {
      nl: ['kunnen bij middel van overeenkomst afwijken van de bepalingen van artikel XII.6',
           'uitsluitend via uitwisseling van elektronische post'],
      fr: ["peuvent déroger conventionnellement aux dispositions de l'article XII.6",
           "exclusivement au moyen d'un échange de courriers électroniques"]
    }.freeze
    XII6_EVIDENCE = {
      nl: ['de gedragscodes die hij desgevallend heeft onderschreven', 'zijn naam of handelsnaam'],
      fr: ['les codes de conduite auxquels il est éventuellement soumis', 'son nom ou sa dénomination sociale']
    }.freeze
    # The corpus holds no French row of art. 10/2; a French answer is then
    # not applicable rather than read against words that are not there.
    TERMINAL_STORAGE_EVIDENCE = {
      nl: ['de opslag van informatie of het verkrijgen van toegang tot informatie die reeds is opgeslagen in de eindapparatuur',
           'strikt noodzakelijk']
    }.freeze
    MAX_ANSWER_CHARS = 200_000

    B2B_OR_EMAIL = /\b(?:B2B|niet\s+als\s+consument|tussen\s+ondernemingen|zakelijke?\s+klant\p{L}*|professionele?\s+(?:klant\p{L}*|afnemer\p{L}*)|ne\s+sont\s+pas\s+des\s+consommateurs|entre\s+(?:entreprises|professionnels)|business[-\s]to[-\s]business|between\s+businesses|non[-\s]consumer\p{L}*|zwischen\s+unternehmen|keine\s+verbraucher|elektronische\s+post|e-?mail\p{L}*|courrier\p{L}*\s+électronique\p{L}*|courriel\p{L}*|XII\.\s?10)\b/i
    IDENTIFICATION = /\b(?:identificati\p{L}*|identiteit|handelsnaam|naam|adres|adressen|contactgegevens|ondernemingsnummer|identité|dénomination|nom|adresse|coordonnées|numéro\s+d['’]entreprise|identity|name|address|contact\s+details|enterprise\s+number|company\s+number|identität|identifizierung|anschrift|kontaktdaten|unternehmensnummer)\b/i
    EXEMPT = /\b(?:vervalt|vervallen|vrijgesteld|uitgezonderd|afwijken|afwijking|afgeweken|disparaît|disparaissent|tombe|tombent|exempté\p{L}*|dispensé\p{L}*|déroger|dérogation|exempt\p{L}*|waived|derogat\p{L}*|entfällt|entfallen|befreit|abweichen|abweichung)\b/i
    NOT_REQUIRED = /\bniet\s+(?:meer\s+)?(?:verplicht|vereist|nodig|van\s+toepassing)\b|\bniet\s+te\s+(?:vermelden|verstrekken|geven|tonen)\b|\bn['’](?:est|sont)\s+pas\s+(?:obligatoire\p{L}*|requis\p{L}*|nécessaire\p{L}*|applicable\p{L}*)|\bne\s+s['’]appliqu\p{L}*\s+pas\b|\bpas\s+besoin\b|\bneed\s+not\b|\b(?:is|are)\s+not\s+(?:required|mandatory|needed)\b|\bdo(?:es)?\s+not\s+apply\b|\bgilt\s+nicht\b|\bgelten\s+nicht\b|\bnicht\s+(?:erforderlich|verpflichtend|notwendig|anzugeben)\b/i
    NEGATOR = /\A(?:niet|nooit|geen|ne|n['’]\p{L}*|jamais|pas|never|not|no|\p{L}+n['’]t|nicht|nie|kein\p{L}*)\z/i
    REFERENCE_8 = /XII\.\s?6\s*,?\s*§\s*1(?:er)?\s*,?\s*8\s*[°º]/i
    IDENTIFICATION_DUTY = /\b(?:identificati\p{L}*|identification|identity|identität|identifizierung)\b/i
    NOT_IDENTIFICATION = /\b(?:niet|geen|pas|not|nicht|keine?)\s+(?:de\s+|l['’]|la\s+|die\s+)?(?:identificati\p{L}*|identification|identity|identität|identifizierung)\b/i
    # Words between the 8° reference and an identification word that detach
    # them: a negation, a contrast, a restriction, a duty that remains, or the
    # codes-of-conduct label itself.
    DETACHED = /\b(?:niet|geen|nooit|not|never|nicht|kein\p{L}*|ne|pas|jamais|terwijl|maar|doch|wel|whereas|while|but|mais|alors|tandis|während|aber|jedoch|blijft|blijven|reste\p{L}*|remain\p{L}*|bleib\p{L}*|enkel|alleen|slechts|uitsluitend|seulement|uniquement|only|nur|lediglich|gedragscode\p{L}*|conduite|conduct|verhaltenskod\p{L}*)\b|\bn['’]/i
    TERMINAL_TERM = %r{\b(?:cookie\p{L}*|eindappara\p{L}*|terminal\s+equipment|équipement\p{L}*\s+terminal\p{L}*|traceur\p{L}*|endgerät\p{L}*|opslag\s+van\s+informatie|stockage\s+d['’]informations|storage\s+of\s+information|speicherung\s+von\s+informationen)\b|10/2|art-10-2}i
    ONLY_IF_PERSONAL_DATA = /\b(alleen|enkel|uitsluitend|slechts|seulement|uniquement|only|solely|exclusively|nur|ausschließlich)\b,?\s+(?:\S+\s+){0,3}?(?:als|indien|wanneer|bij|si|lorsque|quand|en\s+cas\s+de|if|when|where|wenn|falls|bei)\s+(?:\S+\s+){0,4}?(?:persoonsgegevens|données\s+(?:à\s+caractère\s+)?personnelles|personal\s+data|personenbezogen\p{L}*\s+daten)\b/i
    NOT_ONLY = /\b(?:niet|pas|non|not|nicht)\s+(?:\S+\s+)?\z/i

    FEEDBACK = {
      'website_identification_exempted' => {
        'nl' => 'Art. XII.10 WER (verstrekte bron): partijen die niet als consument handelen, "kunnen bij middel van overeenkomst afwijken van de bepalingen van artikel XII.6", § 1, 8°, en van XII.7, § 1, XII.8 en XII.9; voor contracten die "uitsluitend via uitwisseling van elektronische post" gesloten zijn, vallen alleen die bepalingen (XII.9: 1° en 2°) weg. Geen andere informatieplicht valt weg: stel nooit dat naam, adres of andere identificatiegegevens bij B2B of e-mail niet meer hoeven.',
        'fr' => %(L’article XII.10 CDE (source fournie) : les parties qui ne sont pas des consommateurs "peuvent déroger conventionnellement aux dispositions de l'article XII.6", § 1er, 8°, ainsi que des articles XII.7, § 1er, XII.8 et XII.9 ; pour les contrats conclus "exclusivement au moyen d'un échange de courriers électroniques", seules ces dispositions (XII.9 : 1° et 2°) tombent. Aucune autre obligation d'information ne disparaît : n'écrivez jamais que le nom, l'adresse ou d'autres données d'identification ne sont plus requis en B2B ou par e-mail.),
        'en' => 'Article XII.10 of the Code of Economic Law (supplied source): non-consumer parties may derogate by agreement only from XII.6, § 1, 8°, XII.7, § 1, XII.8 and XII.9; for contracts concluded exclusively by e-mail only those provisions (XII.9: 1° and 2°) fall away. No other information duty falls away: never state that the name, address or other identification details are not needed in B2B or e-mail contracts.'
      },
      'website_xii6_8_called_identification' => {
        'nl' => 'Art. XII.6, § 1, 8° WER (verstrekte bron) betreft "de gedragscodes die hij desgevallend heeft onderschreven" en hoe die elektronisch te raadplegen zijn, niet de identificatie; de identificatiegegevens staan in § 1, 1° tot 7° (te beginnen met "zijn naam of handelsnaam").',
        'fr' => 'L’article XII.6, § 1er, 8°, CDE (source fournie) vise "les codes de conduite auxquels il est éventuellement soumis" et leur consultation électronique, pas l’identification ; les données d’identification figurent aux 1° à 7° (à commencer par "son nom ou sa dénomination sociale").',
        'en' => 'Article XII.6, § 1, 8° of the Code of Economic Law (supplied source) concerns the codes of conduct the provider has subscribed to and how to consult them electronically, not identification; the identification details are in § 1, 1° to 7°, starting with the name or trade name.'
      },
      'website_cookie_rule_conditioned_on_personal_data' => {
        'nl' => 'Art. 10/2 (verstrekte bron) regelt "de opslag van informatie of het verkrijgen van toegang tot informatie die reeds is opgeslagen in de eindapparatuur" van een abonnee of gebruiker, met informatie en toestemming, en met de uitzondering voor technische opslag die uitsluitend dient voor de verzending van een communicatie of die "strikt noodzakelijk" is voor een uitdrukkelijk gevraagde dienst. Zet die regel nooit onder de voorwaarde dat u persoonsgegevens verwerkt; behandel de AVG (persoonsgegevens) en art. 10/2 (informatie op het eindapparaat) afzonderlijk.',
        'fr' => 'L’article 10/2 (source fournie) régit le stockage d’informations, ou l’accès à des informations déjà stockées, dans l’équipement terminal d’un abonné ou d’un utilisateur, avec information et consentement, et l’exception pour le stockage technique servant uniquement à la transmission d’une communication ou strictement nécessaire à un service expressément demandé. Ne le soumettez jamais à la condition de traiter des données personnelles ; traitez le RGPD et l’article 10/2 séparément.',
        'en' => 'Article 10/2 (supplied source) governs storing information, or accessing information already stored, on a subscriber’s or user’s terminal equipment, with information and consent, and the exception for technical storage whose sole purpose is transmitting a communication or that is strictly necessary for a service the user explicitly requested. Never make it conditional on processing personal data; treat the GDPR and article 10/2 separately.'
      }
    }.freeze

    def self.evaluate(answer, question, sources)
      text = answer.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS
      return result(false, []) unless CommercialWebsiteIntent.topic?(question.to_s)

      xii10 = GroundingScope.evidenced_units(sources, **XII10, evidence: XII10_EVIDENCE)
      xii6 = GroundingScope.evidenced_units(sources, **XII6, evidence: XII6_EVIDENCE)
      storage = GroundingScope.evidenced_units(sources, **TERMINAL_STORAGE, evidence: TERMINAL_STORAGE_EVIDENCE)
      return result(false, []) if xii10.empty? && xii6.empty? && storage.empty?

      units = xii10 + xii6 + storage
      missing = []
      GroundingScope.sections(text).each do |section|
        heading_condition = storage.any? && conditioned_on_personal_data?(section[:heading])
        section[:lines].each do |line|
          next if line[:quote] && GroundingScope.verbatim_quote?(line[:text], units)

          missing << 'website_cookie_rule_conditioned_on_personal_data' if heading_condition && line[:text].match?(TERMINAL_TERM)
          GroundingScope.sentences(line[:text]).each do |sentence|
            missing << 'website_identification_exempted' if xii10.any? && identification_exempted?(sentence)
            missing << 'website_xii6_8_called_identification' if xii6.any? && eight_called_identification?(sentence)
            if storage.any? && sentence.match?(TERMINAL_TERM) && conditioned_on_personal_data?(sentence)
              missing << 'website_cookie_rule_conditioned_on_personal_data'
            end
          end
        end
      end
      result(true, missing)
    end

    # An exemption predicate whose object is an identification duty, in a
    # B2B or e-mail clause, neither corrected nor negated.
    def self.identification_exempted?(sentence)
      return false if sentence.match?(GroundingScope::CORRECTION_PREFIX)

      # A negation inside a B2B description ("die niet als consument
      # handelen") does not negate the predicate.
      masked = sentence.gsub(B2B_OR_EMAIL) { |phrase| ' ' * phrase.length }
      sentence.to_enum(:scan, IDENTIFICATION).any? do
        object = Regexp.last_match
        start, stop = GroundingScope.main_clause_bounds(sentence, object.begin(0))
        clause = sentence[start...stop]
        next false unless clause.match?(B2B_OR_EMAIL) && !clause.match?(GroundingScope::CLAUSE_DENIAL)

        exemption_asserted?(masked, object.begin(0), object.end(0), start, stop) ||
          not_required?(sentence, object.end(0), stop) || hoeft_gap?(sentence, object.begin(0), stop)
      end
    end

    # An EXEMPT word within reach of the object in its main clause, with no
    # negator in the three words before it, nor after it up to the end of the
    # object's comma part ("vervalt de identificatieplicht niet", "entfällt
    # die Angabe des Namens nicht").
    def self.exemption_asserted?(masked, object_start, object_end, start, stop)
      from = [object_start - 90, start].max
      window = masked[from...[object_end + 60, stop].min]
      window.to_enum(:scan, EXEMPT).any? do
        predicate = Regexp.last_match
        first = from + predicate.begin(0)
        last = from + predicate.end(0)
        next false if last <= object_start && masked[last...object_start].split.length > 12

        part_end = [masked.index(/[,:;]/, [last, object_end].max) || stop, stop].min
        words = masked[start...first].split.last(3) + masked[last...part_end].split
        words.none? { |word| word.gsub(/[^\p{L}'’]/, '').match?(NEGATOR) }
      end
    end

    # "naam en adres niet te vermelden", "n'est pas requise" after the
    # object, within its comma part.
    def self.not_required?(sentence, object_end, stop)
      part_end = [sentence.index(/[,:;]/, object_end) || stop, stop, object_end + 70].min
      sentence[object_end...part_end].match?(NOT_REQUIRED)
    end

    # "hoeft u uw naam en adres niet te vermelden": the object between them,
    # inside one main clause.
    def self.hoeft_gap?(sentence, index, stop)
      sentence.to_enum(:scan, /\b(?:hoeft|hoeven|hoef)\b(.{0,80}?)\bniet\b/i).any? do
        match = Regexp.last_match
        match.begin(1) <= index && index < match.end(1) && match.end(0) <= stop
      end
    end

    # XII.6, § 1, 8° labelled as identification: an identification word
    # within four words of the reference, nothing detaching them, and not
    # negated ("niet de identificatie", "de identificatie niet").
    def self.eight_called_identification?(sentence)
      return false if sentence.match?(GroundingScope::CORRECTION_PREFIX)

      sentence.to_enum(:scan, REFERENCE_8).any? do
        reference = Regexp.last_match
        start, stop = GroundingScope.main_clause_bounds(sentence, reference.begin(0))
        next false if sentence[start...stop].match?(GroundingScope::CLAUSE_DENIAL)

        labelled_identification?(sentence, reference.begin(0), reference.end(0), start, stop)
      end
    end

    def self.labelled_identification?(sentence, reference_start, reference_end, start, stop)
      from = [reference_start - 60, start].max
      sentence[from...[reference_end + 60, stop].min].to_enum(:scan, IDENTIFICATION_DUTY).any? do
        duty = Regexp.last_match
        first = from + duty.begin(0)
        last = from + duty.end(0)
        between = last <= reference_start ? sentence[last...reference_start] : sentence[reference_end...first]
        between.split.length <= 4 && !between.match?(DETACHED) &&
          !sentence[[first - 25, start].max...last].match?(NOT_IDENTIFICATION) &&
          !sentence[last...[last + 12, stop].min].match?(/\A\s*(?:niet|not|nicht|pas)\b/i)
      end
    end

    # "alleen als u persoonsgegevens verwerkt", but not "niet alleen ...".
    def self.conditioned_on_personal_data?(text)
      text.to_s.to_enum(:scan, ONLY_IF_PERSONAL_DATA).any? do
        !text[0...Regexp.last_match.begin(0)].match?(NOT_ONLY)
      end
    end

    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = SeriousCauseDismissalGrounding.feedback_language(language)
      header = { 'nl' => 'Herstel ook deze fouten in de reikwijdte van de websiteregels:',
                 'fr' => 'Corrigez aussi ces erreurs de portée des règles applicables au site :',
                 'en' => 'Also correct these scope errors in the website rules:' }.fetch(lang)
      ([header] + codes.uniq.map { |code| "- #{FEEDBACK.fetch(code).fetch(lang)}" }).join("\n")
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
