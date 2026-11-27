# frozen_string_literal: true

module LegalChatbot
  # Sol 2026-11-26 22:34:20Z (#115 "Bedrag werkloosheidsuitkering?", live 1.1.113): the full-unemployment minima of the
  # answer matched the RVA's new-regime table valid from 1 September 2026, but "The table is introduced as the indexed
  # minima from September without naming the admission group. There is no 1 March cutoff, old-cohort rule, special 55+
  # transition or qualifying readmission, in either body or added index note." The unemployment rule note of 1.1.112
  # (LegalFactProvider) asks the model to say which group the schedule is for; the generated text can leave it out.
  # "Please put the short verified applicability text immediately before the full-unemployment table, cite Article 212,
  # and test the final rendered answer when generated text omits it, including the distinction from temporary
  # unemployment."
  #
  # Read in full in the production corpus on 2026-11-26, Dutch and French: art. 212 of the programme law of 18 July 2025
  # (2025005578) and art. 115 of the royal decree of 25 November 1991 (1991013192) as art. 171 of that law replaced it
  # from 1 March 2026.
  # - Art. 212, § 1: the worker admitted before 1 March 2026 keeps the right at the latest until 30 June 2030; while it is
  #   kept, the amount is further set by arts. 114, 116 and 118 as applicable until 28 February 2026 (seventh
  #   paragraph).
  # - Art. 212, § 2: the worker who had reached the age of 55 on 30 June 2025 with a sufficient career keeps the right
  #   without the time limit of art. 114, § 1 and has the daily amounts that paragraph sets.
  # - Art. 212, § 4: §§ 1 to 3 no longer apply when the worker, after an interruption, claims as fully unemployed from
  #   1 March 2026 and meets the admission conditions of art. 30 or 33 as applicable from that day.
  # - Art. 115: § 1 sets the minima of full unemployment, § 4 those of temporary unemployment, whatever the household.
  #
  # The paragraph goes right before the first table, list or paragraph of the final answer that holds a minimum of
  # art. 115, § 1 as IndexedAmounts reads it (its base amount or an indexed one), above the line that introduces it,
  # unless the answer already holds the paragraph. Sol 2026-11-26 23:02:31Z (review of the sealed 1.1.114): a mention of
  # "Art. 212" and "1 maart 2026" above the table, with no link or claimant groups, had counted as the explanation;
  # "Please only skip an already complete linked explanation (or its verified paragraph)".
  # Version 2 (Sol 2026-11-27 13:27:18Z, #304 on live 1.1.116): the answer "gives the 65/60/60 schedule without stating
  # who is in the post-March regime in this answer". Art. 114 as art. 169 of the programme law of 18 July 2025 replaced it
  # from 1 March 2026 (read in full in NL and FR on 2026-11-27): § 3 pays 65 % of the average daily wage in months one to
  # three of the first period, 60 % in months four to six and 60 % in months seven to twelve; § 6 pays the temporarily
  # unemployed 65 % (force majeure) or 60 %. A line with a percentage of § 3 gets the paragraph too, which now names
  # arts. 114 and 115 for the amounts and percentages.
  module UnemploymentAmountApplicability
    VERSION = 2
    TRANSITION_HREF = '/laws/2025005578#art-212'
    TEXT = {
      'nl' => '**Voor wie gelden deze bedragen?** De bedragen en percentages voor volledige werkloosheid in dit overzicht ' \
              'volgen art. 114 en 115 zoals van toepassing sinds 1 maart 2026. Ze gelden voor wie vanaf 1 maart 2026 tot het recht op ' \
              'uitkeringen wordt toegelaten, ook voor wie na een onderbreking vanaf die datum een aanvraag als volledig ' \
              'werkloze indient en aan de nieuwe toelatingsvoorwaarden voldoet ([art. 212, § 4 van de programmawet van ' \
              "18 juli 2025](#{TRANSITION_HREF})). Wie vóór 1 maart 2026 werd toegelaten, krijgt tijdens de " \
              'overgangsperiode het bedrag volgens art. 114, 116 en 118 zoals van toepassing tot 28 februari 2026 ' \
              '(art. 212, § 1); wie op 30 juni 2025 minstens 55 jaar was met voldoende beroepsverleden, krijgt de ' \
              'dagbedragen van art. 212, § 2. Voor tijdelijke werkloosheid gelden de minima van art. 115, § 4, ongeacht ' \
              'de gezinssituatie.',
      'fr' => "**À qui s'appliquent ces montants ?** Les montants et pourcentages du chômage complet de cet aperçu suivent les " \
              "articles 114 et 115 tels qu'ils s'appliquent depuis le 1er mars 2026. Ils valent pour le travailleur admis au droit aux " \
              'allocations à partir du 1er mars 2026, y compris celui qui, après une interruption, introduit à partir de ' \
              "cette date une demande comme chômeur complet et remplit les nouvelles conditions d'admissibilité " \
              "([art. 212, § 4, de la loi-programme du 18 juillet 2025](#{TRANSITION_HREF})). Pour le travailleur admis " \
              'avant le 1er mars 2026, le montant reste fixé pendant la période transitoire selon les articles 114, 116 ' \
              "et 118 tels qu'ils s'appliquaient jusqu'au 28 février 2026 (art. 212, § 1er) ; le travailleur qui avait " \
              'atteint 55 ans au 30 juin 2025 et a un passé professionnel suffisant reçoit les montants journaliers de ' \
              "l'art. 212, § 2. Le chômage temporaire a ses propres minima (art. 115, § 4), quelle que soit la situation " \
              'familiale.',
      'de' => '**Für wen gelten diese Beträge?** Die Beträge und Prozentsätze der Vollarbeitslosigkeit in dieser Übersicht ' \
              'folgen Art. 114 und 115 in der seit dem 1. März 2026 geltenden Fassung. Sie gelten für Arbeitnehmer, die ab dem 1. März 2026 ' \
              'zum Anspruch auf Leistungen zugelassen werden, auch für Arbeitnehmer, die nach einer Unterbrechung ab ' \
              'diesem Tag einen Antrag als Vollarbeitsloser stellen und die neuen Zulassungsbedingungen erfüllen ' \
              "([Art. 212 § 4 des Programmgesetzes vom 18. Juli 2025](#{TRANSITION_HREF})). Für Arbeitnehmer, die vor " \
              'dem 1. März 2026 zugelassen wurden, wird der Betrag während der Übergangszeit weiter nach den Art. 114, ' \
              '116 und 118 in der bis zum 28. Februar 2026 geltenden Fassung bestimmt (Art. 212 § 1); wer am 30. Juni ' \
              '2025 mindestens 55 Jahre alt war und eine ausreichende berufliche Vergangenheit hat, erhält die ' \
              'Tagesbeträge von Art. 212 § 2. Für die zeitweilige Arbeitslosigkeit gelten die Mindestbeträge von ' \
              'Art. 115 § 4, unabhängig von der Familiensituation.',
      'en' => '**Who do these amounts apply to?** The full-unemployment amounts and percentages in this overview follow arts. ' \
              '114 and 115 as they apply since 1 March 2026. They apply to a worker admitted to benefits from 1 March 2026, including ' \
              'one who, after an interruption, claims as fully unemployed from that day and meets the new admission ' \
              "conditions ([art. 212, § 4 of the programme law of 18 July 2025](#{TRANSITION_HREF})). For a worker " \
              'admitted before 1 March 2026, the amount stays set during the transition by arts. 114, 116 and 118 as ' \
              'they applied until 28 February 2026 (art. 212, § 1); a worker who was aged 55 or older on 30 June 2025 ' \
              'with a sufficient career gets the daily amounts of art. 212, § 2. Temporary unemployment has its own ' \
              'minima (art. 115, § 4), whatever the household.'
    }.freeze
    # The percentages of the first period of full unemployment (art. 114, § 3: 65 % in months one to three, 60 % in four
    # to six and in seven to twelve), on a line that names its months or period: "overmacht: 65 %" under a heading on
    # temporary unemployment is art. 114, § 6
    SCHEDULE = /(?<![\d.,])(?:65|60)[[:space:]]?(?:%|procent|pour[[:space:]-]?cent|prozent|percent)(?![[:alpha:]])/iu
    PERIOD = /(?<![[:alpha:]])(?:maand(?:en)?|\p{L}*periode|mois|p[ée]riodes?|monat(?:e|en)?|\p{L}*zeitraum|months?|periods?)(?![[:alpha:]])/iu
    # A section or a table on temporary unemployment, by its heading or header row: art. 114, § 6 and art. 115, § 4
    TEMPORARY_SECTION = /(?<![[:alpha:]])(?:tijdelijke?\s+werklo\p{L}*|ch[ôo]mage\s+temporaire|ch[ôo]meurs?\s+temporaires?|
                         zeitweilige?\p{L}*\s+arbeitslos\p{L}*|temporar(?:y|ily)\s+unemploy\p{L}*|overmacht|force\s+majeure|
                         h[öo]here[rn]?\s+gewalt)(?![[:alpha:]])/iux
    # A heading or table column that names full unemployment, alone or beside temporary unemployment ("Volledige en
    # tijdelijke werkloosheid", "Voll- und zeitweilige Arbeitslosigkeit", "Full and temporary unemployment")
    FULL_COLUMN = /(?<![[:alpha:]])(?:volledige?\s+(?:(?:en|of)\s+tijdelijke?\s+)?werklo\p{L}*|ch[ôo]mage\s+complet|ch[ôo]meurs?\s+complets?|
                   vollarbeitslos\p{L}*|voll-\s*(?:und|oder)\s+zeitweilige?\s+arbeitslos\p{L}*|
                   full\s+(?:(?:and|or)\s+temporary\s+)?unemploy\p{L}*|fully\s+unemployed)(?![[:alpha:]])/iux
    # A line about temporary unemployment: its figures are those of art. 115, § 4
    TEMPORARY = /(?<![[:alpha:]])(?:tijdelijk\p{L}*|temporaire\p{L}*|zeitweilig\p{L}*|temporary)(?![[:alpha:]])/iu
    HEADING = /\A[[:space:]]*(?:\#{1,6}[[:space:]]|\*\*[^*\n]+\*\*:?[[:space:]]*\z)/
    LIST_CONTINUATION = /\A[[:space:]]{2,}[^[:space:]]/

    module_function

    # The final answer with the paragraph before its first full-unemployment minimum, or the answer unchanged. An answer
    # that already holds the verified paragraph keeps it once; any other wording about art. 212, however close, gets it.
    def apply(text, question:, sources: [], language: 'nl')
      return text if text.blank? || !IndexedAmounts.applies?(text, question, sources)
      return text if TEXT.values.any? { |verified| text.include?(verified) }

      lines = text.split("\n", -1)
      first = lines.each_index.find { |index| full_minimum?(lines[index], section(lines, index), table_header(lines, index)) }
      return text unless first

      start = lead_in_start(lines, block_start(lines, first))
      paragraph = TEXT.fetch(TEXT.key?(language.to_s) ? language.to_s : 'nl')
      head = lines[0...start]
      head.pop while head.any? && head.last.strip.empty?
      [*head, *(head.empty? ? [] : ['']), paragraph, '', *lines[start..]].join("\n")
    end

    # A line outside a quotation and the index note (whose "34,94 → 63,29" gives a quotation's amounts indexed) with a
    # figure that reads as a minimum of art. 115, § 1, or a percentage of the first period of art. 114, § 3 (Sol
    # 2026-11-27 13:27:18Z: "gives the 65/60/60 schedule without stating who is in the post-March regime"), and no word
    # of temporary unemployment, whose own 65 and 60 % are those of art. 114, § 6
    #
    # Sol 2026-11-27 14:17:31Z (review of the sealed 1.1.117): a table headed "| Maanden | Percentage van het gemiddeld
    # dagloon |" with rows "| 1–3 | 65 % |" got no paragraph, and "Voorbeeld: gedurende deze periode ontvangt u 65 % van uw
    # gemiddeld dagloon." under "**Tijdelijke werkloosheid wegens overmacht**" got it. "Please carry table header/section
    # context into the applicability decision." section: the headings that contain the line; header: its table's first
    # row.
    #
    # Sol 2026-11-27 14:58:54Z (review of e6da9432d): "## Tijdelijke werkloosheid", "### Berekening" and "Tijdens deze
    # periode ontvangt u 65 %." got the note, and "| Maanden | Volledige werkloosheid | Tijdelijke werkloosheid |" with "|
    # 1–3 | 65 % | 60 % |" did not. "Preserve parent section scope across a subheading and scope the qualification to the
    # full column of comparison tables."
    def full_minimum?(line, sections = [], header = nil)
      return false if line.match?(IndexedAmounts::BLOCKQUOTE) || line.match?(IndexedAmounts::NOTE_LEAD) || line.match?(TEMPORARY)
      return false if temporary_scope?(sections)

      period = [line, *sections, header.to_s].any? { |text| text.match?(PERIOD) }
      header ? table_minimum?(line, header, period) : minimum_in?(line, period)
    end

    # Sol 2026-11-27 15:56:28Z (review of ecca0a4a8): "## Volledige en tijdelijke werkloosheid" above the comparison
    # table, also with "### Volledige werkloosheid" between, suppressed the note. "A combined heading should not veto a
    # specifically full column or subsection; keep the existing temporary-only negative." The nearest heading that names
    # one regime decides: temporary unemployment alone vetoes, full unemployment alone does not; a heading naming both
    # leaves it to the next heading up, then to the column or the line.
    def temporary_scope?(sections)
      sections.each do |heading|
        temporary = heading.match?(TEMPORARY_SECTION)
        full = heading.match?(FULL_COLUMN)
        return true if temporary && !full
        return false if full && !temporary
      end
      false
    end

    # A percentage of the schedule with its period, or an amount that reads as a minimum of full unemployment
    def minimum_in?(text, period)
      return true if period && text.match?(SCHEDULE)

      text.to_enum(:scan, IndexedAmounts::AMOUNT).any? do
        match = Regexp.last_match
        readings = IndexedAmounts::READINGS.fetch(BigDecimal("#{match[:int]}.#{match[:dec]}"), [])
        readings.any? { |row, _rank| row[:regime] == :full }
      end
    end

    # A table row, cell by cell under its column's header: in a table whose header speaks of temporary unemployment
    # (a column of it, or the table itself), only a column headed as full unemployment counts
    def table_minimum?(row, header, period)
      heads = cells(header)
      temporary_table = header.match?(TEMPORARY_SECTION)
      cells(row).each_with_index.any? do |cell, column|
        next false if temporary_table && !heads[column].to_s.match?(FULL_COLUMN)

        minimum_in?(cell, period)
      end
    end

    def cells(row) = row.to_s.strip.delete_prefix('|').delete_suffix('|').split('|', -1).map(&:strip)

    # The headings that contain the line: the nearest above it, then each heading of a higher level above that one (a
    # bold-only line counts as the lowest level); a heading of the same or a lower level ends a section
    def section(lines, index)
      level = nil
      (index - 1).downto(0).filter_map do |above|
        next unless kind(lines[above]) == :heading

        own = lines[above][/\A[[:space:]]*(\#{1,6})[[:space:]]/, 1]&.length || 7
        next if level && own >= level

        level = own
        lines[above]
      end
    end

    # A table row's header: the first row of its table, when the row is not that first row itself
    def table_header(lines, index)
      return unless kind(lines[index]) == :table

      start = block_start(lines, index)
      lines[start] if start < index
    end

    def kind(line)
      return :blank if line.strip.empty?
      return :table if line.match?(IndexedAmounts::TABLE_ROW)
      return :list if line.match?(IndexedAmounts::LIST_ITEM)
      return :heading if line.match?(HEADING)

      :prose
    end

    # The first line of the table, list or paragraph that holds line index
    def block_start(lines, index)
      own = kind(lines[index])
      start = index
      start -= 1 while start.positive? && same_block?(own, lines[start - 1])
      start
    end

    def same_block?(own, line)
      above = kind(line)
      return above == :list || line.match?(LIST_CONTINUATION) if own == :list

      above == own
    end

    # A table or list keeps the line that introduces it: the paragraph right above it (with or without a blank line
    # between) when it ends in a colon, or that sits directly on it
    def lead_in_start(lines, start)
      above = start - 1
      above -= 1 while above >= 0 && kind(lines[above]) == :blank
      return start if above.negative? || kind(lines[above]) != :prose
      return start unless above == start - 1 || lines[above].strip.delete('*_').end_with?(':')

      above -= 1 while above.positive? && kind(lines[above - 1]) == :prose
      above
    end
  end
end
