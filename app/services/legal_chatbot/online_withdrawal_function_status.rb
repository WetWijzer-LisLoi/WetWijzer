# frozen_string_literal: true

module LegalChatbot
  # One hand-verified status record, the r47 stage A holdout-915 failure (root
  # 2026-10-19 23:16:30 to 23:36:18): WER art. VI.61/2, the online withdrawal
  # function, is in force since 14 August 2026. Verified by the art. VI.61/2
  # Justel note itself (laws.prod ids 11120030 and 11120047) and FOD Economie
  # guidance of 7 September 2026, section 8. No status is inferred from
  # amendment notes in general, from other articles or from law titles: the
  # check applies only when the retained VI.61/2 carries this exact note and
  # the date in force is reached, and it reads only claims that this
  # function or provision is not yet in force. A plain future tense ("zal
  # gelden voor", "will apply to") describes the rule and is no such claim.
  # A question or answer framed before 14 August 2026 keeps its historical
  # answer. Passing does not verify an answer.
  class OnlineWithdrawalFunctionStatus
    VERSION = 1
    CONDITION_CODES = %w[online_withdrawal_function_called_future].freeze
    RECORD = {
      numac: '2013A11134', article: 'VI.61/2', in_force_since: Date.new(2026, 8, 14),
      evidence: {
        nl: ['Ingevoegd bij W 2026-07-19/05, art. 23, 147; Inwerkingtreding : 14-08-2026', 'herroepingsfunctie'],
        fr: ['Inséré par L 2026-07-19/05, art. 23, 147; En vigueur : 14-08-2026', 'fonction de rétractation']
      }
    }.freeze
    MAX_ANSWER_CHARS = 200_000

    FUNCTION = /\b(?:herroepingsfunctie|online[-\s]herroepingsverklaring|hier\s+de\s+overeenkomst\s+herroepen|fonction\s+de\s+rétractation|renoncer\s+au\s+contrat\s+ici|withdrawal\s+(?:function|button)|cancellation\s+(?:function|button)|widerrufsfunktion|widerrufsbutton|widerrufsschaltfläche)\b/i
    UNIT_REFERENCE = %r{VI\.\s?61/2|art-vi-61-2}i
    ANAPHOR = /\b(?:die|deze|dit)\s+(?:bepaling|verplichting|regel|functie)\b|\bcette\s+(?:disposition|obligation|règle|fonction)\b|\bthis\s+(?:provision|obligation|rule|function)\b|\bdiese\s+(?:bestimmung|pflicht|regel|funktion)\b/i
    FUTURE = Regexp.union(
      /\b(?:pas\s+)?later\s+(?:van\s+kracht|in\s+werking|van\s+toepassing)\b/i,
      /\bnog\s+niet\s+(?:in\s+werking|van\s+kracht|van\s+toepassing|verplicht|geldig)\b/i,
      /\btreedt\s+(?:pas\s+(?:later\s+)?|later\s+)in\s+werking\b/i,
      /\bzal\s+pas\s+(?:\S+\s+){0,3}?(?:in\s+werking\s+treden|van\s+toepassing\s+(?:zijn|worden)|gelden)\b/i,
      /\bzal\s+(?:\S+\s+){0,3}?(?:in\s+werking\s+treden|van\s+toepassing\s+worden)\b/i,
      /\bwordt\s+(?:pas\s+(?:later\s+)?|later\s+)van\s+kracht\b/i,
      /\bn['’]est\s+pas\s+encore\s+(?:en\s+vigueur|applicable|obligatoire)\b/i,
      /\bne\s+s['’]applique\s+pas\s+encore\b|\bentrera\s+en\s+vigueur\b|\bs['’]appliquera\s+(?:plus\s+tard|seulement|à\s+partir)\b/i,
      /\bnot\s+yet\s+(?:in\s+force|applicable|in\s+effect|mandatory)\b/i,
      /\bwill\s+(?:only\s+)?(?:enter\s+into\s+force|take\s+effect|become\s+(?:applicable|mandatory))\b|\bwill\s+only\s+apply\b|\bwill\s+apply\s+(?:only\s+)?(?:from|as\s+of|later)\b/i,
      /\bcomes?\s+into\s+(?:force|effect)\s+later\b/i,
      /\bnoch\s+nicht\s+(?:in\s+kraft|anwendbar|verpflichtend)\b|\btritt\s+(?:erst\s+(?:später\s+)?|später\s+)in\s+kraft\b|\bgilt\s+(?:erst\s+später|noch\s+nicht)\b/i
    )
    PAST_NOT_YET = /\b(?:was|waren)\s+(?:\S+\s+){0,3}?nog\s+niet\b|\bn['’](?:était|étaient)\s+pas\s+encore\b|\b(?:was|were)\s+not\s+yet\b|\b(?:war|waren)\s+noch\s+nicht\b|\bgalt\s+noch\s+nicht\b/i
    # "is niet pas later van kracht": the future reading itself negated.
    NEGATED = /\b(?:niet|not|nicht|non)\s+\z/i

    FEEDBACK = {
      'nl' => 'Art. VI.61/2 WER (verstrekte bron) draagt de nota "Ingevoegd bij W 2026-07-19/05, art. 23, 147; Inwerkingtreding : 14-08-2026"; die datum ligt vóór de CURRENT DATE. Stel de "herroepingsfunctie" voor als een geldende verplichting, niet als iets dat later of nog niet van kracht is, tenzij de vraag uitdrukkelijk naar een eerdere datum vraagt.',
      'fr' => 'L’article VI.61/2 CDE (source fournie) porte la note "Inséré par L 2026-07-19/05, art. 23, 147; En vigueur : 14-08-2026" ; cette date précède la DATE ACTUELLE. Présentez la "fonction de rétractation" comme une obligation en vigueur, non comme une règle future ou pas encore applicable, sauf si la question vise expressément une date antérieure.',
      'en' => 'Article VI.61/2 of the Code of Economic Law (supplied source) carries the note that it was inserted by the law of 19 July 2026, art. 23, with entry into force on 14-08-2026; that date is before the CURRENT DATE. Present the online withdrawal function as an obligation in force, not as something that applies later or is not yet in force, unless the question expressly asks about an earlier date.'
    }.freeze

    def self.evaluate(answer, question, sources, as_of: Date.current)
      text = answer.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS

      units = GroundingScope.evidenced_units(sources, numac: RECORD.fetch(:numac), article: RECORD.fetch(:article),
                                                      evidence: RECORD.fetch(:evidence))
      return result(false, []) if units.empty? || as_of < RECORD.fetch(:in_force_since)
      return result(true, []) if GroundingScope.question_frames(question).any? { |range| before_in_force?(range) }

      claim = GroundingScope.sections(text).any? do |section|
        next false if GroundingScope.historical_heading?(section[:heading], before: RECORD.fetch(:in_force_since))

        section[:lines].any? do |line|
          next false if line[:quote] && GroundingScope.verbatim_quote?(line[:text], units)

          about_unit = line[:text].match?(FUNCTION) || line[:text].match?(UNIT_REFERENCE)
          GroundingScope.sentences(line[:text]).any? { |sentence| future_claim?(sentence, about_unit) }
        end
      end
      result(true, claim ? CONDITION_CODES.dup : [])
    end

    def self.future_claim?(sentence, about_unit)
      subject = sentence.match?(FUNCTION) || sentence.match?(UNIT_REFERENCE) || (about_unit && sentence.match?(ANAPHOR))
      return false unless subject

      sentence.to_enum(:scan, FUTURE).any? do
        index = Regexp.last_match.begin(0)
        start, stop = GroundingScope.main_clause_bounds(sentence, index)
        clause = sentence[start...stop]
        next false if GroundingScope.denied?(sentence, clause) || clause.match?(PAST_NOT_YET)
        next false if sentence[start...index].match?(NEGATED)

        GroundingScope.frames(clause).none? { |range| before_in_force?(range) }
      end
    end

    def self.before_in_force?(range)
      range[1] < RECORD.fetch(:in_force_since)
    end

    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = SeriousCauseDismissalGrounding.feedback_language(language)
      header = { 'nl' => 'Herstel ook deze fout over de online herroepingsfunctie:',
                 'fr' => 'Corrigez aussi cette erreur sur la fonction de rétractation en ligne :',
                 'en' => 'Also correct this error about the online withdrawal function:' }.fetch(lang)
      "#{header}\n- #{FEEDBACK.fetch(lang)}"
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
