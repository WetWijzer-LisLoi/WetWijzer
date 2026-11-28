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
  #
  # Version 4 (#1944, Sol 2026-11-25 00:37:56Z): only the note claims a manual check, and only beside a figure it dates;
  # an item or table row left with withheld figures and a label only goes, so the reader gets one limitation instead of
  # a placeholder per figure.
  #
  # Version 5 (Sol 2026-11-27 14:58:54Z and 20:47:47Z, 1.1.117 and 1.1.118): every blockquote form is a quotation
  # (BLOCKQUOTE), an appositive claim of a check goes with its comma, and a list lead-in left without its subject keeps
  # a neutral heading (list_heading).
  class IndexedAmounts
    VERSION = 5
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
    # Sol 2026-11-25 09:55:53Z (#1944): a sentence that names the amounts right before it the article's own, literal ones
    # ("... €37,89 voor een werknemer met gezinslast, ... Dit zijn de bedragen die letterlijk in het artikel staan;"). A
    # base amount it frames stays as written; when the amounts before it were withheld, the sentence goes with them.
    LITERAL_FRAME = /letterlijk[[:space:]]+in[[:space:]]+het[[:space:]]+artikel|textuellement[[:space:]]+(?:dans|à)[[:space:]]+l.article|
                     tels?[[:space:]]+qu.(?:ils|elles)[[:space:]]+figurent[[:space:]]+dans[[:space:]]+l.article|
                     w[öo]rtlich[[:space:]]+im[[:space:]]+artikel|literally[[:space:]]+in[[:space:]]+the[[:space:]]+article/ix
    # Sol 11:19:37Z: only an affirmative sentence frames. A negation up to the end of the words' clause, a question, or
    # "whether" before the words (literal_frame?) leave the amounts to be judged and the sentence in place
    LITERAL_NEGATION = /(?<![[:alpha:]])(?:niet|geen|nooit|noch|nergens|pas|aucun\p{L}*|jamais|nullement|ni|nicht|kein\p{L}*|
                        nie|niemals|not|no|never|neither|nor|none)(?![[:alpha:]])|n['’]t(?![[:alpha:]])/ix
    LITERAL_WHETHER = /(?<![[:alpha:]])(?:(?:of|si|ob|whether|if)(?![[:alpha:]])|s['’](?=(?:ils?|elles?)(?![[:alpha:]])))/ix
    # Money in a sentence: a currency, or a daily rate
    MONEY = /€|(?<![[:alpha:]])(?:eur(?:os?)?(?![[:alpha:]])|per[[:space:]]+(?:uitkerings)?dag|dagbedrag|par[[:space:]]+jour|
             journalier|pro[[:space:]]+tag|tagesbetrag|per[[:space:]]+day|a[[:space:]]+day|daily)/ix
    # The daily rate right after a figure: a qualifier follows it
    DAILY_RATE = /\A[[:space:]]*(?:per[[:space:]]+(?:uitkerings)?dag|par[[:space:]]+jour|pro[[:space:]]+tag|per[[:space:]]+day|
                  a[[:space:]]+day)(?![[:alpha:]])/ix
    # Sol 2026-11-25 04:13:27Z (#115), 05:06:10Z: a sentence of its own that calls the answer's amounts monthly. It
    # points at the amounts (MONTHLY_POINTER: "Deze maandbedragen", "Deze bedragen", "Dit zijn") and calls them monthly
    # or computed over 26 days (MONTHLY_MARK), with no figure, no negation and no daily word in it. No such claim:
    # "Dit zijn dagbedragen, geen maandbedragen.", a general "De maandbedragen worden berekend op 26 dagen.", or "Deze
    # bedragen worden per maand betaald.". Art. 115's figures are daily, so unless the rows the claim describes hold a
    # real conversion (a monthly figure 26 times one of their daily figures: "€1.645,54", "€776,10") the claim is false
    # and goes, and a figure of those rows without a daily label takes its unit and is withheld (monthly_claims). Other
    # rows, and an unrelated four-digit amount, are left alone.
    MONTHLY_POINTER = /(?<![[:alpha:]])(?:(?:deze|die|bovenstaande|vermelde|genoemde|ces|diese|obigen|genannten|these|those|above)
                       [[:space:]]+(?:\p{L}+[[:space:]]+)?(?:maandbedrag\p{L}*|bedrag\p{L}*|montants?|monatsbetr[äa]g\p{L}*|
                       betr[äa]g\p{L}*|amounts?|figures?)|(?:dit|dat|het)[[:space:]]+zijn|ce[[:space:]]+sont|(?:das|dies|es)[[:space:]]+sind|
                       (?:these|they)[[:space:]]+are)(?![[:alpha:]])/ix
    MONTHLY_MARK = /(?<![[:alpha:]])(?:maandbedrag\p{L}*|maandelijkse[[:space:]]+bedragen|bedragen[[:space:]]+per[[:space:]]+maand|
                    montants?[[:space:]]+mensuels?|monatsbetr[äa]g\p{L}*|monthly[[:space:]]+amounts?|
                    (?:berekend|gebaseerd|calcul\p{L}*|berechnet|basier\p{L}*|calculated|based)(?:[[:space:]]+\p{L}+){0,4}[[:space:]]+
                    26[[:space:]]+(?:uitkerings)?(?:dagen|jours|tage\p{L}*|days)|
                    26[[:space:]]+(?:uitkerings)?(?:dagen|jours|tage\p{L}*|days)(?:[[:space:]]+\p{L}+){0,2}[[:space:]]+
                    (?:berekend|berechnet|calcul\p{L}*|calculated))(?![[:alpha:]])/ix
    NEGATION = /(?<![[:alpha:]])(?:geen|niet|nooit|ne|pas|jamais|aucun\p{L}*|kein\p{L}*|nicht|nie|not|no|never)(?![[:alpha:]])/i
    MONEY_VALUE = /(?<![\d.,])(\d{1,3}(?:[.,[:space:]]\d{3})+|\d{1,4})[.,](\d{2})(?!\d)/
    CONVERSION_DAYS = 26
    CONVERSION_TOLERANCE = BigDecimal('0.15')
    DAILY_WORDS = /(?<![[:alpha:]])(?:per[[:space:]]+(?:uitkerings)?dag|dagbedrag\p{L}*|par[[:space:]]+jour|journali\p{L}*|
                   pro[[:space:]]+tag|tagesbetr\p{L}*|t[äa]glich\p{L}*|per[[:space:]]+day|a[[:space:]]+day|daily)(?![[:alpha:]])/ix
    # Sol 2026-11-25 03:16:54Z (#115): art. 115's minima are daily amounts; one the answer labels as a monthly amount is
    # wrong in its unit whatever its number, and is withheld
    MONTHLY_RATE = /\A[[:space:]]*(?:euros?|eur|€)?[[:space:]]*(?:per[[:space:]]+maand|maandelijks\p{L}*|par[[:space:]]+mois|
                    mensuel\p{L}*|pro[[:space:]]+monat|monatlich\p{L}*|per[[:space:]]+month|a[[:space:]]+month|monthly)(?![[:alpha:]])/ix
    AMOUNT = /(?<pre>(?<![[:alpha:]])(?:€|EUR|euros?)[[:space:]]?)?(?<![\d.,])(?<int>\d{1,3})(?<sep>[.,])(?<dec>\d{2})(?!\d|[.,]\d)
              (?![[:space:]]?(?:%|procent|pour[-[:space:]]?cent|percent|prozent))(?<post>[[:space:]]?(?:€|EUR|euros?)(?![[:alpha:]]))?/ix
    # Sol 2026-11-27 14:58:54Z (review of e6da9432d): "- > " and "1. > " quotations of art. 115 were rewritten from 34,94
    # to 63,29 euro after the quote guard had verified them, because only a bare ">" counted here; the quote guard also
    # reads a blockquote in a list item. Every blockquote form, at any indentation and after list markers, is a
    # quotation: its figures go in the note only.
    BLOCKQUOTE = /\A[[:space:]]*(?:(?:[-*+]|\d{1,9}[.)])[[:space:]]+)*>/
    QUOTED = /„[^“”"\n]*[“”"]|“[^”\n]*”|«[^»\n]*»|‘[^’\n]*’|‹[^›\n]*›|"[^"\n]*"/
    # Never rewritten: Markdown links (label and target), URLs, inline code, article references
    PROTECTED = %r{\[[^\]\n]*\]\([^)\n]*\)|https?://[^\s)\]]+|`[^`\n]*`|
                   (?<![[:alpha:]])(?:art(?:ikel|icle|s)?\.?|§)[[:space:]]*\d+(?:[.,/]\d+)*}ix
    TABLE_ROW = /\A[[:space:]]*\|/
    # Abbreviations whose full stop ends no sentence
    ABBREVIATION = /(?<![[:alpha:]])(?:art|artt|nr|nrs|blz|bv|vb|p|pp|al|ca|resp|zgn|enz|etc|cf|vgl|o\.a|i\.e|e\.g|b\.v|n\.v\.t)\z/i
    # Where a clause ends inside a sentence: punctuation (not a decimal comma) or a conjunction
    # A clause that opens with "daarna" or its equals, right after the clause of a figure: that figure is the first period
    THEN_AFTER = /\A(?:[[:space:]]*(?:,|;|en|and|et|und))?[[:space:]]+(?:daarna|nadien|vervolgens|ensuite|puis|danach|anschlie(?:ß|ss)end|
                  then|thereafter|afterwards)(?![[:alpha:]])/ix
    # The "en" of "tot en met" (a band: "maanden één tot en met drie") joins its months and breaks no clause (#116)
    CLAUSE_BREAK = /,(?!\d)|[;:()]|(?<!tot)[[:space:]](?:en|maar|terwijl|and|but|while|et|mais|tandis|und|aber|während)(?=[[:space:]])/i
    # The facts that select a row, in the four languages. A more specific phase (months 1 to 3, ...) is read before the
    # general halves of the first period.
    # The word between the two months of a band: "1 tot 3", "een tot en met drie", "1 t/m 3", "1-3", "1 à 3", "1 bis 3"
    BAND_TO = %r{(?:-|–|tot[[:space:]]+en[[:space:]]+met|tot|t/m|à|au|jusqu.?(?:à|au)|bis|to|through|until)}i
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
      # Sol 2026-11-25 03:16:54Z (#116): a band also in spelled-out numbers and with "tot en met" ("in de maanden een tot
      # drie", "maanden zeven tot en met twaalf", "de eerste tot de derde maand")
      phase: {
        months_1_3: /eerste[[:space:]]+(?:drie|3)[[:space:]]+maanden|(?:trois|3)[[:space:]]+premiers[[:space:]]+mois|ersten[[:space:]]+(?:drei|3)[[:space:]]+monat\p{L}*|
                     first[[:space:]]+(?:three|3)[[:space:]]+months|
                     (?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:1|een|één|eén|un|eins|one)[[:space:]]*#{BAND_TO}[[:space:]]*(?:3|drie|trois|drei|three)(?![\d[:alpha:]])|
                     (?:eerste|1e|1ste)[[:space:]]+tot[[:space:]]+(?:en[[:space:]]+met[[:space:]]+)?(?:de[[:space:]]+)?(?:derde|3e|3de)[[:space:]]+maand/iux,
        months_4_6: /(?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:vier|quatre|four|4)[[:space:]]*#{BAND_TO}[[:space:]]*(?:zes|six|sechs|6)(?![\d[:alpha:]])|
                     (?:vierde|4e|4de)[[:space:]]+tot[[:space:]]+(?:en[[:space:]]+met[[:space:]]+)?(?:de[[:space:]]+)?(?:zesde|6e|6de)[[:space:]]+maand/iux,
        months_7_12: /(?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:zeven|sept|sieben|seven|7)[[:space:]]*#{BAND_TO}[[:space:]]*
                      (?:twaalf|douze|zwölf|zwoelf|twelve|12)(?![\d[:alpha:]])|
                      (?:zevende|7e|7de)[[:space:]]+tot[[:space:]]+(?:en[[:space:]]+met[[:space:]]+)?(?:de[[:space:]]+)?(?:twaalfde|12e|12de)[[:space:]]+maand/iux,
        second: /tweede[[:space:]]+vergoedingsperiode|seconde?[[:space:]]+p[ée]riode[[:space:]]+d.indemnisation|zweiten?[[:space:]]+entsch[äa]digungszeitraum\p{L}*|
                 second[[:space:]]+(?:compensation|benefit)[[:space:]]+period/iux,
        first6: /eerste[[:space:]]+(?:zes|6)[[:space:]]+maanden|(?:zes|6)[[:space:]]+eerste[[:space:]]+maanden|(?:six|6)[[:space:]]+premiers[[:space:]]+mois|
                 ersten[[:space:]]+(?:sechs|6)[[:space:]]+monat\p{L}*|first[[:space:]]+(?:six|6)[[:space:]]+months|
                 (?:maand(?:en)?|mois|monate?|months?)[[:space:]]+(?:1|een|één|eén|un|eins|one)[[:space:]]*#{BAND_TO}[[:space:]]*(?:6|zes|six|sechs)(?![\d[:alpha:]])/iux,
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
        unit: 'Een dagbedrag van art. 115 stond in het antwoord als maandbedrag; het is weggelaten. Zie %<tables>s.',
        unpublished: 'Het minimum bij werkloosheid met bedrijfstoeslag (art. 115, § 2) staat in geen officiële tabel ' \
                     'geïndexeerd en is weggelaten.',
        withheld: '[actueel bedrag: zie de tabel van de RVA]',
        unpublished_withheld: '[geen officieel geïndexeerd bedrag]',
        quoted: 'Het citaat geeft de basisbedragen van de wettekst; geïndexeerd: %<list>s.',
        quoted_base: 'Het citaat geeft de basisbedragen van de wettekst.',
        list_heading: 'Dagbedragen:',
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
        unit: "Un montant journalier de l'art. 115 figurait dans la réponse comme montant mensuel ; il est omis. Voir %<tables>s.",
        unpublished: "Le minimum en cas de chômage avec complément d'entreprise (art. 115, § 2) ne figure indexé dans " \
                     'aucun tableau officiel et est omis.',
        withheld: "[montant actuel : voir le tableau de l'ONEM]",
        unpublished_withheld: '[aucun montant indexé officiel]',
        quoted: 'La citation donne les montants de base du texte légal ; indexés : %<list>s.',
        quoted_base: 'La citation donne les montants de base du texte légal.',
        list_heading: 'Montants journaliers :',
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
        unit: 'Ein Tagesbetrag von Art. 115 stand in der Antwort als Monatsbetrag; er wurde weggelassen. Siehe %<tables>s.',
        unpublished: 'Das Minimum bei Arbeitslosigkeit mit Betriebszuschlag (Art. 115 § 2) steht in keiner amtlichen ' \
                     'Tabelle indexiert und wurde weggelassen.',
        withheld: '[aktueller Betrag: siehe die Tabelle des LfA]',
        unpublished_withheld: '[kein amtlich indexierter Betrag]',
        quoted: 'Das Zitat gibt die Basisbeträge des Gesetzestextes wieder; indexiert: %<list>s.',
        quoted_base: 'Das Zitat gibt die Basisbeträge des Gesetzestextes wieder.',
        list_heading: 'Tagesbeträge:',
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
        unit: 'A daily amount of art. 115 appeared in the answer as a monthly amount; it is left out. See %<tables>s.',
        unpublished: 'The minimum for unemployment with a company supplement (art. 115, § 2) is shown indexed in no ' \
                     'official table and is left out.',
        withheld: "[current amount: see ONEM's table]",
        unpublished_withheld: '[no officially indexed amount]',
        quoted: 'The quotation gives the statutory base amounts; indexed: %<list>s.',
        quoted_base: 'The quotation gives the statutory base amounts.',
        list_heading: 'Daily amounts:',
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
    # The note opens with the base sentence, or with the § 2 limitation when no figure is shown: a copy the model echoed
    # from the conversation is dropped before the new one
    NOTE_LEAD = /\A[[:space:]*_]*#{Regexp.union(TEXT.values.flat_map { |words| [words[:base][0, 40], words[:unpublished][0, 40]] })}/
    # Sol 2026-11-25 00:37:56Z (#1944): only the note says that amounts were checked by hand, and only for a figure it
    # dates. The model writes such a sentence from the context note's check date, also over figures this class then
    # withholds ("Deze bedragen zijn handmatig gecontroleerd op 22 november 2026" under nine placeholders): it goes, and
    # in brackets only the bracket goes.
    CHECK_CLAIM = /(?<![[:alpha:]])(?:handmatig|manueel|met[[:space:]]+de[[:space:]]+hand)(?:[[:space:]]+[^[:space:]]+){0,6}?[[:space:]]+
                   (?:gecontroleerd|nagekeken|gecheckt|geverifieerd|bevestigd)(?![[:alpha:]])|
                   (?<![[:alpha:]])(?:gecontroleerd|nagekeken|geverifieerd)[[:space:]]+(?:handmatig|manueel)(?![[:alpha:]])|
                   (?<![[:alpha:]])(?:v[ée]rifi[ée]e?s?|contr[ôo]l[ée]e?s?)[[:space:]]+(?:manuellement|[àa][[:space:]]+la[[:space:]]+main)|
                   (?<![[:alpha:]])manuellement[[:space:]]+(?:v[ée]rifi|contr[ôo]l)|
                   (?<![[:alpha:]])(?:manuell|h[äa]ndisch|von[[:space:]]+Hand)[[:space:]]+\p{L}*(?:prüft|pruft|kontrolliert)|
                   (?<![[:alpha:]])(?:manually|by[[:space:]]+hand)[[:space:]]+(?:checked|verified|reviewed)|
                   (?<![[:alpha:]])(?:checked|verified|reviewed)[[:space:]]+(?:manually|by[[:space:]]+hand)/ix
    # The words around a claim that go with it (Sol 2026-11-25 04:09:17Z): before it, an auxiliary verb, a date and a
    # conjunction ("... en werd op 1 januari 2026 handmatig nagekeken"); after it, a date ("nagekeken op 1 januari 2026")
    CLAIM_DATE = %r{(?:op|per|le|au|am|on)[[:space:]]+(?:\d{1,2}(?:er|e|\.)?[[:space:]]+\p{L}+[[:space:]]+\d{4}|\d{1,2}[./]\d{1,2}[./]\d{4}|\d{4}-\d{2}-\d{2})}i
    CLAIM_LEAD = /(?:[[:space:]]+(?:werd(?:en)?|wordt|worden|zijn|is|was|waren|a[[:space:]]+été|ont[[:space:]]+été|est|sont|été|wurden?|ist|
                    sind|has[[:space:]]+been|have[[:space:]]+been|been|were|are|en|and|et|und|#{CLAIM_DATE}))+[[:space:]]*\z/ix
    CLAIM_TAIL = /\A(?:[[:space:]]+#{CLAIM_DATE})?/i
    # A claim of a check is about the amounts when its sentence names them (or holds a figure or a placeholder); a
    # sentence about someone checking a dossier, an application or a form names none and stays (Sol 02:47:29Z)
    CHECK_CLAIM_SUBJECT = /(?<![[:alpha:]])(?:\p{L}*bedrag\p{L}*|cijfers?|minim(?:um|a)|montants?|chiffres?|\p{L}*betr[äa]g\p{L}*|
                           zahlen|amounts?|figures?|rates?)(?![[:alpha:]])/ix
    # Sol 00:37:56Z: an item or table row left with only withheld figures and its label tells the reader nothing; the
    # note's one limitation stands for all of them. A label holds nothing but the facts this class reads (FACTS), the
    # figure words and LABEL_FILLER: any other word makes the line a condition or an exception, legal content that stays
    # with its placeholder (Sol 02:47:29Z, 04:09:17Z: "alleen als u minstens ...", "bij deeltijdse arbeid").
    LABEL_FILLER = /(?<![[:alpha:]])(?:de|het|een|van|voor|met|in|op|en|of|tot|na|vanaf|eerste|tweede|werknemers?|werklozen?|
                    volledig\p{L}*|minimum|minima|bedrag\p{L}*|categorie\p{L}*|le|la|les|du|des|pour|avec|ou|et|à|
                    travailleurs?|chômeurs?|catégories?|der|die|das|den|dem|für|mit|und|oder|arbeitnehmer\p{L}*|
                    arbeitslose\p{L}*|kategorie\p{L}*|the|for|with|and|or|workers?|claimants?|unemployed|categor(?:y|ies))
                    (?![[:alpha:]])/ix
    LIST_ITEM = /\A[[:space:]]*(?:[-*•+]|\d{1,2}[.)])[[:space:]]/
    TABLE_SEPARATOR = /\A[[:space:]]*\|?[[:space:]]*:?-{2,}/
    FIGURE_WORDS = /(?<![[:alpha:]])(?:euros?|eur|per|par|pro|uitkeringsdag|dag|dagen|jour|jours|tag|tage|day|days|maand|maanden|
                    mois|monat|monate|month|months|bruto|netto|brut|net|brutto|minimum|minimaal|minimal)(?![[:alpha:]])/ix
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
      words = TEXT.fetch(language)
      body = without_dangling_quote_reference(without_echoed_note(text))
      context = { today: today, schedules: schedules, language: language, question: question.to_s,
                  question_period: period_in(question.to_s, today),
                  answer_cue: question.to_s.match?(UNEMPLOYMENT) || decree_retained?(sources) }
      events = []
      # Sol 02:47:29Z, 04:09:17Z: a claim of a manual check goes before the figures are judged, so its date never dates
      # them; beside a figure only its words of provenance go
      lines = without_check_claims(body.split("\n", -1), words)
      claims = monthly_claims(lines)
      context[:monthly_lines] = claims.values.flatten.to_set
      rewritten = lines.each_with_index.map { |line, index| rewrite_line(line, lines, index, context, events) }
      # a false monthly claim goes once the figures it describes are judged
      rewritten = without_monthly_claims(rewritten, claims.keys) if claims.any?
      rewritten = without_dangling_literal_reference(rewritten, words)
      cleaned = rewritten.join("\n")
      # Sol 14:53:13Z: a copied old note goes even when no figure is left to date; so does a claim with no figure judged
      return unchanged.with(text: cleaned.rstrip) if events.empty? && cleaned != text
      return unchanged if events.empty?

      counts = events.map { |event| event[:kind] }.tally
      # a first block that went leaves no blank line above the answer
      kept = without_withheld_only_lines(cleaned.split("\n", -1), words).join("\n").rstrip.sub(/\A(?:[[:blank:]]*\n)+/, '')
      note = note_for(events, context)
      Result.new(text: kept.empty? ? note : "#{kept}\n\n#{note}", replaced: counts.fetch(:replaced, 0),
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

    # The answer's false monthly claims (MONTHLY_POINTER), each line holding one to the indexes of the rows it describes:
    # rows that hold a figure of art. 115 and no real conversion of one
    def self.monthly_claims(lines)
      lines.each_index.with_object({}) do |index, claims|
        next if lines[index].match?(BLOCKQUOTE) || sentences(lines[index]).none? { |sentence| monthly_sentence?(sentence) }

        rows = described_rows(lines, index)
        described = rows.map { |row| lines[row] }.join("\n")
        claims[index] = rows if art115_values(described).any? && !real_conversion?(described)
      end
    end

    # The rows a claim describes: its own line and the lines right above it in its block, or, when those hold no amount
    # (the claim opens a paragraph of its own, after a list), also the block right before it
    def self.described_rows(lines, index)
      rows = block_up(lines, index)
      return rows if rows.any? { |row| lines[row].match?(MONEY_VALUE) }

      above = rows.last - 1
      above -= 1 while above >= 0 && lines[above].strip.empty?
      above.negative? ? rows : rows + block_up(lines, above)
    end

    # A line and the lines right above it up to a blank line, nearest first
    def self.block_up(lines, index)
      rows = [index]
      rows << (rows.last - 1) while rows.last.positive? && !lines[rows.last - 1].strip.empty?
      rows
    end

    def self.monthly_sentence?(sentence)
      sentence.match?(MONTHLY_POINTER) && sentence.match?(MONTHLY_MARK) && !sentence.match?(AMOUNT) &&
        !sentence.match?(NEGATION) && !sentence.match?(DAILY_WORDS)
    end

    # The figures of a text that read as a row of art. 115
    def self.art115_values(text)
      text.to_enum(:scan, AMOUNT).filter_map do
        value = BigDecimal("#{Regexp.last_match[:int]}.#{Regexp.last_match[:dec]}")
        value if READINGS.key?(value)
      end
    end

    # A monthly figure in the text that is CONVERSION_DAYS times one of its figures of art. 115
    def self.real_conversion?(text)
      daily = art115_values(text)
      text.scan(MONEY_VALUE).any? do |whole, cents|
        value = BigDecimal("#{whole.delete('^0-9')}.#{cents}")
        daily.any? { |day| (value - (day * CONVERSION_DAYS)).abs <= CONVERSION_TOLERANCE }
      end
    end

    # The lines without the monthly claims of the lines at the given indexes
    def self.without_monthly_claims(lines, indexes)
      lines.each_with_index.filter_map do |line, index|
        next line unless indexes.include?(index)

        kept = sentences(line).reject { |sentence| monthly_sentence?(sentence) }
        kept.empty? ? nil : "#{line[/\A[[:space:]]*/]}#{kept.join(' ')}"
      end
    end

    # The lines without the answer's claims of a manual check of the amounts (CHECK_CLAIM), each judged in its sentence
    # (without_claim); a quotation stays
    #
    # Sol 2026-11-27 20:47:47Z (live 1.1.117): "The displayed minima list starts "Zijn:" on its own." "Please preserve a
    # grammatical heading (e.g. "Minimale brutodagbedragen") and test the rendered output." Sol 22:15:28Z (review of the
    # draft): only the damaged final clause is repaired, "without consuming adjacent sentences or an intact one-word
    # heading". The last sentence of a line that introduces a list or a table (it ends with a colon) becomes the neutral
    # heading of the reader's language (list_heading) when its claim went with the whole sentence or with its opening
    # clause; the other sentences of the line, and a lead-in that held no claim, stay as they are.
    def self.without_check_claims(lines, words)
      placeholders = [words[:unpublished_withheld], words[:withheld]]
      lines.filter_map do |line|
        next line if line.match?(BLOCKQUOTE) || !line.match?(CHECK_CLAIM)

        parts = sentences(line)
        lead_in = line.rstrip.end_with?(':')
        mapped = parts.each_with_index.map do |sentence, index|
          next without_claim(sentence, placeholders) unless lead_in && index == parts.length - 1

          claimless_lead_in(sentence, placeholders, words[:list_heading])
        end
        kept = rejoined(mapped)
        kept.empty? ? nil : "#{line[/\A[[:space:]]*/]}#{kept.join(' ')}"
      end
    end

    # A lead-in without its claim; the heading when the claim took the whole sentence or its opening clause (its subject)
    def self.claimless_lead_in(sentence, placeholders, heading)
      result = without_claim(sentence, placeholders)
      return result if result == sentence
      return heading if result.nil?

      opening = sentence.split(/(?<=[,;])[[:space:]]+/).first
      opening.match?(CHECK_CLAIM) && !opening.match?(AMOUNT) ? heading : result
    end

    # The sentences of a line that stay (nil for each that went), the first after a dropped one capitalized: it may have
    # followed a semicolon (Sol 2026-11-25 09:55:53Z, #116: a paragraph opened with "latere indexering kan ze hebben
    # vervangen." after its claim of a check went)
    def self.rejoined(parts)
      parts.each_with_index.filter_map do |sentence, index|
        next unless sentence

        index.positive? && parts[index - 1].nil? ? sentence.sub(/\A\p{Ll}/, &:upcase) : sentence
      end
    end

    # The lines without a sentence that calls the amounts right before it the article's literal ones, where those were
    # withheld (LITERAL_FRAME)
    def self.without_dangling_literal_reference(lines, words)
      placeholders = [words[:unpublished_withheld], words[:withheld]]
      lines.filter_map do |line|
        next line if line.match?(BLOCKQUOTE) || !line.match?(LITERAL_FRAME)

        parts = sentences(line)
        dropped = parts.each_with_index.map do |sentence, index|
          dangling = index.positive? && placeholders.any? { |placeholder| parts[index - 1].include?(placeholder) } &&
                     literal_frame?(sentence) && !sentence.match?(AMOUNT)
          dangling ? nil : sentence
        end
        next line if dropped.all?

        kept = rejoined(dropped)
        kept.empty? ? nil : "#{line[/\A[[:space:]]*/]}#{kept.join(' ')}"
      end
    end

    # A sentence without its claim, or nil when only the claim was in it (Sol 00:37:56Z, 02:47:29Z, 04:09:17Z). The
    # claim is about the amounts only when its sentence holds a figure, a placeholder or an amount word: a person
    # checking a dossier stays. In brackets, the bracket goes; in a comma or semicolon clause without a figure, that
    # clause goes and the statement stays. A claim that shares its clause with a figure loses its words of provenance
    # (without_claim_words) and the statement with its figure stays: the note alone dates the figures it shows, so no
    # second date stands in the answer. A sentence left with neither a figure nor a placeholder goes.
    def self.without_claim(sentence, placeholders)
      return sentence unless sentence.match?(CHECK_CLAIM)

      shown = sentence.match?(AMOUNT)
      withheld = placeholders.any? { |placeholder| sentence.include?(placeholder) }
      return sentence unless shown || withheld || sentence.match?(CHECK_CLAIM_SUBJECT)

      unbracketed = sentence.gsub(/[[:space:]]*\([^()\n]*\)/) { |bracket| bracket.match?(CHECK_CLAIM) ? '' : bracket }
      return unbracketed unless unbracketed.match?(CHECK_CLAIM)

      clauses = unbracketed.split(/(?<=[,;])[[:space:]]+/)
      kept = []
      clauses.each do |clause|
        next kept << clause unless clause.match?(CHECK_CLAIM) && !clause.match?(AMOUNT)

        # Sol 2026-11-27 20:47:47Z (live 1.1.117): an appositive between commas goes with the comma before it ("De
        # bedragen, handmatig nagekeken op 22 november 2026, zijn:" reads "De bedragen zijn:", not "De bedragen, zijn:")
        kept[-1] = kept[-1].sub(/,\z/, '') if kept.any? && clause.end_with?(',')
      end
      return nil if kept.empty?

      joined = kept.join(' ').sub(/[,;]\z/, '')
      joined += unbracketed[/[.!?]\z/].to_s unless joined.match?(/[.!?]\z/)
      joined = without_claim_words(joined)
      return nil unless kept.length < clauses.length || joined.match?(AMOUNT) || placeholders.any? { |placeholder| joined.include?(placeholder) }

      joined.sub(/\A\p{Ll}/, &:upcase)
    end

    # The text without the words of each claim it holds: the check (CHECK_CLAIM), with the auxiliary verb, a date and a
    # conjunction right before it (CLAIM_LEAD) and a date right after it (CLAIM_TAIL)
    def self.without_claim_words(text)
      while (match = text.match(CHECK_CLAIM))
        text = "#{text[0...match.begin(0)].sub(CLAIM_LEAD, '')}#{text[match.end(0)..].sub(CLAIM_TAIL, '')}"
      end
      text.gsub(/[[:space:]]+([.,;:!?])/, '\1').gsub(/[[:space:]]{2,}/, ' ')
    end

    # The rewritten lines without an item or table row that is left with withheld figures and a label only; a list or a
    # table that loses every such line loses its lead-in (the line before it that ends in a colon) as well
    def self.without_withheld_only_lines(lines, words)
      placeholders = [words[:unpublished_withheld], words[:withheld]]
      drop = lines.each_index.select { |index| withheld_only?(lines[index], placeholders) }
      return lines if drop.empty?

      blocks(lines).each do |block|
        items = block.reject { |index| (index == block.first && lines[index].match?(TABLE_ROW)) || lines[index].match?(TABLE_SEPARATOR) }
        next unless items.any? && items.all? { |index| drop.include?(index) }

        drop.concat(block)
        lead = lines[0...block.first].rindex { |line| !line.strip.empty? }
        drop << lead if lead && lines[lead].rstrip.end_with?(':') && !lines[lead].match?(LIST_ITEM) && !lines[lead].match?(TABLE_ROW)
      end
      lines.reject.with_index { |_line, index| drop.include?(index) }
    end

    def self.withheld_only?(line, placeholders)
      return false unless line.match?(LIST_ITEM) || (line.match?(TABLE_ROW) && !line.match?(TABLE_SEPARATOR))
      return false unless placeholders.any? { |placeholder| line.include?(placeholder) }

      rest = placeholders.reduce(line) { |text, placeholder| text.gsub(placeholder, ' ') }
      return false if rest.match?(AMOUNT)

      label = FACTS.values.flat_map(&:values).reduce(rest.sub(LIST_ITEM, ' ').gsub(NEGATED_FAMILY, ' ')) do |text, pattern|
        text.gsub(pattern, ' ')
      end
      label.gsub(FIGURE_WORDS, ' ').gsub(LABEL_FILLER, ' ').scan(/[[:alpha:]]+/).empty?
    end

    # Runs of consecutive list items, and of consecutive table lines, as arrays of line indexes
    def self.blocks(lines)
      lines.each_index.slice_when { |before, after| line_kind(lines[before]) != line_kind(lines[after]) }
           .select { |run| line_kind(lines[run.first]) }
    end

    def self.line_kind(line)
      return :table if line.match?(TABLE_ROW)

      :list if line.match?(LIST_ITEM)
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
        # Sol 2026-11-25 09:55:53Z (#1944): a base amount that the next sentence names as the article's literal one
        literal = scope[:framed_as_literal] && literal_base?(readings, scope, context)
        if literal || readings.empty? || !benefit_claim?(scope, cue, match)
          out << match[0]
          next
        end

        monthly = segment[cursor..].to_s.match?(MONTHLY_RATE) ||
                  (context[:monthly_lines]&.include?(place[:index]) && !scope[:clause].to_s.match?(DAILY_WORDS) &&
                   !scope[:frame].to_s.match?(DAILY_WORDS))
        replacement, qualifier = judge(match, readings, scope, context, events, monthly: monthly)
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
      following = sentences(line[last..].to_s).first.to_s
      { clause: clause, sentence: sentence, before: before_all.grep_v(AMOUNT), before_all: before_all, dated: sentence,
        frame: sentence, local_phase: local_phase(sentence, position - first),
        framed_as_literal: literal_frame?(following) && !following.match?(AMOUNT) }
    end

    # An affirmative sentence that names the amounts before it the article's literal ones: no question, no negation up
    # to the end of the clause with the words, no "whether" before them ("Dit zijn niet de bedragen die letterlijk in
    # het artikel staan", "Letterlijk in het artikel staan ze niet", "Staan ze letterlijk in het artikel?", "Controleer of
    # ze letterlijk in het artikel staan" say nothing of the kind). A negation in a later clause qualifies something
    # else: "Dit zijn de bedragen die letterlijk in het artikel staan, geen geïndexeerde bedragen" affirms.
    def self.literal_frame?(sentence)
      frame = sentence.match(LITERAL_FRAME)
      return false unless frame

      through_clause = sentence[0...(sentence.index(CLAUSE_BREAK, frame.end(0)) || sentence.length)]
      return false if sentence.rstrip.end_with?('?') || through_clause.match?(LITERAL_NEGATION)

      !sentence[0...frame.begin(0)].match?(LITERAL_WHETHER)
    end

    # Sol 2026-11-25 11:19:37Z: a base amount stays as the article's literal one only under the facts its own words give:
    # "€37,89 voor een samenwonende" gives the family's base amount to another household, and is judged
    def self.literal_base?(readings, scope, context)
      pool = candidates(facts_at(scope, context))
      readings.any? { |row, rank| rank.nil? && pool.include?(row) }
    end

    # Sol 2026-11-25 04:13:27Z (#116, #304): the band of a figure from the words around it, when its clause alone cannot
    # say. Among several figures in one clause ("van €51,12 per dag in maanden één tot drie tot €51,12 in maanden zeven
    # tot twaalf"), the one band named between the figure and its neighbour: after it, unless the clause names a band
    # before its first figure. A figure whose clause names no band and that is followed by "en daarna ..." is the first
    # period ("alleenwonend €57,53 en daarna €57,53").
    def self.local_phase(sentence, offset)
      start, stop = clause_bounds(sentence, offset)
      clause = sentence[start...stop]
      figures = clause.to_enum(:scan, AMOUNT).map { Regexp.last_match }
      index = figures.index { |figure| figure.begin(0) <= offset - start && offset - start < figure.end(0) }
      return nil unless index

      if figures.length > 1
        span = if fact_values(clause[0...figures.first.begin(0)], :phase).any?
                 clause[(index.zero? ? 0 : figures[index - 1].end(0))...figures[index].begin(0)]
               else
                 clause[figures[index].end(0)...(figures[index + 1]&.begin(0) || clause.length)]
               end
        bands = fact_values(span.to_s, :phase)
        return bands.first if bands.one?
      end
      return nil unless fact_values(clause, :phase).empty?

      # Sol 2026-11-25 05:06:10Z, 06:53:11Z: only a real pair, a figure in the clause that "daarna" opens, up to its
      # clause break ("... en vervolgens stopt de uitkering terwijl een samenwonende €60,92 krijgt" is no pair), and
      # never against the band a clause without a figure states ("Na de eerste zes maanden: alleenwonend €57,53 en
      # daarna stopt de uitkering.")
      following = sentence[stop..].to_s
      after = following.match(THEN_AFTER)
      return nil unless after && lead_phase(sentence).nil?

      then_clause = following[after.end(0)..].to_s.split(CLAUSE_BREAK, 2).first.to_s
      return nil unless then_clause.match?(AMOUNT)

      # Sol 2026-11-25 09:22:37Z: a clause that names another household than the figure's ("Alleenwonend €57,53 en
      # vervolgens samenwonend €60,92") lists households, not periods
      named = fact_values(then_clause, :household)
      :first6 if named.empty? || named == fact_values(clause, :household)
    end

    def self.clause_bounds(sentence, position)
      start = 0
      sentence.to_enum(:scan, CLAUSE_BREAK).each do
        found = Regexp.last_match
        return [start, found.begin(0)] if position < found.begin(0)

        start = found.end(0)
      end
      [start, sentence.length]
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
    def self.judge(match, readings, scope, context, events, monthly: false)
      words = TEXT[context[:language]]
      facts = facts_at(scope, context)
      period = period_for(scope, context)
      schedule, reason = schedule_for(period, schedules: context[:schedules])
      latest = context[:schedules].sort_by { |candidate| candidate[:from] }.rfind { |candidate| candidate[:from] <= period.first }
      row, rank, by = resolve(readings, facts, (schedule || latest)&.fetch(:rank))
      regime = row ? row[:regime] : facts[:regime]
      if regime == :company
        events << { kind: :unpublished }
        return [words[:unpublished_withheld], nil]
      end
      if monthly
        events << { kind: :withheld, regime: regime || :full, reason: :unit, period: period }
        return [words[:withheld], nil]
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

    # The facts of a figure from its own words outward: its clause, its sentence, the sentences before it, the question.
    # Sol 2026-11-25 03:16:54Z (#116), 03:33:05Z (#304): in a sentence with several figures, a band named only in a
    # clause with another figure is not this figure's. It takes the one band the sentence's clauses without a figure
    # name ("In de eerste zes maanden: alleenwonend ... en daarna ..."), or a band an earlier sentence gives, or none.
    def self.facts_at(scope, context)
      facts = facts_for([scope[:clause], scope[:sentence], *scope[:before], context[:question]])
      if scope[:local_phase]
        facts[:phase] = scope[:local_phase]
      elsif borrowed_phase?(scope)
        facts[:phase] = lead_phase(scope[:sentence].to_s) || facts_for([*scope[:before], context[:question]])[:phase]
      end
      facts
    end

    # A prose sentence with more than one figure whose band is named in another clause than this figure's (a table row's
    # label stands for all its cells)
    def self.borrowed_phase?(scope)
      sentence = scope[:sentence].to_s
      return false if sentence.match?(TABLE_ROW) || sentence.scan(AMOUNT).length < 2

      fact_values(scope[:clause].to_s, :phase).empty? && fact_values(sentence, :phase).any?
    end

    # The one band the clauses of a sentence that hold no figure name, or nil
    def self.lead_phase(sentence)
      bands = sentence.split(CLAUSE_BREAK).grep_v(AMOUNT).flat_map { |clause| fact_values(clause, :phase) }
      bands.uniq.one? ? bands.first : nil
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
      # What the base amounts are matters only beside a figure; without one, the limitation stands alone (Sol 00:37:56Z)
      shown = events.any? { |event| %i[replaced confirmed quoted].include?(event[:kind]) }
      parts = shown ? [words[:base]] : []
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
                 elsif reason == :unit
                   format(words[:unit], tables: see)
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
