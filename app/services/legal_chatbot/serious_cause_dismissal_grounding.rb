# frozen_string_literal: true

module LegalChatbot
  # Art. 35 Arbeidsovereenkomstenwet, the r47 stage A july-18 failure (root
  # 2026-10-19 23:10:22 to 23:36:52). The first three-working-day period is a
  # cut-off ("mag niet meer ... wanneer het feit ... sedert ten minste drie
  # werkdagen bekend is"), never a minimum the fact must be known for; the
  # second is notice of the reasons WITHIN three working days after the
  # dismissal. Only a permission or obligation modal makes a rule: "Het feit
  # kan al minstens drie werkdagen bekend zijn. Dan is het ontslag te laat."
  # states a possibility, not a minimum. A negated modal is the statute's own
  # prohibition ("mag niet worden gegeven wanneer ..."), unless a
  # precondition turns it into a wait ("mag niet ontslaan voordat ...").
  # Applies only when the retained Art. 35 carries that wording; reads prose
  # and any quote that is not the unit's own wording. Passing does not verify
  # an answer.
  class SeriousCauseDismissalGrounding
    VERSION = 1
    CONDITION_CODES = %w[serious_cause_first_deadline_inverted serious_cause_notification_window_inverted].freeze
    UNIT = { numac: '1978070303', article: '35' }.freeze
    EVIDENCE = {
      nl: ['sedert ten minste drie werkdagen bekend is', 'binnen drie werkdagen na het ontslag'],
      fr: ['depuis trois jours ouvrables au moins', 'dans les trois jours ouvrables qui suivent le congé']
    }.freeze
    MAX_ANSWER_CHARS = 200_000

    THREE_DAYS = '(?:drie|3|trois|three|drei)\s+(?:werkdagen|werkdag|jours\s+ouvrables|jours\s+ouvrés|working\s+days|business\s+days|werktagen|werktage|arbeitstagen|arbeitstage)'
    MINIMUM_DAYS = /\b(?:ten\s+minste|tenminste|minstens|minimaal|minimum|au\s+moins|au\s+minimum|at\s+least|a\s+minimum\s+of|mindestens|wenigstens)\s+#{THREE_DAYS}\b|\b#{THREE_DAYS}\s+(?:au\s+moins|au\s+minimum)\b/i
    WAITING = /\b(?:pas|eerst|seulement|only|erst)\s+(?:na|après|after|nach)\s+(?:(?:ten\s+minste|minstens|au\s+moins|at\s+least|mindestens)\s+)?#{THREE_DAYS}\b/i
    # Permission or obligation; "kan", "peut", "can", "may", "kann" are not.
    NORMATIVE = /\b(?:mag|mogen|moet|moeten|dient|dienen|hoort|horen|doit|doivent|devra|devront|faut|must|should|has\s+to|have\s+to|needs?\s+to|required\s+to|muss|müssen|darf|dürfen|soll|sollen)\b/i
    KNOWLEDGE = /\b(?:bekend|connu|connue|connus|known|aware|bekannt|kenntnis)\b|\bkennis\s+(?:van|heeft|had|krijgt|kreeg)\b|\bconnaissance\s+(?:du|de)\b|\bknowledge\s+of\b/i
    DISMISSAL = /\b(?:ontslag\p{L}*|ontsla\p{L}*|congé|licenci\p{L}*|dismiss\p{L}*|entlass\p{L}*|kündig\p{L}*)\b/i
    NOTIFICATION = /\b(?:kennisgeving|ter\s+kennis|kennis\s+(?:te\s+|is\s+)?(?:geven|gegeven)|meedel\p{L}*|meegedeeld|mededel\p{L}*|notifi\p{L}*|notify\p{L}*|mitteil\p{L}*)\b/i
    AFTER_DISMISSAL = /\b(?:na\s+het\s+ontslag|na\s+de\s+opzegging|après\s+le\s+(?:congé|licenciement)|qui\s+suivent\s+le\s+congé|after\s+(?:the\s+)?dismissal|nach\s+der\s+(?:entlassung|kündigung))\b/i
    # The statute's own limit: once known for three working days, no longer,
    # or too late.
    LIMIT = /\b(?:niet\s+meer|niet\s+langer|nooit\s+meer|ne\s+(?:peut|peuvent|pourra|pourront)\s+(?:\S+\s+){0,3}?plus|n['’](?:est|sont)\s+plus|no\s+longer|(?:cannot|can\s*not|can't)\s+(?:\S+\s+){0,4}?(?:any\s+longer|anymore)|nicht\s+mehr|te\s+laat|trop\s+tard|too\s+late|zu\s+spät)\b/i
    # A modal negated in its own comma part is a prohibition: "mag niet
    # worden gegeven wanneer", "must not be given once", "ne doit pas être
    # donné lorsque", "darf nicht ..., wenn". French "ne ... que" (only) is
    # no negation.
    NEGATION = /\b(?:niet|geen|nooit|not|never|cannot|nicht|kein\p{L}*|nie|ne)\b|\bn['’]|\b\p{L}+n['’]t\b/i
    FRENCH_NE = /\bne\b|\bn['’]/i
    FRENCH_ONLY = /\bque\b|\bqu['’]/i
    FRENCH_NEGATION = /\b(?:pas|plus|jamais|point|aucun\p{L}*|nul\p{L}*)\b/i
    # A period inside a condition clause is governed by the modal of its main
    # clause ("..., wanneer het feit sedert ten minste ...").
    CONDITION = /\b(?:wanneer|als|indien|zodra|ingeval|lorsque|si|quand|dès\s+que|when|whenever|if|once|where|wenn|sobald|falls|sofern)\b/i
    # A precondition reverses that reading: "mag niet ontslaan voordat het
    # feit ten minste drie werkdagen bekend is" requires a wait, "moet
    # ontslaan voordat ..." states the deadline. The statute's "before the end
    # of the term" is no precondition.
    PRECONDITION = /\b(?:voordat|vooraleer|alvorens|tenzij|behalve|totdat|zolang|avant\s+(?:que|qu['’]|d['’]|de)|tant\s+que|à\s+moins\s+que|sauf|jusqu['’]à\s+ce\s+que|before(?!\s+the\s+(?:expiry|expiration|end)\b)|until|unless|except|as\s+long\s+as|bevor|ehe|solange|es\s+sei\s+denn|außer)\b/i
    # A wait stated outright, whatever else the clause negates.
    NOT_EARLIER = /\b(?:niet\s+eerder|niet\s+vroeger|not\s+(?:earlier|sooner)|nicht\s+(?:früher|eher|vorher))\b/i

    FEEDBACK = {
      'serious_cause_first_deadline_inverted' => {
        'nl' => 'Art. 35 Arbeidsovereenkomstenwet (verstrekte bron) bepaalt dat ontslag om een dringende reden niet meer mag worden gegeven wanneer het feit "sedert ten minste drie werkdagen bekend is" aan de partij die zich erop beroept: de eerste termijn is een uiterste termijn, geen minimale wachttijd. Formuleer niet dat het feit ten minste drie werkdagen bekend moet of mag zijn.',
        'fr' => 'L’article 35 de la loi sur les contrats de travail (source fournie) dispose que le congé pour motif grave ne peut plus être donné lorsque le fait est connu "depuis trois jours ouvrables au moins" : le premier délai est un délai maximal, pas une attente minimale. N’écrivez pas que le fait doit ou peut être connu depuis au moins trois jours ouvrables.',
        'en' => 'Article 35 of the Employment Contracts Act (supplied source) provides that dismissal for serious cause can no longer be given once the fact has been known for at least three working days to the party relying on it: the first period is a deadline, not a minimum waiting time. Do not state that the fact must or may be known for at least three working days.'
      },
      'serious_cause_notification_window_inverted' => {
        'nl' => 'Art. 35 Arbeidsovereenkomstenwet (verstrekte bron): alleen de dringende reden waarvan kennis is gegeven "binnen drie werkdagen na het ontslag" kan worden aangevoerd. De kennisgeving valt dus binnen die drie werkdagen, niet pas ten minste drie werkdagen na het ontslag.',
        'fr' => 'L’article 35 de la loi sur les contrats de travail (source fournie) : seul le motif grave notifié "dans les trois jours ouvrables qui suivent le congé" peut être invoqué. La notification intervient donc dans ce délai, pas au moins trois jours ouvrables après le congé.',
        'en' => 'Article 35 of the Employment Contracts Act (supplied source): only a serious cause notified within three working days after the dismissal can be invoked. The notification falls within those three working days, not at least three working days after the dismissal.'
      }
    }.freeze

    def self.evaluate(answer, _question, sources)
      text = answer.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS

      units = GroundingScope.evidenced_units(sources, **UNIT, evidence: EVIDENCE)
      return result(false, []) if units.empty?

      missing = []
      GroundingScope.sections(text).each do |section|
        section[:lines].each do |line|
          next if line[:quote] && GroundingScope.verbatim_quote?(line[:text], units)

          GroundingScope.sentences(line[:text]).each do |sentence|
            missing << 'serious_cause_first_deadline_inverted' if first_deadline_inverted?(sentence)
            missing << 'serious_cause_notification_window_inverted' if notification_window_inverted?(sentence)
          end
        end
      end
      result(true, missing)
    end

    # A minimum the fact must or may be known for, or a dismissal that must
    # wait for three working days, that no limit or prohibition governs.
    def self.first_deadline_inverted?(sentence)
      [MINIMUM_DAYS, WAITING].any? do |pattern|
        sentence.to_enum(:scan, pattern).any? do
          index = Regexp.last_match.begin(0)
          clause = GroundingScope.main_clause(sentence, index)
          next false if GroundingScope.segment(sentence, index).match?(NOTIFICATION)
          next false unless clause.match?(NORMATIVE)
          next false unless clause.match?(pattern == MINIMUM_DAYS ? KNOWLEDGE : DISMISSAL)

          !limited?(sentence, clause, index)
        end
      end
    end

    # Notice of the reasons placed at least three working days after the
    # dismissal instead of within them: the period and "na het ontslag" in
    # one comma part, so a correct "binnen ... na het ontslag" elsewhere in
    # the sentence is not read as one.
    def self.notification_window_inverted?(sentence)
      [MINIMUM_DAYS, WAITING].any? do |pattern|
        sentence.to_enum(:scan, pattern).any? do
          index = Regexp.last_match.begin(0)
          clause = GroundingScope.main_clause(sentence, index)
          next false unless GroundingScope.segment(sentence, index).match?(AFTER_DISMISSAL)
          next false unless clause.match?(NOTIFICATION) && clause.match?(NORMATIVE)

          !limited?(sentence, clause, index)
        end
      end
    end

    # Whether the clause states the cut-off rather than a wait: the statute's
    # limit, a denial, or a prohibition (a precondition reverses the
    # prohibition's reading).
    def self.limited?(sentence, clause, index)
      return true if clause.match?(LIMIT) || GroundingScope.denied?(sentence, clause)
      return false if clause.match?(NOT_EARLIER)

      lead = part_lead(sentence, index)
      if lead.match?(PRECONDITION)
        !prohibition?(clause)
      elsif lead.match?(CONDITION)
        prohibition?(clause)
      else
        prohibition?(GroundingScope.segment(sentence, index))
      end
    end

    # A modal and a negation in one comma part, before any precondition.
    def self.prohibition?(text)
      text.split(/[,:]/).any? do |part|
        head = part.split(PRECONDITION, 2).first.to_s
        head.match?(NORMATIVE) && head.match?(NEGATION) && !french_only?(head)
      end
    end

    def self.french_only?(text)
      text.match?(FRENCH_NE) && text.match?(FRENCH_ONLY) && !text.match?(FRENCH_NEGATION)
    end

    # The words of the period's own comma part that precede it.
    def self.part_lead(sentence, index)
      start, = GroundingScope.main_clause_bounds(sentence, index)
      lead = sentence[start...index]
      cut = lead.rindex(/[,:]/)
      cut ? lead[(cut + 1)..] : lead
    end

    # The German lane answers in French before translation, so German takes
    # the French text; any other language takes English.
    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = feedback_language(language)
      header = { 'nl' => 'Herstel ook deze fout over de termijnen van het ontslag om dringende reden:',
                 'fr' => 'Corrigez aussi cette erreur sur les délais du congé pour motif grave :',
                 'en' => 'Also correct this error about the serious-cause dismissal periods:' }.fetch(lang)
      ([header] + codes.uniq.map { |code| "- #{FEEDBACK.fetch(code).fetch(lang)}" }).join("\n")
    end

    def self.feedback_language(language)
      language = language.to_s
      return 'fr' if language == 'de'

      %w[nl fr en].include?(language) ? language : 'en'
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
