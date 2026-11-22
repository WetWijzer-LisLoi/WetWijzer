# frozen_string_literal: true

require 'bigdecimal'

module LegalChatbot
  # #337 (Sol 2026-11-22 08:38:00Z, 11:43:54Z, 12:14:18Z, 13:14:02Z, 14:53:13Z): asked "Hoe werkt
  # werkloosheidsuitkering?", the answer gave the minimum daily amounts of the unemployment decree's art. 115 (34,94 and
  # 31,76 euro for a single claimant, 43,11 with family charges; 38,72 and 35,74 for temporary unemployment) as the
  # amounts paid now. Art. 113 of the decree (1991013192, read in full 2026-11-22) links them to the pivot index 103,14 of
  # 1 June 1999 (base 1996 = 100): the amount paid is the base amount times 1,0200^n, n the rank of the pivot index
  # reached, the multiplier kept to four decimals and the daily amount rounded to the cent. The RVA's tables valid from
  # 01.09.2026 (read 2026-11-22, with their ONEM and LfA editions) give each of the twelve TABLE_AMOUNTS times 1,8114,
  # which is 1,02^30 to four decimals.
  #
  # Two uses, one record:
  # - context_note: the fact provider puts the indexed minima, dated, before the decree's articles (FACT_SOURCES
  #   'werkloosheid'), so the model is told the current figures and that the legal text keeps its base amounts.
  # - apply: in the answer, a benefit claim is a figure in euro that reads as a minimum of art. 115 (its base amount, or
  #   its indexed amount at a pivot index of KNOWN_RANKS). A figure does not validate itself (Sol 14:53:13Z): the claim
  #   is the ROWS entry that the facts around it select (regime, household, phase, cause), and the schedule is that of
  #   the period the claim speaks of. When the facts select one row, that row's amount of the schedule is given, the
  #   figure kept when it is that amount; when only the figure selects the row, it is given with the facts it leaves
  #   out; when neither does, or no schedule checked by hand covers the period, the figure is withheld. One italic line
  #   under the answer gives the schedule's first day, the official table of each regime used and the day it was checked
  #   by hand, or why a figure was left out.
  #
  # A sentence (and, within it, a clause) that speaks of another cost (travel, rent, wages, ...) without naming the
  # benefit, or frames an amount as a base amount, is no claim. Links, URLs, code and article references are never
  # touched, and a quotation keeps its base amounts verbatim: the line gives their indexation apart.
  #
  # Maintenance is manual, and the reader is told so. Nothing discovers a new table: when Statbel reports that the
  # pivot index is exceeded, someone reads the RVA tables once they show the new amounts and adds a SCHEDULES row
  # (first day, rank, the day of that reading). A row entered before its first day takes over on that day. A row read
  # longer ago than RECHECK_DAYS cannot vouch for a later day. The minima of art. 115, § 2 appear indexed in no official
  # table and are always withheld. Not covered: monthly figures a model derives itself, the maxima, which follow from the
  # wage limits of art. 111, and the amount art. 115, § 3 gives the unemployed of art. 28, § 3 whatever their household.
  class IndexedAmounts
    VERSION = 3
    DECREE = '1991013192'
    STEP = BigDecimal('1.02')
    # Art. 115 as the programme law of 18 July 2025 (art. 171, in force 1 March 2026) replaced it, read in full NL on
    # 2026-11-22: each minimum with the facts that select it. § 1: full unemployment, by household and phase of the
    # compensation period (each row lists the phase words that fit it); § 2: with company supplement, by household;
    # § 4: temporary unemployment, by cause, whatever the household.
    ROWS = [
      { key: :family_first, base: '43.11', regime: :full, household: :family, phases: %i[first6 months_1_3 months_4_6],
        phase_label: :first6 },
      { key: :family_after, base: '39.19', regime: :full, household: :family, phases: %i[after6 months_7_12 second],
        phase_label: :after6 },
      { key: :single_first, base: '34.94', regime: :full, household: :single, phases: %i[first6 months_1_3 months_4_6],
        phase_label: :first6 },
      { key: :single_after, base: '31.76', regime: :full, household: :single, phases: %i[after6 months_7_12 second],
        phase_label: :after6 },
      { key: :cohabiting_1_3, base: '33.63', regime: :full, household: :cohabiting, phases: %i[first6 months_1_3],
        phase_label: :months_1_3 },
      { key: :cohabiting_4_6, base: '31.04', regime: :full, household: :cohabiting, phases: %i[first6 months_4_6],
        phase_label: :months_4_6 },
      { key: :cohabiting_7_12, base: '28.22', regime: :full, household: :cohabiting, phases: %i[after6 months_7_12],
        phase_label: :months_7_12 },
      { key: :cohabiting_second_conditions, base: '23.39', regime: :full, household: :cohabiting,
        phases: %i[after6 second], phase_label: :second_conditions },
      { key: :cohabiting_second, base: '16.48', regime: :full, household: :cohabiting, phases: %i[after6 second],
        phase_label: :second_without },
      { key: :spouses_supplement, base: '3.12', regime: :full, household: :cohabiting, phases: %i[after6 second],
        phase_label: :supplement },
      { key: :temporary_force_majeure, base: '38.72', regime: :temporary, cause: :force_majeure },
      { key: :temporary_other, base: '35.74', regime: :temporary, cause: :other },
      { key: :company_family, base: '37.89', regime: :company, household: :family },
      { key: :company_single, base: '30.71', regime: :company, household: :single },
      { key: :company_cohabiting, base: '27.29', regime: :company, household: :cohabiting }
    ].map { |row| row.merge(base: BigDecimal(row[:base])).freeze }.freeze
    # TABLE_AMOUNTS: the minima the RVA's tables show indexed (§ 1 in "volledige werkloosheid nieuwe reglementering",
    # § 4 in "tijdelijke werkloosheid"); UNPUBLISHED_AMOUNTS: the minima of § 2, which no official table shows indexed.
    TABLE_AMOUNTS = ROWS.reject { |row| row[:regime] == :company }.map { |row| row[:base] }.freeze
    UNPUBLISHED_AMOUNTS = ROWS.select { |row| row[:regime] == :company }.map { |row| row[:base] }.freeze
    BASE_AMOUNTS = (TABLE_AMOUNTS + UNPUBLISHED_AMOUNTS).freeze
    TEMPORARY_AMOUNTS = ROWS.select { |row| row[:regime] == :temporary }.map { |row| row[:base] }.freeze
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
    # Each value a figure can be read as, to its readings [row, rank]: rank nil for the base amount itself
    READINGS = ROWS.product([nil, *KNOWN_RANKS.to_a]).group_by do |row, rank|
      rank ? (row[:base] * (STEP**rank).round(4, :half_up)).round(2, :half_up) : row[:base]
    end.freeze
    SUBJECT = /werkloos|werkloze|ch[oô]m|(?<![[:alpha:]])(?:rva|onem|lfa)(?![[:alpha:]])|arbeitslos|unemploy|jobless/i
    # An answer, paragraph, sentence or clause about unemployment benefit
    UNEMPLOYMENT = /(?<![[:alpha:]])(?:\p{L}*werkloos\p{L}*|\p{L}*werkloze\p{L}*|\p{L}*uitkering\p{L}*|\p{L}*dagbedrag\p{L}*|rva|onem|lfa|
                    ch[oô]m\p{L}*|allocations?|indemnit[ée]s?|arbeitslos\p{L}*|unemploy\p{L}*|jobless|benefits?)(?![[:alpha:]])/iux
    # A sentence or clause about another cost or income: its amounts are not the benefit, unless it names the benefit
    OTHER_AMOUNT = /(?<![[:alpha:]])(?:\p{L}*kosten\p{L}*|verplaatsing\p{L}*|kilometer\p{L}*|vervoer\p{L}*|huur\p{L}*|
                    \p{L}*loon\p{L}*|lonen|salaris\p{L}*|premie(?!rs?(?![[:alpha:]]))\p{L}*|bijdrage\p{L}*|boete\p{L}*|frais|d[ée]placement\p{L}*|
                    loyer\p{L}*|salaire\p{L}*|cotisation\p{L}*|amende\p{L}*|fahrtkosten|reisekosten|miete\p{L}*|lohn|
                    gehalt\p{L}*|beitr(?:a|ä)g\p{L}*|geldbu(?:ß|ss)e\p{L}*|travel\p{L}*|expens\p{L}*|fares?|rent|wages?|
                    salar(?:y|ies)|contributions?|fines?)(?![[:alpha:]])/iux
    BASE_FRAME = /basisbedrag|spilindex|index(?:cijfer)?[[:space:]]+100|niet[-[:space:]]ge[iï]ndexeerd|montants?[[:space:]]+de[[:space:]]+base|
                  indice[-[:space:]]pivot|non[[:space:]]+index[ée]|basisbetr[aä]g|schwellenindex|base[[:space:]]+amount|pivot[[:space:]]+index|
                  not[[:space:]]+indexed/ix
    # Money in a sentence: a currency, or a daily rate
    MONEY = /€|(?<![[:alpha:]])(?:eur(?:os?)?(?![[:alpha:]])|per[[:space:]]+(?:uitkerings)?dag|dagbedrag|par[[:space:]]+jour|
             journalier|pro[[:space:]]+tag|tagesbetrag|per[[:space:]]+day|a[[:space:]]+day|daily)/ix
    # The daily rate right after a figure: a qualifier follows it
    DAILY_RATE = /\A[[:space:]]*(?:per[[:space:]]+(?:uitkerings)?dag|par[[:space:]]+jour|pro[[:space:]]+tag|per[[:space:]]+day|
                  a[[:space:]]+day)(?![[:alpha:]])/ix
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
    # Where a clause ends inside a sentence: punctuation (not a decimal comma) or a conjunction
    CLAUSE_BREAK = /,(?!\d)|[;:()]|[[:space:]](?:en|maar|terwijl|and|but|while|et|mais|tandis|und|aber|während)(?=[[:space:]])/i
    # The facts that select a row, in the four languages. A more specific phase (months 1 to 3, ...) is read before the
    # general halves of the first period.
    FACTS = {
      regime: {
        temporary: /tijdelijk\p{L}*[[:space:]]+werklo\p{L}*|ch[ôo]m\p{L}*[[:space:]]+temporaire|zeitweilig\p{L}*|kurzarbeit\p{L}*|
                    temporar\p{L}*[[:space:]]+unemploy\p{L}*|temporarily[[:space:]]+unemployed|art\.?[[:space:]]*115,?[[:space:]]*§[[:space:]]*4(?!\d)/iux,
        company: /bedrijfstoeslag\p{L}*|(?<![[:alpha:]])swt(?![[:alpha:]])|brugpensioen\p{L}*|compl[ée]ment[[:space:]]+d.entreprise|
                  (?<![[:alpha:]])rcc(?![[:alpha:]])|pr[ée]pension\p{L}*|betriebszuschlag\p{L}*|fr[üu]hpension\p{L}*|company[[:space:]]+supplement|
                  bridging[[:space:]]+pension|art\.?[[:space:]]*115,?[[:space:]]*§[[:space:]]*2(?!\d)/iux
      },
      household: {
        family: /gezinslast\p{L}*|gezinshoofd\p{L}*|charges?[[:space:]]+de[[:space:]]+famille|chefs?[[:space:]]+de[[:space:]]+m[ée]nage|
                 familienlast\p{L}*|haushaltsvorst\p{L}*|family[[:space:]]+(?:responsibilities|charges|dependants)|dependants?|
                 head[[:space:]]+of[[:space:]]+(?:the[[:space:]]+)?household/iux,
        single: /alleenwonend\p{L}*|alleenstaand\p{L}*|(?<![[:alpha:]])isol[ée]e?s?(?![[:alpha:]])|alleinstehend\p{L}*|alleinlebend\p{L}*|
                 allein[[:space:]]+lebend\p{L}*|living[[:space:]]+alone|lives?[[:space:]]+alone|single[[:space:]]+(?:claimants?|persons?|workers?|people)/iux,
        cohabiting: /samenwonend\p{L}*|cohabitant\p{L}*|zusammenwohnend\p{L}*|zusammenlebend\p{L}*|cohabiting/iux
      },
      phase: {
        months_1_3: /eerste[[:space:]]+(?:drie|3)[[:space:]]+maanden|(?:trois|3)[[:space:]]+premiers[[:space:]]+mois|ersten[[:space:]]+(?:drei|3)[[:space:]]+monat\p{L}*|
                     first[[:space:]]+(?:three|3)[[:space:]]+months|(?:maand(?:en)?|mois|monate?|months?)[[:space:]]+1[[:space:]]*(?:-|–|tot|à|bis|to)[[:space:]]*3(?!\d)/iux,
        months_4_6: /(?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:vier|quatre|four|4)[[:space:]]*(?:-|–|tot|à|bis|to)[[:space:]]*(?:zes|six|sechs|6)(?!\d)/iux,
        months_7_12: /(?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:zeven|sept|sieben|seven|7)[[:space:]]*(?:-|–|tot|à|bis|to)[[:space:]]*
                      (?:twaalf|douze|zwölf|zwoelf|twelve|12)(?!\d)/iux,
        second: /tweede[[:space:]]+vergoedingsperiode|seconde?[[:space:]]+p[ée]riode[[:space:]]+d.indemnisation|zweiten?[[:space:]]+entsch[äa]digungszeitraum\p{L}*|
                 second[[:space:]]+(?:compensation|benefit)[[:space:]]+period/iux,
        first6: /eerste[[:space:]]+(?:zes|6)[[:space:]]+maanden|(?:zes|6)[[:space:]]+eerste[[:space:]]+maanden|(?:six|6)[[:space:]]+premiers[[:space:]]+mois|
                 ersten[[:space:]]+(?:sechs|6)[[:space:]]+monat\p{L}*|first[[:space:]]+(?:six|6)[[:space:]]+months|
                 (?:maand(?:en)?|mois|monate?|months?)[[:space:]]+1[[:space:]]*(?:-|–|tot|à|bis|to)[[:space:]]*6(?!\d)/iux,
        after6: /daaropvolgende[[:space:]]+maanden|(?<![[:alpha:]])daarna(?![[:alpha:]])|vanaf[[:space:]]+de[[:space:]]+(?:zevende|7de|7e)[[:space:]]+maand|
                 na[[:space:]]+(?:de[[:space:]]+eerste[[:space:]]+)?(?:zes|6)[[:space:]]+maanden|mois[[:space:]]+suivants|(?<![[:alpha:]])ensuite(?![[:alpha:]])|
                 apr[èe]s[[:space:]]+les[[:space:]]+(?:six|6)[[:space:]]+premiers[[:space:]]+mois|
                 nach[[:space:]]+den[[:space:]]+ersten[[:space:]]+(?:sechs|6)[[:space:]]+monat\p{L}*|
                 (?:à|a)[[:space:]]+partir[[:space:]]+du[[:space:]]+(?:septième|7e)[[:space:]]+mois|folgenden[[:space:]]+monat\p{L}*|
                 (?<![[:alpha:]])danach(?![[:alpha:]])|ab[[:space:]]+dem[[:space:]]+(?:siebten|7\.)[[:space:]]+monat|following[[:space:]]+months|
                 (?<![[:alpha:]])thereafter(?![[:alpha:]])|after[[:space:]]+(?:the[[:space:]]+first[[:space:]]+)?(?:six|6)[[:space:]]+months|
                 from[[:space:]]+the[[:space:]]+(?:seventh|7th)[[:space:]]+month/iux
      },
      cause: {
        force_majeure: /overmacht|force[[:space:]]+majeure|h[öo]here[nr]?[[:space:]]+gewalt/iu,
        other: /andere[[:space:]]+reden|economische[[:space:]]+(?:reden|oorza)\p{L}*|autres?[[:space:]]+raisons?|raisons?[[:space:]]+[ée]conomiques?|
                anderen?[[:space:]]+grund\p{L}*|wirtschaftlich\p{L}*[[:space:]]+gr[üu]nd\p{L}*|other[[:space:]]+reasons?|economic[[:space:]]+reasons?/iux
      }
    }.freeze
    SPECIFIC_PHASES = %i[months_1_3 months_4_6 months_7_12 second].freeze
    # Sol 19:11:40Z: "alleenwonende zonder gezinslast" names no family; the negated term is read as absent
    NEGATED_FAMILY = /(?<![[:alpha:]])(?:zonder|geen|niet\s+met)[[:space:]]+gezinslast\p{L}*|sans[[:space:]]+charges?[[:space:]]+de[[:space:]]+famille|
                      ohne[[:space:]]+familienlast\p{L}*|without[[:space:]]+(?:family[[:space:]]+(?:responsibilities|charges|dependants)|
                      dependants?)(?![[:alpha:]])/iux
    # Sol 19:11:40Z: "Voor een werknemer met gezinslast bedroeg het in dezelfde maand ..." takes the period of the earlier
    # sentence, even though that sentence has a figure of its own
    SAME_PERIOD = /(?<![[:alpha:]])(?:(?:dezelfde|diezelfde|die)[[:space:]]+(?:maand|periode|tijd|datum|dag)|toen|op[[:space:]]+dat[[:space:]]+moment|
                   (?:m[êe]me|cette)[[:space:]]+(?:mois|p[ée]riode|date|[ée]poque|jour)|[àa][[:space:]]+cette[[:space:]]+(?:date|[ée]poque)|
                   (?:selben|gleichen|diesem)[[:space:]]+(?:monat|zeitraum|tag|zeitpunkt)|damals|
                   the[[:space:]]+same[[:space:]]+(?:month|period|day|date)|at[[:space:]]+that[[:space:]]+(?:time|date))(?![[:alpha:]])/iux
    # "nu", "currently": the sentence speaks of today, whatever an earlier sentence dated
    NOW = /(?<![[:alpha:]])(?:nu|momenteel|thans|actueel|vandaag|actuellement|aujourd.hui|derzeit|aktuell|heute|now|currently|today|
           deze[[:space:]]+maand|dit[[:space:]]+jaar|ce[[:space:]]+mois(?:-ci)?|cette[[:space:]]+ann[ée]e|diesen[[:space:]]+monat|
           dieses[[:space:]]+jahr|this[[:space:]]+(?:month|year))(?![[:alpha:]])/iux
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
        unidentified: 'Uit het antwoord blijkt niet welk minimum van art. 115 een bedrag betreft (gezin, fase of regeling); ' \
                      'het is weggelaten. Zie %<tables>s.',
        unpublished: 'Het minimum bij werkloosheid met bedrijfstoeslag (art. 115, § 2) staat in geen officiële tabel ' \
                     'geïndexeerd en is weggelaten.',
        withheld: '[actueel bedrag: zie de tabel van de RVA]',
        unpublished_withheld: '[geen officieel geïndexeerd bedrag]',
        quoted: 'Het citaat geeft de basisbedragen van de wettekst; geïndexeerd: %<list>s.',
        quoted_base: 'Het citaat geeft de basisbedragen van de wettekst.',
        tables: { full: 'de tabel van de [RVA](%<full>s)',
                  temporary: 'de tabel tijdelijke werkloosheid van de [RVA](%<temporary>s)',
                  both: 'de tabellen van de RVA voor [volledige](%<full>s) en [tijdelijke werkloosheid](%<temporary>s)' },
        range: 'de periode van %<first>s tot %<last>s',
        months: %w[januari februari maart april mei juni juli augustus september oktober november december],
        facets: { family: 'werknemer met gezinslast', single: 'alleenwonende werknemer', cohabiting: 'samenwonende werknemer',
                  first6: 'eerste zes maanden', after6: 'na de eerste zes maanden', months_1_3: 'maanden 1 tot 3',
                  months_4_6: 'maanden 4 tot 6', months_7_12: 'maanden 7 tot 12',
                  second_conditions: 'tweede vergoedingsperiode, met de voorwaarden van art. 114, § 4, 1°',
                  second_without: 'tweede vergoedingsperiode, zonder de voorwaarden van art. 114, § 4, 1°',
                  second_conditions_only: 'met de voorwaarden van art. 114, § 4, 1°',
                  second_without_only: 'zonder de voorwaarden van art. 114, § 4, 1°',
                  supplement: 'verhoging voor twee samenwonende echtgenoten',
                  force_majeure: 'tijdelijke werkloosheid door overmacht', other: 'tijdelijke werkloosheid om een andere reden' }
      },
      'fr' => {
        base: "Les montants de l'art. 115 de l'arrêté royal du 25 novembre 1991 portant réglementation du chômage sont " \
              "des montants de base, liés à l'indice-pivot 103,14 du 1er juin 1999 (art. 113).",
        note: 'Montants indexés valables à partir du %<from>s selon %<tables>s, vérifiés manuellement le %<checked>s ; ' \
              'une indexation ultérieure peut les avoir remplacés depuis.',
        stale: "Le montant actuel n'a pas pu être confirmé : la dernière vérification manuelle des montants indexés est " \
               'trop ancienne. Voir %<tables>s.',
        uncovered: "Pour %<period>s, aucun montant vérifié manuellement n'est disponible ; il est omis. Voir %<tables>s.",
        unidentified: "La réponse ne permet pas de savoir quel minimum de l'art. 115 un montant vise (ménage, phase ou " \
                      'régime) ; il est omis. Voir %<tables>s.',
        unpublished: "Le minimum en cas de chômage avec complément d'entreprise (art. 115, § 2) ne figure indexé dans " \
                     'aucun tableau officiel et est omis.',
        withheld: "[montant actuel : voir le tableau de l'ONEM]",
        unpublished_withheld: '[aucun montant indexé officiel]',
        quoted: 'La citation donne les montants de base du texte légal ; indexés : %<list>s.',
        quoted_base: 'La citation donne les montants de base du texte légal.',
        tables: { full: "le tableau de l'[ONEM](%<full>s)",
                  temporary: "le tableau chômage temporaire de l'[ONEM](%<temporary>s)",
                  both: "les tableaux de l'ONEM pour le [chômage complet](%<full>s) et le [chômage temporaire](%<temporary>s)" },
        range: 'la période du %<first>s au %<last>s',
        months: %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre],
        facets: { family: 'travailleur ayant charge de famille', single: 'travailleur isolé', cohabiting: 'travailleur cohabitant',
                  first6: 'six premiers mois', after6: 'après les six premiers mois', months_1_3: 'mois 1 à 3',
                  months_4_6: 'mois 4 à 6', months_7_12: 'mois 7 à 12',
                  second_conditions: "seconde période d'indemnisation, aux conditions de l'art. 114, § 4, 1°",
                  second_without: "seconde période d'indemnisation, sans les conditions de l'art. 114, § 4, 1°",
                  second_conditions_only: "aux conditions de l'art. 114, § 4, 1°",
                  second_without_only: "sans les conditions de l'art. 114, § 4, 1°",
                  supplement: 'majoration pour deux conjoints cohabitants',
                  force_majeure: 'chômage temporaire pour force majeure', other: 'chômage temporaire pour une autre raison' }
      },
      'de' => {
        base: 'Die Beträge in Art. 115 des Königlichen Erlasses vom 25. November 1991 zur Regelung der Arbeitslosigkeit ' \
              'sind Basisbeträge, gekoppelt an den Schwellenindex 103,14 vom 1. Juni 1999 (Art. 113).',
        note: 'Indexierte Beträge gültig ab dem %<from>s laut %<tables>s, manuell geprüft am %<checked>s; eine spätere ' \
              'Indexierung kann sie inzwischen ersetzt haben.',
        stale: 'Der aktuelle Betrag konnte nicht bestätigt werden: Die letzte manuelle Prüfung der indexierten Beträge ' \
               'liegt zu weit zurück. Siehe %<tables>s.',
        uncovered: 'Für %<period>s ist kein manuell geprüfter Betrag verfügbar; er wurde weggelassen. Siehe %<tables>s.',
        unidentified: 'Aus der Antwort geht nicht hervor, welches Minimum von Art. 115 ein Betrag meint (Haushalt, Phase ' \
                      'oder Regelung); er wurde weggelassen. Siehe %<tables>s.',
        unpublished: 'Das Minimum bei Arbeitslosigkeit mit Betriebszuschlag (Art. 115 § 2) steht in keiner amtlichen ' \
                     'Tabelle indexiert und wurde weggelassen.',
        withheld: '[aktueller Betrag: siehe die Tabelle des LfA]',
        unpublished_withheld: '[kein amtlich indexierter Betrag]',
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
        months: %w[Januar Februar März April Mai Juni Juli August September Oktober November Dezember],
        facets: { family: 'Arbeitnehmer mit Familienlasten', single: 'alleinstehender Arbeitnehmer',
                  cohabiting: 'zusammenwohnender Arbeitnehmer', first6: 'erste sechs Monate', after6: 'nach den ersten sechs Monaten',
                  months_1_3: 'Monate 1 bis 3', months_4_6: 'Monate 4 bis 6', months_7_12: 'Monate 7 bis 12',
                  second_conditions: 'zweiter Entschädigungszeitraum, mit den Bedingungen von Art. 114 § 4 Nr. 1',
                  second_without: 'zweiter Entschädigungszeitraum, ohne die Bedingungen von Art. 114 § 4 Nr. 1',
                  second_conditions_only: 'mit den Bedingungen von Art. 114 § 4 Nr. 1',
                  second_without_only: 'ohne die Bedingungen von Art. 114 § 4 Nr. 1',
                  supplement: 'Erhöhung für zwei zusammenwohnende Ehepartner',
                  force_majeure: 'zeitweilige Arbeitslosigkeit wegen höherer Gewalt',
                  other: 'zeitweilige Arbeitslosigkeit aus einem anderen Grund' }
      },
      'en' => {
        base: 'The amounts in art. 115 of the Royal Decree of 25 November 1991 on unemployment are base amounts, linked ' \
              'to the pivot index 103.14 of 1 June 1999 (art. 113).',
        note: 'Indexed amounts valid from %<from>s according to %<tables>s, checked manually on %<checked>s; a later ' \
              'indexation may have replaced them since.',
        stale: 'The current amount could not be confirmed: the last manual check of the indexed amounts is too old. ' \
               'See %<tables>s.',
        uncovered: 'For %<period>s no manually checked amount is available; it is left out. See %<tables>s.',
        unidentified: 'The answer does not show which minimum of art. 115 an amount concerns (household, phase or ' \
                      'scheme); it is left out. See %<tables>s.',
        unpublished: 'The minimum for unemployment with a company supplement (art. 115, § 2) is shown indexed in no ' \
                     'official table and is left out.',
        withheld: "[current amount: see ONEM's table]",
        unpublished_withheld: '[no officially indexed amount]',
        quoted: 'The quotation gives the statutory base amounts; indexed: %<list>s.',
        quoted_base: 'The quotation gives the statutory base amounts.',
        tables: { full: "[ONEM's table](%<full>s) (in French)",
                  temporary: "[ONEM's temporary unemployment table](%<temporary>s) (in French)",
                  both: "ONEM's tables for [full](%<full>s) and [temporary unemployment](%<temporary>s) (in French)" },
        range: 'the period from %<first>s to %<last>s',
        months: %w[January February March April May June July August September October November December],
        facets: { family: 'worker with family responsibilities', single: 'worker living alone', cohabiting: 'cohabiting worker',
                  first6: 'first six months', after6: 'after the first six months', months_1_3: 'months 1 to 3',
                  months_4_6: 'months 4 to 6', months_7_12: 'months 7 to 12',
                  second_conditions: 'second compensation period, meeting the conditions of art. 114, § 4, 1°',
                  second_without: 'second compensation period, without the conditions of art. 114, § 4, 1°',
                  second_conditions_only: 'meeting the conditions of art. 114, § 4, 1°',
                  second_without_only: 'without the conditions of art. 114, § 4, 1°',
                  supplement: 'increase for two cohabiting spouses',
                  force_majeure: 'temporary unemployment due to force majeure', other: 'temporary unemployment for another reason' }
      }
    }.freeze
    # The quote guard's notice for a quotation it withheld (AnswerGuards#missing_quote_message), and a sentence that
    # refers back to the quoted amounts (Sol 17:42:33Z: "De geciteerde bedragen zijn de basisbedragen" under a withheld
    # quotation of art. 115)
    QUOTE_WITHHELD = /Een citaat is weggelaten|Une citation a été omise|Ein Zitat wurde weggelassen|A quotation was omitted/
    QUOTE_BACK_REFERENCE = /(?<![[:alpha:]])(?:(?:geciteerde|aangehaalde)\s+(?:basis)?bedragen|(?:basis)?bedragen\s+(?:in|uit)\s+(?:het|dit|dat|de)\s+citaat|
                            montants?\s+(?:de\s+base\s+)?cit[ée]s|zitierten\s+(?:Basis)?betr[äa]ge|quoted\s+(?:base\s+)?amounts)(?![[:alpha:]])/ix
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
      body = without_dangling_quote_reference(without_echoed_note(text))
      context = { today: today, schedules: schedules, language: language, question: question.to_s,
                  question_period: period_in(question.to_s, today),
                  answer_cue: question.to_s.match?(UNEMPLOYMENT) || decree_retained?(sources) }
      events = []
      lines = body.split("\n", -1)
      rewritten = lines.each_with_index.map { |line, index| rewrite_line(line, lines, index, context, events) }
      # Sol 14:53:13Z: a copied old note goes even when no figure is left to date
      return unchanged.with(text: body.rstrip) if events.empty? && body != text
      return unchanged if events.empty?

      counts = events.map { |event| event[:kind] }.tally
      Result.new(text: "#{rewritten.join("\n").rstrip}\n\n#{note_for(events, context)}", replaced: counts.fetch(:replaced, 0),
                 confirmed: counts.fetch(:confirmed, 0), withheld: counts.fetch(:withheld, 0) + counts.fetch(:unpublished, 0),
                 quoted: counts.fetch(:quoted, 0), schedule: events.filter_map { |event| event[:schedule] }.first)
    end

    # When the quote guard withheld a quotation, a sentence that only refers back to the quoted amounts goes
    def self.without_dangling_quote_reference(text)
      return text unless text.match?(QUOTE_WITHHELD)

      text.split("\n", -1).filter_map do |line|
        next line unless line.match?(QUOTE_BACK_REFERENCE)

        kept = sentences(line).reject { |sentence| sentence.match?(QUOTE_BACK_REFERENCE) && !sentence.match?(AMOUNT) }
        kept.empty? ? nil : kept.join(' ')
      end.join("\n")
    end

    def self.without_echoed_note(text)
      paragraphs = text.split(/\n{2,}/)
      paragraphs.any? { |paragraph| paragraph.match?(NOTE_LEAD) } ? paragraphs.grep_v(NOTE_LEAD).join("\n\n") : text
    end

    # One line: quotations and protected spans pass unchanged; every figure elsewhere is judged in its clause
    def self.rewrite_line(line, lines, index, context, events)
      paragraph = paragraph_text(lines, index)
      cue = context[:answer_cue] || paragraph.match?(UNEMPLOYMENT)
      if line.match?(BLOCKQUOTE)
        quoted_figures(line, line.match?(MONEY), cue, paragraph, context, events)
        return line
      end

      place = { lines: lines, index: index, table: line.match?(TABLE_ROW) ? table_lines(lines, index) : nil }
      offset = 0
      line.split(/(#{QUOTED}|#{PROTECTED.source})/ix).map do |segment|
        start = offset
        offset += segment.length
        next segment if segment.match?(/\A(?:#{PROTECTED.source})\z/ix)

        if segment.match?(/\A(?:#{QUOTED})\z/)
          money = segment.match?(MONEY) || sentence_span(line, start).then { |first, last| line[first...last] }.match?(MONEY)
          quoted_figures(segment, money, cue, paragraph, context, events)
          next segment
        end

        rewrite_segment(segment, start, line, place, cue, context, events)
      end.join
    end

    def self.rewrite_segment(segment, start, line, place, cue, context, events)
      out = +''
      cursor = 0
      segment.to_enum(:scan, AMOUNT).map { Regexp.last_match }.each do |match|
        out << segment[cursor...match.begin(0)]
        cursor = match.end(0)
        position = start + match.begin(0)
        scope = scope_at(line, position, place)
        readings = READINGS.fetch(BigDecimal("#{match[:int]}.#{match[:dec]}"), [])
        unless readings.any? && benefit_claim?(scope, cue, match)
          out << match[0]
          next
        end

        replacement, qualifier = judge(match, readings, scope, context, events)
        if qualifier
          rate = segment[cursor..].to_s[DAILY_RATE]
          if rate
            replacement += rate
            cursor += rate.length
          end
          replacement += " (#{qualifier})"
        end
        out << replacement
      end
      out << segment[cursor..].to_s
    end

    # Where a figure stands: its clause, its sentence and the earlier sentences of its paragraph that state no figure of
    # their own (nearest first: "Voor een werknemer met gezinslast:", "In april 2026 gold het volgende."); a sentence
    # with its own figure speaks of its own claim. In a table: its cell, its row, its column's header and the line that
    # introduces the table. frame: the text whose currency, other cost or base-amount wording counts (the whole table).
    def self.scope_at(line, position, place)
      if place[:table]
        rows = place[:table]
        cell_index = line[0...position].count('|')
        header = rows.first.split('|')[cell_index].to_s
        cell = line.split('|')[cell_index].to_s
        intro = place[:lines][[place[:index] - rows.index(line).to_i - 1, 0].max].to_s
        context = [header, intro].reject(&:empty?)
        return { clause: cell, sentence: line, before: context, before_all: context, dated: line,
                 frame: ([intro] + rows).uniq.join("\n") }
      end

      first, last = sentence_span(line, position)
      sentence = line[first...last]
      clause = clause_at(sentence, position - first)
      paragraph = place[:lines][paragraph_start(place[:lines], place[:index])...place[:index]] + [line[0...first]]
      before_all = paragraph.flat_map { |text| sentences(text) }.reverse
      { clause: clause, sentence: sentence, before: before_all.grep_v(AMOUNT), before_all: before_all, dated: sentence,
        frame: sentence }
    end

    # A figure in euro in an answer about unemployment, whose clause names no other cost (or names the benefit), whose
    # sentence frames no base amount
    def self.benefit_claim?(scope, cue, match)
      clause = scope[:clause]
      sentence = scope[:frame]
      return false unless cue
      return false if sentence.match?(BASE_FRAME)
      return false if clause.match?(OTHER_AMOUNT) && !clause.match?(UNEMPLOYMENT)
      return false if !clause.match?(UNEMPLOYMENT) && sentence.match?(OTHER_AMOUNT) && !sentence.match?(UNEMPLOYMENT)

      (match[:pre] || match[:post] || sentence.match?(MONEY)).present?
    end

    # The figure's row and the schedule of its period: [replacement, qualifier or nil]
    def self.judge(match, readings, scope, context, events)
      words = TEXT[context[:language]]
      facts = facts_for([scope[:clause], scope[:sentence], *scope[:before], context[:question]])
      period = period_for(scope, context)
      schedule, reason = schedule_for(period, schedules: context[:schedules])
      latest = context[:schedules].sort_by { |candidate| candidate[:from] }.rfind { |candidate| candidate[:from] <= period.first }
      row, rank, by = resolve(readings, facts, (schedule || latest)&.fetch(:rank))
      regime = row ? row[:regime] : facts[:regime]
      if regime == :company
        events << { kind: :unpublished }
        return [words[:unpublished_withheld], nil]
      end
      unless row
        events << { kind: :withheld, regime: regime || :full, reason: :unidentified, period: period }
        return [words[:withheld], nil]
      end
      unless schedule
        events << { kind: :withheld, regime: row[:regime], reason: reason, period: period }
        return [words[:withheld], nil]
      end

      qualifier = by == :figure ? qualifier_for(row, facts, scope, words) : nil
      if rank == schedule[:rank] && by == :figure
        events << { kind: :confirmed, regime: row[:regime], schedule: schedule }
        return [match[0], qualifier]
      end

      events << { kind: :replaced, regime: row[:regime], schedule: schedule }
      ["#{match[:pre]}#{written(indexed(row[:base], schedule[:rank]), match[:sep])}#{match[:post]}", qualifier]
    end

    # [row, rank, how]: the row the facts allow that the figure reads as (:figure), the one row the facts allow when the
    # figure reads as another (:facts, the figure is wrong for them), or nil. Between readings of the figure, the
    # schedule's own rank or a base amount wins: 57,53 is 31,76 at rank 30 rather than 38,72 at rank 20.
    def self.resolve(readings, facts, schedule_rank)
      pool = candidates(facts)
      matching = readings.select { |reading| pool.include?(reading.first) }
      rows = matching.map(&:first).uniq
      if rows.length > 1
        preferred = matching.select { |_row, rank| rank.nil? || rank == schedule_rank }.map(&:first).uniq
        rows = preferred if preferred.one?
      end
      if rows.one?
        reading = matching.find { |row, rank| row == rows.first && (rank.nil? || rank == schedule_rank) } ||
                  matching.find { |row, _rank| row == rows.first }
        return [reading.first, reading.last, :figure]
      end
      return [pool.first, nil, :facts] if rows.empty? && pool.one?

      [nil, nil, nil]
    end

    # The rows the facts allow. A household, a phase or a cause without a regime implies one: full unemployment, or
    # temporary unemployment for a cause; § 4 holds whatever the household, § 2 has no phases.
    def self.candidates(facts)
      regime = facts[:regime] || (facts[:cause] ? :temporary : nil) || (facts[:household] || facts[:phase] ? :full : nil)
      ROWS.select do |row|
        (regime.nil? || row[:regime] == regime) &&
          (facts[:household].nil? || row[:household].nil? || row[:household] == facts[:household]) &&
          (facts[:phase].nil? || row[:phases].nil? || row[:phases].include?(facts[:phase])) &&
          (facts[:cause].nil? || row[:cause].nil? || row[:cause] == facts[:cause])
      end
    end

    # Each fact from the nearest text that names it: a text naming two values of a fact leaves it open
    def self.facts_for(texts)
      FACTS.keys.to_h do |fact|
        value = nil
        texts.each do |text|
          found = fact_values(text.to_s, fact)
          next if found.empty?

          value = found.one? ? found.first : nil
          break
        end
        [fact, value]
      end
    end

    def self.fact_values(text, fact)
      text = text.gsub(NEGATED_FAMILY, ' ') if fact == :household
      found = FACTS.fetch(fact).select { |_value, pattern| text.match?(pattern) }.keys
      return found unless fact == :phase

      # "na de eerste zes maanden" names the later phase, not the first six months it contains
      after = FACTS.dig(:phase, :after6)
      found -= [:first6] if found.include?(:after6) && !text.gsub(after, ' ').match?(FACTS.dig(:phase, :first6))
      return found unless found.length > 1

      specific = found & SPECIFIC_PHASES
      specific.any? ? specific : found
    end

    # The row's facts its text leaves out: the household and phase of § 1, the cause of § 4
    def self.qualifier_for(row, facts, scope, words)
      facets = words.fetch(:facets)
      missing = []
      if row[:regime] == :temporary
        missing << facets.fetch(row[:cause]) if facts[:cause].nil?
      elsif row[:key] == :spouses_supplement
        missing << facets.fetch(:supplement) unless scope[:sentence].match?(/echtgeno|conjoint|ehegatt|ehepartner|spouse/i)
      else
        missing << facets.fetch(row[:household]) if facts[:household].nil?
        if phase_open?(row, facts[:phase])
          # a stated second period leaves only its condition open
          label = facts[:phase] == :second ? :"#{row[:phase_label]}_only" : row[:phase_label]
          missing << facets.fetch(label)
        end
      end
      missing.any? ? missing.join(', ') : nil
    end

    # Whether the text leaves the row's phase open: it names none, or a wider one ("eerste zes maanden" for a
    # cohabitant's months 1 to 3, "tweede vergoedingsperiode" without the conditions of art. 114, § 4, 1°)
    def self.phase_open?(row, phase)
      return true if phase.nil?
      return false if phase == row[:phase_label]

      !(%i[first6 after6].include?(row[:phase_label]) && row[:phases].include?(phase))
    end

    # A quotation keeps its base amounts; the line gives their indexation for the period its paragraph speaks of
    def self.quoted_figures(segment, money, cue, paragraph, context, events)
      return unless cue

      segment.to_enum(:scan, AMOUNT).each do
        match = Regexp.last_match
        value = BigDecimal("#{match[:int]}.#{match[:dec]}")
        next unless BASE_AMOUNTS.include?(value) && (match[:pre] || match[:post] || money)

        schedule, = schedule_for(period_in(paragraph, context[:today]) || context[:question_period] ||
                                 [context[:today], context[:today]], schedules: context[:schedules])
        events << { kind: :quoted, value: value, separator: match[:sep], regime: regime(value),
                    schedule: (schedule if TABLE_AMOUNTS.include?(value)) }
      end
    end

    # :full (§ 1), :temporary (§ 4) or nil (§ 2, which no official table shows indexed)
    def self.regime(value)
      return :temporary if TEMPORARY_AMOUNTS.include?(value)

      TABLE_AMOUNTS.include?(value) ? :full : nil
    end

    # The period a figure speaks of: its own sentence's dates; "nu" means today; else the nearest earlier sentence of its
    # paragraph that dates a closed period ("In april 2026 gold het volgende."); else the question's; else today
    def self.period_for(scope, context)
      today = [context[:today], context[:today]]
      own = period_in(scope[:dated], context[:today])
      return own if own
      return today if scope[:dated].match?(NOW)

      if scope[:dated].match?(SAME_PERIOD)
        named = scope[:before_all].lazy.map { |text| period_in(text, context[:today], closed_only: true) }.find(&:itself)
        return named if named
      end
      earlier = scope[:before].lazy.map { |text| period_in(text, context[:today], closed_only: true) }.find(&:itself)
      earlier || context[:question_period] || today
    end

    # [first, last] spanned by the dates a text names (a law's own date excepted), or nil. closed_only: an open-ended
    # date ("sinds 1 maart 2026") names no period for a later sentence.
    def self.period_in(text, today, closed_only: false)
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

          if before.match?(OPEN_ENDED)
            return nil if closed_only

            span = [span.first, [span.last, today].max]
          end
          spans << span
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

    # [first, last] of the sentence of line holding position: a full stop after an abbreviation or inside a number ends
    # none
    def self.sentence_span(line, position)
      start = 0
      line.to_enum(:scan, /[.!?;](?=[[:space:]]|\z)/).each do
        stop = Regexp.last_match.end(0)
        next if line[stop - 1] == '.' && line[start...(stop - 1)].match?(ABBREVIATION)
        return [start, stop] if position < stop

        start = stop
      end
      [start, line.length]
    end

    def self.sentences(text)
      spans = []
      start = 0
      while start < text.length
        _, stop = sentence_span(text[start..], 0)
        spans << text[start, stop]
        start += [stop, 1].max
      end
      spans.map(&:strip).reject(&:empty?)
    end

    def self.clause_at(sentence, position)
      start = 0
      sentence.to_enum(:scan, CLAUSE_BREAK).each do
        found = Regexp.last_match
        return sentence[start...found.begin(0)] if position < found.begin(0)

        start = found.end(0)
      end
      sentence[start..].to_s
    end

    def self.paragraph_start(lines, index)
      first = index
      first -= 1 while first.positive? && lines[first - 1].strip.present?
      first
    end

    def self.paragraph_text(lines, index)
      first = paragraph_start(lines, index)
      last = index
      last += 1 while last < lines.length - 1 && lines[last + 1].strip.present?
      lines[first..last].join("\n")
    end

    # A table's rows, the header first
    def self.table_lines(lines, index)
      first = index
      first -= 1 while first.positive? && lines[first - 1].match?(TABLE_ROW)
      last = index
      last += 1 while last < lines.length - 1 && lines[last + 1].match?(TABLE_ROW)
      lines[first..last]
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
        parts << if reason == :unidentified
                   format(words[:unidentified], tables: see)
                 elsif reason == :stale && period == [context[:today], context[:today]]
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
    private_class_method :source_numac, :decree_retained?, :without_echoed_note, :without_dangling_quote_reference,
                         :rewrite_line, :rewrite_segment,
                         :scope_at, :benefit_claim?, :judge, :resolve, :candidates, :facts_for, :fact_values,
                         :qualifier_for, :phase_open?, :quoted_figures, :regime, :period_for, :day_span, :month_span, :year_span,
                         :sentence_span, :sentences, :clause_at, :paragraph_start, :paragraph_text, :table_lines,
                         :note_for, :quoted_sentence, :tables, :period_words
  end
end
