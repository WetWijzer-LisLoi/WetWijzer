# frozen_string_literal: true

module LegalChatbot
  # Measured misstatements of supplied DSA articles in short platform-redress
  # answers (the 2026-10-17 depth run), not a general verifier of DSA answers.
  # Each check needs the exact admitted article it is about; a changed,
  # excerpted or other-edition unit disables that check until it is reviewed
  # again. No answer text is logged, and passing does not verify an answer.
  class PlatformRedressGrounding
    VERSION = 1
    CONDITION_CODES = %w[platform_whole_act_size_exemption platform_unsupported_size_threshold
                         platform_pending_dispute_refusal platform_resolved_refusal_inverted platform_unsupported_paragraph].freeze
    REVIEW_AFTER = Date.new(2027, 1, 17)
    MAX_ANSWER_CHARS = 200_000
    MAX_QUESTION_CHARS = 12_000
    CELEX = '02022R2065-20221027'
    # Complete article bodies of the only editions production serves for this
    # CELEX, read read-only from both EU corpora on 2026-10-17: German and
    # French. Neither corpus holds a Dutch or English consolidated edition.
    BODY_SIGNATURES = {
      %w[17 de] => 'e66e76a7a76f448579bfc33307162842f7cae6496aa4a402582142d9657c00c5',
      %w[17 fr] => '52d2662173a2e42e4088617a5edd6a94363182b7ff187ba28381e5cd48154e63',
      %w[19 de] => 'cf6544ba030167166c9ea67fe69a50c54520c72bafe5ac2e62979b4e951b5738',
      %w[19 fr] => '3a33925517faccee53a7577a8f295ca88293aa936556cbb5d8dc282e641223ff',
      %w[20 de] => '2cef95fb15a88e6ae263a616248f8efa58a816fef304a63fbe1db244fbb85265',
      %w[20 fr] => '4e1d59bb5bc72371c05ab94d52e726c9cde6a15aca33b404aef8f70451a86753',
      %w[21 de] => '6ade31603f64755f48e472ad203e38e1fe1bb5c65da39edb19819433df403ac3',
      %w[21 fr] => 'a6e5a203d711c7c61c7f7c15ebf3bafeec4cdd79f376aa9df67acafb645d5d5a'
    }.transform_keys(&:freeze).freeze

    WHOLE_ACT_PATTERN = /\b(?:DSA|digitaledienstenverordening|digitale\s+dienstenverordening|Digital\s+Services\s+Act|Gesetz\s+über\s+digitale\s+Dienste|règlement\s+sur\s+les\s+services\s+numériques|(?:de|deze|die)\s+verordening|(?:the|this)\s+regulation|(?:le|ce)\s+règlement|(?:die|diese)\s+Verordnung|DSA[-\s]?(?:verplichtingen|regels|obligations|rules|Pflichten|Regeln))\b/iu
    NOT_APPLICABLE_PATTERN = /\b(?:geldt|gelden)\s+(?:\p{L}+\s+){0,3}niet\b|\bniet\s+van\s+toepassing\b|\bvall\p{L}*\s+(?:\p{L}+\s+){0,2}niet\s+onder\b|\bdoes(?:n['’]t|\s+not)\s+apply\b|\bdo(?:n['’]t|\s+not)\s+apply\b|\bne\s+s['’]appliqu\p{L}*\s+pas\b|\bn['’]est\s+pas\s+applicable\b|\bgilt\s+(?:\p{L}+\s+){0,3}nicht\b|\bfindet\s+(?:\p{L}+\s+){0,3}keine\s+Anwendung\b|\b(?:vrijgesteld|uitgezonderd|uitgesloten|exempt\p{L}*|excluded|exclu\p{L}*|ausgenommen)\b/iu
    SMALL_PATTERN = /\b(?:klein\p{L}*|micro\p{L}*|kleinst\p{L}*|small|petit\p{L}*|microentreprise\p{L}*|Klein\p{L}*)\b/iu
    # A reference to the part of the act that actually holds the exemption.
    SCOPED_PATTERN = /\b(?:afdeling\p{L}*|section\p{L}*|Abschnitt\p{L}*|bepaalde\s+(?:verplichtingen|bepalingen|regels)|sommige\s+(?:verplichtingen|bepalingen|regels)|deze\s+verplichtingen|certain\p{L}*\s+(?:obligations|provisions|rules|dispositions)|bestimmte\p{L}*\s+(?:Pflichten|Vorschriften|Bestimmungen)|interne?\s+klacht\p{L}*|klachtenprocedure\p{L}*|klachtensyste\p{L}*|buitengerechtelijk\p{L}*|internal\s+complaint\p{L}*|out[-\s]of[-\s]court|réclamation\p{L}*|extrajudiciaire\p{L}*|Beschwerde\p{L}*|außergerichtlich\p{L}*|artikel(?:en)?\s+(?:2[0-8])\b|articles?\s+(?:2[0-8])\b|Artikel\s+(?:2[0-8])\b)/iu
    WHOLE_ACT_DENIAL_PATTERN = /\b(?:onjuist|niet\s+(?:waar|juist|correct)|klopt\s+niet|incorrect|untrue|not\s+(?:true|correct|right)|wrong|faux|inexact|pas\s+(?:vrai|exact|correct)|falsch|unrichtig|nicht\s+(?:richtig|zutreffend|wahr)|unzutreffend)\b[^.!?;\n]{0,25}\b(?:dat|that|que|qu['’]|dass)\b|\b(?:misverstand|misconception|idée\s+reçue|Missverständnis|Irrtum)\b|\b(?:geen\s+(?:algemene\s+)?(?:vrijstelling|uitzondering)\s+(?:van|op)\s+(?:de\s+)?(?:hele|gehele|volledige)|niet\s+(?:\p{L}+\s+){0,2}(?:vrijgesteld|uitgezonderd|uitgesloten)|niet\s+(?:voor\s+|van\s+)?(?:de\s+)?(?:hele|gehele|volledige)|not\s+(?:an?\s+)?(?:exemption|exception|exclusion)\s+from\s+the\s+(?:whole|entire)|not\s+(?:\p{L}+\s+){0,2}exempt\p{L}*|not\s+(?:from\s+)?the\s+(?:whole|entire)|pas\s+(?:une\s+)?(?:exemption|exception|exclusion)\s+de\s+l['’]ensemble|pas\s+(?:\p{L}+\s+){0,2}(?:exempt\p{L}*|exclu\p{L}*)|keine\s+(?:generelle\s+)?(?:Ausnahme|Befreiung)\s+von\s+der\s+gesamten|nicht\s+(?:\p{L}+\s+){0,2}ausgenommen|nicht\s+(?:die\s+)?gesamte)\b/iu
    PEOPLE_FIGURE_PATTERN = /\b(\d{1,3}(?:[.,\s]\d{3})*)\s*(?:\p{L}+\s+){0,2}?(?:werknemers|personeelsleden|medewerkers|werkzame\s+personen|employees|staff|persons|people|salariés|employés|personnes|Beschäftigte\p{L}*|Mitarbeiter\p{L}*|Personen)\b/iu
    MONEY_FIGURE_PATTERN = /(?:€|EUR|euro)\s*(\d{1,3}(?:[.,]\d{1,3})?)\s*(?:miljoen|mln|million\p{L}*|Millionen|Mio\.?)|\b(\d{1,3}(?:[.,]\d{1,3})?)\s*(?:miljoen|mln|million\p{L}*|Millionen|Mio\.?)\s*(?:euro|EUR|€)/iu
    USER_FIGURE_PATTERN = /\b(\d{1,3}(?:[.,]\d{1,3})?)\s*(?:miljoen|mln|million\p{L}*|Millionen|Mio\.?)\s*(?:\p{L}+\s+){0,2}?(?:gebruikers|afnemers|actieve|users|recipients|utilisateurs|destinataires|Nutzer\p{L}*)\b/iu
    REFUSAL_PATTERN = /\b(?:weiger\p{L}*|geweigerd|refus\p{L}*|declin\p{L}*|verweiger\p{L}*|ablehn\p{L}*|abgelehnt)\b/iu
    BODY_PATTERN = /\b(?:buitengerechtelijk\p{L}*|geschil\p{L}*|instantie\p{L}*|orgaan|out[-\s]of[-\s]court|dispute\s+settlement|settlement\s+body|ADR|extrajudiciaire\p{L}*|règlement\s+des\s+litiges|organe\p{L}*|außergerichtlich\p{L}*|Streitbeileg\p{L}*)\b/iu
    # "mag niet weigeren als hetzelfde geschil reeds is beslecht" reverses the
    # Article 21 refusal ground (2026-10-17 run); "tenzij" keeps it correct.
    NEGATED_REFUSAL_PATTERN = /\b(?:mag|mogen|kan|kunnen|may|can|peut|peuvent|darf|dürfen|kann|können)\s+(?:\p{L}+\s+){0,3}?(?:niet|not|pas|nicht|kein\p{L}*|nooit|never|jamais|nie)\s+(?:\p{L}+\s+){0,4}?(?:weiger\p{L}*|refus\p{L}*|declin\p{L}*|verweiger\p{L}*|ablehn\p{L}*)|\b(?:cannot|can['’]t)\s+(?:\p{L}+\s+){0,3}?(?:refus\p{L}*|declin\p{L}*)/iu
    RESOLVED_PATTERN = /\b(?:al|reeds|eerder|already|previously|déjà|bereits|schon)\s+(?:\p{L}+\s+){0,2}?(?:beslecht|opgelost|beslist|afgehandeld|resolved|settled|résolu\p{L}*|réglé\p{L}*|beigelegt|entschieden)\b/iu
    EXCEPTION_WORD_PATTERN = /\b(?:tenzij|behalve|uitgezonderd|unless|except|sauf|à\s+moins|es\s+sei\s+denn|außer)\b/iu
    # French "pendant" alone also means "during"; only its pending senses count.
    PENDING_PATTERN = /\b(?:aanhangig|hangende|lopend\p{L}*|in\s+behandeling|nog\s+niet\s+(?:beslecht|opgelost|beslist)|pending|ongoing|still\s+being|en\s+cours|litiges?\s+pendants?|pendante?s?\s+devant|encore\s+pendante?s?|anhängig|laufend\p{L}*|noch\s+nicht\s+(?:beigelegt|entschieden))\b/iu
    PENDING_DENIAL_PATTERN = /\b(?:niet|geen|not|no|pas|nicht|kein\p{L}*)\s+(?:\p{L}+\s+){0,4}?(?:aanhangig|hangende|lopend\p{L}*|pending|ongoing|en\s+cours|anhängig|laufend\p{L}*)|\b(?:aanhangig|lopend\p{L}*|pending|en\s+cours|anhängig)\p{L}*[^.!?;\n]{0,60}?\b(?:volstaat|is|zijn|suffit|suffices|reicht|ist)[\s,]+(?:\p{L}+[\s,]+){0,2}?(?:niet|geen|not|no|pas|nicht|kein\p{L}*)\b|\b(?:alleen|enkel|uitsluitend|only|seulement|uniquement|nur)\b[^.!?;\n]{0,80}\b(?:al\s+(?:eerder\s+)?(?:beslecht|opgelost|beslist)|already\s+(?:been\s+)?resolved|déjà\s+(?:été\s+)?résolu|bereits\s+beigelegt)\b[^.!?;\n]{0,60}\b(?:niet|not|pas|nicht)\b/iu

    class << self
      def topic?(question)
        question.to_s.length <= MAX_QUESTION_CHARS && EuTopicIntent.plan(question.to_s)&.dig(:topic) == :platform_redress
      end

      def evidence(sources)
        return {} if Date.current > REVIEW_AFTER

        EuSealedUnits.selected(sources, celex: CELEX, signatures: BODY_SIGNATURES)
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) ? evidence(sources) : {}
        return { applicable: false, missing_conditions: [], version: VERSION } if grounded.empty?

        text = answer.to_s[0, MAX_ANSWER_CHARS]
        source_texts = Array(sources).filter_map { |source| source_text(source) }
        missing = []
        sentences(text).each do |sentence|
          missing << 'platform_whole_act_size_exemption' if grounded['19'] && whole_act_exemption?(sentence)
          missing << 'platform_unsupported_size_threshold' if grounded['19'] && unsupported_figure?(sentence, source_texts)
          missing << 'platform_pending_dispute_refusal' if grounded['21'] && pending_refusal?(sentence)
          missing << 'platform_resolved_refusal_inverted' if grounded['21'] && resolved_refusal_inverted?(sentence)
        end
        missing << 'platform_unsupported_paragraph' if EuSealedUnits.unsupported_paragraph?(text, grounded)
        { applicable: true, missing_conditions: CONDITION_CODES & missing, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        copy = FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
        "#{codes.map { |code| copy.fetch(code) }.join(' ')} [#{codes.join(', ')}]"
      end

      private

      def sentences(text)
        text.gsub(/```[\s\S]*?```/, '').gsub(/^[ \t]*>.*$/, '')
            .gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1').gsub(%r{https?://\S+}, '')
            .gsub(/[*_`#]/, '').split(/(?<=[!?;])\s+|\n|(?<=\.)\s+(?=[[:upper:]])/)
            .map(&:strip).reject(&:empty?)
      end

      def whole_act_exemption?(sentence)
        return false if sentence.end_with?('?')
        return false unless sentence.match?(WHOLE_ACT_PATTERN) && sentence.match?(SMALL_PATTERN)
        return false if sentence.match?(SCOPED_PATTERN) || sentence.match?(WHOLE_ACT_DENIAL_PATTERN)

        sentence.match?(NOT_APPLICABLE_PATTERN)
      end

      # A size figure the supplied texts do not hold. Article 19 refers to a
      # Commission recommendation without stating its figures, so an employee,
      # turnover or user count in the answer came from elsewhere.
      def unsupported_figure?(sentence, source_texts)
        { people: PEOPLE_FIGURE_PATTERN, money: MONEY_FIGURE_PATTERN, users: USER_FIGURE_PATTERN }.any? do |kind, pattern|
          sentence.to_enum(:scan, pattern).any? do
            figure = Regexp.last_match.captures.compact.first.to_s
            next false if figure.empty?

            source_texts.none? { |text| figure_in_source?(figure, kind, text) }
          end
        end
      end

      def figure_in_source?(figure, kind, text)
        number = Regexp.escape(figure.gsub(/[.,\s]/, '')).chars.join('[.,\s]?')
        case kind
        when :people
          text.match?(/(?<![\d.,])#{number}(?!\d)\s*(?:\p{L}+\s+){0,2}?(?:werknemers|personeelsleden|medewerkers|personen|employees|staff|persons|people|salariés|employés|personnes|Beschäftigte\p{L}*|Mitarbeiter\p{L}*|Personen)\b/iu)
        else
          text.match?(/(?<![\d.,])#{number}(?!\d)\s*(?:miljoen|mln|million\p{L}*|Millionen|Mio\.?)/iu)
        end
      end

      def resolved_refusal_inverted?(sentence)
        return false if sentence.end_with?('?') || sentence.match?(EXCEPTION_WORD_PATTERN)

        sentence.match?(NEGATED_REFUSAL_PATTERN) && sentence.match?(RESOLVED_PATTERN) && sentence.match?(BODY_PATTERN)
      end

      def pending_refusal?(sentence)
        return false if sentence.end_with?('?') || sentence.match?(PENDING_DENIAL_PATTERN)

        sentence.match?(REFUSAL_PATTERN) && sentence.match?(BODY_PATTERN) && sentence.match?(PENDING_PATTERN)
      end

      def source_text(source)
        return nil unless source.is_a?(Hash)

        %i[article_text text full_text content].filter_map do |key|
          value = EuSealedUnits.field(source, key)
          value if value.is_a?(String) && value.valid_encoding?
        end.join("\n").presence
      end
    end

    FEEDBACK_COPY = {
      'nl' => {
        'platform_whole_act_size_exemption' => 'CORRECTIE: artikel 19 zondert micro- en kleine ondernemingen alleen uit van de afdeling die het noemt (met de uitzondering voor aangewezen zeer grote platforms), niet van de hele DSA. Beschrijf die uitzondering als beperkt tot die bepalingen, zonder deze correctie te vermelden.',
        'platform_unsupported_size_threshold' => 'CORRECTIE: noem geen aantallen werknemers, omzetbedragen of gebruikersaantallen voor micro-, kleine of zeer grote platforms die niet in de aangeleverde tekst staan; artikel 19 verwijst naar een aanbeveling zonder die cijfers te geven. Herschrijf zonder deze correctie te vermelden.',
        'platform_pending_dispute_refusal' => 'CORRECTIE: volgens artikel 21 mag een platform medewerking aan een gecertificeerde instantie alleen weigeren als een geschil over dezelfde informatie en dezelfde gronden al is beslecht; een geschil dat enkel aanhangig is, is daarvoor geen grond. Herschrijf die toepassing zonder deze correctie te vermelden.',
        'platform_resolved_refusal_inverted' => 'CORRECTIE: artikel 21 staat het platform juist toe medewerking te weigeren wanneer een geschil over dezelfde informatie en dezelfde gronden al is beslecht; zeg niet dat het platform dan niet mag weigeren. Herschrijf die toepassing zonder deze correctie te vermelden.',
        'platform_unsupported_paragraph' => 'CORRECTIE: verwijs alleen naar een lid dat het aangeleverde artikel werkelijk heeft en dat zelf zegt wat u eraan toeschrijft; anders link het artikel zonder lidnummer. Herschrijf zonder deze correctie te vermelden.'
      },
      'fr' => {
        'platform_whole_act_size_exemption' => 'CORRECTION : l’article 19 exclut les micro et petites entreprises uniquement de la section qu’il vise (sauf les très grandes plateformes désignées), pas de l’ensemble du DSA. Décrivez cette exception comme limitée à ces dispositions, sans mentionner cette correction.',
        'platform_unsupported_size_threshold' => 'CORRECTION : n’indiquez aucun nombre de salariés, chiffre d’affaires ou nombre d’utilisateurs pour les micro, petites ou très grandes plateformes qui ne figure pas dans le texte fourni ; l’article 19 renvoie à une recommandation sans en donner les chiffres. Réécrivez sans mentionner cette correction.',
        'platform_pending_dispute_refusal' => 'CORRECTION : selon l’article 21, une plateforme ne peut refuser de s’engager avec un organe certifié que si un litige portant sur les mêmes informations et les mêmes motifs a déjà été résolu ; un litige simplement pendant n’est pas ce motif. Réécrivez cette application sans mentionner cette correction.',
        'platform_resolved_refusal_inverted' => 'CORRECTION : l’article 21 permet précisément à la plateforme de refuser de s’engager lorsqu’un litige portant sur les mêmes informations et les mêmes motifs a déjà été résolu ; ne dites pas qu’elle ne peut alors pas refuser. Réécrivez cette application sans mentionner cette correction.',
        'platform_unsupported_paragraph' => 'CORRECTION : ne citez qu’un paragraphe que l’article fourni comporte réellement et qui dit lui-même ce que vous lui attribuez ; sinon liez l’article sans numéro de paragraphe. Réécrivez sans mentionner cette correction.'
      },
      'de' => {
        'platform_whole_act_size_exemption' => 'KORREKTUR: Artikel 19 nimmt Kleinst- und Kleinunternehmen nur von dem Abschnitt aus, den er nennt (außer benannten sehr großen Plattformen), nicht vom gesamten DSA. Beschreiben Sie diese Ausnahme als auf diese Bestimmungen beschränkt, ohne Hinweis auf diese Korrektur.',
        'platform_unsupported_size_threshold' => 'KORREKTUR: Nennen Sie keine Beschäftigtenzahlen, Umsatzbeträge oder Nutzerzahlen für Kleinst-, Klein- oder sehr große Plattformen, die nicht im bereitgestellten Text stehen; Artikel 19 verweist auf eine Empfehlung, ohne deren Zahlen zu nennen. Überarbeiten Sie ohne Hinweis auf diese Korrektur.',
        'platform_pending_dispute_refusal' => 'KORREKTUR: Nach Artikel 21 darf eine Plattform die Zusammenarbeit mit einer zertifizierten Stelle nur verweigern, wenn ein Streit über dieselben Informationen und dieselben Gründe bereits beigelegt wurde; ein bloß anhängiger Streit ist kein solcher Grund. Überarbeiten Sie diese Anwendung ohne Hinweis auf diese Korrektur.',
        'platform_resolved_refusal_inverted' => 'KORREKTUR: Artikel 21 erlaubt der Plattform gerade, die Zusammenarbeit zu verweigern, wenn ein Streit über dieselben Informationen und dieselben Gründe bereits beigelegt wurde; sagen Sie nicht, dass sie dann nicht verweigern darf. Überarbeiten Sie diese Anwendung ohne Hinweis auf diese Korrektur.',
        'platform_unsupported_paragraph' => 'KORREKTUR: Verweisen Sie nur auf einen Absatz, den der bereitgestellte Artikel tatsächlich hat und der selbst sagt, was Sie ihm zuschreiben; sonst verlinken Sie den Artikel ohne Absatznummer. Überarbeiten Sie ohne Hinweis auf diese Korrektur.'
      },
      'en' => {
        'platform_whole_act_size_exemption' => 'CORRECTION: Article 19 exempts micro and small enterprises only from the section it names (except designated very large platforms), not from the whole DSA. Describe that exception as limited to those provisions, without mentioning this correction.',
        'platform_unsupported_size_threshold' => 'CORRECTION: do not state employee, turnover or user-number figures for micro, small or very large platforms that the supplied text does not contain; Article 19 refers to a recommendation without giving its figures. Rewrite without mentioning this correction.',
        'platform_pending_dispute_refusal' => 'CORRECTION: under Article 21 a platform may refuse to engage with a certified body only where a dispute on the same information and the same grounds has already been resolved; a merely pending dispute is not that ground. Rewrite that application without mentioning this correction.',
        'platform_resolved_refusal_inverted' => 'CORRECTION: Article 21 does allow the platform to refuse to engage where a dispute on the same information and the same grounds has already been resolved; do not say that it may not refuse then. Rewrite that application without mentioning this correction.',
        'platform_unsupported_paragraph' => 'CORRECTION: refer only to a paragraph that the supplied article actually has and that itself says what you attribute to it; otherwise link the article without a paragraph number. Rewrite without mentioning this correction.'
      }
    }.transform_values(&:freeze).freeze
  end
end
