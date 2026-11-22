# frozen_string_literal: true

require 'bigdecimal'

module LegalChatbot
  # #337 (Sol 2026-11-22 08:38:00Z, 11:43:54Z, 12:14:18Z, 13:14:02Z): asked "Hoe werkt werkloosheidsuitkering?", the
  # answer gave the minimum daily amounts of the unemployment decree's art. 115 (34,94 and 31,76 euro for a single
  # claimant, 43,11 with family charges; 38,72 and 35,74 for temporary unemployment) as the amounts paid now. Art. 113
  # of the decree (1991013192, read in full 2026-11-22) links them to the pivot index 103,14 of 1 June 1999 (base 1996 =
  # 100): the amount paid is the base amount times 1,0200^n, n the rank of the pivot index reached, the multiplier kept
  # to four decimals and the daily amount rounded to the cent. The RVA's tables valid from 01.09.2026 (read 2026-11-22,
  # with their ONEM and LfA editions) give each of the twelve TABLE_AMOUNTS times 1,8114, which is 1,02^30 to four
  # decimals.
  #
  # Two uses, one record:
  # - context_note: the fact provider puts the indexed minima, dated, before the decree's articles (FACT_SOURCES
  #   'werkloosheid'), so the model is told the current figures and that the legal text keeps its base amounts.
  # - apply: in the answer, a benefit figure (below) is checked against the schedule of the period it speaks of: the
  #   dates in its sentence, else those in the question, else today. A base amount, or the indexed amount of another
  #   pivot index, becomes that schedule's amount; the right amount is kept; either way one italic line under the answer
  #   gives the schedule's first day, the official table of each regime used and the day it was checked by hand. Without
  #   a verified schedule for the whole period the figure is withheld and the line says why.
  #
  # A benefit figure is a figure in euro (its own sign, or a currency or a daily rate in its sentence or table) equal to
  # a base amount of art. 115 or to its indexed amount at a pivot index of KNOWN_RANKS, in an answer about unemployment
  # benefit, whose sentence speaks of no other cost (travel, rent, wages, ...) and does not frame it as a base amount.
  # Links, URLs, code and article references are never touched, and a quotation keeps its base amounts verbatim: the
  # line gives their indexation apart.
  #
  # Maintenance is manual, and the reader is told so. Nothing discovers a new table: when Statbel reports that the
  # pivot index is exceeded, someone reads the RVA tables once they show the new amounts and adds a SCHEDULES row
  # (first day, rank, the day of that reading). A row entered before its first day takes over on that day. A row read
  # longer ago than RECHECK_DAYS cannot vouch for a later day. The minima of art. 115, § 2 appear indexed in no official
  # table and are always withheld. Not covered: monthly figures a model derives itself, and the maxima, which come from
  # the wage limits of art. 111.
  class IndexedAmounts
    VERSION = 2
    DECREE = '1991013192'
    STEP = BigDecimal('1.02')
    # Art. 115 as the programme law of 18 July 2025 (art. 171, in force 1 March 2026) replaced it, read in full NL on
    # 2026-11-22. TABLE_AMOUNTS: the minima the RVA's tables show indexed (§ 1 in "volledige werkloosheid nieuwe
    # reglementering", § 4 in "tijdelijke werkloosheid"); UNPUBLISHED_AMOUNTS: the minima of § 2 (unemployment with
    # company supplement), which no official table shows indexed.
    TABLE_AMOUNTS = %w[43.11 39.19 34.94 31.76 33.63 31.04 28.22 23.39 16.48 3.12 38.72 35.74]
                    .map { |value| BigDecimal(value) }.freeze
    UNPUBLISHED_AMOUNTS = %w[37.89 30.71 27.29].map { |value| BigDecimal(value) }.freeze
    BASE_AMOUNTS = (TABLE_AMOUNTS + UNPUBLISHED_AMOUNTS).freeze
    # § 4: temporary unemployment, in the RVA's own table
    TEMPORARY_AMOUNTS = %w[38.72 35.74].map { |value| BigDecimal(value) }.freeze
    # The tables in each reader language, full unemployment and temporary unemployment, each edition read 2026-11-22
    # with the same amounts valid from 01.09.2026. There is no English edition: English readers get the French one.
    TABLES = {
      'nl' => { full: 'https://www.rva.be/documentatie/bedragen/volledige-werkloosheid-nieuwe-reglementering',
                temporary: 'https://www.rva.be/documentatie/bedragen/tijdelijke-werkloosheid' }.freeze,
      'fr' => { full: 'https://www.onem.be/documentation/montants/chomage-complet-nouvelle-reglementation',
                temporary: 'https://www.onem.be/documentation/montants/chomage-temporaire' }.freeze,
      'de' => { full: 'https://www.lfa.be/dokumentation/betrage/vollarbeitslosigkeit-neue-vorschriften',
                temporary: 'https://www.lfa.be/dokumentation/betrage/zeitweilige-arbeitslosigkeit' }.freeze,
      'en' => { full: 'https://www.onem.be/documentation/montants/chomage-complet-nouvelle-reglementation',
                temporary: 'https://www.onem.be/documentation/montants/chomage-temporaire' }.freeze
    }.freeze
    # rank: art. 113, § 1 (rank 1 is the pivot index after 103,14 of 1 June 1999); checked_on: the day the tables were
    # last read by hand and showed this row's amounts.
    SCHEDULES = [{ from: Date.new(2026, 9, 1), rank: 30, checked_on: Date.new(2026, 11, 22) }].freeze
    RECHECK_DAYS = 120
    # The pivot indices whose amounts are recognised in an answer: a model can print those of an earlier or later one
    KNOWN_RANKS = (20..40)
    SUBJECT = /werkloos|werkloze|ch[oô]m|(?<![[:alpha:]])(?:rva|onem|lfa)(?![[:alpha:]])|arbeitslos|unemploy|jobless/i
    # An answer, paragraph or sentence about unemployment benefit
    UNEMPLOYMENT = /(?<![[:alpha:]])(?:\p{L}*werkloos\p{L}*|\p{L}*werkloze\p{L}*|\p{L}*uitkering\p{L}*|\p{L}*dagbedrag\p{L}*|rva|onem|lfa|
                    ch[oô]m\p{L}*|allocations?|indemnit[ée]s?|arbeitslos\p{L}*|unemploy\p{L}*|jobless|benefits?)(?![[:alpha:]])/iux
    # A sentence about another cost or income: its amounts are not the benefit, unless it names the benefit itself
    OTHER_AMOUNT = /(?<![[:alpha:]])(?:\p{L}*kosten\p{L}*|verplaatsing\p{L}*|kilometer\p{L}*|vervoer\p{L}*|huur\p{L}*|
                    \p{L}*loon\p{L}*|lonen|salaris\p{L}*|premie\p{L}*|bijdrage\p{L}*|boete\p{L}*|frais|d[ée]placement\p{L}*|
                    loyer\p{L}*|salaire\p{L}*|cotisation\p{L}*|amende\p{L}*|fahrtkosten|reisekosten|miete\p{L}*|lohn|
                    gehalt\p{L}*|beitr(?:a|ä)g\p{L}*|geldbu(?:ß|ss)e\p{L}*|travel\p{L}*|expens\p{L}*|fares?|rent|wages?|
                    salar(?:y|ies)|contributions?|fines?)(?![[:alpha:]])/iux
    BASE_FRAME = /basisbedrag|spilindex|index(?:cijfer)?[[:space:]]+100|niet[-[:space:]]ge[iï]ndexeerd|montants?[[:space:]]+de[[:space:]]+base|
                  indice[-[:space:]]pivot|non[[:space:]]+index[ée]|basisbetr[aä]g|schwellenindex|base[[:space:]]+amount|pivot[[:space:]]+index|
                  not[[:space:]]+indexed/ix
    # Money in a sentence: a currency, or a daily rate
    MONEY = /€|(?<![[:alpha:]])(?:eur(?:os?)?(?![[:alpha:]])|per[[:space:]]+(?:uitkerings)?dag|dagbedrag|par[[:space:]]+jour|
             journalier|pro[[:space:]]+tag|tagesbetrag|per[[:space:]]+day|a[[:space:]]+day|daily)/ix
    AMOUNT = /(?<pre>(?<![[:alpha:]])(?:€|EUR|euros?)[[:space:]]?)?(?<![\d.,])(?<int>\d{1,3})(?<sep>[.,])(?<dec>\d{2})(?!\d|[.,]\d)
              (?![[:space:]]?(?:%|procent|pour[-[:space:]]?cent|percent|prozent))(?<post>[[:space:]]?(?:€|EUR|euros?)(?![[:alpha:]]))?/ix
    BLOCKQUOTE = /\A[[:space:]]*>/
    QUOTED = /„[^“”"\n]*[“”"]|“[^”\n]*”|«[^»\n]*»|‘[^’\n]*’|‹[^›\n]*›|"[^"\n]*"/
    # Never rewritten: Markdown links (label and target), URLs, inline code, article references
    PROTECTED = %r{\[[^\]\n]*\]\([^)\n]*\)|https?://[^\s)\]]+|`[^`\n]*`|
                   (?<![[:alpha:]])(?:art(?:ikel|icle|s)?\.?|§)[[:space:]]*\d+(?:[.,/]\d+)*}ix
    TABLE_ROW = /\A[[:space:]]*\|/
    # Abbreviations whose full stop ends no sentence
    ABBREVIATION = /(?<![[:alpha:]])(?:art|artt|nr|nrs|blz|bv|vb|p|pp|al|ca|resp|zgn|enz|etc|cf|vgl|o\.a|i\.e|e\.g|b\.v|n\.v\.t)\z/i
    MONTHS = {
      'januari' => 1, 'janvier' => 1, 'january' => 1, 'januar' => 1, 'februari' => 2, 'février' => 2, 'fevrier' => 2,
      'february' => 2, 'februar' => 2, 'maart' => 3, 'mars' => 3, 'march' => 3, 'märz' => 3, 'marz' => 3, 'maerz' => 3,
      'april' => 4, 'avril' => 4, 'mei' => 5, 'mai' => 5, 'may' => 5, 'juni' => 6, 'juin' => 6, 'june' => 6, 'juli' => 7,
      'juillet' => 7, 'july' => 7, 'augustus' => 8, 'août' => 8, 'aout' => 8, 'august' => 8, 'september' => 9,
      'septembre' => 9, 'oktober' => 10, 'octobre' => 10, 'october' => 10, 'november' => 11, 'novembre' => 11,
      'december' => 12, 'décembre' => 12, 'decembre' => 12, 'dezember' => 12
    }.freeze
    MONTH = /#{MONTHS.keys.sort_by { |name| -name.length }.map { |name| Regexp.escape(name) }.join('|')}/i
    FULL_DATE = /(?<![[:alnum:]])(\d{1,2})(?:er|e|\.)?[[:space:]]+(#{MONTH})[[:space:]]+(\d{4})(?![[:alnum:]])/i
    NUMERIC_DATE = %r{(?<![\d.,/])(\d{1,2})[./](\d{1,2})[./](\d{4})(?!\d)}
    ISO_DATE = /(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)/
    MONTH_YEAR = /(?<![[:alnum:]])(#{MONTH})[[:space:]]+(\d{4})(?![[:alnum:]])/i
    YEAR = /(?<![[:alpha:]])(?:in|en|im|tijdens|during|pour|for|f(?:ü|ue)r|voor)[[:space:]]+(\d{4})(?![[:alnum:]])/i
    # "vanaf 1 september 2026": the period runs on to today
    OPEN_ENDED = /(?:vanaf|sinds|sedert|depuis(?:[[:space:]]+le)?|(?:à|a)[[:space:]]+partir[[:space:]]+du?|d[èe]s[[:space:]]+le|
                  (?:ab|seit)(?:[[:space:]]+dem)?|from|since|as[[:space:]]+of)[[:space:]]*\z/ix
    # A law's own date names no period of the facts
    LAW_DATE = /(?:wet|besluit|decreet|ordonnantie|kb|programmawet|herstelwet|loi|arr[êe]t[ée]|d[ée]cret|ordonnance|gesetz\p{L}*|
                erlass\p{L}*|dekret\p{L}*|act|decree|law|regulation|verordening|richtlijn|directive|omzendbrief|circulaire)
                [[:space:][:punct:]]+(?:van|du|vom|of|de)[[:space:]]+\z/ix
    TEXT = {
      'nl' => {
        base: 'De bedragen in art. 115 van het koninklijk besluit van 25 november 1991 houdende de ' \
              'werkloosheidsreglementering zijn basisbedragen, gekoppeld aan de spilindex 103,14 van 1 juni 1999 (art. 113).',
        note: 'Geïndexeerde bedragen geldig vanaf %<from>s volgens %<tables>s, handmatig nagekeken op %<checked>s; ' \
              'een latere indexering kan ze sindsdien vervangen hebben.',
        stale: 'Het actuele bedrag kon niet worden bevestigd: de laatste handmatige controle van de geïndexeerde bedragen ' \
               'is te lang geleden. Zie %<tables>s.',
        uncovered: 'Voor %<period>s is geen handmatig nagekeken bedrag beschikbaar; het is weggelaten. Zie %<tables>s.',
        unpublished: 'Het minimum bij werkloosheid met bedrijfstoeslag (art. 115, § 2) staat in geen officiële tabel ' \
                     'geïndexeerd en is weggelaten.',
        withheld: '[actueel bedrag: zie de tabel van de RVA]',
        quoted: 'Het citaat geeft de basisbedragen van de wettekst; geïndexeerd: %<list>s.',
        quoted_base: 'Het citaat geeft de basisbedragen van de wettekst.',
        tables: { full: 'de tabel van de [RVA](%<full>s)',
                  temporary: 'de tabel tijdelijke werkloosheid van de [RVA](%<temporary>s)',
                  both: 'de tabellen van de RVA voor [volledige](%<full>s) en [tijdelijke werkloosheid](%<temporary>s)' },
        range: 'de periode van %<first>s tot %<last>s',
        months: %w[januari februari maart april mei juni juli augustus september oktober november december]
      },
      'fr' => {
        base: "Les montants de l'art. 115 de l'arrêté royal du 25 novembre 1991 portant réglementation du chômage sont " \
              "des montants de base, liés à l'indice-pivot 103,14 du 1er juin 1999 (art. 113).",
        note: 'Montants indexés valables à partir du %<from>s selon %<tables>s, vérifiés manuellement le %<checked>s ; ' \
              'une indexation ultérieure peut les avoir remplacés depuis.',
        stale: "Le montant actuel n'a pas pu être confirmé : la dernière vérification manuelle des montants indexés est " \
               'trop ancienne. Voir %<tables>s.',
        uncovered: "Pour %<period>s, aucun montant vérifié manuellement n'est disponible ; il est omis. Voir %<tables>s.",
        unpublished: "Le minimum en cas de chômage avec complément d'entreprise (art. 115, § 2) ne figure indexé dans " \
                     'aucun tableau officiel et est omis.',
        withheld: "[montant actuel : voir le tableau de l'ONEM]",
        quoted: 'La citation donne les montants de base du texte légal ; indexés : %<list>s.',
        quoted_base: 'La citation donne les montants de base du texte légal.',
        tables: { full: "le tableau de l'[ONEM](%<full>s)",
                  temporary: "le tableau chômage temporaire de l'[ONEM](%<temporary>s)",
                  both: "les tableaux de l'ONEM pour le [chômage complet](%<full>s) et le [chômage temporaire](%<temporary>s)" },
        range: 'la période du %<first>s au %<last>s',
        months: %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre]
      },
      'de' => {
        base: 'Die Beträge in Art. 115 des Königlichen Erlasses vom 25. November 1991 zur Regelung der Arbeitslosigkeit ' \
              'sind Basisbeträge, gekoppelt an den Schwellenindex 103,14 vom 1. Juni 1999 (Art. 113).',
        note: 'Indexierte Beträge gültig ab dem %<from>s laut %<tables>s, manuell geprüft am %<checked>s; eine spätere ' \
              'Indexierung kann sie inzwischen ersetzt haben.',
        stale: 'Der aktuelle Betrag konnte nicht bestätigt werden: Die letzte manuelle Prüfung der indexierten Beträge ' \
               'liegt zu weit zurück. Siehe %<tables>s.',
        uncovered: 'Für %<period>s ist kein manuell geprüfter Betrag verfügbar; er wurde weggelassen. Siehe %<tables>s.',
        unpublished: 'Das Minimum bei Arbeitslosigkeit mit Betriebszuschlag (Art. 115 § 2) steht in keiner amtlichen ' \
                     'Tabelle indexiert und wurde weggelassen.',
        withheld: '[aktueller Betrag: siehe die Tabelle des LfA]',
        quoted: 'Das Zitat gibt die Basisbeträge des Gesetzestextes wieder; indexiert: %<list>s.',
        quoted_base: 'Das Zitat gibt die Basisbeträge des Gesetzestextes wieder.',
        # dative after "laut", accusative after "Siehe"
        tables: { full: 'der Tabelle des [LfA](%<full>s)',
                  temporary: 'der Tabelle zur zeitweiligen Arbeitslosigkeit des [LfA](%<temporary>s)',
                  both: 'den Tabellen des LfA zur [Vollarbeitslosigkeit](%<full>s) und zur [zeitweiligen Arbeitslosigkeit](%<temporary>s)' },
        tables_see: { full: 'die Tabelle des [LfA](%<full>s)',
                      temporary: 'die Tabelle zur zeitweiligen Arbeitslosigkeit des [LfA](%<temporary>s)',
                      both: 'die Tabellen des LfA zur [Vollarbeitslosigkeit](%<full>s) und zur [zeitweiligen Arbeitslosigkeit](%<temporary>s)' },
        range: 'den Zeitraum vom %<first>s bis zum %<last>s',
        months: %w[Januar Februar März April Mai Juni Juli August September Oktober November Dezember]
      },
      'en' => {
        base: 'The amounts in art. 115 of the Royal Decree of 25 November 1991 on unemployment are base amounts, linked ' \
              'to the pivot index 103.14 of 1 June 1999 (art. 113).',
        note: 'Indexed amounts valid from %<from>s according to %<tables>s, checked manually on %<checked>s; a later ' \
              'indexation may have replaced them since.',
        stale: 'The current amount could not be confirmed: the last manual check of the indexed amounts is too old. ' \
               'See %<tables>s.',
        uncovered: 'For %<period>s no manually checked amount is available; it is left out. See %<tables>s.',
        unpublished: 'The minimum for unemployment with a company supplement (art. 115, § 2) is shown indexed in no ' \
                     'official table and is left out.',
        withheld: "[current amount: see ONEM's table]",
        quoted: 'The quotation gives the statutory base amounts; indexed: %<list>s.',
        quoted_base: 'The quotation gives the statutory base amounts.',
        tables: { full: "[ONEM's table](%<full>s) (in French)",
                  temporary: "[ONEM's temporary unemployment table](%<temporary>s) (in French)",
                  both: "ONEM's tables for [full](%<full>s) and [temporary unemployment](%<temporary>s) (in French)" },
        range: 'the period from %<first>s to %<last>s',
        months: %w[January February March April May June July August September October November December]
      }
    }.freeze
    # The note opens with the base sentence: a copy the model echoed from the conversation is dropped before the new one
    NOTE_LEAD = /\A[[:space:]*_]*#{Regexp.union(TEXT.values.map { |words| words[:base][0, 40] })}/
    # The context note's lines: art. 115's categories with their base amounts, and whether the RVA's table also gives
    # the monthly amount (26 days)
    CONTEXT_LINES = [
      ['werknemer met gezinslast (art. 115, § 1, 1°)', [['eerste zes maanden', '43.11', true], ['daarna', '39.19', true]]],
      ['alleenwonende werknemer (§ 1, 2°)', [['eerste zes maanden', '34.94', true], ['daarna', '31.76', true]]],
      ['samenwonende werknemer (§ 1, 3°)', [['maanden 1 tot 3', '33.63', true], ['maanden 4 tot 6', '31.04', true],
                                            ['maanden 7 tot 12', '28.22', true],
                                            ['tweede vergoedingsperiode, met de voorwaarden van art. 114, § 4, 1°', '23.39', false],
                                            ['tweede vergoedingsperiode, zonder die voorwaarden', '16.48', true]]],
      ['verhoging van het minimum van § 1, 3°, e), als twee samenwonende echtgenoten enkel dat minimum ontvangen',
       [[nil, '3.12', false]]],
      ['tijdelijk werkloze (§ 4)', [['overmacht', '38.72', false], ['andere reden', '35.74', false]]]
    ].freeze
    # The indexed amounts of the table minima at the known pivot indices, each to its [base, rank]; a value two pairs
    # share, or one equal to a base amount, identifies nothing
    INDEXED = TABLE_AMOUNTS.product(KNOWN_RANKS.to_a)
                           .group_by { |base, rank| (base * (STEP**rank).round(4, :half_up)).round(2, :half_up) }
                           .select { |value, pairs| pairs.one? && !BASE_AMOUNTS.include?(value) }
                           .transform_values(&:first).freeze

    Result = Data.define(:text, :replaced, :confirmed, :withheld, :quoted, :schedule)

    def self.multiplier(rank) = (STEP**rank).round(4, :half_up)

    def self.indexed(base, rank) = (base * multiplier(rank)).round(2, :half_up)

    # The schedule that vouches for every day of period [first, last], or [nil, reason]: :uncovered (no row, or two rows
    # within the period) or :stale (the row's last manual check is too old for the period's end)
    def self.schedule_for(period, schedules: SCHEDULES)
      first, last = period
      ordered = schedules.sort_by { |row| row[:from] }
      row = ordered.rfind { |candidate| candidate[:from] <= first }
      return [nil, :uncovered] unless row
      return [nil, :uncovered] if ordered.any? { |candidate| candidate[:from] > row[:from] && candidate[:from] <= last }
      return [nil, :stale] if last > row[:checked_on] + RECHECK_DAYS

      [row, nil]
    end

    # The schedule that applies on day, or nil
    def self.schedule_on(day, schedules: SCHEDULES) = schedule_for([day, day], schedules: schedules).first

    # The last day the newest schedule vouches for
    def self.fresh_until(schedules = SCHEDULES) = schedules.max_by { |row| row[:from] }.fetch(:checked_on) + RECHECK_DAYS

    # Whether the answer is about unemployment benefit: its question or answer says so, or it retained the decree
    def self.applies?(text, question, sources)
      [question, text].any? { |value| value.to_s.match?(SUBJECT) } || decree_retained?(sources)
    end

    def self.decree_retained?(sources) = Array(sources).any? { |source| source_numac(source) == DECREE }

    def self.apply(text, question:, sources: [], language: 'nl', today: Date.current, schedules: SCHEDULES)
      unchanged = Result.new(text: text, replaced: 0, confirmed: 0, withheld: 0, quoted: 0, schedule: nil)
      return unchanged if text.blank? || !applies?(text, question, sources)

      language = TEXT.key?(language.to_s) ? language.to_s : 'nl'
      body = without_echoed_note(text)
      context = { today: today, schedules: schedules, language: language,
                  question_period: period_in(question.to_s, today),
                  answer_cue: question.to_s.match?(UNEMPLOYMENT) || decree_retained?(sources) }
      events = []
      lines = body.split("\n", -1)
      rewritten = lines.each_with_index.map { |line, index| rewrite_line(line, lines, index, context, events) }
      return unchanged if events.empty?

      counts = events.map { |event| event[:kind] }.tally
      Result.new(text: "#{rewritten.join("\n").rstrip}\n\n#{note_for(events, context)}", replaced: counts.fetch(:replaced, 0),
                 confirmed: counts.fetch(:confirmed, 0), withheld: counts.fetch(:withheld, 0) + counts.fetch(:unpublished, 0),
                 quoted: counts.fetch(:quoted, 0), schedule: events.filter_map { |event| event[:schedule] }.first)
    end

    def self.without_echoed_note(text)
      paragraphs = text.split(/\n{2,}/)
      paragraphs.any? { |paragraph| paragraph.match?(NOTE_LEAD) } ? paragraphs.grep_v(NOTE_LEAD).join("\n\n") : text
    end

    # One line: quotations and protected spans pass unchanged; every figure elsewhere is judged in its sentence
    def self.rewrite_line(line, lines, index, context, events)
      paragraph = paragraph_text(lines, index)
      cue = context[:answer_cue] || paragraph.match?(UNEMPLOYMENT)
      if line.match?(BLOCKQUOTE)
        quoted_figures(line, line.match?(MONEY), cue, paragraph, context, events)
        return line
      end

      table = line.match?(TABLE_ROW) ? table_text(lines, index) : nil
      offset = 0
      line.split(/(#{QUOTED}|#{PROTECTED.source})/ix).map do |segment|
        start = offset
        offset += segment.length
        next segment if segment.match?(/\A(?:#{PROTECTED.source})\z/ix)

        if segment.match?(/\A(?:#{QUOTED})\z/)
          money = segment.match?(MONEY) || sentence_at(line, start).match?(MONEY)
          quoted_figures(segment, money, cue, paragraph, context, events)
          next segment
        end

        rewrite_segment(segment, start, line, table, cue, context, events)
      end.join
    end

    def self.rewrite_segment(segment, start, line, table, cue, context, events)
      segment.gsub(AMOUNT) do |figure|
        match = Regexp.last_match
        sentence = table || sentence_at(line, start + match.begin(0))
        base, rank = identify(BigDecimal("#{match[:int]}.#{match[:dec]}"))
        next figure unless base && benefit_claim?(sentence, cue, match)

        judge(figure, match, base, rank, period_for(sentence, context), context, events)
      end
    end

    # A figure in euro in an answer about unemployment, whose sentence names no other cost and frames no base amount
    def self.benefit_claim?(sentence, cue, match)
      return false unless cue
      return false if sentence.match?(BASE_FRAME)
      return false if sentence.match?(OTHER_AMOUNT) && !sentence.match?(UNEMPLOYMENT)

      (match[:pre] || match[:post] || sentence.match?(MONEY)).present?
    end

    def self.judge(figure, match, base, rank, period, context, events)
      regime = regime(base)
      if regime.nil?
        events << { kind: :unpublished }
        return TEXT[context[:language]][:withheld]
      end

      schedule, reason = schedule_for(period, schedules: context[:schedules])
      unless schedule
        events << { kind: :withheld, regime: regime, reason: reason, period: period }
        return TEXT[context[:language]][:withheld]
      end

      if rank == schedule[:rank]
        events << { kind: :confirmed, regime: regime, schedule: schedule }
        return figure
      end

      events << { kind: :replaced, regime: regime, schedule: schedule }
      "#{match[:pre]}#{written(indexed(base, schedule[:rank]), match[:sep])}#{match[:post]}"
    end

    # A quotation keeps its base amounts; the line gives their indexation for the period its paragraph speaks of
    def self.quoted_figures(segment, money, cue, paragraph, context, events)
      return unless cue

      segment.to_enum(:scan, AMOUNT).each do
        match = Regexp.last_match
        value = BigDecimal("#{match[:int]}.#{match[:dec]}")
        next unless BASE_AMOUNTS.include?(value) && (match[:pre] || match[:post] || money)

        schedule, = schedule_for(period_for(paragraph, context), schedules: context[:schedules])
        events << { kind: :quoted, value: value, separator: match[:sep], regime: regime(value),
                    schedule: (schedule if TABLE_AMOUNTS.include?(value)) }
      end
    end

    # [base, nil] for a base amount, [base, rank] for an indexed amount, else nil
    def self.identify(value)
      return [value, nil] if BASE_AMOUNTS.include?(value)

      INDEXED[value]
    end

    # :full (§ 1), :temporary (§ 4) or nil (§ 2, which no official table shows indexed)
    def self.regime(value)
      return :temporary if TEMPORARY_AMOUNTS.include?(value)

      TABLE_AMOUNTS.include?(value) ? :full : nil
    end

    # The period a sentence speaks of: its own dates, else the question's, else today
    def self.period_for(sentence, context)
      period_in(sentence, context[:today]) || context[:question_period] || [context[:today], context[:today]]
    end

    # [first, last] spanned by the dates a text names (a law's own date excepted), or nil
    def self.period_in(text, today)
      spans = []
      masked = text.to_s.dup
      [[FULL_DATE, ->(m) { day_span(m[3], MONTHS[m[2].downcase], m[1]) }],
       [ISO_DATE, ->(m) { day_span(m[1], m[2], m[3]) }],
       [NUMERIC_DATE, ->(m) { day_span(m[3], m[2], m[1]) }],
       [MONTH_YEAR, ->(m) { month_span(m[2], MONTHS[m[1].downcase]) }],
       [YEAR, ->(m) { year_span(m[1]) }]].each do |pattern, build|
        masked.to_enum(:scan, pattern).map { Regexp.last_match }.each do |found|
          before = masked[[found.begin(0) - 40, 0].max...found.begin(0)]
          span = build.call(found)
          masked[found.begin(0)...found.end(0)] = ' ' * found.to_s.length
          next if span.nil? || before.match?(LAW_DATE)

          spans << (before.match?(OPEN_ENDED) ? [span.first, [span.last, today].max] : span)
        end
      end
      return nil if spans.empty?

      [spans.map(&:first).min, spans.map(&:last).max]
    end

    def self.day_span(year, month, day)
      date = Date.new(year.to_i, month.to_i, day.to_i)
      [date, date] if date.year.between?(1990, 2100)
    rescue Date::Error
      nil
    end

    def self.month_span(year, month)
      return nil unless month && year.to_i.between?(1990, 2100)

      first = Date.new(year.to_i, month, 1)
      [first, first.end_of_month]
    end

    def self.year_span(year)
      return nil unless year.to_i.between?(1990, 2100)

      [Date.new(year.to_i, 1, 1), Date.new(year.to_i, 12, 31)]
    end

    # The sentence of line holding position: a full stop after an abbreviation or inside a number ends none
    def self.sentence_at(line, position)
      start = 0
      line.to_enum(:scan, /[.!?;](?=[[:space:]]|\z)/).each do
        stop = Regexp.last_match.end(0)
        next if line[stop - 1] == '.' && line[start...(stop - 1)].match?(ABBREVIATION)
        return line[start...stop] if position < stop

        start = stop
      end
      line[start..]
    end

    def self.paragraph_text(lines, index)
      first = index
      first -= 1 while first.positive? && lines[first - 1].strip.present?
      last = index
      last += 1 while last < lines.length - 1 && lines[last + 1].strip.present?
      lines[first..last].join("\n")
    end

    # A table row is judged with its whole table and the line that introduces it
    def self.table_text(lines, index)
      first = index
      first -= 1 while first.positive? && lines[first - 1].match?(TABLE_ROW)
      last = index
      last += 1 while last < lines.length - 1 && lines[last + 1].match?(TABLE_ROW)
      lines[[first - 1, 0].max..last].join("\n")
    end

    # One italic line: what the art. 115 amounts are, each schedule used with its manual check, why a figure was left
    # out, and the indexation of quoted base amounts
    def self.note_for(events, context)
      language = context[:language]
      words = TEXT.fetch(language)
      parts = [words[:base]]
      # quoted base amounts given indexed apart are dated by their schedule too
      events.select { |event| %i[replaced confirmed quoted].include?(event[:kind]) && event[:schedule] }
            .group_by { |event| event[:schedule] }.each do |schedule, used|
        parts << format(words[:note], from: long_date(schedule[:from], language), checked: long_date(schedule[:checked_on], language),
                                      tables: tables(language, used.map { |event| event[:regime] }))
      end
      events.select { |event| event[:kind] == :withheld }
            .group_by { |event| [event[:reason], event[:period]] }.each do |(reason, period), withheld|
        see = tables(language, withheld.map { |event| event[:regime] }, see: true)
        parts << if reason == :stale && period == [context[:today], context[:today]]
                   format(words[:stale], tables: see)
                 else
                   format(words[:uncovered], period: period_words(period, language), tables: see)
                 end
      end
      parts << words[:unpublished] if events.any? { |event| event[:kind] == :unpublished }
      parts << quoted_sentence(events.select { |event| event[:kind] == :quoted }, words)
      "*#{parts.compact.uniq.join(' ')}*"
    end

    def self.quoted_sentence(quoted, words)
      return nil if quoted.empty?

      known = quoted.uniq { |event| [event[:value], event[:separator]] }.select { |event| event[:schedule] }.map do |event|
        "#{written(event[:value], event[:separator])} → #{written(indexed(event[:value], event[:schedule][:rank]), event[:separator])}"
      end
      known.any? ? format(words[:quoted], list: known.join('; ')) : words[:quoted_base]
    end

    # The table, or both tables, of the regimes concerned; the full-unemployment table when none applies
    def self.tables(language, regimes, see: false)
      words = TEXT.fetch(language)
      known = %i[full temporary] & regimes
      key = known.length == 2 ? :both : (known.first || :full)
      phrases = (see && words[:tables_see]) || words[:tables]
      format(phrases.fetch(key), **TABLES.fetch(language))
    end

    def self.period_words(period, language)
      first, last = period
      return long_date(first, language) if first == last
      return "#{TEXT.fetch(language)[:months][first.month - 1]} #{first.year}" if first.day == 1 && last == first.end_of_month

      format(TEXT.fetch(language)[:range], first: long_date(first, language), last: long_date(last, language))
    end

    # The fact provider's note before the decree's articles: each schedule with its period, the newest marked as the
    # last confirmed one with the day of its manual check, and how to use them. Dutch, like the fact provider's notes.
    def self.context_note(schedules = SCHEDULES)
      ordered = schedules.sort_by { |row| row[:from] }
      blocks = ordered.each_with_index.map do |row, index|
        following = ordered[index + 1]
        period = if following
                   "VAN #{long_date(row[:from], 'nl')} TOT EN MET #{long_date(following[:from] - 1, 'nl')}".upcase
                 else
                   "VANAF #{long_date(row[:from], 'nl')} (LAATST BEVESTIGD SCHEMA, HANDMATIG NAGEKEKEN OP " \
                   "#{long_date(row[:checked_on], 'nl')})".upcase
                 end
        lines = ["Geïndexeerde minimumdagbedragen van art. 115 #{period}, coëfficiënt " \
                 "#{written(multiplier(row[:rank]), ',', decimals: 4)}:"]
        CONTEXT_LINES.each do |category, values|
          amounts = values.map do |label, base, monthly|
            amount = indexed(BigDecimal(base), row[:rank])
            month = monthly ? " (#{written_thousands(amount * 26)} euro per maand van 26 dagen)" : ''
            "#{"#{label} " if label}#{written(amount, ',')} euro per dag#{month}"
          end
          lines << "- #{category}: #{amounts.join('; ')}"
        end
        lines << "  Bron: #{TABLES.fetch('nl').fetch(:full)} en #{TABLES.fetch('nl').fetch(:temporary)}"
        lines.join("\n")
      end
      <<~NOTE.strip
        OPGELET: De bedragen in art. 115 zijn basisbedragen, gekoppeld aan de spilindex 103,14 van 1 juni 1999 (art. 113). De RVA indexeert ze; deze schema's worden handmatig bijgewerkt.
        #{blocks.reverse.join("\n")}
        TOEPASSING: geef bij een bedrag het geïndexeerde bedrag met zijn begindatum en de datum van de handmatige controle, en zeg dat een latere indexering het kan hebben vervangen. Noem de basisbedragen van art. 115 nooit als de huidige bedragen. Citeer je art. 115, dan letterlijk, met zijn basisbedragen, en geef de indexering apart. Voor de minima van art. 115, § 2 (werkloosheid met bedrijfstoeslag) en voor de maxima toont dit schema geen bedrag: noem er geen en verwijs naar de tabellen van de RVA.
      NOTE
    end

    # 63.29 written with the separator the answer used: "63,29" or "63.29"
    def self.written(amount, separator, decimals: 2)
      whole, fraction = amount.round(decimals, :half_up).to_s('F').split('.')
      "#{whole}#{separator}#{fraction.to_s.ljust(decimals, '0')}"
    end

    # 1645.54 as "1.645,54"
    def self.written_thousands(amount)
      whole, cents = amount.round(2, :half_up).to_s('F').split('.')
      "#{whole.reverse.scan(/\d{1,3}/).join('.').reverse},#{cents.to_s.ljust(2, '0')}"
    end

    # "1 september 2026", "1er septembre 2026", "1. September 2026", "1 September 2026"
    def self.long_date(day, language)
      number = { 'fr' => (day.day == 1 ? '1er' : day.day.to_s), 'de' => "#{day.day}." }.fetch(language, day.day.to_s)
      "#{number} #{TEXT.fetch(language)[:months][day.month - 1]} #{day.year}"
    end

    def self.source_numac(source)
      return source[:numac] || source[:content_numac] || source['numac'] || source['content_numac'] if source.is_a?(Hash)

      source.respond_to?(:content_numac) ? source.content_numac : nil
    end
    private_class_method :source_numac, :decree_retained?, :without_echoed_note, :rewrite_line, :rewrite_segment,
                         :benefit_claim?, :judge, :quoted_figures, :identify, :regime, :period_for, :day_span,
                         :month_span, :year_span, :sentence_at, :paragraph_text, :table_text, :note_for,
                         :quoted_sentence, :tables, :period_words
  end
end
