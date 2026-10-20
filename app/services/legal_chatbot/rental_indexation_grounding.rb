# frozen_string_literal: true

module LegalChatbot
  # Brussels Housing Code art. 224/2, the r47 stage A july-284 failure (root
  # 2026-10-19 23:14:19 to 23:36:18). § 1/1 froze the indexation of an F or G
  # dwelling for twelve months from 14 October 2022; § 1/2, 2° multiplies the
  # indexed rent for F or G by a correction factor from 14 October 2023. A
  # CURRENT freeze claim is false. Historical only with an explicit frame:
  # past tense governing the freeze, a closed period, an expiry, a frame
  # inside the freeze period (in the claim, its section heading, or the
  # question), never a stray year, "tijdelijk" or "vanaf 2022". The § 1/1
  # wording quoted under a current heading or lead-in is a current claim
  # too. A partial indexation ("niet volledig geïndexeerd") is the current
  # rule, not the freeze. Applies only when the retained art. 224/2 carries
  # both paragraphs. Passing does not verify an answer.
  class RentalIndexationGrounding
    VERSION = 1
    CONDITION_CODES = %w[brussels_fg_freeze_presented_as_current].freeze
    UNIT = { numac: '2013A31614', article: '224/2' }.freeze
    EVIDENCE = {
      nl: ['F of G is afgegeven', 'niet aangepast mogen worden aan de kosten van het levensonderhoud',
           'geldt voor twaalf maanden', 'Inwerkingtreding : 14-10-2022', 'energieklasse F of G',
           'vanaf 14 oktober 2023 vermenigvuldigd met een correctiefactor'],
      fr: ['F ou G a été délivré', "il ne peut y avoir d'adaptation du loyer au coût de la vie",
           'est valable 12 mois', 'En vigueur : 14-10-2022', 'classe énergétique F ou G',
           'est multiplié par un facteur de correction à partir du 14 octobre 2023']
    }.freeze
    FREEZE_FROM = Date.new(2022, 10, 14)
    FREEZE_UNTIL = Date.new(2023, 10, 13)
    FREEZE_WORDING = ['niet aangepast mogen worden aan de kosten van het levensonderhoud',
                      "il ne peut y avoir d'adaptation du loyer au coût de la vie"].freeze
    MAX_ANSWER_CHARS = 200_000

    # Energy class F or G; the letters are matched in capitals only.
    CLASS_FG = %r{(?<!\p{L})(?:[FG]\s*(?:of|ou|or|oder|en|et|and|und|/)\s*[FG]|(?:EPB|PEB|EPC|[Ee]nergie\p{L}*|[Kk]lasse|[Cc]lasse|[Cc]lass|[Ll]abel)[\s-]+(?:\p{L}+\s+){0,2}?[FG])(?!\p{L})}
    FREEZE = Regexp.union(
      /\b(?:mag|mogen|kan|kunnen)\s+(?:\S+\s+){0,9}?niet\s+(?:\S+\s+){0,3}?(?:aangepast|geïndexeerd|geindexeerd|verhoogd|indexeren)\b/i,
      /\bniet\s+(?:meer\s+)?(?:worden\s+)?(?:aangepast|geïndexeerd|geindexeerd)\s+(?:mogen\s+|kunnen\s+)?worden\b/i,
      /\bniet\s+(?:meer\s+)?worden\s+(?:aangepast|geïndexeerd|geindexeerd)\b/i,
      /\bgeen\s+(?:aanpassing|indexering|indexatie)\b/i,
      /\bindexering\s+is\s+(?:verboden|uitgesloten|niet\s+toegestaan)\b/i,
      /\bindexeringsstop\b|\bbevroren\b/i,
      /\bne\s+(?:peut|peuvent)\s+(?:pas\s+|plus\s+)?(?:être\s+)?(?:indexé|adapté|augmenté)\p{L}*/i,
      /\bil\s+ne\s+peut\s+y\s+avoir\s+d['’]adaptation\b/i,
      /\b(?:pas|aucune)\s+(?:d['’])?(?:indexation|adaptation)\b/i,
      /\bgel\s+(?:des\s+loyers|de\s+l['’]indexation)\b/i,
      /\b(?:cannot|can\s*not|can't|may\s+not|must\s+not)\s+be\s+(?:indexed|adjusted|increased)\b/i,
      /\bno\s+(?:indexation|index\s+adjustment|rent\s+indexation)\b|\bindexation\s+(?:freeze|ban)\b/i,
      /\b(?:darf|dürfen|kann|können)\s+(?:\S+\s+){0,9}?nicht\s+(?:\S+\s+){0,2}?(?:indexiert|angepasst|erhöht)\b/i,
      /\bkeine\s+(?:indexierung|indexanpassung|mietanpassung)\b/i
    )
    # A qualifier inside the freeze wording makes it the current partial
    # indexation: "niet volledig", "niet zomaar", "nicht vollständig".
    PARTIAL = /\b(?:volledig\p{L}*|helemaal|zomaar|onbeperkt|integraal|hoger|boven|vollständig|voll|uneingeschränkt|höher)\b/i
    PAST = Regexp.union(
      /\b(?:mocht|mochten|kon|konden|gold|golden|was|waren|werd|pouvait|pouvaient|était|étaient|a\s+été|could|couldn't|were|durfte|durften|konnte|konnten|galt|galten|war|wurde|wurden)\b/i,
      # The Dutch past plural "werden" only beside a Dutch participle: the
      # German "werden" is the present passive ("darf nicht indexiert werden").
      /\bwerden\s+(?:\S+\s+){0,8}?(?:geïndexeerd|geindexeerd|aangepast|verhoogd)\b|\b(?:geïndexeerd|geindexeerd|aangepast|verhoogd)\s+werden\b/i
    )
    CLOSED_PERIOD = /\b(?:(?:van|vanaf)\s+14\s+oktober\s+2022\s+tot(?:\s+en\s+met)?\s+13\s+oktober\s+2023|tussen\s+14\s+oktober\s+2022\s+en\s+13\s+oktober\s+2023|tot(?:\s+en\s+met)?\s+13\s+oktober\s+2023|du\s+14\s+octobre\s+2022\s+au\s+13\s+octobre\s+2023|jusqu['’]au\s+13\s+octobre\s+2023|(?:from\s+14\s+october\s+2022\s+)?(?:to|until|till)\s+13\s+october\s+2023|(?:vom\s+14\.\s*oktober\s+2022\s+)?bis\s+(?:zum\s+)?13\.\s*oktober\s+2023)\b/i
    EXPIRY = /\b(?:verstreken|vervallen|afgelopen|niet\s+meer\s+van\s+toepassing|n['’]est\s+plus\s+(?:applicable|d['’]application|en\s+vigueur)|expired|no\s+longer\s+(?:applies|applicable|in\s+force)|abgelaufen|nicht\s+mehr\s+(?:anwendbar|gültig|in\s+kraft))\b/i
    BRUSSELS = /\b(?:brussel\p{L}*|bruxell\p{L}*|brussels|brüssel|bxl)\b/i
    OTHER_REGION = /\b(?:vlaander\p{L}*|vlaams\p{L}*|flandre\p{L}*|flamand\p{L}*|flanders|flemish|wallon\p{L}*|waals\p{L}*|wallonia|walloon)\b/i
    REGION_LABEL = /\A(?:[-*+]\s+)?(?:\S+\s+){0,2}?(brussel\p{L}*|bruxell\p{L}*|brussels|brüssel|vlaander\p{L}*|vlaams\p{L}*|flandre\p{L}*|flanders|wallon\p{L}*|waals\p{L}*|wallonia)\s*[:(]/i
    UNIT_LINK = %r{/laws/2013A31614\b}

    FEEDBACK = {
      'nl' => 'Art. 224/2 Brusselse Huisvestingscode (verstrekte bron): de beperking van § 1/1 bij een EPB-certificaat F of G ("niet aangepast mogen worden aan de kosten van het levensonderhoud") "geldt voor twaalf maanden" en werd ingevoegd met "Inwerkingtreding : 14-10-2022"; § 1/2, 2° bepaalt bij "energieklasse F of G" dat de huurprijs "vanaf 14 oktober 2023 vermenigvuldigd met een correctiefactor" wordt. Presenteer § 1/2 als de huidige regel en § 1/1 alleen als een verstreken regel, tenzij de vraag uitdrukkelijk naar die periode vraagt.',
      'fr' => %(L’article 224/2 du Code bruxellois du Logement (source fournie) : la limitation du § 1er/1 pour un certificat PEB F ou G ("il ne peut y avoir d'adaptation du loyer au coût de la vie") "est valable 12 mois" et a été insérée avec "En vigueur : 14-10-2022" ; le § 1er/2, 2°, prévoit pour la "classe énergétique F ou G" que le loyer "est multiplié par un facteur de correction à partir du 14 octobre 2023". Présentez le § 1er/2 comme la règle actuelle et le § 1er/1 seulement comme une règle expirée, sauf si la question vise expressément cette période.),
      'en' => 'Article 224/2 of the Brussels Housing Code (supplied source): the § 1/1 limitation for an F or G energy certificate (no adjustment to the cost of living) applies for twelve months from its entry into force on 14-10-2022; § 1/2, 2° provides that for energy class F or G the indexed rent is multiplied by a correction factor from 14 October 2023. Present § 1/2 as the current rule and § 1/1 only as an expired rule, unless the question expressly asks about that period.'
    }.freeze

    def self.evaluate(answer, question, sources)
      text = answer.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS

      units = GroundingScope.evidenced_units(sources, **UNIT, evidence: EVIDENCE)
      return result(false, []) if units.empty?
      return result(false, []) unless LegislationSearch.rental_regime(question.to_s) == :residential
      # A question set inside the freeze period may get that period's rule.
      return result(true, []) if GroundingScope.question_frames(question).any? { |range| in_freeze?(range) }

      result(true, current_freeze_claim?(text, units) ? CONDITION_CODES.dup : [])
    end

    def self.current_freeze_claim?(text, units)
      GroundingScope.sections(text).any? do |section|
        next false if GroundingScope.historical_heading?(section[:heading], before: FREEZE_UNTIL + 1) ||
                      section[:heading].match?(CLOSED_PERIOD) || section[:heading].match?(EXPIRY)

        region = region_of(section[:heading])
        lead_in = nil
        section[:lines].any? do |line|
          region = region_of(line[:text]) || region if line[:text].match?(REGION_LABEL)
          claim = if line[:quote] && GroundingScope.verbatim_quote?(line[:text], units)
                    quoted_freeze_as_current?(line[:text], lead_in)
                  else
                    GroundingScope.sentences(line[:text]).any? { |sentence| prose_freeze_claim?(sentence, region) }
                  end
          lead_in = line[:text] unless line[:quote]
          claim
        end
      end
    end

    # A present or normative F/G freeze in Brussels scope, not framed in the
    # past within its own clause.
    def self.prose_freeze_claim?(sentence, region)
      return false unless sentence.match?(CLASS_FG)
      return false unless brussels_scope?(sentence, region)

      sentence.to_enum(:scan, FREEZE).any? do
        match = Regexp.last_match
        index = match.begin(0)
        next false if match[0].match?(PARTIAL)

        clause = GroundingScope.main_clause(sentence, index)
        next false unless clause.match?(CLASS_FG)

        !historical_clause?(sentence, clause, index)
      end
    end

    # The § 1/1 freeze wording quoted without an explicitly historical lead-in.
    def self.quoted_freeze_as_current?(quote, lead_in)
      text = GroundingScope.normalize(quote).downcase
      return false unless FREEZE_WORDING.any? { |wording| text.include?(GroundingScope.normalize(wording).downcase) }
      return true if lead_in.nil?

      GroundingScope.sentences(lead_in).none? do |sentence|
        historical_clause?(sentence, sentence, 0) || sentence.match?(GroundingScope::HISTORICAL_HEADING)
      end
    end

    def self.historical_clause?(sentence, clause, index)
      return true if GroundingScope.denied?(sentence, clause)
      return true if clause.match?(CLOSED_PERIOD) || clause.match?(EXPIRY)
      return true if GroundingScope.segment(sentence, index).match?(PAST)

      GroundingScope.frames(clause).any? { |range| in_freeze?(range) }
    end

    def self.in_freeze?(range)
      GroundingScope.overlaps?(range, FREEZE_FROM, FREEZE_UNTIL) && range[1] <= FREEZE_UNTIL + 365
    end

    def self.brussels_scope?(sentence, region)
      return true if sentence.match?(BRUSSELS) || sentence.match?(UNIT_LINK)
      return false if sentence.match?(OTHER_REGION)

      region == :brussels
    end

    def self.region_of(text)
      return :brussels if text.match?(BRUSSELS)
      return :other if text.match?(OTHER_REGION)

      nil
    end

    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = SeriousCauseDismissalGrounding.feedback_language(language)
      header = { 'nl' => 'Herstel ook deze fout over de Brusselse indexering:',
                 'fr' => 'Corrigez aussi cette erreur sur l’indexation bruxelloise :',
                 'en' => 'Also correct this error about Brussels rent indexation:' }.fetch(lang)
      "#{header}\n- #{FEEDBACK.fetch(lang)}"
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
