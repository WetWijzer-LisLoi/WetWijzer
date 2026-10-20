# frozen_string_literal: true

module LegalChatbot
  # Measured misstatements in consumer withdrawal answers (the candidate QA of
  # 15 real July catalogue questions, 2026-10-19), not a verifier of Book VI
  # answers: it decides neither the scope nor any remedy. It reads only the
  # model's own prose; verbatim quotations of the law are checked by the quote
  # guard and are skipped here. No answer text is logged, and passing does not
  # verify an answer.
  #
  #   withdrawal_deadline_without_fourteen_days  the withdrawal period said
  #     to end ON the day itself: "De herroepingstermijn verstrijkt: de dag
  #     waarop de overeenkomst wordt gesloten" (july-1496); WER art. VI.47,
  #     par. 2 counts 14 days AFTER that day. Only that zero-offset claim is
  #     read: a stated offset, the VI.48 extension, a negation or a refund or
  #     return deadline is not.
  #   withdrawal_sealed_exception_without_seal_condition  sealed goods unfit
  #     for return for health or hygiene reasons listed without "the seal was
  #     broken after delivery" (july-301; art. VI.53, 5deg).
  #   withdrawal_alcohol_exception_without_market_condition  alcoholic drinks
  #     listed without the market-fluctuation condition (july-301; VI.53, 7deg).
  #   withdrawal_excluded_for_defect  "Dit recht is niet van toepassing als het
  #     product al defect was bij levering" (july-1082): a defect is not an
  #     exception of art. VI.53. Only the defect given as the reason counts;
  #     "ook als het product defect is" and an exclusion for another scope (a
  #     purchase between businesses, a private seller) are not that claim.
  class ConsumerWithdrawalGrounding
    VERSION = 1
    CONDITION_CODES = %w[withdrawal_deadline_without_fourteen_days withdrawal_sealed_exception_without_seal_condition
                         withdrawal_alcohol_exception_without_market_condition withdrawal_excluded_for_defect].freeze
    MAX_ANSWER_CHARS = 200_000
    MAX_QUESTION_CHARS = 12_000

    WITHDRAWAL_PATTERN = /\b(?:herroep\p{L}*|bedenktijd|r[ée]tractation|r[ée]tracter|d[ée]lai\s+de\s+r[ée]flexion|withdraw\p{L}*|cooling[-\s]off|widerruf\p{L}*)\b/i
    # The withdrawal period itself as the subject, not a refund or return
    # deadline elsewhere in the answer.
    WITHDRAWAL_PERIOD_PATTERN = /\b(?:herroepingstermijn|herroepingsperiode|bedenktijd|d[ée]lai\s+de\s+r[ée]tractation|withdrawal\s+period|cooling[-\s]off\s+period)\b/i
    PERIOD_END_PATTERN = /\b(?:verstrijkt|verloopt|eindigt|loopt\s+af|expire|expires|prend\s+fin|ends)\b/i
    DAY_ANCHOR_PATTERN = /\b(?:de\s+dag\s+waarop|le\s+jour\s+o[uù]|the\s+day\s+(?:on\s+which|when|of))\b/i
    # The measured claim: the period ends ON the day itself, nothing between
    # the end verb and the day but a colon or "op"/"on" ("De
    # herroepingstermijn verstrijkt op de dag waarop ...", "verstrijkt de
    # herroepingstermijn op de dag waarop ..."). A stated offset ("14 dagen na
    # de dag waarop"), the VI.48 extension ("twaalf maanden na de dag
    # waarop") and a negation ("verstrijkt niet op de dag") do not match.
    ZERO_OFFSET_INLINE_PATTERN = /#{WITHDRAWAL_PERIOD_PATTERN}[^.:\n]{0,20}?#{PERIOD_END_PATTERN}(?::\s*|\s+)(?:(?:op|on|at)\s+)?#{DAY_ANCHOR_PATTERN}
      |#{PERIOD_END_PATTERN}\s+(?:de|le|the)\s+#{WITHDRAWAL_PERIOD_PATTERN}(?::\s*|\s+)(?:(?:op|on|at)\s+)?#{DAY_ANCHOR_PATTERN}/ix
    # A negation that governs the very claim, directly before it in the same
    # clause ("Het is niet zo dat de herroepingstermijn verstrijkt op de dag
    # waarop ..."), denies the zero-offset rule. Only this lead counts: a
    # negative word elsewhere in the sentence or answer excuses nothing
    # (root 2026-10-19 20:50:58).
    CLAIM_NEGATION_PATTERN = /(?:\b(?:het\s+is\s+)?niet\s+(?:zo|waar|juist)\s+dat
      |\b(?:il\s+)?n['’]est\s+pas\s+(?:vrai|exact|correct)\s+que
      |\bce\s+n['’]est\s+pas\s+(?:le\s+cas\s+)?que
      |\b(?:it\s+is\s+)?not\s+(?:true|the\s+case|correct)\s+that)
      [[:space:]]+(?:(?:de|het|dan|le|la|l['’]|the|then)[[:space:]]+)*\z/ix
    # The same claim as a heading over day items (july-1496): "De
    # herroepingstermijn verstrijkt:" then "- Voor diensten: de dag waarop".
    ZERO_OFFSET_HEADING_PATTERN = /#{WITHDRAWAL_PERIOD_PATTERN}[^.:\n]{0,20}?#{PERIOD_END_PATTERN}\s*:\z/i
    DAY_ITEM_PATTERN = /\A(?:[-*+]|\d{1,2}[.)])\s+(?:[^:\n]{0,80}:\s*)?(?:(?:op|on|at)\s+)?#{DAY_ANCHOR_PATTERN}/i
    SEALED_PATTERN = /\b(?:verzegel\p{L}*|scell\p{L}*|sealed)\b/i
    HYGIENE_PATTERN = /\b(?:gezondheid|hygi[eë]n\p{L}*|sant[ée]|hygi[èe]ne|health|hygiene)\b/i
    # The seal condition stated as a condition: the goods opened or unsealed,
    # the seal broken (after delivery), or its converse ("zolang de
    # verzegeling niet verbroken is"). "After delivery" alone is no seal
    # condition, a bare "open" elsewhere is none, and a concessive "ook als",
    # "zelfs als", "even if" or "même si" states none.
    SEAL_CONDITION_PATTERN = /(?:\bna\s+(?:de\s+)?(?:levering\s+)?(?:opening|openen|ontzegeling)\b
      |\bverzegeling\s+(?:na\s+(?:de\s+)?levering\s+)?(?:is\s+|werd\s+|wordt\s+)?(?:verbroken|geopend)\b
      |(?<!\book\s)(?<!\bzelfs\s)\b(?:als|indien|wanneer|zodra|zolang)\s+(?:de\s+verzegeling|het\s+zegel|de\s+verpakking|ze|zij|het|deze|die)\s+
        (?:na\s+(?:de\s+)?levering\s+)?(?:niet\s+)?(?:(?:is|zijn|werd|werden|wordt|worden)\s+)?(?:verbroken|geopend|ontzegeld)\b
      |(?<!\bniet\s)\bontzegeld\b
      |\bdescell[ée]e?s?\s+(?:par\s+le\s+consommateur\s+)?apr[èe]s\s+(?:la\s+)?livraison\b|\bapr[èe]s\s+(?:leur\s+|son\s+)?ouverture\b
      |(?<!\bm[êe]me\s)\b(?:si|lorsque|une\s+fois(?:\s+que)?)\s+(?:le\s+(?:scell[ée]|sceau)|ils|elles|le\s+bien|les\s+biens)\s+
        (?:a\s+[ée]t[ée]\s+|ont\s+[ée]t[ée]\s+|est\s+|sont\s+)?(?:bris[ée]|ouverte?s?|retir[ée]|descell[ée]e?s?)\b
      |(?<!\beven\s)\b(?:once|if|when|unless|after)\s+(?:the\s+seal|they|it)\s+(?:has\s+been\s+|have\s+been\s+|is\s+|are\s+|was\s+|were\s+)?
        (?:not\s+)?(?:broken|opened|unsealed)\b
      |(?<!\beven\s)\b(?:once|if|when|after)\s+(?:opened|unsealed)\b|\bunsealed\s+after\s+delivery\b|\bafter\s+(?:opening|unsealing)\b)/ix
    # A qualified, non-affirmative mention is not the listed exception.
    NOT_AUTOMATIC_PATTERN = /\b(?:niet\s+(?:automatisch|altijd|zomaar)|pas\s+(?:automatiquement|toujours)|not\s+(?:automatically|always))\b/i
    ALCOHOL_PATTERN = /\b(?:alcohol\p{L}*|alcool\p{L}*|boissons?\s+alcoolis[ée]es?)\b/i
    # The market-fluctuation condition itself, not any word "markt".
    MARKET_CONDITION_PATTERN = /\b(?:marktschommeling\p{L}*|schommeling\p{L}*\s+(?:van|op)\s+de\s+markt|fluctuations?\s+(?:du|de\s+march[ée]|sur\s+le)\s*march[ée]?|market\s+fluctuation\p{L}*|fluctuations?\s+(?:in|of|on)\s+the\s+market)\b/i
    # An affirmative exclusion of withdrawal; "vervalt niet" or "is niet
    # uitgesloten" says the opposite.
    EXCLUSION_PATTERN = /\b(?:is\s+niet\s+van\s+toepassing|geldt\s+(?:dan\s+)?niet(?!\s+(?:alleen|enkel))|vervalt(?!\s+niet)|is\s+uitgesloten|kunt\s+u\s+(?:dan\s+)?niet\s+(?:herroepen|terug\p{L}*|gebruik\p{L}*)|heeft\s+u\s+(?:dan\s+)?geen\s+herroepingsrecht|bestaat\s+(?:dan\s+)?niet|ne\s+s['’]applique\s+pas|n['’]est\s+pas\s+applicable|ne\s+pouvez\s+pas\s+vous\s+r[ée]tracter|does\s+not\s+apply|is\s+not\s+available|cannot\s+(?:withdraw|cancel|return))\b/i
    DEFECT_PATTERN = /\b(?:defect\p{L}*|gebrek\p{L}*|kapot|werkt\s+niet|niet\s+(?:meer\s+)?werkt|niet\s+conform|d[ée]fectueu\p{L}*|d[ée]faut\p{L}*|en\s+panne|defective|faulty|broken)\b/i
    # A connector that gives the defect as the reason or condition. After
    # "ook", "zelfs", "even" or "même" it is concessive (the defect does not
    # matter), which is correct.
    REASON_CONNECTOR_PATTERN = /(?<!\book\s)(?<!\bzelfs\s)(?<!\beven\s)(?<!\bm[êe]me\s)\b(?:(?:als|indien|wanneer|omdat|doordat|zodra|bij|in\s+geval\s+van|vanwege|wegens|si|lorsque|quand|puisque|en\s+cas\s+de|pour\s+cause\s+de|if|when|because|since|in\s+case\s+of|due\s+to)\b|parce\s+qu(?:e\b|['’]))/i
    # The exclusion with the defect as its reason, in either order: "is niet
    # van toepassing als het product al defect was" (july-1082), "Als het
    # product defect is, vervalt het herroepingsrecht".
    DEFECT_AS_REASON_PATTERN = /#{EXCLUSION_PATTERN}[^.;,]{0,40}?#{REASON_CONNECTOR_PATTERN}[^.;:,]{0,60}?#{DEFECT_PATTERN}
      |#{REASON_CONNECTOR_PATTERN}[^.;:,]{0,60}?#{DEFECT_PATTERN}[^.;]{0,40}?#{EXCLUSION_PATTERN}/x
    # An exclusion for another scope (a purchase between businesses, from a
    # private seller) applies whatever the state of the product.
    OTHER_SCOPE_PATTERN = /\b(?:tussen\s+(?:ondernemingen|bedrijven|handelaars|particulieren)|B2B|business[-\s]to[-\s]business|als\s+(?:onderneming|bedrijf|zelfstandige)|particuliere\s+verkoper|van\s+een\s+particulier|entre\s+(?:entreprises|professionnels|particuliers)|vendeu(?:r|se)\s+particuli(?:er|[eè]re)|between\s+(?:businesses|companies|traders|private\s+(?:individuals|persons))|private\s+seller|as\s+a\s+business)\b/i
    THIS_RIGHT_PATTERN = /\b(?:dit\s+recht|dat\s+recht|ce\s+droit|this\s+right|that\s+right)\b/i
    BLOCKQUOTE_LINE = /\A\s*(?:(?:[-*+]|\d{1,2}[.)])\s+)?>/
    # Inline emphasis is read as plain text: "vervalt **niet**" is a negation.
    EMPHASIS_PATTERN = /(\*\*|__|\*|_)(?=\S)(.+?)(?<=\S)\1/

    FEEDBACK = {
      'withdrawal_deadline_without_fourteen_days' => {
        'nl' => 'Schrijf de herroepingstermijn als 14 dagen NA de genoemde dag (de sluiting van de overeenkomst of de ontvangst van het goed), zoals artikel VI.47 bepaalt; de termijn verstrijkt niet op die dag zelf.',
        'fr' => "Écrivez le délai de rétractation comme 14 jours APRÈS le jour indiqué (la conclusion du contrat ou la réception du bien), comme le prévoit l'article VI.47 ; le délai n'expire pas ce jour-là.",
        'en' => 'State the withdrawal period as 14 days AFTER the day named (conclusion of the contract or receipt of the goods), as Article VI.47 provides; the period does not expire on that day itself.'
      },
      'withdrawal_sealed_exception_without_seal_condition' => {
        'nl' => 'Vermeld bij verzegelde goederen die om redenen van gezondheid of hygiëne niet geschikt zijn voor terugzending ook de voorwaarde dat de verzegeling na de levering is verbroken.',
        'fr' => 'Pour les biens scellés impropres au renvoi pour des raisons de santé ou d’hygiène, indiquez aussi la condition que le scellé a été brisé après la livraison.',
        'en' => 'For sealed goods unfit for return for health or hygiene reasons, also state the condition that the seal was broken after delivery.'
      },
      'withdrawal_alcohol_exception_without_market_condition' => {
        'nl' => 'Vermeld bij alcoholische dranken alle voorwaarden: de prijs is overeengekomen bij de sluiting, de levering kan pas na 30 dagen, en de werkelijke waarde hangt af van marktschommelingen waarop de onderneming geen invloed heeft.',
        'fr' => 'Pour les boissons alcoolisées, indiquez toutes les conditions : prix convenu à la conclusion, livraison seulement après 30 jours, et valeur réelle dépendant de fluctuations du marché échappant au contrôle de l’entreprise.',
        'en' => 'For alcoholic drinks, state every condition: the price was agreed at conclusion, delivery can only take place after 30 days, and the actual value depends on market fluctuations beyond the trader’s control.'
      },
      'withdrawal_excluded_for_defect' => {
        'nl' => 'Een gebrek of defect bij levering sluit het herroepingsrecht niet uit; schrijf niet dat het herroepingsrecht vervalt omdat het product defect is. Behandel een defect product onder de wettelijke conformiteitsregels (garantie) wanneer die bronnen zijn verstrekt.',
        'fr' => 'Un défaut à la livraison n’exclut pas le droit de rétractation ; n’écrivez pas que ce droit disparaît parce que le produit est défectueux. Traitez un produit défectueux selon la garantie légale de conformité lorsque ces sources sont fournies.',
        'en' => 'A defect at delivery does not exclude the right of withdrawal; do not write that the right lapses because the product is defective. Treat a defective product under the legal conformity guarantee when those sources are supplied.'
      }
    }.freeze

    def self.evaluate(answer, question, _sources)
      text = answer.to_s
      return result(false, []) if text.length > MAX_ANSWER_CHARS || question.to_s.length > MAX_QUESTION_CHARS

      lines = prose_lines(text)
      applicable = question.to_s.match?(WITHDRAWAL_PATTERN) || lines.any? { |line| line.match?(WITHDRAWAL_PATTERN) }
      return result(false, []) unless applicable

      missing = []
      missing << 'withdrawal_deadline_without_fourteen_days' if deadline_without_fourteen_days?(lines)
      missing << 'withdrawal_sealed_exception_without_seal_condition' if lines.each_index.any? { |i| sealed_without_condition?(lines, i) }
      missing << 'withdrawal_alcohol_exception_without_market_condition' if lines.each_index.any? { |i| alcohol_without_market?(lines, i) }
      missing << 'withdrawal_excluded_for_defect' if excluded_for_defect?(lines)
      result(true, missing)
    end

    def self.corrective_feedback(codes, language: 'nl')
      codes = Array(codes) & CONDITION_CODES
      return nil if codes.empty?

      lang = %w[nl fr en].include?(language.to_s) ? language.to_s : 'en'
      lines = codes.map { |code| "- #{FEEDBACK.fetch(code).fetch(lang)}" }
      header = { 'nl' => 'Herstel ook deze inhoudelijke fouten in de herroepingsregels:',
                 'fr' => 'Corrigez aussi ces erreurs de fond sur la rétractation :',
                 'en' => 'Also correct these substantive errors on withdrawal:' }.fetch(lang)
      ([header] + lines).join("\n")
    end

    # The model's own sentences: quotations are dropped, inline emphasis is
    # read as plain text, list items and sentences become separate lines.
    def self.prose_lines(text)
      text.lines.grep_v(BLOCKQUOTE_LINE)
          .map { |line| line.gsub(EMPHASIS_PATTERN, '\2') }
          .flat_map { |line| line.split(/(?<=[.!?])\s+(?=[[:upper:]])/) }
          .map(&:strip).reject(&:empty?)
    end

    # An inline zero-offset claim that no negation governs: every match in
    # the line counts on its own, so "Het is niet zo dat ..., maar de
    # herroepingstermijn verstrijkt op de dag waarop ..." is still a claim.
    def self.zero_offset_claim?(line)
      line.to_enum(:scan, ZERO_OFFSET_INLINE_PATTERN).any? do
        !Regexp.last_match.pre_match.match?(CLAIM_NEGATION_PATTERN)
      end
    end

    # The zero-offset claim only, inline or as a heading over day items.
    def self.deadline_without_fourteen_days?(lines)
      lines.each_with_index.any? do |line, index|
        next true if zero_offset_claim?(line)

        heading = ZERO_OFFSET_HEADING_PATTERN.match(line)
        next false if heading.nil? || heading.pre_match.match?(CLAIM_NEGATION_PATTERN)

        Array(lines[index + 1, 3]).any? { |item| item.match?(DAY_ITEM_PATTERN) }
      end
    end

    # An affirmative sealed-hygiene exception whose condition is neither in its
    # own line nor in the next one (a continuation of the same item).
    def self.sealed_without_condition?(lines, index)
      line = lines[index]
      return false unless line.match?(SEALED_PATTERN) && line.match?(HYGIENE_PATTERN)
      return false if line.match?(NOT_AUTOMATIC_PATTERN)

      !lines[index, 2].join(' ').match?(SEAL_CONDITION_PATTERN)
    end

    def self.alcohol_without_market?(lines, index)
      line = lines[index]
      return false unless line.match?(ALCOHOL_PATTERN) && line.match?(/\b30\b/)

      !lines[index, 2].join(' ').match?(MARKET_CONDITION_PATTERN)
    end

    def self.excluded_for_defect?(lines)
      lines.each_with_index.any? do |line, index|
        next false unless line.match?(DEFECT_AS_REASON_PATTERN)
        next false if line.match?(OTHER_SCOPE_PATTERN)

        line.match?(WITHDRAWAL_PATTERN) ||
          (line.match?(THIS_RIGHT_PATTERN) && index.positive? && lines[index - 1].match?(WITHDRAWAL_PATTERN))
      end
    end

    def self.result(applicable, missing)
      { applicable: applicable, missing_conditions: missing.uniq, version: VERSION }
    end
  end
end
