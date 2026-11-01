# frozen_string_literal: true

module LegalChatbot
  # General and neighbour-noise questions ("Wat zijn de regels voor
  # geluidsoverlast?"): whether a question is one, the governing group of
  # current provisions it gets, and which other sources may join them.
  #
  # The claim is read per clause. A noise subject counts only when the
  # question ASKS about it and does not negate it ("Geen lawaai van mijn buur,
  # wel van treinverkeer" is not one). Specialist subjects are legal PURPOSES
  # the question asks about: workers' protection, a subsidy, a permit or
  # planning procedure, inspection powers, and the noise regimes of rail,
  # aviation and road traffic. A noise's source is not such a purpose: "het
  # lawaai van de werkplaats van mijn buur" asks about the neighbour's noise,
  # not about workers' protection. A specialist source joins the group only
  # when every purpose it serves is asked; a factual or negated subject does
  # not count, and a noise question about a specialist subject only (workers'
  # noise in a quarry, aircraft noise) is not a general-noise question.
  #
  # An explicitly selected law (the law page the question is asked from) or a
  # NUMAC or article named in the question keeps today's path: no group, no
  # scoping. Ordinary conversation context does not count as selected.
  #
  # The group holds the units verified in the corpus on 2026-10-20 (design
  # v2, A3): Book 3 Art. 3.101/3.102, the GAS Act Art. 2, the competence
  # clause of Judicial Code Art. 591 (2° ter), and per region the operative
  # body: Flanders the 1973 Act Art. 1 in its Flemish version, Wallonia its
  # general Art. 1, Brussels the 1997 ordinance Art. 14/13 and the Brussels
  # Nieuwe Gemeentewet Art. 135. A named region gets only its own rows. The
  # transition articles of the inserting act join only for facts that may
  # predate 1 September 2021. Nothing here is a legal answer: missing
  # coverage stays missing and the synthesis task says so.
  module GeneralNoiseScope
    WORD_START = '(?<![\p{L}\p{N}])'
    WORD_END = '(?![\p{L}\p{N}])'

    NOISE_PATTERN = /#{WORD_START}(?:\p{L}*lawaai\p{L}*|geluidsoverlast\p{L}*|geluidshinder\p{L}*|bruits?|bruyant\p{L}*|tapages?|nuisances?\s+sonores?|noise|noises|noisy|l[äa]rm\p{L}*|ruhest[öo]rung\p{L}*)#{WORD_END}/iu
    # "Geluid" alone is a sound, not a complaint; with a neighbour it is one.
    SOUND_PATTERN = /#{WORD_START}(?:geluid(?:en)?|sound|sounds|son|sons|geräusch\p{L}*)#{WORD_END}/iu
    NEIGHBOUR_PATTERN = /#{WORD_START}(?:buur\p{L}*|buren\p{L}*|bovenbu\p{L}*|onderbu\p{L}*|voisin\p{L}*|neighbo\p{L}*|nachbar\p{L}*)#{WORD_END}/iu

    # The purposes. Workers' protection is named by the worker or the work
    # relation, never by a workshop, factory, quarry or office that makes the
    # noise; such a source of noise is a fact of a neighbour question.
    SPECIALIST_PATTERNS = {
      workplace: /#{WORD_START}(?:werknemer\p{L}*|arbeider\p{L}*|personeelsle\p{L}*|arbeidsbescherming\p{L}*|werkgever\p{L}*|welzijn\s+op\s+het\s+werk|op\s+(?:het|mijn|ons)\s+werk|op\s+(?:de|mijn|onze)\s+werkplek|ik\s+werk|wij\s+werken|travailleu\p{L}*|employ[ée]s?|employeur\p{L}*|au\s+travail|(?:sur\s+)?(?:le|mon)\s+lieu\s+de\s+travail|je\s+travaille|workers?|employees?|employers?|at\s+work|my\s+(?:workplace|job)|i\s+work|arbeitnehmer\p{L}*|arbeitgeber\p{L}*|am\s+arbeitsplatz|bei\s+der\s+arbeit|ich\s+arbeite)#{WORD_END}/iu,
      rail: /#{WORD_START}(?:\p{L}*trein\p{L}*|\p{L}*spoor\p{L}*|\p{L}*wagon\p{L}*|trains?|ferroviaire\p{L}*|railway\p{L}*|rail|z[üu]ge?|\p{L}*eisenbahn\p{L}*|g[üu]terwagen\p{L}*)#{WORD_END}/iu,
      air: /#{WORD_START}(?:\p{L}*luchthaven\p{L}*|vliegtuig\p{L}*|vliegveld\p{L}*|vlucht\p{L}*|a[ée]roport\p{L}*|avions?|airport\p{L}*|aircraft|airplane\p{L}*|flights?|flughafen\p{L}*|flugzeug\p{L}*|flugl[äa]rm\p{L}*)#{WORD_END}/iu,
      traffic: /#{WORD_START}(?:verkeer\p{L}*|\p{L}*snelweg\p{L}*|trafic\p{L}*|autoroute\p{L}*|traffic|motorway|highway|verkehr\p{L}*|autobahn\p{L}*)#{WORD_END}/iu,
      planning: /#{WORD_START}(?:\p{L}*vergunning\p{L}*|stedenbouw\p{L}*|bouwaanvraag\p{L}*|agent\s+of\s+change|agent\s+du\s+changement|permis|urbanisme|permits?|\p{L}*genehmigung\p{L}*|geluidsplan\p{L}*|plan\s+bruit)#{WORD_END}/iu,
      subsidy: /#{WORD_START}(?:subsidie\p{L}*|premie\p{L}*|toelage\p{L}*|subvention\p{L}*|subsid\p{L}*|grants?|zuschuss\p{L}*|förder\p{L}*)#{WORD_END}/iu,
      inspection: /#{WORD_START}(?:inspect\p{L}*|toezicht\p{L}*|verzegel\p{L}*|controleur\p{L}*|scell[ée]\p{L}*|inspektion\p{L}*|versiegel\p{L}*|sealing)#{WORD_END}/iu
    }.freeze

    # A noise claim is negated by a determiner ("geen lawaai", "pas de bruit",
    # "no noise", "kein Lärm") right before it; "niet" mostly negates the verb
    # ("ze stoppen niet met lawaai maken") and does not count there. A
    # specialist subject is negated by any negation within four words
    # ("geen lawaai op het werk", "niet op het werk", "pas au travail").
    NOISE_NEGATORS = /\A(?:geen|zonder|pas|sans|no|without|kein\p{L}*|ohne)\z/iu
    SPECIALIST_NEGATORS = /\A(?:niet|geen|zonder|pas|sans|not|no|without|nicht|kein\p{L}*|ohne)\z/iu
    ASK_PATTERN = /\?|#{WORD_START}(?:welke?|wat|hoe|wanneer|waar|wie|waarom|mag|mogen|kan|kunnen|moet|moeten|geldt|gelden|regels?|quel(?:le)?s?|quoi|comment|quand|qui|pourquoi|puis|peut|peuvent|dois|doit|r[èe]gles?|what|which|how|when|where|who|why|can|may|must|should|rules?|welche\p{L}*|wie|wann|wer|warum|darf|d[üu]rfen|kann|k[öo]nnen|muss|m[üu]ssen|regeln?)#{WORD_END}/iu
    BOTH_PATTERN = /#{WORD_START}(?:beide|allebei|les\s+deux|tous\s+les\s+deux|both|beides)#{WORD_END}/iu
    CLAUSE_BOUNDARY = /[;.!?:\n,]+/
    # French "en train de" is a tense, not a train.
    FRENCH_PROGRESSIVE = /#{WORD_START}en\s+train\s+de#{WORD_END}/iu
    # A NUMAC or an article the question names: an explicit selection.
    EXPLICIT_REFERENCE_PATTERN = %r{#{WORD_START}(?:\d{10}|\d{4}[A-Z]\d{5}|art(?:ikel(?:en)?|icles?|s)?\.?\s*\d[\w./]*)#{WORD_END}}iu

    MONTHS = {
      1 => %w[januari janvier january januar], 2 => %w[februari février fevrier february februar],
      3 => %w[maart mars march märz marz], 4 => %w[april avril], 5 => %w[mei mai may],
      6 => %w[juni juin june], 7 => %w[juli juillet july], 8 => %w[augustus août aout august],
      9 => %w[september septembre], 10 => %w[oktober octobre october], 11 => %w[november novembre],
      12 => %w[december décembre decembre dezember]
    }.freeze
    MONTH_NUMBERS = MONTHS.flat_map { |number, names| names.map { |name| [name, number] } }.to_h.freeze
    # A date of the facts: a preposition, an optional day and month, a year.
    # A law's own date ("de wet van 1973", "loi du 18 juillet 1973") has no
    # such preposition and is not a date of the facts.
    FACT_DATE_PATTERN = /#{WORD_START}(?<preposition>in|sinds|sedert|vanaf|tot|en|op|vóór|voor|voordien|depuis|avant|jusqu['’]?(?:en|au)|le|since|until|during|before|on|im|seit|bis|vor|am)\s+(?:(?<day>\d{1,2})(?:e|er|ste|de|st|nd|rd|th|\.)?\s+)?(?:(?<month>#{MONTH_NUMBERS.keys.map { |name| Regexp.escape(name) }.join('|')})\s+)?(?<year>(?:19|20)\d{2})(?!\d)/iu
    BEFORE_PREPOSITIONS = %w[voor vóór voordien avant before vor].freeze
    # Book 3 took effect on 1 September 2021.
    BOOK3_COMMENCEMENT = Date.new(2021, 9, 1)

    BOOK3 = '2020A20347'
    INSERTING_ACT = '2020020347'
    GAS_ACT = '2013000441'
    JUDICIAL_CODE = '1967101054'
    NOISE_ACT_1973 = '1973071810'
    BRUSSELS_NOISE_ORDINANCE = '1997031360'
    BRUSSELS_MUNICIPAL_LAW = '1988062452'

    # [numac, article number per language_id (1 NL, 2 FR), label key]
    FEDERAL_TARGETS = [
      [BOOK3, { 1 => '3.101', 2 => '3.101' }, :federal_civil],
      [BOOK3, { 1 => '3.102', 2 => '3.102' }, :federal_civil]
    ].freeze
    MUNICIPAL_SANCTION_TARGETS = [[GAS_ACT, { 1 => '2', 2 => '2' }, :federal_gas]].freeze
    REGION_TARGETS = {
      'vlaamse_codex' => [[NOISE_ACT_1973, { 1 => '1_VLAAMS_GEWEST', 2 => '1_REGION_FLAMANDE' }, :flanders]],
      'wallex' => [[NOISE_ACT_1973, { 1 => '1', 2 => '1' }, :wallonia]],
      'brussels' => [
        [BRUSSELS_NOISE_ORDINANCE, { 1 => '14', 2 => '14' }, :brussels],
        [BRUSSELS_NOISE_ORDINANCE, { 1 => '13', 2 => '13' }, :brussels],
        [BRUSSELS_MUNICIPAL_LAW, { 1 => '135', 2 => '135' }, :brussels_police]
      ]
    }.freeze
    # Art. 591 2° ter reads the same in the general text and in each regional
    # version (both languages, checked 2026-10-20); that proves the clause,
    # not the identity of the whole regional articles. A named region gets
    # its own version.
    COURT_TARGETS = {
      nil => [JUDICIAL_CODE, { 1 => '591', 2 => '591' }, :court_general],
      'vlaamse_codex' => [JUDICIAL_CODE, { 1 => '591_VLAAMS_GEWEST', 2 => '591_REGION_FLAMANDE' }, :court_region],
      'wallex' => [JUDICIAL_CODE, { 1 => '591_WAALS_GEWEST', 2 => '591_REGION_WALLONNE' }, :court_region],
      'brussels' => [JUDICIAL_CODE, { 1 => '591_BRUSSELS_HOOFDSTEDELIJK_GEWEST', 2 => '591_REGION_DE_BRUXELLES-CAPITALE' },
                     :court_region]
    }.freeze
    HISTORICAL_TARGETS = [
      [INSERTING_ACT, { 1 => '37', 2 => '37' }, :historical],
      [INSERTING_ACT, { 1 => '39', 2 => '39' }, :historical]
    ].freeze

    ALL_TARGETS = (FEDERAL_TARGETS + MUNICIPAL_SANCTION_TARGETS + REGION_TARGETS.values.flatten(1) +
                   COURT_TARGETS.values + HISTORICAL_TARGETS).freeze

    # The deployment readiness contract of the group (Sol 18:15:12): every row
    # it can fetch, in ITS language with ITS title (NL 1_VLAAMS_GEWEST, FR
    # 1_REGION_FLAMANDE; never both titles checked in both languages), and a
    # phrase its text must still hold, so a cut, replaced or stale body fails.
    # lib/wetwijzer_updater/import_missing_popular_laws.py
    # (load_language_article_targets) reads this block literally for
    # --verify-pin-readiness; a test keeps it equal to ALL_TARGETS and checks
    # every phrase against the corpus rows.
    READINESS_TARGETS = [
      ['2020A20347', 1, '3.101', 'Bovenmatige burenhinder'],
      ['2020A20347', 2, '3.101', 'Troubles anormaux de voisinage'],
      ['2020A20347', 1, '3.102', 'Voorkomen van bovenmatige burenhinder'],
      ['2020A20347', 2, '3.102', 'Prévention des troubles anormaux de voisinage'],
      ['2013000441', 1, '2', 'De gemeenteraad kan straffen of administratieve sancties bepalen'],
      ['2013000441', 2, '2', 'Le conseil communal peut établir des peines ou des sanctions administratives'],
      ['1973071810', 1, '1_VLAAMS_GEWEST', 'de nodige maatregelen treffen om de geluidshinder'],
      ['1973071810', 2, '1_REGION_FLAMANDE', 'prévenir ou combattre le bruit'],
      ['1973071810', 1, '1', 'de nodige maatregelen treffen om de geluidshinder'],
      ['1973071810', 2, '1', 'prévenir ou combattre le bruit'],
      ['1997031360', 1, '14', 'het lawaai en de trillingen'],
      ['1997031360', 2, '14', 'le bruit et les vibrations'],
      ['1997031360', 1, '13', 'geluidshinder en trillingen'],
      ['1997031360', 2, '13', 'le bruit et les vibrations'],
      ['1988062452', 1, '135', 'openbare rust'],
      ['1988062452', 2, '135', 'tranquillité'],
      ['1967101054', 1, '591', '2° ter van geschillen inzake bovenmatige burenhinder'],
      ['1967101054', 2, '591', '2° ter des contestations ayant pour objet les troubles anormaux de voisinage'],
      ['1967101054', 1, '591_VLAAMS_GEWEST', '2° ter van geschillen inzake bovenmatige burenhinder'],
      ['1967101054', 2, '591_REGION_FLAMANDE', '2° ter des contestations ayant pour objet les troubles anormaux de voisinage'],
      ['1967101054', 1, '591_WAALS_GEWEST', '2° ter van geschillen inzake bovenmatige burenhinder'],
      ['1967101054', 2, '591_REGION_WALLONNE', '2° ter des contestations ayant pour objet les troubles anormaux de voisinage'],
      ['1967101054', 1, '591_BRUSSELS_HOOFDSTEDELIJK_GEWEST', '2° ter van geschillen inzake bovenmatige burenhinder'],
      ['1967101054', 2, '591_REGION_DE_BRUXELLES-CAPITALE', '2° ter des contestations ayant pour objet les troubles anormaux de voisinage'],
      ['2020020347', 1, '37', 'na haar inwerkingtreding'],
      ['2020020347', 2, '37', 'après son entrée en vigueur'],
      ['2020020347', 1, '39', 'achttiende maand'],
      ['2020020347', 2, '39', 'dix-huitième mois']
    ].freeze

    # Every [numac, number] pair of the group, both languages, for
    # LegislationSearch::GOVERNING_GROUP_TARGETS.
    GOVERNING_PAIRS = ALL_TARGETS.flat_map { |numac, numbers, _label| numbers.values.map { |number| [numac, number] } }
                                 .uniq.freeze

    REGION_NAMES = {
      'nl' => { 'vlaamse_codex' => 'Vlaams Gewest', 'wallex' => 'Waals Gewest', 'brussels' => 'Brussels Hoofdstedelijk Gewest' },
      'fr' => { 'vlaamse_codex' => 'Région flamande', 'wallex' => 'Région wallonne', 'brussels' => 'Région de Bruxelles-Capitale' }
    }.freeze
    LABELS = {
      'nl' => {
        federal_civil: 'Federaal, in de drie gewesten (Burgerlijk Wetboek, Boek 3: burenhinder)',
        federal_gas: 'Federaal, in de drie gewesten (GAS-wet: sancties op inbreuken op gemeentelijke reglementen; ' \
                     'niet de geluidsregel zelf)',
        court_general: 'Bevoegde rechter in de drie gewesten: vrederechter, ongeacht het bedrag, alleen voor geschillen ' \
                       'over art. 3.101 en 3.102 (2° ter; die bepaling luidt gelijk in de drie gewestelijke versies)',
        court_region: 'Bevoegde rechter (%<region>s): vrederechter, ongeacht het bedrag, alleen voor geschillen over ' \
                      'art. 3.101 en 3.102 (2° ter)',
        flanders: 'Vlaams Gewest (geluidshinderwet 1973, Vlaamse versie)',
        wallonia: 'Waals Gewest (geluidshinderwet 1973, versie die in het Waals Gewest geldt)',
        brussels: 'Brussels Hoofdstedelijk Gewest (ordonnantie geluidshinder 1997)',
        brussels_police: 'Brussels Hoofdstedelijk Gewest (Nieuwe Gemeentewet, Brusselse versie: gemeentelijke politie)',
        historical: 'Overgangsrecht van Boek 3 (alleen voor feiten van vóór 1 september 2021)'
      },
      'fr' => {
        federal_civil: 'Fédéral, dans les trois Régions (Code civil, livre 3 : troubles de voisinage)',
        federal_gas: 'Fédéral, dans les trois Régions (loi SAC : sanctions des infractions aux règlements communaux ; ' \
                     'pas la règle sur le bruit elle-même)',
        court_general: 'Juge compétent dans les trois Régions : juge de paix, quel que soit le montant, uniquement pour ' \
                       'les contestations visées aux articles 3.101 et 3.102 (2° ter ; cette disposition est identique ' \
                       'dans les trois versions régionales)',
        court_region: 'Juge compétent (%<region>s) : juge de paix, quel que soit le montant, uniquement pour les ' \
                      'contestations visées aux articles 3.101 et 3.102 (2° ter)',
        flanders: 'Région flamande (loi de 1973 sur le bruit, version flamande)',
        wallonia: 'Région wallonne (loi de 1973 sur le bruit, version applicable en Région wallonne)',
        brussels: 'Région de Bruxelles-Capitale (ordonnance bruit de 1997)',
        brussels_police: 'Région de Bruxelles-Capitale (Nouvelle loi communale, version bruxelloise : police communale)',
        historical: 'Droit transitoire du livre 3 (uniquement pour des faits antérieurs au 1er septembre 2021)'
      }
    }.freeze

    # The purposes of sources that serve a specialist purpose only, by law;
    # the rest is read from their text. The quarry-workers decree protects
    # workers (in a sector); the 2022 decree is an aid for quieter rail
    # wagons; the 2026 Brussels ordinance amends planning law ("agent of
    # change"). These, the 1973 Act's inspection and meter-subsidy articles
    # and the Brussels noise-plan procedure took a general question's answer
    # on 2026-10-20 (design v2, A1).
    SPECIALIST_SOURCE_NUMACS = {
      '1989011096' => %i[workplace],
      '2022015059' => %i[rail subsidy],
      '2026004582' => %i[planning]
    }.freeze
    PROCEDURE_SOURCE_PATTERN = /#{WORD_START}(?:\p{L}*plan|plannen|programma\p{L}*|procedure\p{L}*|openbaar\s+onderzoek|enquête\s+publique|programme\p{L}*|proc[ée]dure\p{L}*)#{WORD_END}/iu
    NOISE_SOURCE_PATTERN = /(?:lawaai|geluid|hinder|overlast|rust|bruit|sonore|tapage|nuisance|voisinage|tranquillit|buren|buur|noise|l[äa]rm|nachbar|ruhe)/iu
    # Laws of one region, by NUMAC; variant rows carry their region in
    # article_variant.
    BRUSSELS_ONLY_NUMACS = %w[1997031360 1988062452 2026004582 2004031165].freeze
    VARIANT_REGIONS = {
      'vlaamse_codex' => /VLAAMS_GEWEST|REGION_FLAMANDE/i,
      'wallex' => /WAALS_GEWEST|REGION_WALLONNE/i,
      'brussels' => /BRUSSELS_HOOFDSTEDELIJK_GEWEST|REGION_(?:DE_)?BRUXELLES/i
    }.freeze

    # 1973 Act Art. 10 is current nowhere. Justel: Brussels repealed the whole
    # Act from 21 July 1998 (ORD 1997-07-17/64 art. 21, 2°), Wallonia Art. 10
    # from 6 February 2009 (DRW 2008-06-05/36 art. 16), Flanders from 1 May
    # 2009 (DCFL 2007-12-21/82 art. 16). Only its stale general row is left.
    # It is evidence only for facts dated before the repeal in the region
    # asked about, or before the earliest repeal when no region is named;
    # a Book 3 transition cue (any date before September 2021) is not enough.
    STALE_GENERAL_ROWS = {
      [NOISE_ACT_1973, 'art10'] => {
        'brussels' => Date.new(1998, 7, 21), 'wallex' => Date.new(2009, 2, 6), 'vlaamse_codex' => Date.new(2009, 5, 1)
      }.freeze
    }.freeze

    module_function

    # selected_law: the NUMAC of the law page the question is asked from.
    def asked?(question, selected_law: nil)
      return false if explicit_selection?(question, selected_law)

      analysis(question)[:general]
    end

    def explicit_selection?(question, selected_law)
      selected_law.to_s.strip.present? || question.to_s.match?(EXPLICIT_REFERENCE_PATTERN)
    end

    def specialists_asked(question)
      analysis(question)[:specialists]
    end

    # Facts that may predate 1 September 2021: a date of the facts before it,
    # a year before 2021, or 2021 without a month (it may be either side).
    def historical?(question)
      question.to_s.to_enum(:scan, FACT_DATE_PATTERN).any? do
        match = Regexp.last_match
        before_commencement?(match[:preposition].downcase, match[:day], match[:month], match[:year].to_i)
      end
    end

    def before_commencement?(preposition, day, month, year)
      return year <= 2021 if BEFORE_PREPOSITIONS.include?(preposition)
      return year < 2021 unless year == 2021
      return true if month.nil?

      Date.new(2021, MONTH_NUMBERS.fetch(month.downcase), (day || 1).to_i) < BOOK3_COMMENCEMENT
    rescue ArgumentError, KeyError
      false
    end

    def named_regions(question)
      RegionalSearch.named_regions(question) & RegionalSearch::REGION_SOURCES
    end

    # The group for this question and search language, in order: Book 3, the
    # named region's rows (all three regions when none is named), the GAS Act,
    # the competence clause, and the transition articles only for facts that
    # may predate 1 September 2021. Each entry is [numac, number, label].
    def targets(question, language_id, selected_law: nil)
      return [] unless asked?(question, selected_law: selected_law)

      named = named_regions(question)
      regions = named.presence || RegionalSearch::REGION_SOURCES
      language = language_id == 2 ? 'fr' : 'nl'
      court_region = named.length == 1 ? named.first : nil
      entries = FEDERAL_TARGETS + regions.flat_map { |region| REGION_TARGETS.fetch(region) } +
                MUNICIPAL_SANCTION_TARGETS + [COURT_TARGETS.fetch(court_region)]
      entries += HISTORICAL_TARGETS if historical?(question)
      entries.map do |numac, numbers, label|
        [numac, numbers.fetch(language_id == 2 ? 2 : 1), label_text(label, language, court_region)]
      end
    end

    # The source budget a general-noise question needs: its whole group plus
    # room for the few sources an asked specialist subject or another noise
    # source keeps beside it (SearchFanOut's final quota and the
    # orchestrator's context policy take it as a floor, like the commercial
    # and marketplace packs). 0 for any other question.
    EXTRA_ROOM = 2

    def pack_size(question, selected_law: nil)
      group = targets(question, 1, selected_law: selected_law).length
      group.positive? ? group + EXTRA_ROOM : 0
    end

    def label_text(label, language, region)
      template = LABELS.fetch(language).fetch(label)
      return template unless label == :court_region

      format(template, region: REGION_NAMES.fetch(language).fetch(region))
    end

    # Whether a source that is not one of the group may join it for a general
    # noise question. Selected sources (pinned, viewed, named) stay. Another
    # region's material is not evidence for a named region. Otherwise a source
    # must be about noise or neighbour nuisance, and a specialist source must
    # serve only purposes the question asks. Other questions: unchanged.
    def source_relevant?(source, question, selected_law: nil)
      question = question.to_s
      return true unless asked?(question, selected_law: selected_law)
      return true if selected_source?(source, question)
      return false if other_region_source?(source, named_regions(question))

      text = source_text(source)
      return false unless text.match?(NOISE_SOURCE_PATTERN)

      source_specialist_kinds(source, text).subset?(specialists_asked(question))
    end

    # The stale general row of a law whose every current version is repealed
    # (STALE_GENERAL_ROWS), unless the question dates its facts before that
    # repeal. Checked before every explicit-selection shortcut.
    def stale_current_row?(source, question)
      numac = field(source, :numac).to_s
      return false unless STALE_GENERAL_ROWS.keys.any? { |stale_numac, _key| stale_numac == numac }
      return false if field(source, :article_variant).present?

      repeals = STALE_GENERAL_ROWS[[numac, article_key(field(source, :article_title))]]
      return false unless repeals

      cutoff = (named_regions(question).presence || repeals.keys).filter_map { |region| repeals[region] }.min
      facts = fact_dates(question)
      facts.empty? || facts.min >= cutoff
    end

    # The dates a question gives its facts (FACT_DATE_PATTERN): the first day
    # of the year or month given, and the day before for "before".
    def fact_dates(question)
      question.to_s.to_enum(:scan, FACT_DATE_PATTERN).filter_map do
        match = Regexp.last_match
        month = match[:month] ? MONTH_NUMBERS.fetch(match[:month].downcase) : 1
        date = Date.new(match[:year].to_i, month, (match[:day] || 1).to_i)
        BEFORE_PREPOSITIONS.include?(match[:preposition].downcase) ? date - 1 : date
      rescue ArgumentError, KeyError
        nil
      end
    end

    def analysis(question)
      text = question.to_s.gsub(FRENCH_PROGRESSIVE, ' ')
      clauses = text.split(CLAUSE_BOUNDARY).map(&:strip).reject(&:empty?)
      return { general: false, specialists: Set.new } if clauses.empty?

      asked = clauses.grep(ASK_PATTERN)
      asked = clauses if asked.empty?
      # "Wat kan ik doen?" or "welke regels gelden voor beide?" asks about the
      # subjects the question stated before.
      asked = clauses if asked.any? { |clause| clause.match?(BOTH_PATTERN) } || asked.none? { |clause| subject_clause?(clause) }

      general = asked.any? { |clause| general_noise_clause?(clause) }
      specialists = asked.each_with_object(Set.new) { |clause, kinds| kinds.merge(asked_specialists(clause)) }
      { general: general, specialists: specialists }
    end

    def subject_clause?(clause)
      noise_mentions(clause).any? || clause.match?(NEIGHBOUR_PATTERN) ||
        SPECIALIST_PATTERNS.values.any? { |pattern| clause.match?(pattern) }
    end

    # The positions of the noise claims a clause makes, negated ones left out.
    def noise_mentions(clause)
      positions = clause.to_enum(:scan, NOISE_PATTERN).map { Regexp.last_match.begin(0) }
      positions += clause.to_enum(:scan, SOUND_PATTERN).map { Regexp.last_match.begin(0) } if clause.match?(NEIGHBOUR_PATTERN)
      positions.reject { |position| negated?(clause, position, NOISE_NEGATORS, 2) }
    end

    # Noise asked in a clause that also asks a specialist purpose is that
    # purpose's noise ("lawaai voor werknemers in een steengroeve"), unless the
    # clause names neighbours too.
    def general_noise_clause?(clause)
      return false if noise_mentions(clause).empty?
      return true if clause.match?(NEIGHBOUR_PATTERN)

      asked_specialists(clause).empty?
    end

    def asked_specialists(clause)
      SPECIALIST_PATTERNS.each_with_object(Set.new) do |(kind, pattern), kinds|
        clause.to_enum(:scan, pattern).each do
          kinds << kind unless negated?(clause, Regexp.last_match.begin(0), SPECIALIST_NEGATORS, 4)
        end
      end
    end

    def negated?(clause, position, negators, window)
      clause[0...position].scan(/[\p{L}\p{N}']+/).last(window).any? { |word| word.match?(negators) }
    end

    def source_specialist_kinds(source, text)
      numac = field(source, :numac).to_s
      return SPECIALIST_SOURCE_NUMACS.fetch(numac).to_set if SPECIALIST_SOURCE_NUMACS.key?(numac)

      key = article_key(field(source, :article_title))
      kinds = SPECIALIST_PATTERNS.each_with_object(Set.new) do |(kind, pattern), found|
        found << kind if text.match?(pattern)
      end
      # Every article of the Brussels noise ordinance other than the group's
      # own is plan and procedure material, and every article of the 1973 Act
      # other than Art. 1 is airport, subsidy or enforcement material.
      kinds << :planning if numac == BRUSSELS_NOISE_ORDINANCE && !%w[art13 art14].include?(key)
      kinds << :inspection if numac == NOISE_ACT_1973 && !key.to_s.match?(/\Aart1(?:_|\z)/)
      kinds << :planning if text.match?(PROCEDURE_SOURCE_PATTERN)
      kinds
    end

    def other_region_source?(source, named)
      return false if named.empty?

      region = source_region(source)
      region.present? && !named.include?(region)
    end

    def source_region(source)
      origin = field(source, :source).to_s.downcase
      return 'vlaamse_codex' if origin.include?('vlaam') || origin.include?('fland')
      return 'wallex' if origin.include?('wallex') || origin.include?('wallon')
      return 'brussels' if origin.include?('bruss') || origin.include?('brux')

      variant = field(source, :article_variant).to_s
      found = VARIANT_REGIONS.find { |_region, pattern| variant.match?(pattern) }&.first
      return found if found
      return 'brussels' if BRUSSELS_ONLY_NUMACS.include?(field(source, :numac).to_s)

      nil
    end

    def selected_source?(source, question)
      return true if %i[pinned viewed selected explicit].any? { |key| truthy?(field(source, key)) }

      numac = field(source, :numac).to_s
      !numac.empty? && question.downcase.include?(numac.downcase)
    end

    def source_text(source)
      %i[law_title title article_title article_text content].filter_map { |key| field(source, key)&.to_s }.join("\n")
    end

    def article_key(title)
      token = title.to_s[%r{\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w/.:-]*)}i, 1]
      token ? "art#{token.delete(' ').sub(/\.+\z/, '').downcase}" : nil
    end

    def field(source, key)
      return nil unless source.respond_to?(:[])

      source[key] || source[key.to_s]
    rescue StandardError
      nil
    end

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
