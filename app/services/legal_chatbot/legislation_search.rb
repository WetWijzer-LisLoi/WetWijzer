# frozen_string_literal: true

module LegalChatbot
  # Searches federal legislation via FAISS vector search + FTS5/LIKE keyword supplement.
  # This is the primary search service - Belgian federal legislation is the core dataset.
  #
  # Search pipeline:
  # 1. FAISS nearest-neighbor search against 2.3M article embeddings (port 8767)
  # 2. Keyword extraction + FTS5 search as supplement
  # 3. Merge results with core law boosting (Burgerlijk Wetboek, AOW, etc.)
  # 4. Quality filters: title relevance, similarity threshold
  # 5. Context building with abolished warnings, exdecs, modifications
  #
  # Dependencies:
  #   - ActiveRecord models: Article, Legislation, Content, Exdec, UpdatedLaw, ArticleModification
  #   - SQLite: search.sqlite3 (FTS5 for keyword supplement)
  #   - FAISS service on port 8767
  #   - CoreLawMappings concern (constants: CORE_LAW_NUMACS, KEYWORD_TO_CORE_LAWS, etc.)
  class LegislationSearch
    CANONICAL_LANGUAGE_IDS = [1, 2].freeze
    include TextProcessing
    include CoreLawMappings

    FAISS_URL = ENV.fetch('FAISS_LARGE_URL', 'http://localhost:8767')
    FAISS_ENABLED_ENV = 'LEGISLATION_FAISS_ENABLED'

    # Known bad or obsolete source identities must never survive semantic
    # retrieval, viewed-law context, or stale configuration. 1994071450 is an
    # election-information order, not the coordinated sickness-insurance law;
    # 1930123150 is the drugs decree repealed by Art. 64 of the current 2017 KB.
    INVALID_LEGISLATION_NUMACS = %w[1994071450 1930123150].to_set.freeze

    # Short law-code keys are abbreviations, not semantic prefixes. Without a
    # right boundary `wer` also matched ordinary words such as `werkt`, causing
    # unrelated Economic Law articles to be injected into health questions.
    EXACT_CORE_LAW_KEYWORDS = %w[wer wib wib92 ziv vcro].to_set.freeze

    # A bounded morphology bridge for FTS5. The production FTS index uses the
    # default tokenizer (no Dutch/French stemmer), so use prefix queries only
    # as a fallback when exact lexical matches are sparse. This avoids a broad
    # stemmer turning ordinary words into noisy search terms.
    FTS_STEM_SUFFIXES = %w[eringen ering ations ation heids heid ement ment ing en er es s e].freeze
    FTS_IRREGULAR_PREFIXES = {
      'belaging' => %w[belaag belag],
      'belaagd' => %w[belaag belag],
      'belagen' => %w[belaag belag]
    }.freeze

    REGIONAL_TAX_NUMACS = Set.new(%w[2013036154 1936033102 1939113002]).freeze
    FLANDERS_TAX_NUMACS = Set.new(%w[2013036154]).freeze
    REGIONAL_TAX_SUBJECT_PATTERN = /\b(?:erfbelasting|erfenisbelasting|successierecht|schenkbelasting|schenkingsrecht|registratiebelasting|registratierecht(?:en)?|verkooprecht|verdeelrecht|onroerende\s+voorheffing|droits?\s+(?:(?:de\s+)?(?:succession|donation|enregistrement|vente)|d['’]enregistrement)|precompte\s+immobilier|précompte\s+immobilier|erbschafts?steuer|schenkungs?steuer|registrierungssteuer|inheritance\s+tax|gift\s+tax|registration\s+tax|property\s+tax)\b/i
    REGIONAL_TAX_GIFT_TERM_PATTERN = /(?<![[:alnum:]])(?:schenking|donation|schenkung|gift)(?![[:alnum:]])/iu
    REGIONAL_TAX_EXPRESSION_PATTERN = /(?<![[:alnum:]])(?:belasting(?:en)?|belast[[:alpha:]]*|rechten?|tax[[:alpha:]]*|imp[oô]t|impos[[:alpha:]]*|fisc[[:alpha:]]*|steuer[[:alpha:]]*|besteuer[[:alpha:]]*|versteuer[[:alpha:]]*)(?![[:alnum:]])/iu
    REGIONAL_TAX_GIFT_CONTEXT_PATTERN = Regexp.union(
      /#{REGIONAL_TAX_GIFT_TERM_PATTERN.source}.{0,40}#{REGIONAL_TAX_EXPRESSION_PATTERN.source}/iu,
      /#{REGIONAL_TAX_EXPRESSION_PATTERN.source}.{0,40}#{REGIONAL_TAX_GIFT_TERM_PATTERN.source}/iu
    )
    REGIONAL_TAX_SUCCESSION_TERM_PATTERN = /(?<![[:alnum:]])(?:erfenis|nalatenschap|successie|héritage|heritage|succession|inheritance|erbschaft)(?![[:alnum:]])/iu
    REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN = Regexp.union(
      /#{REGIONAL_TAX_SUCCESSION_TERM_PATTERN.source}.{0,40}#{REGIONAL_TAX_EXPRESSION_PATTERN.source}/iu,
      /#{REGIONAL_TAX_EXPRESSION_PATTERN.source}.{0,40}#{REGIONAL_TAX_SUCCESSION_TERM_PATTERN.source}/iu
    )
    SUCCESSION_TAX_PATTERN = /\b(?:erfbelasting|erfenisbelasting|successierecht|erfenis|nalatenschap|successie|droits?\s+(?:de\s+)?succession|héritage|heritage|succession|erbschaft|erbschafts?steuer|inheritance|inheritance\s+tax)\b/i
    REGISTRATION_TAX_PATTERN = /\b(?:schenkbelasting|schenkingsrecht|schenking|registratiebelasting|registratierecht(?:en)?|verkooprecht|verdeelrecht|droits?\s+(?:(?:de\s+)?(?:donation|enregistrement|vente)|d['’]enregistrement)|donation|schenkung|schenkungs?steuer|registrierungssteuer|gift|gift\s+tax|registration\s+tax)\b/i
    # The taxes for which art. 4, § 1 of the special financing act gives the regions the
    # rate, the taxable base and the exemptions: art. 3, first paragraph, 1° to 4° and 6° to
    # 9°, which covers succession duties (4°) and the registration duties (6° to 8°).
    #
    # Deliberately NOT REGIONAL_TAX_SUBJECT_PATTERN. That constant also carries onroerende
    # voorheffing / précompte immobilier / property tax, which is art. 3, 5° and is governed
    # by art. 4, § 2 with its own carve-out forbidding the regions to change the federal
    # kadastraal inkomen. Reusing it would cite the wrong legal basis for a quarter of what
    # it matches.
    REGIONAL_TAX_COMPETENCE_PATTERN =
      Regexp.union(SUCCESSION_TAX_PATTERN, REGISTRATION_TAX_PATTERN).freeze
    FLANDERS_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('vlaamse_codex')
    WALLONIA_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('wallex')
    BRUSSELS_REGION_PATTERN = RegionalSearch::REGION_PATTERNS.fetch('brussels')
    BRUSSELS_WALLONIA_REGION_PATTERN = Regexp.union(WALLONIA_REGION_PATTERN, BRUSSELS_REGION_PATTERN)
    REGIONAL_FAMILY_BENEFIT_PATTERN = /\b(?:groeipakket|kinderbijslag|allocations?\s+familiales|kindergeld|child\s+benefit|family\s+allowance)\b/i
    REGIONAL_HOUSING_NUMACS = Set.new(%w[2018015087 2013A31614 2018201408]).freeze
    HOUSING_CONTEXT_EXCLUDED_NUMACS = Set.new(%w[1978070303]).freeze
    REGIONAL_HOUSING_SUBJECT_PATTERN = /\b(?:woninghuur|huurwaarborg|huurcontract|huurder|verhuurder|uithuiszetting|plaatsbeschrijving|bail\s+(?:d['’]habitation|de\s+residence|de\s+résidence)|locataire|bailleur|garantie\s+locative|expulsion|état\s+des\s+lieux|mietvertrag|mietkaution|mieterh[oö]hung|mieter|vermieter|wohnungsmiete|kurzzeitmiete|mietdauer|tenant|landlord|rental\s+deposit|residential\s+(?:rent|lease|tenancy)|short-term\s+rental|eviction|property\s+inventory|condition\s+report)\b/i
    FLANDERS_PLANNING_NUMACS = Set.new(%w[2009A35738 2014036510 2010035645 2010035576]).freeze
    REGIONAL_PLANNING_SUBJECT_PATTERN = /\b(?:ruimtelijke\s+ordening|stedenbouw\w*|omgevingsvergunning|bouwvergunning|verkavelingsvergunning|planologisch\w*|aménagement\s+du\s+territoire|urbanisme|permis\s+(?:d['’])?(?:urbanisme|environnement)|spatial\s+planning|planning\s+permission|building\s+permit|raumordnung|baugenehmigung)\b/i

    LEGACY_CRIMINAL_CODE_NUMAC = '1867060850'
    CURRENT_CRIMINAL_CODE_NUMACS = Set.new(%w[2024002052 2024002088]).freeze
    LEGACY_CRIMINAL_CODE_NAME_PATTERN = /\b(?:oud\s+strafwetboek|strafwetboek\s+van\s+1867|ancien\s+code\s+pénal|old\s+criminal\s+code|altes\s+strafgesetzbuch)\b/i
    CRIMINAL_OFFENCE_PATTERN = /\b(?:feiten?|misdrijf|strafbaar\s+feit|diefstal|stelen|belaging|inbraak|oplichting|fraude|moord|doodslag|verkrachting|mishandeling|drugs?(?:bezit)?|vol|harcèlement|infraction|cambriolage|escroquerie|fraude|meurtre|homicide|viol|agression|stupéfiants?|drogue|theft|offen[cs]e|burglary|robbery|fraud|murder|homicide|rape|assault|drugs?|diebstahl|straftat|einbruch|raub|betrug|mord|totschlag|vergewaltigung|körperverletzung|drogen)\b/i
    CRIMINAL_EVENT_PATTERN = %r{
      \b(?:
        vond\s+plaats|gebeurde|dateert|(?:werd|is|heb|heeft|hebben)?\s*gepleegd|begaan|
        (?:a|ont)\s+été\s+commis(?:e|es)?|commis(?:e|es)?|a\s+eu\s+lieu|dat(?:e|ent)|
        was\s+committed|committed|happened|occurred|took\s+place|
        wurde\s+begangen|begangen|ereignete\s+sich|fand\s+statt
      )\b
    }ix
    LEGACY_CRIMINAL_DATE_PATTERN = %r{
      (?:
        (?:19\d{2}|20(?:0\d|1\d|2[0-5]))(?!\d)(?!\s*(?:€|eur(?:o)?s?\b|dollars?\b|usd\b|gbp\b))|
        2026[-/.]0?[1-3][-/.](?:0?[1-9]|[12]\d|3[01])(?!\d)|
        2026[-/.]0?4[-/.]0?[1-7](?!\d)|
        (?:0?[1-9]|[12]\d|3[01])[-/.]0?[1-3][-/.]2026(?!\d)|
        0?[1-7][-/.]0?4[-/.]2026(?!\d)|
        (?:(?:[1-9]|[12]\d|3[01])(?:st|nd|rd|th|er|e|\.)?\s+)?
          (?:januari|janvier|january|januar|februari|février|fevrier|february|februar|maart|mars|march|märz|maerz)\s+2026|
        [1-7](?:st|nd|rd|th|er|e|\.)?\s+(?:april|avril)\s+2026|
        (?:january|february|march)\s+(?:[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?,?\s+2026|
        april\s+[1-7](?:st|nd|rd|th)?,?\s+2026
      )
    }ix
    PRE_CUTOVER_CRIMINAL_REFERENCE_PATTERN = %r{
      (?:
        (?:de\s+|le\s+|dem\s+|the\s+)?(?:8(?:th|e|er|\.)?\s+(?:april|avril)\s+2026|april\s+8(?:th)?,?\s+2026|0?8[-/.]0?4[-/.]2026|2026[-/.]0?4[-/.]0?8)|
        (?:de\s+|du\s+|the\s+|des\s+)?(?:inwerkingtreding|entrée\s+en\s+vigueur|entry\s+into\s+force|inkrafttreten)\s+(?:van\s+|du\s+|of\s+|des\s+)?(?:het\s+|le\s+|the\s+|des\s+)?(?:nieuwe?\s+|nouveau\s+|new\s+|neuen?\s+)?(?:strafwetboek|code\s+pénal|criminal\s+code|strafgesetzbuch)
      )
    }ix
    LEGACY_CRIMINAL_FACT_PATTERN = %r{
      (?:
        #{CRIMINAL_OFFENCE_PATTERN.source}\s+(?:op|in|uit|van|on|from|im|am|aus|le|en|de)\s+#{LEGACY_CRIMINAL_DATE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,30}(?:vóór|voor|avant|before|vor)\s+#{PRE_CUTOVER_CRIMINAL_REFERENCE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,80}#{CRIMINAL_EVENT_PATTERN.source}.{0,30}#{LEGACY_CRIMINAL_DATE_PATTERN.source}|
        #{CRIMINAL_OFFENCE_PATTERN.source}.{0,80}#{LEGACY_CRIMINAL_DATE_PATTERN.source}.{0,30}#{CRIMINAL_EVENT_PATTERN.source}|
        #{LEGACY_CRIMINAL_DATE_PATTERN.source}.{0,40}#{CRIMINAL_EVENT_PATTERN.source}.{0,40}#{CRIMINAL_OFFENCE_PATTERN.source}
      )
    }ix
    HISTORICAL_THEFT_PATTERN = %r{\A(?=.*#{LEGACY_CRIMINAL_FACT_PATTERN.source})(?=.*\b(?:diefstal|stelen|gestolen|vol|theft|diebstahl)\b).*\z}ix
    HISTORICAL_STALKING_PATTERN = %r{\A(?=.*#{LEGACY_CRIMINAL_FACT_PATTERN.source})(?=.*\b(?:belaging|belagen|belaagd|harcèlement|stalking)\b).*\z}ix

    def initialize(embedding_service:, language: 'nl', context_numacs: [], profile: 'general')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @context_numacs = context_numacs
      @profile = profile
    end

    # ------------------------------------------------------------------
    # PUBLIC API
    # ------------------------------------------------------------------

    # Find similar legislation articles via FAISS, lexical FTS supplementation,
    # and core-law boosting. Keeping the hybrid retrieval here (rather than in
    # an orchestrator-only post-step) means FTS can rescue a FAISS zero-hit.
    # Returns array of article hashes with metadata.
    def search(question_embedding, limit: 12, question: nil)
      # The legacy main index predates source-identity manifests and can map an
      # old vector to a different article that later reused the same integer
      # ID. Keep it fail-closed until a manifest-bound generation is activated.
      # FTS, article pins and core-law mappings remain available while disabled.
      top_articles = if legislation_faiss_enabled?
                       search_faiss(question_embedding, limit * 3) || []
                     else
                       Rails.logger.info(
                         "[Search] Main legislation FAISS disabled by #{FAISS_ENABLED_ENV}; " \
                         'using verified lexical and pinned routes'
                       )
                       []
                     end

      # Merge semantic and lexical candidates before applying any legal or
      # regional scope. Otherwise a lexical hit added after scoping can
      # reintroduce a repealed code or a law from the wrong region.
      if question.present?
        # The lexical supplement covers the vocabulary gap where a user's word
        # differs from the statute's wording. Preserve a small BM25-ranked
        # lexical quota so a high-volume semantic result set cannot crowd it
        # out before title filtering.
        keyword_articles = find_by_keywords(extract_keywords(question), limit: 5)
        if keyword_articles.any?
          top_articles = merge_search_results(top_articles, keyword_articles, limit: limit * 3)
        end

        top_articles = apply_core_law_boosting(top_articles, question, profile: @profile)
      end

      # Article-level pins: for well-known concepts whose governing article the
      # semantic search misses on VOCABULARY MISMATCH (user says "belaging",
      # the statute says "belaagd"; "verjaring" vs "rechtsvorderingen verjaren";
      # "beslagvrije som" vs "voor beslag vatbaar"), force the exact governing
      # article to the top. Core-law boosting is only numac-level, so it
      # surfaces a code's Art.1/headings, never the specific article.
      if question.present?
        pins = pinned_articles(question).uniq { |article| article[:id] }
        if pins.any?
          # A pin is a ranking instruction, not merely an injection fallback.
          # Promote it even when FAISS already found the same article lower in
          # the result list, while retaining exactly one copy of every result.
          pinned_ids = pins.to_set { |article| article[:id] }
          top_articles = pins + top_articles.reject { |article| pinned_ids.include?(article[:id]) }
        end
      end

      # Return top N without allowing the final ranking cut to undo the
      # vocabulary-rescue quota established by the hybrid merge.
      # Sanitize INSIDE the quota call, so rows dropped for being future law are backfilled
      # and the caller still receives `limit` articles that are actually in force.
      retain_final_search_quota(sanitize_future_law(top_articles), limit: limit)
    end

    # Private hospitalisation insurance is governed by the Insurance Act, not
    # by the statutory sickness-insurance regime. These deliberately require a
    # product-specific phrase: the retrieved provisions and policy terms must
    # still establish the concrete duration, premium, eligibility, or waiting
    # rule for the user's contract.
    HOSPITALISATION_POLICY_PATTERN = /\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b/i
    HOSPITALISATION_WAITING_PATTERN = /\A(?=.*\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b)(?=.*\b(?:wachttijd|wachtperiode|stageperiode|délai\s+de\s+carence|période\s+d[’']attente|waiting\s+period|wartezeit)\b).*\z/im
    HOSPITALISATION_DURATION_PATTERN = /\A(?=.*\b(?:hospitalisatieverzekering(?:en)?|hospitalisatiepolis(?:sen)?|assurance\s+(?:d[’']hospitalisation|hospitalisation|hospitalière)|hospital(?:i[sz]ation)?\s+insurance|krankenhauszusatzversicherung)\b)(?=.*\b(?:levenslang\w*|looptijd|duur|voortzetting|continu[iï]teit|opzeg\w*|be[eë]indig\w*|délai|durée|à\s+vie|résili\w*|cessation|lifetime|duration|terminat\w*|lebenslang\w*|laufzeit|kündig\w*)\b).*\z/im

    # Concept -> governing article, when FAISS reliably misses it. Keep this
    # LIST tight and high-confidence: a wrong pin poisons an answer. Format:
    # [question-regex, numac, article-number]. Seeded 2026-07-15 from the
    # hands-on retrieval diagnosis; expandable from the full-corpus audit.
    DRUG_OFFENCE_PATTERN = %r{
      \b(?:
        drugs?bezit|drugshandel|
        bezit\s+(?:van\s+)?(?:drugs?|verdovende\s+middelen|cannabis|cocaïne|heroïne)|
        handel\s+(?:in|van)\s+(?:drugs?|verdovende\s+middelen)|
        (?:détention|possession|trafic|commerce)\s+(?:de|des)\s+(?:drogues?|stupéfiants?|cannabis|cocaïne|héroïne)|
        drug\s+possession|possession\s+of\s+(?:(?:small|limited)\s+amounts?\s+of\s+)?(?:drugs?|narcotics|cannabis|cocaine|heroin)|drug\s+trafficking|trafficking\s+in\s+(?:drugs?|narcotics)|
        drogenbesitz|drogenhandel|besitz\s+von\s+(?:drogen|betäubungsmitteln?|cannabis|kokain|heroin)|handel\s+mit\s+(?:drogen|betäubungsmitteln?)
      )\b
    }ix.freeze
    CANNABIS_OR_POSSESSION_PATTERN = %r{
      \A(?!.*\b(?:cocaïne|cocaine|heroïne|héroïne|heroin|kokain)\b).*\b(?:
        drugs?bezit|bezit\s+(?:van\s+)?(?:drugs?|verdovende\s+middelen|cannabis)|cannabisbezit|
        (?:détention|possession)\s+(?:de|des)\s+(?:drogues?|stupéfiants?|cannabis)|
        drug\s+possession|possession\s+of\s+(?:(?:small|limited)\s+amounts?\s+of\s+)?(?:drugs?|narcotics|cannabis)|cannabis\s+possession|
        drogenbesitz|besitz\s+von\s+(?:drogen|betäubungsmitteln?|cannabis)
      )\b.*\z
    }ix.freeze
    MAJORITY_AGE_PATTERN = /
      (?=.*\b(?:meerderjarig(?:heid)?|majorité|majeur(?:e)?|age\s+of\s+majority|legally\s+adult|volljährig\w*)\b)
      (?=.*\b(?:leeftijd|jaar|vanaf|wanneer|âge|ans|quel\s+âge|age|years?|when|alter|jahre|wann|18|achttien|dix-huit|achtzehn)\b)
    /ix
    TESTAMENT_FORM_PATTERN = /
      \A
      (?!.*\b(?:aanvecht\w*|betwist\w*|bedrog|dwang|wilsgebrek|wilsbekwaam\w*|onbekwaam\w*|
                 herroep\w*|intrek\w*|révoqu\w*|contest\w*|fraude?|dol|capacité|incapacité|
                 revoc\w*|revok\w*|challeng\w*|fraud|capacity|undue\s+influence|
                 widerruf\w*|anfecht\w*|betrug|testierfähigkeit)\b)
      (?=.*\b(?:testament(?:en|s)?|last\s+will|(?:handwritten|notarial|international)\s+will)\b)
      (?=.*\b(?:geldig(?:heid)?|vorm(?:en)?|voorwaard(?:e|en)|eigenhandig|notarieel|internationaal|
                    valide?|validité|forme|conditions?|olographe|notarié|international|requis|
                    valid(?:ity)?|forms?|requirements?|required|necessary|handwritten|notarial|
                    gültig(?:keit)?|formen?|voraussetzungen?|eigenhändig|handschriftlich\w*|notariell|
                    erforderlich|notwendig)\b)
      .*\z
    /ix
    EMPLOYMENT_NON_COMPETE_PATTERN = /
      (?:
        \b(?:niet[-\s]?)?concurrentiebeding(?:en)?\b|\bnon[-\s]?concurrence\b
      ).{0,80}\b(?:
        arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling|
        contrat\s+de\s+travail|travailleur|employeur|licenciement
      )\b
      |
      \b(?:
        arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling|
        contrat\s+de\s+travail|travailleur|employeur|licenciement
      )\b.{0,80}(?:
        \b(?:niet[-\s]?)?concurrentiebeding(?:en)?\b|\bnon[-\s]?concurrence\b
      )
    /ix
    USED_GOODS_WARRANTY_PATTERN = /
      \A
      (?=.*\b(?:tweedehands(?:e)?|occasie(?:wagen)?|d[’']occasion|seconde?\s+main|used|second[-\s]?hand|gebraucht\w*)\b)
      (?=.*\b(?:aankoop|koop|kopen|gekocht|vente|achat|acheter|purchase|buy|bought|kauf|gekauft)\b)
      (?=.*\b(?:garantie|conformiteit|conformité|warranty|gewährleistung)\b)
      .*\z
    /ix
    ONLINE_CONSUMER_RIGHTS_PATTERN = /
      \A
      (?=.*\b(?:online|webshop|internet|op\s+afstand|afstandsovereenkomst|en\s+ligne|
                    vente\s+à\s+distance|contrat\s+à\s+distance|distance\s+(?:contract|sale)|online\s+purchase)\b)
      (?=.*\b(?:consument|consumenten|consumer|consommateur)\b)
      (?=.*\b(?:bescherming|recht(?:en)?|droits?|protection|rights?)\b)
      .*\z
    /ix
    UNEMPLOYMENT_BENEFIT_PATTERN = /
      \b(?:werkloosheidsuitkering(?:en)?|werkloosheidsvergoeding|werkloze|rva|ch[oô]mage|allocations?\s+de\s+ch[oô]mage|onem)\b
    /ix
    UNEMPLOYMENT_CONDITIONS_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:voorwaarden|voorwaarde|recht\s+op|toegelaten|toelaatbaar|beroepsverleden|voorwaarden\s+voor\s+toelating|
                conditions?|droit\s+aux?|admis|admissibilit[eé]|stage)\b)
      .*\z
    /ix
    UNEMPLOYMENT_AVAILABILITY_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:beschikbaar(?:heid)?|arbeidsmarkt|actief\s+zoeken|passende\s+dienstbetrekking|
                disponibilit[eé]|march[eé]\s+de\s+l['’]emploi|recherche\s+d['’]emploi|emploi\s+convenable)\b)
      .*\z
    /ix
    UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:vrijstelling|vrijgesteld|dispense|exemption)\b)
      (?=.*\b(?:opleiding|studie|studies|vorming|beroepsopleiding|formation|[eé]tudes?)\b)
      .*\z
    /ix
    UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN = /
      \A
      (?=.*#{UNEMPLOYMENT_BENEFIT_PATTERN})
      (?=.*\b(?:dringende\s+reden|motif\s+grave|eigen\s+toedoen|ontslag\s+wegens\s+fout|faute|ch[oô]mage\s+volontaire)\b)
      .*\z
    /ix
    TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN = /
      \A
      (?=.*\b(?:tijdelijke\s+werkloosheid|ch[oô]mage\s+temporaire)\b)
      (?=.*\b(?:economisch(?:e)?|oorzaken|raisons?\s+[eé]conomiques?|[eé]conomique)\b)
      .*\z
    /ix
    TEMPORARY_UNEMPLOYMENT_FORCE_MAJEURE_PATTERN = /
      \A
      (?=.*\b(?:tijdelijke\s+werkloosheid|ch[oô]mage\s+temporaire)\b)
      (?=.*\b(?:overmacht|force\s+majeure)\b)
      .*\z
    /ix
    VAT_SMALL_ENTERPRISE_EXEMPTION_PATTERN = /
      \A
      (?=.*\b(?:btw|tva|belasting\s+over\s+de\s+toegevoegde\s+waarde|taxe\s+sur\s+la\s+valeur\s+ajout[eé]e)\b)
      (?=.*\b(?:kleine\s+onderneming(?:en)?|kleineondernemersregeling|vrijstellingsregeling|vrijstelling|franchise|petites?\s+entreprises?)\b)
      .*\z
    /ix
    ALCOHOL_DRIVING_LIMIT_PATTERN = /
      \A
      (?=.*\b(?:alcohol(?:limiet|grens)?|alcohollimiet|promille|ademanalyse|bloedanalyse|alcool|taux\s+d['’]?alcool)\b)
      (?=.*\b(?:bestuurders?|rijden|verkeer|wegverkeer|bloed|voertuig|conducteurs?|conduire|circulation)\b)
      .*\z
    /ix

    ARTICLE_PINS = [
      # Criminal / civil procedure
      [LEGACY_CRIMINAL_FACT_PATTERN,                                  '2024002052', '2'],        # Book I: more-favourable-law transition
      [HISTORICAL_THEFT_PATTERN,                                      '1867060850', '461'],      # 1867 Code: historical theft definition
      [HISTORICAL_THEFT_PATTERN,                                      '1867060850', '463'],      # 1867 Code: historical simple-theft penalty
      [HISTORICAL_STALKING_PATTERN,                                   '1867060850', '442bis'],   # 1867 Code: historical stalking provision
      [/\bbelaging\b|\bstalking\b|belaag[dt]|\bbelagen\b/i,        '2024002088', '237'],      # Strafwetboek Boek II
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:strafvordering|misdrij(?:f|ven)|wanbedrijf|overtreding|diefstal|oplichting|strafzaak|strafrecht|drugsbezit|drugshandel|drugsdelict)\b|\b(?:strafvordering|misdrij(?:f|ven)|wanbedrijf|overtreding|diefstal|oplichting|strafzaak|strafrecht|drugsbezit|drugshandel|drugsdelict)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1878041750', '21'], # V.T.Sv. criminal prescription
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:factuur|schuld|vordering|contract|aansprakelijkheid|schadevergoeding|betaling|burgerlijk|civiel)\b|\b(?:factuur|schuld|vordering|contract|aansprakelijkheid|schadevergoeding|betaling|burgerlijk|civiel)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1804032155', '2262bis'], # oud BW civil prescription
      [/(?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,60}\b(?:factuur|schuld|vordering|contract|betaling|periodieke\s+schuld)\b|\b(?:factuur|schuld|vordering|contract|betaling|periodieke\s+schuld)\b.{0,60}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)/i, '1804032155', '2277'], # old BW special short prescription candidates
      [/beslagvrije\s*som|loonbeslag|voor\s*beslag\s*vatbaar/i,       '1967101056', '1409'],     # Ger.W. Part V
      [/\b(?:kort\s+geding|référé|einstweilige\s+verfügung)\b/i,       '1967101054', '584'],      # Ger.W. Part III
      [/\A(?!.*\b(?:straf\w*|misdrijf|beklaagde|veroordeelde|correctioneel|pénal\w*|prévenu|condamné)\b)(?=.*(?:\btermijn\b.*\bhoger\s*beroep\b|\bhoger\s*beroep\b.*\btermijn\b|\bdélai\b.*\bappel\b|\bappel\b.*\bdélai\b)).*\z/im, '1967101055', '1051'], # civil appeal only
      [/(?=.*\b(?:minnelijke\s+schikking|verval\s+van\s+strafvordering|transaction\s+pénale)\b)(?=.*\b(?:straf|misdrijf|parket|procureur|pénal|infraction|ministère\s+public)\b)/i, '1808111901', '216bis'],
      [/(?:\bsalduz\b|(?=.*\b(?:verhoor|politieverhoor|ondervraging|audition|interrogatoire)\b)(?=.*\b(?:advocaat|rechtsbijstand|rechten|avocat|assistance|droits)\b))/i, '1808111701', '47bis'],
      [/\b(?:burgerlijke\s+partijstelling|zich\s+burgerlijke\s+partij\s+stellen|constitution\s+de\s+partie\s+civile)\b/i, '1808111701', '63'],
      [/\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|avec|commis|constitue|puni|passible)\b/i, '2024002088', '463'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|avec|commis|constitue|puni|passible)\b))(?=.*\b(?:straf|bestraft|gevangenis|boete|peine)\b)/i, '2024002088', '465'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen|inbraak)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:simple|qualifi[eé]|commis|constitue|puni|passible)\b))(?=.*\b(?:braak|inklimming|valse\s+sleutel|effraction|escalade|nacht|nuit)\b)/i, '2024002088', '466'],
      [/(?=.*(?:\b(?:diefstal|stelen|gestolen)\b|\b(?:le|du|au|un|ce|des|pour)\s+vol\b|\bvol\s+(?:avec|violence|menace)\b))(?=.*\b(?:geweld|bedreiging|violence|menace)\b)/i, '2024002088', '467'],
      [/(?=.*\b(?:rechtspersoon|rechtspersonen|personne\s+morale|legal\s+person)\b)(?=.*\b(?:strafrechtelijk|pénal\w*|criminal\w*|aansprakelijk\w*|responsab\w*|liab\w*)\b)/i, '1867060850', '5'],
      [/\bdwangsom\b/i,                                                '1967101055', '1385bis'],  # Ger.W. Part IV

      # Constitution — narrow rights/concept phrases only.
      [/\b(?:betog(?:en|ing)|vrijheid\s+van\s+vergadering|manifest(?:er|ation)|liberté\s+de\s+réunion)\b/i, '1994021048', '26'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '19'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '20'],
      [/(?=.*\b(?:godsdienst(?:vrijheid)?|eredienst|religion|culte)\b)(?=.*\b(?:grondwet(?:telijk)?|vrijheid|recht|constitution(?:nel)?|liberté|droit)\b)/i, '1994021048', '21'],
      [/(?=.*\b(?:bestuursdocumenten|documenten\s+van\s+het\s+bestuur|documents?\s+administratifs?)\b)(?=.*\b(?:openbaarheid|inzage|raadplegen|publicité|consulter|accès)\b)/i, '1994021048', '32'],
      [/(?=.*\b(?:onteigening|expropriation)\b)(?=.*\b(?:schadeloosstelling|vergoeding|indemnité|indemnisation)\b)/i, '1994021048', '16'],
      [/\b(?:grondwettelijk\s+hof|cour\s+constitutionnelle|verfassungsgerichtshof)\b/i, '1994021048', '142'],

      # Lay-term aliases (decision D, docs/ops/withheld-answers-2026-08-04.md,
      # measured against config/quality/retrieval_recall_fixture_v1.json):
      # the user's everyday word appears nowhere in the official title the
      # index embeds, so the governing law never surfaced. Pins are additive
      # and floor-proof, so a wrong match adds one law to context rather than
      # displacing anything.
      [/\bgroepsverzekering(?:en)?\b|\bassurance[\s\-]groupes?\b/i, '2003022481', '2'],   # WAP: doel/toepassingsgebied
      [/\bgroepsverzekering(?:en)?\b|\bassurance[\s\-]groupes?\b/i, '2003022481', '3'],   # WAP: definities (incl. groepsverzekering)
      [/\bsociaal\s+strafwetboek\b|\bcode\s+p[eé]nal\s+social\b/i,  '2010A09589', '1'],   # the code names itself; the 2024 Strafwetboek otherwise dominates
      # Pop-up rent: the Flemish decree titles itself "huur van korte duur
      # voor handel en ambacht". Regionalized topic - the answer model must
      # hedge for Brussels/Wallonia; the pin only guarantees the concept's
      # statutory basis reaches the context at all.
      [/(?=.*\bpop[\s\-]?ups?\b)(?=.*\b(?:huur|hur(?:en)?|winkel|handelszaak|handelshuur|zaak|locat\w*)\b)/i, '2016036108', '2'],
      [/(?=.*\bpop[\s\-]?ups?\b)(?=.*\b(?:huur|hur(?:en)?|winkel|handelszaak|handelshuur|zaak|locat\w*)\b)/i, '2016036108', '3'],

      # Coordinated compulsory health-insurance law (ZIV/AMI). These pins are
      # intentionally concept-specific; exact tariffs and nomenclature remain
      # outside the statute and must still be hedged by the answer model.
      [/\b(?:remgeld|persoonlijk\s+aandeel|ticket\s+modérateur)\b/i, '1994071451', '37'],
      [/\b(?:maximumfactuur|maximumfactuurregeling|\bmaf\b)\b/i, '1994071451', '37octies'],
      [/\b(?:derdebetalersregeling|tiers\s+payant)\b/i, '1994071451', '53'],
      [/\b(?:geconventioneerde?\s+arts|médecin\s+conventionné)\b/i, '1994071451', '50'],
      [/\b(?:arbeidsongeschiktheidsuitkering|primaire\s+arbeidsongeschiktheid)\b/i, '1994071451', '87'],
      [/(?=.*\b(?:invaliditeit|invaliditeitsuitkering)\b)(?=.*\b(?:ziekte|arbeidsongeschiktheid|uitkering|mutualiteit|ziekenfonds|riziv|ziv)\b)/i, '1994071451', '93'],
      [/\b(?:progressieve\s+werkhervatting|progressie(?:f|ve)\s+(?:het\s+)?werk\s+hervat\w*|toegelaten\s+arbeid|halftijds\s+werken\s+tijdens\s+arbeidsongeschiktheid)\b/i, '1994071451', '100'],
      [/\b(?:moederschapsuitkering|uitkering\b.{0,40}\bmoederschapsrust|moederschapsrust\b.{0,40}\buitkering)\b/i, '1994071451', '112'],
      [/(?=.*\b(?:aansluiten|aansluiting|aangesloten|verplicht)\b)(?=.*\b(?:ziekenfonds|mutualiteit|ziekteverzekering)\b)/i, '1994071451', '118'],
      [/\b(?:geneesmiddel(?:en)?|medicijn(?:en)?|farmaceutische\s+specialiteit).{0,50}\bterugbeta(?:l|al)\w*\b|\bterugbeta(?:l|al)\w*.{0,50}\b(?:geneesmiddel(?:en)?|medicijn(?:en)?|farmaceutische\s+specialiteit)\b/i, '1994071451', '35bis'],
      [/\b(?:verhoogde\s+tegemoetkoming|bim-statuut|omnio)\b/i, '1994071451', '37'],
      [/\b(?:voorschrijven\s+op\s+stofnaam|voorschrift\s+op\s+stofnaam|international\s+nonproprietary\s+name)\b/i, '1994071451', '73'],

      # Arbeidsovereenkomstenwet (AOW) — high-confidence diagnosis cluster.
      [/\b(?:minimumloon|ggmmi|gewaarborgd\s+gemiddeld\s+minimum(?:maand)?inkomen|salaire\s+minimum|rmmmg|revenu\s+minimum\s+mensuel\s+moyen)\b/i, '1988050250', '3'],
      [/\b(?:minimumloon|ggmmi|gewaarborgd\s+gemiddeld\s+minimum(?:maand)?inkomen|salaire\s+minimum|rmmmg|revenu\s+minimum\s+mensuel\s+moyen)\b/i, '1988050250', '5'],
      [/\b(?:ius\s+variandi|eenzijdige?\s+(?:wijziging|wijzigen)\s+(?:van\s+)?(?:arbeidsvoorwaarden|arbeidsovereenkomst|loon|functie)|(?:loon|salaris)\s+eenzijdige?\s+(?:verlagen|verminderen|wijzigen)|eenzijdige?\s+(?:loon|salaris)\s+(?:verlagen|verminderen|wijzigen))\b/i, '1978070303', '25'],
      [EMPLOYMENT_NON_COMPETE_PATTERN, '1978070303', '65'],
      [EMPLOYMENT_NON_COMPETE_PATTERN, '1978070303', '86'],
      [/(?:\b(?:handelsvertegenwoordiger|représentant\s+de\s+commerce)\b.{0,80}\b(?:niet[-\s]?)?concurrentiebeding\b|\b(?:niet[-\s]?)?concurrentiebeding\b.{0,80}\b(?:handelsvertegenwoordiger|représentant\s+de\s+commerce)\b)/i, '1978070303', '104'],
      [/(?=.*\b(?:geheimhoudingsbeding|vertrouwelijkheidsbeding|geheimhoudingsplicht|vertrouwelijkheidsplicht|discretieplicht|clause\s+de\s+confidentialité)\b)(?=.*\b(?:werknemer|werkgever|arbeidsovereenkomst|arbeidscontract|tewerkstelling|travailleur|employeur|contrat\s+de\s+travail)\b)/i, '1978070303', '17'],
      [/(?:scholingsbeding|opleidingsbeding|clause\s+d[’']écolage)/i,   '1978070303', '22bis'],
      [/(?:deeltijds(?:e)?\s+(?:arbeids)?overeenkomst|arbeidsovereenkomst.{0,30}deeltijd)/i, '1978070303', '11bis'],
      [/\bvervangingsovereenkomst\b|contrat\s+de\s+remplacement/i,   '1978070303', '11ter'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*(?:\b(?:opeenvolgende|successieve)\b.{0,50}\b(?:arbeids?)?overeenkomsten\b|\b(?:maximumduur|duur)\b.{0,40}\b(?:bepaalde\s+tijd|durée\s+déterminée)\b))/i, '1978070303', '10'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*(?:\b(?:opeenvolgende|successieve)\b.{0,50}\b(?:arbeids?)?overeenkomsten\b|\b(?:maximumduur|duur)\b.{0,40}\b(?:bepaalde\s+tijd|durée\s+déterminée)\b))/i, '1978070303', '10bis'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*\b(?:ontslag|opzeg(?:ging|brief)|licenciement|préavis)\b)(?=.*\b(?:schriftelijk|aangetekend|deurwaarder|kennisgeving|écrit|recommandé|huissier|notification)\b)/i, '1978070303', '37'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|contrat\s+de\s+travail|travailleur|employeur)\b)(?=.*\b(?:begin(?:nen|t)?|ingang|start|commenc|début)\w*\b)(?=.*\b(?:opzeg(?:termijn|\s+termijn)|préavis)\b)/i, '1978070303', '37/1'],
      [/(?:opzeg|ontslag).{0,50}anci[eë]nniteit|anci[eë]nniteit.{0,50}(?:opzeg|ontslag)/i, '1978070303', '37/4'],
      [/\btegenopzeg\b|(?=.*\bopzeg(?:termijn|\s+termijn)\b)(?=.*\b(?:bereken(?:en|ing)?|hoeveel|anci[eë]nniteit|weken?|jaren?)\b)(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|ontslag|tewerkstelling)\b)/i, '1978070303', '37/2'],
      [/\A(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?=.*\b(?:opzeg(?:termijn|ging)|préavis)\b)(?=.*\b(?:schors\w*|suspend\w*|vakantie|ziekte|congé|maladie)\b).*\z/im, '1978070303', '38'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?:opzeg(?:gings)?vergoeding|verbrekingsvergoeding|vergoeding.{0,30}verbreking|indemnité.{0,30}(?:préavis|rupture))/i, '1978070303', '39'],
      [/(?:sollicitatieverlof|wederindiensttredingsverlof|congé\s+pour\s+chercher\s+un\s+emploi)/i, '1978070303', '41'],
      [/\b(?:controlearts|controlegeneesheer)\b|\b(?:medisch(?:e)?\s+(?:attest|getuigschrift)|ziekteattest)\b.*\b(?:werkgever|werknemer|ziekte|arbeidsongeschiktheid)\b|\b(?:werkgever|werknemer|ziekte|arbeidsongeschiktheid)\b.*\b(?:medisch(?:e)?\s+(?:attest|getuigschrift)|ziekteattest)\b|certificat\s+médical.*\b(?:employeur|travailleur|maladie|incapacité)\b/i, '1978070303', '31'],
      [/\bmedische\s+overmacht\b/i,                                '1978070303', '34'],
      [/\A(?=.*\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement)\b)(?=.*\b(?:dringende\s+reden|motif\s+grave)\b).*\z/im, '1978070303', '35'],
      [TEMPORARY_UNEMPLOYMENT_FORCE_MAJEURE_PATTERN, '1978070303', '26'],
      [TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN, '1978070303', '51'],
      [TEMPORARY_UNEMPLOYMENT_ECONOMIC_PATTERN, '1978070303', '77/1'],
      [/(?:verlof\s+om\s+dwingende\s+redenen|congé\s+pour\s+raisons\s+impérieuses)/i, '1978070303', '30bis'],
      [/(?:adoptieverlof|congé\s+d[’']adoption)/i,                     '1978070303', '30ter'],
      [/(?:pleegzorgverlof|congé\s+d[’']accueil)/i,                    '1978070303', '30quater'],
      [/(?:pleegouderverlof|congé\s+parental\s+d[’']accueil)/i,       '1978070303', '30sexies'],
      [/(?:studenten(?:contract|overeenkomst|arbeid)|jobstudent|contrat\s+d[’']étudiant)/i, '1978070303', '120'],
      [/(?:student(?:en)?(?:contract|overeenkomst).{0,30}(?:proef|proeftijd)|(?:proef|proeftijd).{0,30}student)/i, '1978070303', '127'],
      [/\b(?:proefperiode|proeftijd)\b/i, '1978070303', '127'],
      [/\b(?:proefperiode|proeftijd)\b/i, '1987012597', '5'],
      [/(?:student(?:en)?(?:contract|overeenkomst).{0,30}(?:opzeg|beëindig)|(?:opzeg|beëindig).{0,30}student)/i, '1978070303', '130'],
      [/\bwillekeurige\s+afdanking\b/i,                              '1978070303', '63'],
      # Classification turns on authority/subordination. Pin the statutory
      # employment definition so a comparison with an independent contractor
      # cannot be built from unrelated termination provisions.
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract)\b)(?=.*\b(?:aannemingsovereenkomst|aannemer|zelfstandig(?:e)?|ondergeschiktheid|gezag)\b)/i, '1978070303', '2'],
      [/(?=.*\b(?:arbeidsovereenkomst|arbeidscontract)\b)(?=.*\b(?:aannemingsovereenkomst|aannemer|zelfstandig(?:e)?|ondergeschiktheid|gezag)\b)/i, '1978070303', '3'],

      # Arbeidswet 1971
      [/(?:zondags(?:rust|arbeid|werk)|travail\s+du\s+dimanche)/i,    '1971031602', '11'],
      [/\b(?:arbeidsduur|maximale?\s+(?:werk|arbeids)uren|hoeveel\s+uur\s+(?:mag|kan)\s+(?:ik|een\s+werknemer)\s+werken|38[-\s]?urenweek)\b/i, '1971031602', '19'],
      [/(?:glijdende\s+(?:werktijd|uurroosters?)|glijtijd|horaires?\s+flexibles?)/i, '1971031602', '20ter'],
      [/\b(?:annualisering|referteperiode)\b.*\b(?:arbeidsduur|werkuren|overuren)\b|\b(?:arbeidsduur|werkuren|overuren)\b.*\b(?:annualisering|referteperiode)\b/i, '1971031602', '26bis'],
      [/\b(?:maximum|plafond|grens)\b.*\b(?:overuren|overwerk)\b|\b(?:overuren|overwerk)\b.*\b(?:maximum|plafond|grens)\b|\b(?:11\s*uur|50\s*uur)\b.*\b(?:werk|arbeid|overuren)\b/i, '1971031602', '27'],
      [/\b(?:overloon|overurenvergoeding|toeslag\s+voor\s+overuren)\b/i, '1971031602', '29'],
      [/(?:nacht(?:arbeid|werk)|travail\s+de\s+nuit)/i,               '1971031602', '35'],
      [/\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b.*\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b|\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b.*\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b/i, '1971031602', '36'],
      [/\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b.*\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b|\bnacht(?:arbeid|werk|prestaties|shift|dienst)\b.*\b(?:uitzondering(?:en)?|toegelaten|toestaan)\b/i, '1971031602', '37'],
      [/\b(?:invoeren|instellen)\b.*\bnacht(?:regeling|prestaties|arbeid)\b|\bnacht(?:regeling|prestaties|arbeid)\b.*\b(?:invoeren|instellen)\b/i, '1971031602', '38'],
      [/\b(?:pauze|rustpauze)\b.*\b(?:werk|arbeid|(?:meer\s+dan\s+)?6\s*uur)\b|\b(?:werk|arbeid|(?:meer\s+dan\s+)?6\s*uur)\b.*\b(?:pauze|rustpauze)\b/i, '1971031602', '38quater'],
      [/\b(?:prenataal|postnataal|nabevallings(?:rust|verlof)?|moederschaps(?:rust|verlof)|bevallingsverlof|zwangerschapsverlof)\b/i, '1971031602', '39'],
      [/(?:zwanger(?:schap|e)?|grossesse).{0,40}(?:ontslag|licenciement)|(?:ontslag|licenciement).{0,40}(?:zwanger(?:schap|e)?|grossesse)/i, '1971031602', '40'],
      [/\bprofylactisch\s+verlof\b|\bpreventieve\s+werkverwijdering\b|\bwerkverwijdering\b.*\b(?:zwangere?|zwangerschap|werkneemster)\b|\b(?:zwangere?|zwangerschap|werkneemster)\b.*\bwerkverwijdering\b/i, '1971031602', '42'],
      [/\b(?:zwangere?|zwangerschap|werkneemster)\b.*\bnacht(?:arbeid|werk|prestaties)\b|\bnacht(?:arbeid|werk|prestaties)\b.*\b(?:zwangere?|zwangerschap|werkneemster)\b/i, '1971031602', '43'],
      [/(?=.*\b(?:jaarlijkse\s+vakantie|vakantiedagen|betaald\s+verlof|wettelijke\s+vakantie|congés?\s+payés?)\b)(?=.*\b(?:hoeveel|aantal|dagen|duur|per\s+jaar|combien|nombre|jours|durée)\b)/i, '1971062850', '3'],

      # High-value single-article diagnosis targets.
      # Drug offences: penalties sit in the 1921 Drugs Law, while the current
      # possession/prohibition and penalty bridge are in the 2017 decree. The
      # former KB of 31 December 1930 was repealed by the 2017 decree.
      [DRUG_OFFENCE_PATTERN, '1921022450', '2bis'],
      [CANNABIS_OR_POSSESSION_PATTERN, '1921022450', '2ter'],
      [DRUG_OFFENCE_PATTERN, '2017031231', '6'],
      [DRUG_OFFENCE_PATTERN, '2017031231', '61'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '34'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '35'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '36'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '38'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '55'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '37/1'],
      [ALCOHOL_DRIVING_LIMIT_PATTERN, '1968031601', '37'],
      [/(?:onmiddellijke\s+inning|verkeersboete.{0,30}(?:betalen|inning)|perception\s+immédiate)/i, '1968031601', '65'],
      # Consumer conformity (old Civil Code) versus hidden defects. These are
      # deliberately consumer/product scoped so they do not capture financial
      # guarantees, rental deposits, or construction warranties.
      [USED_GOODS_WARRANTY_PATTERN, '1804032154', '1649quater'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:wettelijke\s+garantie|garantie\s+légale|conformiteit|non[-\s]?conformiteit|conformité|twee\s+jaar|2\s+jaar)\b)/i, '1804032154', '1649bis'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:wettelijke\s+garantie|garantie\s+légale|conformiteit|non[-\s]?conformiteit|conformité)\b)/i, '1804032154', '1649ter'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:garantie|conformiteit|conformité|gebrek|défaut)\b)(?=.*\b(?:termijn|duur|jaar|bewijs|vermoeden|délai|durée|an|preuve)\b)/i, '1804032154', '1649quater'],
      [/(?=.*\b(?:consument|koper|verkoper|product|goed|toestel|wagen|consommateur|acheteur|vendeur|produit|bien)\b)(?=.*\b(?:garantie|conformiteit|conformité|gebrek|défaut)\b)(?=.*\b(?:herstel|herstelling|vervanging|prijsvermindering|ontbinding|réparation|remplacement|réduction|résolution)\b)/i, '1804032154', '1649quinquies'],
      [/\A(?=.*\b(?:verborgen\s+gebrek|verborgen\s+gebreken|vice\s+caché|vices\s+cachés)\b)(?!.*\b(?:nieuwbouw|aannemer|architect|constructie|bouwwerk|construction|entrepreneur|architecte)\b).*\z/im, '1804032154', '1641'],
      [/\A(?=.*\b(?:verborgen\s+gebrek|verborgen\s+gebreken|vice\s+caché|vices\s+cachés)\b)(?=.*\b(?:terugbetaling|prijsvermindering|ontbinding|remboursement|réduction|résolution)\b)(?!.*\b(?:nieuwbouw|aannemer|architect|constructie|bouwwerk|construction|entrepreneur|architecte)\b).*\z/im, '1804032154', '1644'],

      # Family law (old Civil Code, Book I).
      [MAJORITY_AGE_PATTERN, '1804032150', '488'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:kind|kinderen|ouder|ouders|enfant|parent)\b)/i, '1804032150', '203'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:kind|kinderen|ouder|ouders|bijdrage|enfant|parent|contribution)\b)/i, '1804032150', '203bis'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:index|aanpassing|indexation)\b)/i, '1804032150', '203quater'],
      [/(?=.*\b(?:onderhoudsgeld|alimentatie|pension\s+alimentaire)\b)(?=.*\b(?:ex[-\s]?(?:echtgenoot|partner)|echtscheiding|divorce|ex[-\s]?(?:époux|partenaire))\b)/i, '1804032150', '301'],
      [/\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b.*\b(?:aangaan|verklaring|begin|voorwaarden|conclure|déclaration|conditions)\b|\b(?:aangaan|verklaring|begin|voorwaarden|conclure|déclaration|conditions)\b.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b/i, '1804032153', '1475'],
      [/\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b.*\b(?:verklaring|ambtenaar|burgerlijke\s+stand|déclaration|officier|état\s+civil)\b/i, '1804032153', '1476'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:rechten|plichten|kosten|schulden|woning|droits|obligations|charges|dettes|logement)\b)/i, '1804032153', '1477'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:eigendom|goederen|vermogen|propriété|biens|patrimoine)\b)/i, '1804032153', '1478'],
      [/(?=.*\b(?:wettelijke\s+samenwoning|cohabitation\s+légale)\b)(?=.*\b(?:beëindig|einde|dringende\s+maatregel|cessation|fin|mesure\s+urgente)\b)/i, '1804032153', '1479'],
      [/\b(?:ouderlijk\s+gezag|autorité\s+parentale)\b/i,             '1804032150', '371'],
      [/\b(?:ouderlijk\s+gezag|autorité\s+parentale)\b/i,             '1804032150', '373'],
      [/(?=.*\b(?:ouderlijk\s+gezag|verblijf|huisvesting|autorité\s+parentale|hébergement)\b)(?=.*\b(?:scheiding|gescheiden|ouders|séparation|parents)\b)/i, '1804032150', '374'],
      [/\b(?:contactrecht\s+(?:van\s+)?grootouders|omgangsrecht\s+(?:van\s+)?grootouders|relations\s+personnelles\s+(?:des\s+)?grands[-\s]?parents)\b/i, '1804032150', '375bis'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onherstelbare\s+ontwrichting|désunion\s+irrémédiable|voorwaarden|conditions)\b)/i, '1804032150', '229'],
      # The family home remains protected during marriage; this narrow pin is
      # useful when a divorce question expressly concerns the marital home.
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:woonrecht|echtelijke\s+woning|gezinswoning|logement\s+familial|résidence\s+familiale)\b)/i, '1804032150', '215'],

      # General lease defects: the exact residential regime remains regional,
      # but these Civil Code provisions safely anchor the general warranty and
      # urgent-repairs baseline.
      [/(?=.*\b(?:huurder|huur|huurcontract|verhuurder|bail|locataire|bailleur)\b)(?=.*\b(?:gebrek|gebreken|herstelling|herstellingen|defect|défaut|vice|réparation)\b)/i, '1804032154', '1721'],
      [/(?=.*\b(?:huurder|huur|huurcontract|verhuurder|bail|locataire|bailleur)\b)(?=.*\b(?:gebrek|gebreken|herstelling|herstellingen|defect|défaut|vice|réparation)\b)/i, '1804032154', '1724'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1804032150', '230'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1967101055', '1287'],
      [/(?=.*\b(?:echtscheiding|divorce)\b)(?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)/i, '1967101055', '1288'],
      [/(?=.*\b(?:adoptie|adoption)\b)(?=.*\b(?:voorwaarden|leeftijd|toestemming|conditions|âge|consentement)\b)/i, '1804032150', '343'],
      [/\b(?:bewindvoering|bewindvoerder|beschermde\s+persoon|administration\s+des\s+biens|administrateur\s+de\s+la\s+personne)\b/i, '1804032150', '488/1'],

      # Occupational risks.
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:wanneer|definitie|erken|voorwaarden|quand|définition|reconnaître|conditions)\b)/i, '1971041001', '7'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:oorzaak|uitvoering|overkomen|cause|exécution|survenu)\b)/i, '1971041001', '9'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:vergoeding|arbeidsongeschiktheid|loon|indemnité|incapacité|rémunération)\b)/i, '1971041001', '24'],
      [/(?=.*\b(?:arbeidsongeval|accident\s+du\s+travail)\b)(?=.*\b(?:aangifte|melden|termijn|déclaration|signaler|délai)\b)/i, '1971041001', '62'],
      [/\b(?:beroepsziekte|beroepsziekten|maladie\s+professionnelle|maladies\s+professionnelles)\b/i, '1970060309', '30'],
      [/\b(?:beroepsziekte|beroepsziekten|maladie\s+professionnelle|maladies\s+professionnelles)\b/i, '1970060309', '30bis'],

      # Motor liability insurance and business registers.
      [/(?=.*\b(?:autoverzekering|verzekering\s+burgerlijke\s+aansprakelijkheid|assurance\s+responsabilité\s+civile)\b)(?=.*\b(?:verplicht|voertuig|obligatoire|véhicule)\b)/i, '1989011371', '2'],
      [/(?=.*\b(?:onverzekerd|zonder\s+verzekering|non\s+assuré|sans\s+assurance)\b)(?=.*\b(?:voertuig|rijden|véhicule|conduire)\b)/i, '1989011371', '22'],
      [/\b(?:zwakke\s+weggebruiker|usager\s+faible)\b/i,             '1989011371', '29bis'],
      [/(?=.*\b(?:onverzekerd|onbekend\s+voertuig|non\s+assuré|véhicule\s+inconnu)\b)(?=.*\b(?:fonds|vergoeding|indemnisation)\b)/i, '1989011371', '19bis-11'],

      # Book 4 Civil Code replaced the old testament-form articles in 2022.
      # Art. 4.184 is explicitly the international-form provision in the
      # current canonical NL corpus.
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.180'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.181'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.183'],
      [TESTAMENT_FORM_PATTERN, '2022B30600', '4.184'],

      # Private/supplementary hospitalisation policies. Articles 201-206 are
      # supplied as the governing cluster, while the order favours the more
      # specific duration or waiting-period provisions. A pin is evidence to
      # inspect, never proof that a particular policy grants the claimed term.
      [HOSPITALISATION_WAITING_PATTERN, '2014011239', '205'],
      [HOSPITALISATION_WAITING_PATTERN, '2014011239', '206'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '201'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '202'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '203'],
      [HOSPITALISATION_DURATION_PATTERN, '2014011239', '204'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '201'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '202'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '203'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '204'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '205'],
      [HOSPITALISATION_POLICY_PATTERN, '2014011239', '206'],

      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '73'],
      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '74'],
      [/\b(?:ubo[-\s]register|registre\s+ubo|uiteindelijk\s+begunstigde|bénéficiaire\s+effectif)\b/i, '2017013368', '75'],
      [/(?=.*\b(?:kbo|kruispuntbank\s+van\s+ondernemingen|bce|banque-carrefour\s+des\s+entreprises)\b)(?=.*\b(?:inschrij|registr|nummer|identifier|immatricul)\w*\b)/i, '2013A11134', 'III.15'],
      [ONLINE_CONSUMER_RIGHTS_PATTERN, '2013A11134', 'VI.47'],
      [/(?=.*\b(?:online|webshop|internet|op\s+afstand|afstandsovereenkomst|en\s+ligne|vente\s+à\s+distance|contrat\s+à\s+distance|distance\s+(?:contract|sale)|online\s+purchase)\b)(?=.*\b(?:herroepingsrecht|droit\s+de\s+rétractation|retour(?:neren)?|terugsturen|herroepen|rétracter|retourner|withdraw\w*)\b)/i, '2013A11134', 'VI.47'],
      [/\bontslagmotivering\b|\bmotiveringsplicht\b.{0,60}\b(?:ontslag|werkgever|werknemer)\b|\b(?:ontslag|werkgever|werknemer)\b.{0,60}\bmotiveringsplicht\b|\b(?:motivering|reden(?:en)?)\s+(?:voor|van)\s+(?:mijn\s+)?ontslag\b/i, '2014A01545', '3'],
      [/\bkennelijk\s+onredelijk\s+ontslag\b.*\b(?:vergoeding|schade|weken)\b|\b(?:vergoeding|schade|weken)\b.*\bkennelijk\s+onredelijk\s+ontslag\b/i, '2014A01545', '9'],
      [/\bkennelijk\s+onredelijk\s+ontslag\b|\blicenciement\s+manifestement\s+déraisonnable\b/i, '2014A01545', '8'],

      # Werkloosheidsbesluit — high-confidence diagnosis cluster.
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '30'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '44'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '56'],
      [UNEMPLOYMENT_CONDITIONS_PATTERN, '1991013192', '58'],
      [UNEMPLOYMENT_AVAILABILITY_PATTERN, '1991013192', '56'],
      [UNEMPLOYMENT_AVAILABILITY_PATTERN, '1991013192', '58'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '92'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '93'],
      [UNEMPLOYMENT_TRAINING_EXEMPTION_PATTERN, '1991013192', '94'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '51'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '52'],
      [UNEMPLOYMENT_FAULT_DISMISSAL_PATTERN, '1991013192', '53'],

      # Federal VAT Code — small-enterprise exemption/franchise.
      [VAT_SMALL_ENTERPRISE_EXEMPTION_PATTERN, '1969070305', '56bis'],

      # Consumer debt settlement is judicial procedure, not enterprise bankruptcy.
      [/\b(?:collectieve\s+schuldenregeling|règlement\s+collectif\s+de\s+dettes)\b/i, '1967101056', '1675/2'],
      [/(?:\bfaillissement\b.{0,60}\b(?:onderneming|vennootschap|handelaar)\b|\b(?:onderneming|vennootschap|handelaar)\b.{0,60}\bfaillissement\b)/i, '2013A11134', 'XX.99'],

      # Regional tax competence. Succession and registration duties are REGIONAL taxes, and
      # for them the region sets the rate, the base and the exemptions while the federal
      # text is residual — so an answer that gives a figure without naming a gewest is
      # quoting a rate that may apply nowhere.
      #
      # These are pinned rather than left to retrieval because the citation has to survive
      # the guards: an /laws/1989021010 link whose law was not retrieved is stripped by
      # LinkGuard, and the bare "art. 3" left behind is then reported as an unsupported
      # citation. Pinning is what makes the statement quotable at all.
      [REGIONAL_TAX_COMPETENCE_PATTERN, '1989021010', '3'],
      [REGIONAL_TAX_COMPETENCE_PATTERN, '1989021010', '4'],
    ].freeze

    # Deployment tooling must validate the complete target surface, not a
    # hand-maintained subset of laws that happened to need a repair import.
    # Keep this derived from ARTICLE_PINS so a new pin is automatically part of
    # the readiness contract. The historical 1867 Criminal Code targets are
    # the only pins that may intentionally resolve through an abolished law.
    ARTICLE_PIN_TARGETS = ARTICLE_PINS
                          .map { |_pattern, numac, article_number| [numac, article_number].freeze }
                          .uniq
                          .sort
                          .freeze
    ARTICLE_PIN_ALLOWED_ABOLISHED_TARGETS = ARTICLE_PIN_TARGETS
                                             .select { |numac, _article_number| numac == '1867060850' }
                                             .freeze
    ZIV_ARTICLE_PIN_TARGETS = ARTICLE_PIN_TARGETS
                              .select { |numac, _article_number| numac == '1994071451' }
                              .freeze

    def self.article_pin_targets
      ARTICLE_PIN_TARGETS
    end

    def pinned_articles(question)
      matched = matching_article_pins(question)
      return [] if matched.empty?

      matched.filter_map do |_rx, numac, artnum|
        normalized_title = "Art#{artnum}".delete(' .').downcase
        art = ::Article
              .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                      'legislation.is_abolished, legislation.is_modification')
              .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
              .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
              .where(content_numac: numac, language_id: @language_id)
              .where("LOWER(REPLACE(REPLACE(article_title, ' ', ''), '.', '')) = ?", normalized_title)
              .first
        unless art
          Rails.logger.warn("[ArticlePins] target missing: #{numac} Art. #{artnum} (language #{@language_id})")
          next
        end

        {
          id: art.id, numac: art.content_numac,
          law_title: art.law_title || lookup_law_title(numac, @language_id) || "Wetgeving #{numac}",
          article_title: art.article_title, article_text: art.article_text,
          article_variant: art.try(:article_variant),
          language_id: art.language_id, similarity: 99.0, pinned: true,
          is_abolished: art.try(:is_abolished) == 1, is_modification: art.try(:is_modification) == 1
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[ArticlePins] skipped: #{e.class}")
      []
    end

    # Extract keywords from a legal question (bilingual NL/FR + cross-lingual)
    def extract_keywords(question)
      # Multilingual stop words. Without the FR/EN/DE set, filler such as
      # "quelle procédure pour" consumed the four-word fallback before the
      # legally meaningful noun reached FTS.
      stop_words = %w[
        wat is de het een op van voor met als in door bij hoe kan mag moet waar wanneer welke wie waarom hoeveel zijn mijn ik
        recht hebben rechten onder aan naar tot dit deze die dat jaar jaren
        le la les un une des du de au aux en est ce que qui quoi quel quelle quels quelles pour avec dans par sur sous comment procédure
        peut peux puis doit dois où quand pourquoi combien mon ma mes votre vos son sa ses cette ces être avoir
        the a an of on for with in into from by as is are was were be been this that these those what which who where when why
        how can could may must should do does my your his her their our
        der die das ein eine einer eines den dem des und oder zu zum zur im in auf von mit für als ist sind war waren sein
        was wie wer wo wann warum welche welcher welches kann darf muss soll mein meine ihr ihre
      ]

      # Legal term mappings: user term → [search terms with synonyms]
      legal_terms = build_legal_term_map

      # Find matching legal terms
      phrases = []
      legal_terms.each do |pattern, terms|
        match = if pattern.is_a?(Regexp)
                  question =~ pattern
                else
                  question.downcase.include?(pattern.to_s.downcase)
                end
        phrases += terms if match
      end

      # Extract meaningful words as fallback
      important_short = %w[btw rsz cao ziv igo bob rva wet kb mb bw]
      words = question.downcase.scan(/[[:alnum:]]+/)
      keywords = words.select { |w| (w.length >= 4 || important_short.include?(w)) && !stop_words.include?(w) }

      # Combine: prioritize legal terms, add keywords
      result = phrases.compact.uniq
      result += keywords.take(4) if result.length < 3

      # Apply QUERY_EXPANSIONS for additional synonyms
      expanded = []
      result.each do |term|
        expanded << term
        expanded.concat(QUERY_EXPANSIONS[term.downcase]) if QUERY_EXPANSIONS[term.downcase]
      end

      expanded.uniq.take(12)
    end

    # Find articles by keyword search (FTS5 with LIKE fallback)
    def find_by_keywords(keywords, limit: 5)
      return [] if keywords.empty?

      articles = find_by_keywords_fts(keywords, limit)
      return articles if articles.any?

      find_by_keywords_like(keywords, limit)
    end

    # Merge semantic and lexical results while reserving a small lexical slice.
    # FTS is especially valuable for terminology/morphology misses; without the
    # quota, high-scoring semantic neighbours can push every lexical hit out of
    # the context before the title relevance filter gets to inspect it.
    def merge_search_results(embedding_results, keyword_results, limit: 15, lexical_quota: 3)
      seen_ids = Set.new
      semantic = []

      embedding_results.each do |result|
        next if seen_ids.include?(result[:id])

        seen_ids.add(result[:id])
        semantic << result
      end

      semantic_by_id = semantic.index_by { |result| result[:id] }
      lexical_seen = Set.new
      lexical = keyword_results.filter_map do |result|
        next if lexical_seen.include?(result[:id])

        lexical_seen.add(result[:id])
        # A lexical hit may also be a low-ranked semantic hit. It still needs
        # to consume one lexical-quota slot; otherwise marking every semantic
        # ID as seen before truncation silently defeats the vocabulary rescue.
        (semantic_by_id[result[:id]] || result).merge(keyword_hit: true)
      end

      lexical_keep = lexical.take([lexical_quota, limit].min)
      lexical_ids = lexical_keep.to_set { |result| result[:id] }
      semantic_keep = semantic.reject { |result| lexical_ids.include?(result[:id]) }
                              .take([limit - lexical_keep.length, 0].max)
      (semantic_keep + lexical_keep).sort_by { |result| -result[:similarity] }
    end

    # Future law (TOEKOMSTIG RECHT / DROIT FUTUR) is enacted but NOT YET IN FORCE. Drop a
    # row that IS future law; cut the trailing future block off a row that merely carries
    # one, keeping its in-force half.
    #
    # This has to happen on the way OUT rather than in the SELECTs. normalize_article_number
    # strips the marker from an article number, so once a row is keyed a future variant is
    # indistinguishable from the in-force article it shadows - same anchor, same
    # citation-repair key. And validate_answer_quotes would then certify a blockquote taken
    # from it, because verification is verbatim presence in the source text.
    #
    # See docs/ops/future-law-in-retrieval-2026-08-07.md.
    def sanitize_future_law(articles)
      Array(articles).filter_map do |article|
        next if LegalChatbot::FutureLaw.row_future?(variant: article[:article_variant],
                                                    title: article[:article_title])

        in_force, future_block = LegalChatbot::FutureLaw.split(article[:article_text])
        next if in_force.nil?          # the marker opens the text: the whole row is future law
        next article if future_block.nil?

        article.merge(
          article_text: in_force,
          future_amendment: true,
          future_effective_date: LegalChatbot::FutureLaw.effective_date(future_block)
        )
      end
    end

    def retain_final_search_quota(results, limit:, lexical_quota: 3)
      pins = results.select { |result| result[:pinned] }.take(limit)
      remaining = results.reject { |result| pins.include?(result) }
      lexical = remaining.select { |result| result[:keyword_hit] }
                         .take([lexical_quota, limit - pins.length].min)
      semantic = remaining.reject { |result| lexical.include?(result) }
                          .take(limit - pins.length - lexical.length)

      (pins + semantic + lexical)
        .sort_by { |result| result[:pinned] ? -Float::INFINITY : -result[:similarity].to_f }
        .take(limit)
    end

    # Filter articles by title relevance to the question
    def filter_by_title_relevance(articles, question)
      question_lower = question.downcase
      # scan (not split) strips punctuation so 'verkoop?' matches title word
      # 'verkoop'; keep important short legal tokens ('btw', 'cao', ...) that
      # the length cut used to discard — dropping 'btw' filtered every real
      # VAT hit out of context.
      important_short = %w[btw rsz cao ziv igo bob rva wet kb mb bw wib tva]
      question_words = question_lower.scan(/[[:alnum:]]+/)
                                     .select { |w| w.length > 3 || important_short.include?(w) }
      topic_keywords = extract_topic_keywords(question_lower)

      lnk_articles = []
      substantive_articles = []

      articles.each do |article|
        article_title = article[:article_title] || ''
        if article_title.start_with?('LNK') || article_title =~ /^(HOOFDSTUK|CHAPITRE|AFDELING|SECTION|TITEL|TITRE)\b/i
          lnk_articles << article
        else
          substantive_articles << article
        end
      end

      filtered = substantive_articles.select do |article|
        title = (article[:law_title] || '').downcase
        next true if CORE_LAW_NUMACS.key?(article[:numac])

        title_words = title.scan(/[[:alnum:]]+/)
        has_topic_match = topic_keywords.any? { |kw| title.include?(kw) }
        has_word_overlap = question_words.intersect?(title_words)
        # A strong vector match bypasses lexical title filtering. Threshold is
        # cosine (0..1) since the 2026-07-13 metric-aware serve; the old 1.5
        # was a squared-L2 distance and, under cosine, unreachable (dead code
        # that let the LEAST similar articles through when it did the distance).
        high_similarity = article[:similarity] >= 0.55

        has_topic_match || has_word_overlap || high_similarity
      end

      if filtered.length >= 5
        filtered
      else
        filtered + lnk_articles.take(5 - filtered.length)
      end
    end

    # Build context from legislation articles
    def build_context(articles)
      seen_preambles = Set.new

      articles.take(12).map do |article|
        numac = article[:numac]
        window = CORE_LAW_NUMACS.key?(numac) ? 5000 : 3000
        text = ensure_utf8(extract_relevant_window(ensure_utf8(article[:article_text]), ensure_utf8(article[:article_title]), window_size: window))

        warnings = []
        warnings << '[OPGEHEVEN/ABROGÉ]' if article[:is_abolished]

        # Check article_modifications for specific article abolition.
        # The column stores title strings ("Art. 37/2"), so pass the real title —
        # the old digits-only key ("372") never matched and conflated Art. 37/2
        # with Art. 372.
        #
        # DORMANT: article_modifications holds 0 rows in production (measured
        # 2026-08-15) and nothing in the codebase writes it, so this warning has
        # never been emitted. The code is correct and kept for when a source
        # exists; per-article abolition dates would have to come from Justel,
        # which the updater does not extract today. Abolition is still surfaced
        # by the two coarser signals below - the text-marker regex and the
        # UpdatedLaw joins - so the gap is precision, not silence.
        art_title = article[:article_title].to_s.strip
        if art_title.present?
          begin
            abolition_date = ArticleModification.abolition_date(numac, art_title, @language_id)
            warnings << "[ARTIKEL OPGEHEVEN OP #{abolition_date}]" if abolition_date
          rescue StandardError => e
            Rails.logger.debug("ArticleModification check failed: #{e.class}")
          end
        end

        warnings << '[BEPALING MOGELIJK OPGEHEVEN - controleer actuele status]' if text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt|vervallen)\b/i

        exdec_count = begin
          Exdec.where(content_numac: numac, language_id: @language_id).count
        rescue StandardError
          0
        end
        warnings << "[HEEFT #{exdec_count} UITVOERINGSBESLUITEN]" if exdec_count.positive?

        begin
          updating_base = UpdatedLaw
                          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
                          .where(content_numac: numac, language_id: @language_id)

          update_count = updating_base.count
          warnings << "[GEWIJZIGD DOOR #{update_count} WETTEN]" if update_count.positive?

          abolition_laws = updating_base.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
          warnings << '[BEVAT OPGEHEVEN BEPALINGEN - controleer actuele status]' if abolition_laws.any?
        rescue StandardError => e
          Rails.logger.debug("Error checking modifications: #{e.class}")
        end

        warning_str = warnings.any? ? " #{warnings.join(' ')}" : ''

        preamble_text = ''
        if article[:preamble].present? && !seen_preambles.include?(numac)
          seen_preambles.add(numac)
          preamble_text = "\n[PARLEMENTAIRE CONTEXT: #{article[:preamble].to_s[0..300]}]"
        end

        "[WET NUMAC #{numac}#{warning_str}] #{article[:law_title]}\n#{article[:article_title]}\n#{text}#{preamble_text}"
      end.join("\n\n---\n\n")
    end

    # Format legislation sources for response
    def format_sources(articles)
      sources = articles.map do |article|
        numac = article[:numac]
        article_anchor = article[:article_title].to_s.parameterize.presence

        source = {
          numac: numac,
          law_title: ensure_utf8(article[:law_title]),
          article_title: ensure_utf8(article[:article_title]),
          url: article_anchor ? "/laws/#{numac}##{article_anchor}" : "/laws/#{numac}",
          language: article[:language_id] == 1 ? 'NL' : 'FR',
          relevance: [article[:similarity].round(3), 1.0].min
        }
        source[:abolished] = true if article[:is_abolished]

        if article[:article_text].present?
          clean_text = ensure_utf8(article[:article_text])
          excerpt = clean_text.gsub(/\s+/, ' ').strip[0..200]
          excerpt += '...' if clean_text.length > 200
          source[:excerpt] = excerpt
        end

        begin
          exdec_count = Exdec.where(content_numac: numac, language_id: @language_id).count
          source[:exdec_count] = exdec_count if exdec_count.positive?

          updating_laws = UpdatedLaw
                          .joins("LEFT JOIN legislation ON updated_laws.update_numac = legislation.numac AND legislation.language_id = #{@language_id}")
                          .where(content_numac: numac, language_id: @language_id)

          update_count = updating_laws.count
          source[:modification_count] = update_count if update_count.positive?

          abolition_laws = updating_laws.where("legislation.title LIKE '%ophef%' OR legislation.title LIKE '%afschaf%' OR legislation.title LIKE '%intrekk%'")
          source[:has_abolitions] = true if abolition_laws.any?
        rescue StandardError => e
          Rails.logger.debug("Error in format_sources: #{e.class}")
        end

        source
      end

      # Filter out noise sources below minimum relevance threshold.
      # relevance = min(boosted_similarity, 1.0) on the cosine scale (metric-
      # aware serve, 2026-07-13). Core laws are boosted (>=2x) so they cap at
      # 1.0 and clear MIN_SOURCE_RELEVANCE trivially; the non-core floor
      # (0.45 cosine) keeps genuinely relevant matches (~0.45-0.62) and drops
      # only noise. The old 0.8 was calibrated to a squared-L2 distance and,
      # once similarity became cosine, culled EVERY non-core source.
      good_sources = sources.select do |s|
        s[:relevance] >= if CORE_LAW_NUMACS.key?(s[:numac])
                           MIN_SOURCE_RELEVANCE
                         else
                           NONCORE_SOURCE_RELEVANCE
                         end
      end
      if good_sources.length >= 2
        dropped = sources.length - good_sources.length
        Rails.logger.info("Source relevance filter: dropped #{dropped} sources below threshold") if dropped.positive?
        good_sources
      else
        # A failed floor used to return EVERYTHING, so the filter waived
        # itself exactly when retrieval was noisiest. Degrade to the best two
        # instead: the user sees the least-bad candidates rather than a dozen
        # noise sources presented as support (decision A,
        # docs/ops/legal-merit-fixes-2026-08-03.md). Loud log on purpose: if a
        # future similarity-scale migration miscalibrates these floors again
        # (as the 2026-07-13 cosine switch did), this line is the tripwire,
        # where the old return-everything branch hid the regression.
        Rails.logger.warn(
          "Source relevance filter: only #{good_sources.length} of #{sources.length} " \
          'sources cleared the floor; returning the best 2 by relevance'
        )
        # Floor-passers first: a plain max_by(2) ranked by raw relevance and
        # could drop the one CORE source that cleared its 0.30 floor in favour
        # of two non-core sources that failed their 0.45 floor (review
        # finding, 2026-08-03). The degraded set must always contain every
        # survivor before any failer.
        (good_sources + (sources - good_sources).sort_by { |s| -s[:relevance].to_f }).first(2)
      end
    end

    # Inject abolished topic warnings into context
    def inject_abolished_warnings(question, context)
      q = question.downcase
      warnings = []

      if q.include?('proefperiode') || q.include?('proeftijd')
        warnings << <<~WARN
          [OPGELET] KRITIEKE CONTEXT VOOR DEZE VRAAG:
          De PROEFPERIODE voor gewone arbeidsovereenkomsten is AFGESCHAFT sinds 1 januari 2014 (Wet Eenheidsstatuut).
          De bronnen hieronder kunnen verwijzen naar een 3-dagen proefperiode, maar dit geldt ALLEEN voor:
          - Uitzendarbeid (interim)
          - Studentencontracten
          Dit is NIET de algemene regel. Begin je antwoord met de afschaffing in 2014, daarna pas de uitzonderingen.
        WARN
      end

      if q.include?('carensdag')
        warnings << <<~WARN
          [OPGELET] KRITIEKE CONTEXT VOOR DEZE VRAAG:
          De CARENSDAG is AFGESCHAFT sinds 1 januari 2014.
          Vroeger: eerste ziektedag onbetaald. Nu: eerste ziektedag WEL betaald (gewaarborgd loon vanaf dag 1).
          Begin je antwoord met deze afschaffing.
        WARN
      end

      # Regional topics
      regional_parts = build_regional_warnings(q)

      if regional_parts.any?
        warnings << <<~WARN
          [OPGELET] DIT IS EEN REGIONAAL ONDERWERP:
          België heeft 3 gewesten met verschillende wetgeving. Vermeld het relevante gewest.
          #{regional_parts.join("\n")}
        WARN
      end

      return context if warnings.empty?

      "#{warnings.join("\n")}\n\n---\nBRONNEN (let op: kunnen verouderde info bevatten):\n#{context}"
    end

    # Detect if a question is tax-related
    def tax_question?(question_lower)
      LegalChatbot::FisconetSearch.tax_question?(question_lower)
    end

    # Fetch specific articles BY NUMBER from laws that were already retrieved
    # for this question. This exists because retrieval routinely returns the
    # right law and misses the article the answer needs: of 89 citations
    # CitationGuard rejected in the 2026-07-29 sample, 77 (87%) were articles
    # that existed in a law the same search had returned - "Art. 37/2" of the
    # Arbeidsovereenkomstenwet for a dismissal question, for example.
    #
    # Deliberately narrow. `numacs` must be laws retrieved this turn, so this
    # can only deepen existing evidence, never introduce a new law the search
    # did not justify. Numbers are matched the same way article pins are
    # (spaces and dots removed), and the result hashes are the same shape as
    # search hits so the context builder, formatter and guards treat them
    # identically. A number that does not exist in any of those laws simply
    # yields nothing, leaving the citation unsupported and the guard's
    # rejection intact.
    def fetch_articles_by_number(numacs:, article_numbers:, limit: 5)
      numacs = Array(numacs).compact.uniq
      wanted = Array(article_numbers).compact.uniq.first(limit)
      return [] if numacs.empty? || wanted.empty?

      by_normalized = wanted.to_h { |number| [normalized_article_key(number), number] }
      rows = ::Article
             .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                     'legislation.is_abolished, legislation.is_modification')
             .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
             .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
             .where(content_numac: numacs, language_id: @language_id)
             .where(
               "LOWER(REPLACE(REPLACE(articles.article_title, ' ', ''), '.', '')) IN (?)",
               by_normalized.keys
             )
             .limit(limit * numacs.length)
             .to_a

      # Keep retrieval order: the earliest-ranked law wins a number, and each
      # requested number contributes at most one article.
      rank = numacs.each_with_index.to_h
      rows.sort_by! { |row| [rank.fetch(row.content_numac, numacs.length), row.id] }
      seen = {}
      rows.each do |row|
        key = normalized_article_key(row.article_title)
        next unless by_normalized.key?(key)
        next if seen.key?(key)

        seen[key] = {
          id: row.id, numac: row.content_numac,
          law_title: row.law_title || lookup_law_title(row.content_numac, @language_id) ||
                     "Wetgeving #{row.content_numac}",
          article_title: row.article_title, article_text: row.article_text,
          article_variant: row.try(:article_variant),
          language_id: row.language_id, similarity: 0.0, cited_repair: true,
          is_abolished: row.try(:is_abolished) == 1,
          is_modification: row.try(:is_modification) == 1
        }
      end
      # Second pass for the numbers the exact-title SQL could not resolve.
      # Real titles carry suffixes the equality match can never see -
      # "Art. 37/2, par. 1", annotation tails, separator variants - so a
      # repairable citation stayed rejected even though the article sits in a
      # retrieved law (2026-08-04 withheld-answer mining: the largest wrong-
      # withhold cluster). This sweep reads TITLES ONLY for the same laws,
      # extracts each title's own number token, and compares through the same
      # normalization - an exact compare, never prefix matching, so "Art. 37"
      # cannot resolve to "Art. 370". TOEKOMSTIG RECHT variants are excluded:
      # citing future-law text as current law is the obsolete-version hazard,
      # not a repair.
      unresolved = by_normalized.keys.reject { |key| seen.key?(key) }
      if unresolved.any?
        title_rows = ::Article
                     .select(:id, :article_title, :content_numac)
                     .where(content_numac: numacs, language_id: @language_id)
                     .to_a
        rank = numacs.each_with_index.to_h
        matches = title_rows.filter_map do |row|
          key = article_number_key_from_title(row.article_title)
          next if key.nil? || !unresolved.include?(key)

          [key, row]
        end
        matches.sort_by! { |_key, row| [rank.fetch(row.content_numac, numacs.length), row.id] }
        chosen = {}
        matches.each { |key, row| chosen[key] ||= row.id }
        if chosen.any?
          ::Article
            .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                    'legislation.is_abolished, legislation.is_modification')
            .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
            .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
            .where(id: chosen.values)
            .each do |row|
              key = chosen.key(row.id)
              next if key.nil? || seen.key?(key)

              seen[key] = {
                id: row.id, numac: row.content_numac,
                law_title: row.law_title || lookup_law_title(row.content_numac, @language_id) ||
                           "Wetgeving #{row.content_numac}",
                article_title: row.article_title, article_text: row.article_text,
                article_variant: row.try(:article_variant),
                language_id: row.language_id, similarity: 0.0, cited_repair: true,
                is_abolished: row.try(:is_abolished) == 1,
                is_modification: row.try(:is_modification) == 1
              }
            end
        end
      end

      Rails.logger.info(
        "[CitationRepair] resolved #{seen.size}/#{wanted.length} cited articles from #{numacs.length} retrieved laws"
      )
      # Not optional. This method never passes through #search, and the orchestrator splices
      # its output straight into leg_articles AFTER the quality filters have run. It is also
      # the likeliest path to surface a future variant, precisely because it goes looking for
      # articles retrieval did not return.
      sanitize_future_law(seen.values)
    rescue StandardError => e
      Rails.logger.warn("[CitationRepair] lookup skipped: #{e.class}")
      []
    end

    def normalized_article_key(value)
      value.to_s.sub(/\A\s*Art(?:ikel|icle)?s?\.?\s*/i, '')
           .then { |number| "art#{number}" }
           .delete(' .')
           .downcase
    end

    # Public seam for the title-token extraction the repair fallback relies
    # on, so the exact-compare guarantee is unit-testable without a database.
    def article_number_key_from_title(title)
      return nil if title.to_s.match?(/TOEKOMSTIG\s+RECHT/i)

      token = title.to_s[/\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w\/.:\-]*)/i, 1]
      return nil if token.blank?

      normalized_article_key(token)
    end

    private

    # ------------------------------------------------------------------
    # FAISS SEARCH
    # ------------------------------------------------------------------

    def legislation_faiss_enabled?
      ENV.fetch(FAISS_ENABLED_ENV, 'false').strip.casecmp?('true')
    end

    # Call FAISS service for fast article similarity search
    def search_faiss(question_embedding, limit)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: 5, read_timeout: 10) do |http|
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        Rails.logger.info("FAISS article search completed in #{data['search_time_ms']&.round(1)}ms (searched #{data['total_indexed']} articles)")

        article_ids = data['results'].map { |r| r['article_id'] }
        articles_by_id = Article
                         .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, legislation.date, legislation.is_abolished, legislation.is_modification')
                         .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
                         .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
                         .where(id: article_ids, language_id: CANONICAL_LANGUAGE_IDS)
                         .index_by(&:id)

        data['results'].map do |result|
          article = articles_by_id[result['article_id']]
          next unless article

          adjusted_similarity = article.language_id == @language_id ? result['similarity'] * 1.20 : result['similarity']

          {
            id: article.id,
            numac: article.content_numac,
            law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
            article_title: article.article_title,
            article_text: article.article_text,
            article_variant: article.try(:article_variant),
            language_id: article.language_id,
            similarity: adjusted_similarity,
            is_abolished: article.try(:is_abolished) == 1,
            is_modification: article.try(:is_modification) == 1
          }
        end.compact.sort_by { |a| -a[:similarity] }
      else
        Rails.logger.error("FAISS article service error: #{response.code} #{response.message}")
        nil
      end
    rescue StandardError => e
      Rails.logger.debug("FAISS article service unavailable: #{e.class}")
      nil
    end

    # ------------------------------------------------------------------
    # KEYWORD SEARCH
    # ------------------------------------------------------------------

    def find_by_keywords_fts(keywords, limit)
      match_expr = fts_exact_match_expression(keywords)
      return [] if match_expr.blank?

      article_ids = nil
      fts_search_database_paths.each do |search_path|
        begin
          db = fts_search_database(search_path)
          # A dedicated search database intentionally contains only the
          # extracted FTS/ngram tables, not `articles`. Pull a bounded BM25
          # window from FTS, then filter its rowids through the primary laws DB
          # while preserving rank. The helper expands the window when one
          # language dominates the top.
          article_ids = fts_ranked_article_ids(db, match_expr, limit * 3)

          # Exact phrase terms are precise, but Belgian legal vocabulary often
          # differs only by inflection (verjaring/verjaren, belaging/belaagd).
          # Supplement sparse exact results with conservative FTS prefix terms.
          if article_ids.length < limit
            stem_expr = fts_stemmed_match_expression(keywords)
            if stem_expr.present?
              stem_ids = fts_ranked_article_ids(db, stem_expr, limit * 3)
              added = stem_ids.reject { |id| article_ids.include?(id) }
              article_ids.concat(added)
              Rails.logger.info("[Search] FTS5 stem supplement added #{added.length} candidates") if added.any?
            end
          end
          break if article_ids.any?

          Rails.logger.info("[Search] No FTS5 hits in #{File.basename(search_path)}, trying fallback")
        rescue StandardError => e
          close_fts_search_database
          Rails.logger.warn("[Search] FTS5 error in #{File.basename(search_path)} (#{e.class}), trying fallback")
        end
      end

      if article_ids.nil?
        Rails.logger.warn('[Search] No usable FTS5 database found, falling back to LIKE')
        return []
      end

      return [] if article_ids.empty?

      articles_by_id = keyword_articles_with_metadata
                       .where(articles: { id: article_ids, language_id: @language_id })
                       .index_by(&:id)
      articles = article_ids.filter_map { |id| articles_by_id[id] }

      Rails.logger.info("[Search] FTS5 keyword search found #{articles.length} articles")

      articles.each_with_index.filter_map do |article, rank|
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          # Without these, a keyword-retrieved REPEALED article reached the
          # answer without the [OPGEHEVEN/ABROGÉ] warning the FAISS path adds.
          is_abolished: article.try(:is_abolished) == 1,
          is_modification: article.try(:is_modification) == 1,
          # Keep BM25 order meaningful when results are fused with FAISS.
          # This is intentionally below article pins (99.0) and conservative
          # versus a strong semantic match, while retaining lexical recall.
          similarity: [0.82 - (rank * 0.02), 0.65].max,
          keyword_rank: rank + 1
        }
      end.compact.take(limit)
    end

    # Prefer an explicitly configured search DB. Without one, prefer the
    # primary laws DB because current importers build articles_fts there; a
    # historical storage/search.sqlite3 file is the final compatibility
    # fallback and must not silently shadow the current laws database.
    def fts_search_database_paths
      configured_path = ENV.fetch('SEARCH_DB_PATH', nil).presence
      [configured_path, primary_fts_search_database_path, default_fts_search_database_path]
        .compact
        .map { |path| File.expand_path(path) }
        .select { |path| File.file?(path) }
        .uniq
    rescue StandardError => e
      Rails.logger.warn("[Search] Could not resolve FTS5 database paths: #{e.class}")
      []
    end

    def default_fts_search_database_path
      Rails.root.join('storage', 'search.sqlite3').to_s
    end

    def primary_fts_search_database_path
      Article.connection_db_config.database.to_s.presence
    end

    # Puma reuses worker threads. Bind the cached read-only connection to both
    # its resolved path and the file generation. Updaters install databases by
    # atomic rename, so a path-only cache can otherwise keep querying the old
    # inode after the pathname starts referring to the replacement database.
    def fts_search_database(path)
      resolved_path = File.expand_path(path)
      generation = fts_search_database_generation(resolved_path)
      cached_db = Thread.current[:search_db]
      cached_path = Thread.current[:search_db_path]
      cached_generation = Thread.current[:search_db_generation]
      if cached_db && cached_path == resolved_path && cached_generation == generation
        return cached_db
      end

      close_fts_search_database
      Thread.current[:search_db] = SQLite3::Database.new(resolved_path, readonly: true)
      Thread.current[:search_db_path] = resolved_path
      Thread.current[:search_db_generation] = generation
      Thread.current[:search_db]
    end

    def fts_search_database_generation(path)
      stat = File.stat(path)
      [
        stat.dev,
        stat.ino,
        stat.size,
        (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec
      ]
    end

    def close_fts_search_database
      Thread.current[:search_db]&.close
    rescue StandardError
      nil
    ensure
      Thread.current[:search_db] = nil
      Thread.current[:search_db_path] = nil
      Thread.current[:search_db_generation] = nil
    end

    # Build a safe exact-phrase FTS expression. Tokenizing first avoids FTS5
    # treating punctuation in user input (e.g. parentheses or apostrophes) as
    # query operators.
    def fts_exact_match_expression(keywords)
      keywords.filter_map do |keyword|
        phrase = fts_tokens(keyword).join(' ')
        "\"#{phrase}\"" if phrase.present?
      end.uniq.join(' OR ')
    end

    # The dedicated search DB has no `articles` table, so language cannot be
    # filtered in the FTS SQL itself. Expand a small ranked window until enough
    # rowids survive a language lookup in the primary laws DB. This keeps BM25
    # order, avoids the former invalid cross-database JOIN, and prevents an NL
    # or FR-heavy top window from starving the requested language.
    def fts_ranked_article_ids(db, match_expr, desired)
      fetch_limit = [desired * 2, 30].max
      max_fetch = [desired * 32, 480].max

      loop do
        rows = db.execute(
          'SELECT rowid FROM articles_fts WHERE articles_fts MATCH ? ORDER BY rank LIMIT ?',
          [match_expr, fetch_limit]
        )
        ranked_ids = rows.map { |row| row[0] }
        language_ids = article_ids_in_language(ranked_ids)
        filtered = ranked_ids.select { |id| language_ids.include?(id) }
        return filtered.take(desired) if filtered.length >= desired || rows.length < fetch_limit || fetch_limit >= max_fetch

        fetch_limit = [fetch_limit * 2, max_fetch].min
      end
    end

    def article_ids_in_language(article_ids)
      return Set.new if article_ids.empty?

      Article.where(id: article_ids, language_id: @language_id).pluck(:id).to_set
    end

    # Prefix fallback for inflectional vocabulary mismatch. It runs only when
    # the exact search produced fewer than the requested result count.
    def fts_stemmed_match_expression(keywords)
      prefixes = keywords.flat_map do |keyword|
        fts_tokens(keyword).flat_map { |token| fts_prefixes_for(token) }
      end.uniq
      prefixes.map { |prefix| "#{prefix}*" }.join(' OR ')
    end

    def fts_tokens(value)
      value.to_s.downcase.scan(/[\p{L}\p{N}]+/)
    end

    def fts_prefixes_for(token)
      prefixes = FTS_IRREGULAR_PREFIXES.fetch(token, []).dup
      suffix = FTS_STEM_SUFFIXES.find { |candidate| token.end_with?(candidate) }
      if suffix
        stem = token.delete_suffix(suffix)
        prefixes << stem if stem.length >= 5
      end
      prefixes.uniq
    end

    def find_by_keywords_like(keywords, limit)
      conditions = []
      params = []
      keywords.each do |kw|
        # Parameterized bind: no manual quote-doubling (that made "d'office"
        # match the literal string "d''office", i.e. never). Escape only the
        # LIKE wildcards, with an explicit ESCAPE char for SQLite.
        conditions << "article_text LIKE ? ESCAPE '\\'"
        params << "%#{ActiveRecord::Base.sanitize_sql_like(kw)}%"
      end

      articles = nil
      begin
        Timeout.timeout(5) do
          articles = keyword_articles_with_metadata
                     .where(conditions.join(' OR '), *params)
                     .where(articles: { language_id: @language_id })
                     .limit(limit * 3)
                     .to_a
        end
      rescue Timeout::Error
        Rails.logger.warn('[Search] Keyword LIKE search timed out after 5s, skipping')
        return []
      end

      articles.map do |article|
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          is_abolished: article.try(:is_abolished) == 1,
          is_modification: article.try(:is_modification) == 1,
          similarity: 0.75
        }
      end.compact.take(limit)
    end

    KEYWORD_CONTENT_JOIN = 'LEFT JOIN contents ON articles.content_numac = contents.legislation_numac ' \
                           'AND articles.language_id = contents.language_id'
    KEYWORD_LEGISLATION_JOIN = 'LEFT JOIN legislation ON contents.legislation_numac = legislation.numac ' \
                               'AND contents.language_id = legislation.language_id'

    # Article's legacy `belongs_to :content` is keyed only by NUMAC. With NL
    # and FR Content rows for the same law, `includes(:content)` can attach the
    # other language's legislation metadata. Hydrate lexical results through
    # explicit composite (NUMAC + language) joins instead.
    def keyword_articles_with_metadata
      Article
        .select('articles.*, COALESCE(legislation.short_title, legislation.title) AS law_title, ' \
                'legislation.is_abolished AS is_abolished, legislation.is_modification AS is_modification')
        .joins(KEYWORD_CONTENT_JOIN)
        .joins(KEYWORD_LEGISLATION_JOIN)
    end

    # ------------------------------------------------------------------
    # BOOSTING & FILTERING
    # ------------------------------------------------------------------

    def apply_core_law_boosting(articles, question, profile: 'general')
      question_lower = question.downcase

      # Extract meaningful words from question for keyword overlap boosting
      # Excludes stop words so only substantive terms influence ranking
      stop_words = Set.new(%w[
                             de het een van in op voor met is dat dit die wat hoe wie waar
                             wanneer waarom hoeveel welke welk zijn wordt worden kan moet
                             le la les un une des du en est ce que qui pour avec dans
                             the a an of on for with that this what how who where
                             er sie das ein den dem und zu im auf
                             mijn uw je mij moi mon ma tu votre
                           ])
      question_words = question_lower.scan(/[\w\d]+/).reject { |w| w.length < 3 || stop_words.include?(w) }.uniq

      relevant_core_numacs = Set.new
      KEYWORD_TO_CORE_LAWS.each do |keyword, numacs|
        kw = keyword.to_s.downcase
        # Prefix word-boundary match: the keyword must START at a word
        # boundary but may continue into a compound ('huur' still matches
        # 'huurcontract'). Plain include? made 'koop' match inside
        # 'verkoop', injecting+boosting Oud BW articles to the top of the
        # ranking for e.g. VAT questions about online sales.
        right_boundary = EXACT_CORE_LAW_KEYWORDS.include?(kw) ? '(?![[:alnum:]])' : ''
        pattern = /(?<![[:alnum:]])#{Regexp.escape(kw)}#{right_boundary}/
        numacs.each { |n| relevant_core_numacs.add(n) } if question_lower.match?(pattern)
      end

      relevant_core_numacs.subtract(INVALID_LEGISLATION_NUMACS)

      # The 1867 Criminal Code was replaced on 8 April 2026. Keep it available
      # only for explicitly historical facts; otherwise stale semantic hits
      # must not outrank the current 2024 Books I/II.
      if historical_criminal_exposition?(question_lower)
        relevant_core_numacs.subtract(CURRENT_CRIMINAL_CODE_NUMACS)
        relevant_core_numacs.add(LEGACY_CRIMINAL_CODE_NUMAC)
      elsif legacy_criminal_fact_question?(question_lower)
        # Facts before the 2026 cutover can require the more-favourable-law
        # comparison. Retrieve both the historical provisions and current
        # Books I/II; Book I Art. 2 is pinned below as the transition rule.
        relevant_core_numacs.add(LEGACY_CRIMINAL_CODE_NUMAC)
        relevant_core_numacs.merge(CURRENT_CRIMINAL_CODE_NUMACS)
      else
        relevant_core_numacs.delete(LEGACY_CRIMINAL_CODE_NUMAC)
      end


      if question_lower.match?(REGIONAL_FAMILY_BENEFIT_PATTERN)
        # 1967102704 was historically mislabeled as a family-benefit law in
        # this app. It is not a current family-benefit regime. Remove stale
        # semantic hits even though the keyword mapping itself is gone.
        relevant_core_numacs.delete('1967102704')
      end


      # Inheritance, donation, registration, and property taxes are regional.
      # VCF is Flemish; the consolidated W.Succ./W.Reg. texts serve Brussels
      # and Wallonia. Never mix those regimes or silently choose Flanders for
      # a question that did not identify a region.
      if (allowed_regional_tax_numacs = regional_tax_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          REGIONAL_TAX_NUMACS.include?(numac) && !allowed_regional_tax_numacs.include?(numac)
        end
      end


      if (allowed_housing_numacs = regional_housing_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          REGIONAL_HOUSING_NUMACS.include?(numac) && !allowed_housing_numacs.include?(numac)
        end
      end

      # Spatial planning and environmental permits are regional. The mapped
      # NUMACs below are Flemish and must never be injected for an unqualified
      # or explicitly Brussels/Walloon question.
      if (allowed_planning_numacs = regional_planning_numacs_for(question_lower))
        relevant_core_numacs.delete_if do |numac|
          FLANDERS_PLANNING_NUMACS.include?(numac) && !allowed_planning_numacs.include?(numac)
        end
      end

      # INJECTION: If core laws are relevant but missing, inject them
      if relevant_core_numacs.any?
        existing_numacs = articles.to_set { |a| a[:numac] }
        missing_numacs = relevant_core_numacs - existing_numacs

        if missing_numacs.any?
          injected = inject_core_law_articles(missing_numacs, question_lower)
          if injected.any?
            Rails.logger.info("Core law injection: Added #{injected.length} articles")
            articles += injected
          end
        end
      end

      # CONTEXT LAW INJECTION: If user is viewing a specific law and FAISS didn't find it,
      # inject articles from that law so sources are relevant to the viewed page
      context_numacs_set = Set.new(@context_numacs)
      if context_numacs_set.any?
        existing_numacs = articles.to_set { |a| a[:numac] }
        missing_context = context_numacs_set - existing_numacs
        if missing_context.any?
          injected = inject_core_law_articles(missing_context, question_lower)
          if injected.any?
            Rails.logger.info("[ContextBoost] Injected #{injected.length} articles from viewed law(s)")
            articles += injected
          end
        end
      end

      # Scope once, after every source of candidates (semantic, lexical, core
      # injection, and viewed-law context) has been combined. This is the
      # fail-closed boundary that prevents later pipeline stages from
      # reintroducing an inapplicable law.
      articles = scope_articles_to_question(articles, question_lower)

      # Resolve profile-preferred numacs (nudge, not restrict)
      profile_numacs = Set.new(PROFILE_PREFERRED_NUMACS[profile] || [])

      boosted = articles.map do |article|
        numac = article[:numac]
        law_title = article[:law_title] || ''
        boost = 1.0

        if CORE_LAW_NUMACS.key?(numac)
          boost = relevant_core_numacs.include?(numac) ? CORE_LAW_BOOST * 1.1 : CORE_LAW_BOOST
        elsif is_sector_cao?(law_title)
          boost = CAO_PENALTY
        end

        boost *= 1.05 if article[:modification_count].to_i > 50
        boost *= 0.7 if law_title =~ /covid|corona|pandemie|tijdelijke.*2020|tijdelijke.*2021/i
        boost *= 0.5 if article[:is_modification]
        boost *= 0.3 if article[:is_abolished]

        article_text = article[:article_text].to_s.downcase
        boost *= 0.5 if article_text =~ /\b(opgeheven|abrogé|afgeschaft|geschrapt)\b/

        boost *= FISCONET_PENALTY if is_fisconet_source?(numac, law_title) && !tax_question?(question_lower)

        # Profile-based nudge: preferred laws for the selected category get boosted
        # This stacks with core law boosting - a tax law in the 'tax' profile gets both boosts
        if profile_numacs.include?(numac)
          boost *= PROFILE_BOOST
        end

        # Context law boost: user is viewing this law - strongest boost to ensure relevance
        if context_numacs_set.include?(numac)
          boost *= CONTEXT_LAW_BOOST
        end

        # Keyword overlap boost: articles containing more question words rank higher
        # Naturally handles years, specific terms, etc. without special-casing
        if question_words.any?
          combined_text = "#{law_title} #{article_text}"
          matches = question_words.count { |w| combined_text.include?(w) }
          if matches.positive?
            # Scale boost by overlap ratio: 1 of 3 words = small boost, 3 of 3 = strong boost
            overlap_ratio = matches.to_f / question_words.length
            boost *= 1.0 + (overlap_ratio * 0.4) # max +40% for full overlap
          end
        end

        article.merge(similarity: article[:similarity] * boost, boosted: boost > 1.0)
      end

      result = boosted.sort_by { |a| -a[:similarity] }
      core_in_top5 = result.take(5).count { |a| a[:boosted] }
      profile_in_top5 = result.take(5).count { |a| profile_numacs.include?(a[:numac]) }
      context_in_top5 = result.take(5).count { |a| context_numacs_set.include?(a[:numac]) }
      Rails.logger.info("Core law boosting: #{core_in_top5}/5 top results boosted, #{profile_in_top5}/5 profile-preferred") if core_in_top5.positive? || profile_in_top5.positive?
      Rails.logger.info("[ContextBoost] #{context_in_top5}/5 top results from viewed law") if context_in_top5.positive?
      Rails.logger.info("[KeywordOverlap] Boosted using #{question_words.size} normalized question terms") if question_words.any?
      result
    end

    def matching_article_pins(question)
      matched = ARTICLE_PINS.select { |pattern, _numac, _article| question.match?(pattern) }
      return matched unless historical_criminal_exposition?(question)

      matched.reject { |_pattern, numac, _article| CURRENT_CRIMINAL_CODE_NUMACS.include?(numac) }
    end

    def legacy_criminal_code_question?(question)
      historical_criminal_exposition?(question) || legacy_criminal_fact_question?(question)
    end

    def legacy_criminal_fact_question?(question)
      question.match?(LEGACY_CRIMINAL_FACT_PATTERN)
    end

    def historical_criminal_exposition?(question)
      question.match?(LEGACY_CRIMINAL_CODE_NAME_PATTERN) && !legacy_criminal_fact_question?(question)
    end

    def scope_articles_to_question(articles, question)
      safe_articles = articles.reject { |article| INVALID_LEGISLATION_NUMACS.include?(article[:numac]) }
      scoped = if historical_criminal_exposition?(question)
                 safe_articles.reject { |article| CURRENT_CRIMINAL_CODE_NUMACS.include?(article[:numac]) }
               elsif legacy_criminal_fact_question?(question)
                 safe_articles
               else
                 safe_articles.reject { |article| article[:numac] == LEGACY_CRIMINAL_CODE_NUMAC }
               end

      if question.match?(REGIONAL_FAMILY_BENEFIT_PATTERN)
        scoped = scoped.reject { |article| article[:numac] == '1967102704' }
      end

      if (allowed = regional_tax_numacs_for(question))
        scoped = scoped.reject do |article|
          REGIONAL_TAX_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac])
        end
      end

      if (allowed = regional_housing_numacs_for(question))
        scoped = scoped.reject do |article|
          REGIONAL_HOUSING_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac])
        end
        scoped = scoped.reject do |article|
          HOUSING_CONTEXT_EXCLUDED_NUMACS.include?(article[:numac]) && !employment_context_question?(question)
        end
      end

      if (allowed = regional_planning_numacs_for(question))
        scoped = scoped.reject do |article|
          FLANDERS_PLANNING_NUMACS.include?(article[:numac]) && !allowed.include?(article[:numac])
        end
      end

      scoped
    end

    def regional_tax_numacs_for(question)
      return nil unless question.match?(REGIONAL_TAX_SUBJECT_PATTERN) ||
                        question.match?(REGIONAL_TAX_GIFT_CONTEXT_PATTERN) ||
                        question.match?(REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN)

      flanders = question.match?(FLANDERS_REGION_PATTERN)
      brussels_or_wallonia = question.match?(BRUSSELS_WALLONIA_REGION_PATTERN)
      non_flemish = Set.new
      non_flemish << '1936033102' if question.match?(SUCCESSION_TAX_PATTERN)
      non_flemish << '1939113002' if question.match?(REGISTRATION_TAX_PATTERN)
      return FLANDERS_TAX_NUMACS | non_flemish if flanders && brussels_or_wallonia
      return FLANDERS_TAX_NUMACS if flanders
      return non_flemish if brussels_or_wallonia

      Set.new
    end

    def regional_housing_numacs_for(question)
      return nil unless question.match?(REGIONAL_HOUSING_SUBJECT_PATTERN)

      allowed = Set.new
      allowed << '2018015087' if question.match?(FLANDERS_REGION_PATTERN)
      allowed << '2013A31614' if question.match?(BRUSSELS_REGION_PATTERN)
      allowed << '2018201408' if question.match?(WALLONIA_REGION_PATTERN)
      allowed
    end

    def employment_context_question?(question)
      question.match?(/\b(?:arbeidsovereenkomst|arbeidscontract|werknemer|werkgever|tewerkstelling|job|ontslag|contrat\s+de\s+travail|travailleur|employeur|licenciement|employment\s+contract|employee|employer|dismissal)\b/i)
    end

    def regional_planning_numacs_for(question)
      return nil unless question.match?(REGIONAL_PLANNING_SUBJECT_PATTERN)

      question.match?(FLANDERS_REGION_PATTERN) ? FLANDERS_PLANNING_NUMACS : Set.new
    end

    def inject_core_law_articles(numacs, question_lower)
      keywords = question_lower.split(/\s+/).select { |w| w.length > 3 }
      stop_roots = %w[belg belgi straf recht wetbo]
      roots = keywords.select { |w| w.length >= 6 }.map { |w| w[0, 5] }
      roots.reject! { |r| stop_roots.include?(r) }
      search_terms = (keywords + roots).uniq

      injected = []
      numacs.each do |numac|
        base_query = Article
                     .select('articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, legislation.date, legislation.is_abolished, contents.preamble')
                     .joins('LEFT JOIN contents ON articles.content_numac = contents.legislation_numac AND articles.language_id = contents.language_id')
                     .joins('LEFT JOIN legislation ON contents.legislation_numac = legislation.numac AND contents.language_id = legislation.language_id')
                     .where(content_numac: numac, language_id: @language_id)

        # Strategy 1: Targeted text search
        targeted_articles = []
        if keywords.any?
          like_conditions = keywords.map { 'article_text LIKE ? OR article_title LIKE ?' }
          like_params = keywords.flat_map { |k| ["%#{k}%", "%#{k}%"] }
          begin
            Timeout.timeout(3) do
              targeted_articles = base_query.where(like_conditions.join(' OR '), *like_params).limit(20).to_a
            end
          rescue Timeout::Error
            Rails.logger.warn("Core law injection: text search timed out for #{numac}")
            targeted_articles = []
          end
        end

        # Strategy 2: Fallback to first N articles
        targeted_articles = base_query.limit(10).to_a if targeted_articles.empty?

        scored = targeted_articles.map do |article|
          text = "#{article.article_title} #{article.article_text}".downcase
          matches = search_terms.count { |term| text.include?(term) }
          base_similarity = matches.positive? ? 0.82 : 0.70

          {
            id: article.id,
            numac: article.content_numac,
            law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Wetgeving #{article.content_numac}",
            article_title: article.article_title,
            article_text: article.article_text,
            article_variant: article.try(:article_variant),
            language_id: article.language_id,
            similarity: base_similarity + (matches * 0.02),
            injected: true,
            match_count: matches,
            is_abolished: article.try(:is_abolished) == 1,
            preamble: article.try(:preamble)
          }
        end

        injected += scored.sort_by { |a| [-a[:match_count], -a[:similarity]] }.take(3)
      end

      injected
    end

    # ------------------------------------------------------------------
    # HELPERS
    # ------------------------------------------------------------------

    def is_sector_cao?(law_title)
      return false if law_title.blank?

      title_lower = law_title.downcase
      cao_patterns = [
        /paritair comit[eé]/i, /paritair subcomit[eé]/i,
        /collectieve arbeidsovereenkomst/i, /convention collective/i,
        /commission paritaire/i, /sous-commission paritaire/i,
        /pc\s*\d+/i, /cp\s*\d+/i
      ]
      sector_keywords = %w[hardsteengroeven kwartsietgroeven zandsteen warenhuizen groothandelaar
                           voedingsnijverheid bakkerijen textielnijverheid kleding metaal garage carrosserie
                           bouw hout meubel haven scheepvaart luchtvaart hotels horeca toerisme]

      return true if cao_patterns.any? { |p| title_lower.match?(p) }
      return true if (title_lower.include?('overeenkomst') || title_lower.include?('convention')) && sector_keywords.any? { |k| title_lower.include?(k) }

      false
    end

    def is_fisconet_source?(numac, law_title)
      return true if numac.to_s.start_with?('fisconet')

      title = law_title.to_s.downcase
      # Explicit tax law titles (NOT the broad W.Reg. which also covers griffierechten)
      return true if title =~ /\b(fiscaal|btw|belasting|accijns|tva|impôt|taxe)\b/i
      # Specific tax codes within W.Reg. – only if title mentions tax-specific sections
      return true if title =~ /\b(successierecht|schenkbelasting|erfbelasting)\b/i

      false
    end

    def extract_topic_keywords(question)
      topic_map = {
        'ontslag' => %w[arbeid ontslag werk], 'opzeg' => %w[arbeid ontslag opzeg],
        'vakantie' => %w[vakantie arbeid werk verlof], 'huur' => %w[huur woning woon verhuur],
        'belasting' => %w[belasting fiscaal btw inkomsten], 'echtscheiding' => %w[echtscheiding huwelijk burgerlijk],
        'btw' => %w[belasting btw toegevoegde omzet], 'tva' => ['taxe', 'valeur ajoutée', 'impôt'],
        'erfenis' => %w[erfenis successie nalatenschap burgerlijk], 'vennootschap' => %w[vennootschap onderneming economisch],
        'straf' => %w[straf boete sanctie verkeer], 'rijbewijs' => %w[verkeer rijbewijs wegverkeer],
        'werkloosheid' => %w[werkloosheid uitkering sociale], 'pensioen' => %w[pensioen sociale zekerheid],
        'kinderbijslag' => %w[kind gezin groeipakket], 'garantie' => %w[consument garantie economisch]
      }

      keywords = []
      topic_map.each { |topic, title_keywords| keywords.concat(title_keywords) if question.include?(topic) }
      question.split(/\s+/).each { |word| keywords << word if word.length >= 5 }
      keywords.uniq
    end

    def extract_relevant_window(full_text, _article_title, window_size: 3000)
      return full_text if full_text.length <= window_size

      data_patterns = [
        /\d+[°º]\s/, /§\s*\d+/,
        /\b\d+\s*(dagen|jours|days|Tage|weken|semaines|weeks|Wochen|maanden|mois|months|Monate|jaar|ans|years|Jahre|euro|EUR|%)\b/i,
        /\b(bedraagt|égale?|equals?|beträgt|maximum|minimum|ten\s+minste|au\s+moins|at\s+least|mindestens)\b/i
      ]

      best_start = nil
      data_patterns.each do |pattern|
        match = full_text.match(pattern)
        if match
          pos = match.begin(0)
          best_start = pos if best_start.nil? || pos < best_start
        end
      end

      if best_start && best_start > 500
        start_pos = [best_start - 300, 0].max
        newline_pos = full_text.rindex("\n", start_pos + 50)
        start_pos = newline_pos + 1 if newline_pos && newline_pos >= start_pos - 100
        return full_text[start_pos, window_size]
      end

      full_text[0, window_size]
    end

    def build_regional_warnings(q)
      parts = []

      if q.include?('registratierecht')
        parts << "REGISTRATIERECHTEN (regionaal!):\nTarieven verschillen per gewest (Vlaanderen, Wallonie, Brussel). " \
                 'Vermeld het toepasselijke gewest en gebruik de tarieven uit de bronnen hieronder.'
      end

      if q.include?('kinderbijslag') || q.include?('groeipakket')
        parts << "KINDERBIJSLAG/GROEIPAKKET (regionaal!):\nBedragen verschillen per gewest. " \
                 'Vlaanderen: "Groeipakket", Wallonie: allocations familiales, Brussel: eigen regeling. ' \
                 'Gebruik de bedragen uit de bronnen hieronder.'
      end

      if q.include?('huur') || q.include?('woninghuur')
        parts << "HUURRECHT (regionaal!):\nVermeld welke gewestelijke regeling van toepassing is " \
                 '(Vlaams Woninghuurdecreet 2018, Brusselse Huisvestingscode, of Waalse Woninghuurwet).'
      end

      if q.include?('erfbelasting') || q.include?('successie')
        parts << "ERFBELASTING/SUCCESSIERECHTEN (regionaal!):\nTarieven en vrijstellingen verschillen per gewest. " \
                 'Vermeld welk gewest van toepassing is en gebruik de tarieven uit de bronnen.'
      end

      if q.include?('onroerende voorheffing')
        parts << "ONROERENDE VOORHEFFING (regionaal!):\nFederale basispercentage KI, " \
                 'maar opcentiemen zijn regionaal en gemeentelijk verschillend. Vermeld het toepasselijke gewest.'
      end

      if q.include?('premie') || q.include?('renovatie') || q.include?('vergunning')
        parts << "PREMIES/VERGUNNINGEN (regionaal!):\nVoorwaarden en bedragen zijn gewestelijk bepaald. " \
                 'Vermeld het toepasselijke gewest.'
      end

      parts
    end

    # The legal term map is huge - extracted to its own method for readability
    def build_legal_term_map
      {
        /vakantiedagen|jaarlijks.*vakantie/i => ['vakantiedagen', 'jaarlijkse vakantie', 'wettelijke vakantie', 'verlof'],
        'ontslag' => %w[ontslag opzeg beëindiging ontslaan opzegtermijn opzegvergoeding],
        'zelfstandig' => %w[zelfstandig zelfstandige freelance independent schijnzelfstandigheid],
        'deeltijd' => %w[deeltijd deeltijds part-time parttime],
        'proef' => ['proef', 'proeftijd', 'proefperiode', 'trial period', 'testperiode'],
        'concurrentie' => %w[concurrentiebeding niet-concurrentiebeding concurrentie non-compete],
        'arbeider' => ['arbeider', 'arbeiders', 'blue collar', 'handarbeider'],
        'bediende' => ['bediende', 'bedienden', 'white collar', 'kantoorwerk'],
        'loon' => %w[loon salaris verloning minimumloon bezoldiging],
        'overuren' => ['overuren', 'meeruren', 'extra uren', 'overtime'],
        /arbeidsovereenkomst|arbeidscontract|werkcontract/i => %w[arbeidsovereenkomst arbeidscontract dienstverband tewerkstelling],
        /deeltijds.*werk|parttime/i => ['deeltijds', 'part-time', 'gedeeltelijke arbeid', 'halftijds'],
        /overuren|over.*uren|meeruren/i => ['overuren', 'meeruren', 'aanvullende prestaties', 'extra uren'],
        /ontslag|afdanking/i => %w[ontslag afdanking beëindiging arbeidsbeëindiging],
        /dringende.*reden|dringend.*ontslag/i => ['dringende reden', 'dringend ontslag', 'onmiddellijke beëindiging'],
        /zelfstandige|ondernemer/i => ['zelfstandige', 'zelfstandig ondernemer', 'vrij beroep'],
        /sociale.*bijdrage|rsz/i => ['sociale bijdragen', 'RSZ', 'socialezekerheidsbijdrage'],
        /werkloosheid|werkloosheidsuitkering/i => %w[werkloosheid werkloosheidsuitkering werkloosheidsvergoeding],
        /minimumloon|minimum.*loon/i => ['minimumloon', 'minimum loon', 'gewaarborgd loon'],
        /loon|salaris|bezoldiging/i => %w[loon salaris bezoldiging wedde],
        /eindejaar.*premie|13.*maand/i => ['eindejaarspremie', '13de maand', 'dertiende maand'],
        /ziekteverlof|ziek/i => %w[ziekteverlof ziekte arbeidsongeschiktheid],
        /zwangerschapsverlof|moederschaps/i => %w[zwangerschapsverlof moederschapsverlof bevallingsrust],
        /vaderschapsverlof|vaderschaps/i => ['vaderschapsverlof', 'geboorteverlof', 'verlof geboorte'],
        /congé.*paternel|congé.*paternité|paternité/i => ['congé de paternité', 'congé paternel', 'congé de naissance'],
        /paternity.*leave|paternity/i => ['paternity leave', 'birth leave', 'paternal leave'],
        /vaterschaftsurlaub|vaterschaft/i => %w[vaterschaftsurlaub geburtsurlaub väterurlaub],
        /congé.*maternité|maternité/i => ['congé de maternité', 'congé maternité', 'repos de maternité'],
        /maternity.*leave|maternity/i => ['maternity leave', 'maternal leave', 'pregnancy leave'],
        /mutterschaftsurlaub|mutterschaft/i => %w[mutterschaftsurlaub mutterschutz schwangerschaftsurlaub],
        /durée.*travail|temps.*travail|heures.*travail/i => ['durée du travail', 'temps de travail', 'heures de travail', 'semaine de travail'],
        /working.*hours|work.*hours|maximum.*hours/i => ['working hours', 'work hours', 'maximum hours', 'working time'],
        /arbeitszeit|arbeitsstunden|wochenarbeitszeit/i => %w[arbeitszeit arbeitsstunden wochenarbeitszeit höchstarbeitszeit],
        /discriminatie|ongelijke.*behandeling/i => ['discriminatie', 'ongelijke behandeling', 'gelijke behandeling'],
        /pesten|pestgedrag|intimidatie|harassment/i => ['pestgedrag', 'pesten', 'intimidatie', 'psychosociale risicos'],
        /thuiswerk|telewerk|remote/i => %w[thuiswerk telewerk thuiswerken afstandswerk],
        /arbeidsduur|werkuren|arbeidstijd/i => %w[arbeidsduur arbeidstijd werkuren arbeidstijdvermindering],
        /concurrentiebeding|concurrentie/i => %w[concurrentiebeding niet-concurrentiebeding concurrentieclausule],
        /burnout/i => ['burnout', 'overspanning', 'psychische belasting', 'arbeidsongeval'],
        /alcohol.*driv|drink.*driv|blood.*alcohol/i => ['alcoholgrens', 'rijden onder invloed', 'promille', 'alcool au volant', 'taux alcool'],
        /alkohol.*fahr|alkoholgrenze/i => ['alcoholgrens', 'rijden onder invloed', 'promille', 'alcool au volant'],
        /driving.*licen[sc]e|driving.*ban/i => ['rijbewijs', 'rijverbod', 'permis de conduire', 'retrait permis'],
        /führerschein|fahrverbot/i => ['rijbewijs', 'rijverbod', 'permis de conduire', 'retrait permis'],
        /traffic.*(?:fine|offence|violation)/i => ['verkeersboete', 'verkeersovertreding', 'infraction routière', 'amende'],
        /verkehrsstrafe|bußgeld/i => ['verkeersboete', 'verkeersovertreding', 'infraction routière'],
        /marriage.*age|minimum.*marriage/i => ['huwelijksleeftijd', 'huwelijk', 'meerderjarig', 'âge mariage', 'mariage', 'majeur'],
        /mindestalter.*heirat|heiratsalter/i => ['huwelijksleeftijd', 'huwelijk', 'âge mariage', 'mariage'],
        /child.*support|alimony/i => ['onderhoudsgeld', 'alimentatie', 'pension alimentaire', 'obligation alimentaire'],
        /kindesunterhalt|unterhaltspflicht/i => ['onderhoudsgeld', 'alimentatie', 'pension alimentaire'],
        /divorce|separation/i => %w[echtscheiding scheiding divorce séparation],
        /inheritance|heir|estate/i => %w[erfenis erfrecht nalatenschap succession héritage héritier],
        /rental.*deposit|security.*deposit/i => ['huurwaarborg', 'waarborg', 'garantie locative', 'caution', 'bail'],
        /mietkaution|kaution.*miete/i => ['huurwaarborg', 'waarborg', 'garantie locative', 'caution'],
        /notice.*period.*(?:tenant|landlord|rent)/i => ['opzegtermijn', 'huur', 'opzeg huur', 'préavis', 'locataire', 'bailleur'],
        /kündigungsfrist.*miet|mieter.*kündigung/i => %w[opzegtermijn huur préavis locataire],
        /annual.*accounts?.*filing/i => ['jaarrekening', 'neerlegging', 'comptes annuels', 'dépôt', 'WVV'],
        /jahresabschluss/i => ['jaarrekening', 'neerlegging', 'comptes annuels', 'dépôt'],
        /general.*(?:meeting|assembly)|shareholder.*meeting/i => ['algemene vergadering', 'aandeelhouder', 'assemblée générale', 'actionnaire'],
        /hauptversammlung/i => ['algemene vergadering', 'assemblée générale', 'actionnaire'],
        /minimum.*capital|share.*capital/i => ['minimumkapitaal', 'kapitaal', 'capital minimum', 'capital social', 'BV', 'NV'],
        /\bvat\b.*(?:rate|percent|standard)/i => ['BTW', 'BTW-tarief', 'TVA', 'taux TVA', 'taxe sur la valeur ajoutée'],
        /mwst.*(?:satz|prozent)/i => ['BTW', 'BTW-tarief', 'TVA', 'taux TVA'],
        /reduced.*vat|vat.*(?:food|renovation)/i => ['verlaagd BTW-tarief', 'BTW', '6%', 'taux réduit TVA', 'TVA'],
        /ermäßigt.*mwst/i => ['verlaagd BTW-tarief', 'BTW', 'taux réduit TVA'],
        /corporate.*tax.*(?:rate|percent)/i => ['vennootschapsbelasting', 'ISOC', 'impôt des sociétés', 'KMO-tarief', 'taux PME'],
        /körperschaftsteuer/i => ['vennootschapsbelasting', 'ISOC', 'impôt des sociétés'],
        /(?:legal|statutory).*(?:guarantee|warranty)/i => ['wettelijke garantie', 'garantie', 'garantie légale', 'consommateur', 'conformiteit'],
        /gesetzliche.*garantie/i => ['wettelijke garantie', 'garantie légale', 'consommateur'],
        /hidden.*defect|latent.*defect/i => ['verborgen gebrek', 'verborgen gebreken', 'vice caché', 'vices cachés'],
        /versteckte.*mängel/i => ['verborgen gebrek', 'vice caché', 'vices cachés'],
        /withdrawal.*(?:right|period)|cooling.*off/i => ['herroepingsrecht', 'bedenktijd', 'droit de rétractation', 'délai de réflexion'],
        /widerrufsrecht|widerrufsfrist/i => ['herroepingsrecht', 'bedenktijd', 'droit de rétractation'],
        /public.*holiday|bank.*holiday/i => ['feestdag', 'feestdagen', 'wettelijke feestdag', 'jour férié', 'jours fériés'],
        /feiertag/i => ['feestdag', 'feestdagen', 'jour férié', 'jours fériés'],
        /(?:minimum|gross).*(?:wage|salary)/i => ['minimumloon', 'GGMMI', 'salaire minimum', 'RMMMG'],
        /mindestlohn/i => ['minimumloon', 'GGMMI', 'salaire minimum', 'RMMMG'],
        /bereavement.*leave|compassionate.*leave/i => ['rouwverlof', 'klein verlet', 'overlijden', 'congé de deuil', 'décès'],
        /trauerurlaub/i => ['rouwverlof', 'klein verlet', 'congé de deuil'],
        /diefstal|stelen|gestolen/i => %w[diefstal ontvreemding wegnemen heling roof],
        /drugs|drugsbezit|verdovende/i => ['drugs', 'verdovende middelen', 'bezit', 'handel', 'stupéfiants'],
        /geweld|slagen|verwondingen|mishandeling/i => ['slagen', 'verwondingen', 'geweld', 'opzettelijk', 'lichamelijke integriteit'],
        /fraude|oplichting|bedrog/i => %w[fraude oplichting valsheid bedrog misleiding],
        /moord|doodslag/i => ['moord', 'doodslag', 'opzettelijke doding', 'levensberoving'],
        /verkrachting|aanranding/i => ['verkrachting', 'aanranding', 'eerbaarheid', 'seksueel geweld'],
        /stalking|belaging/i => %w[belaging stalking hinderlijk lastigvallen],
        /inbraak|braak/i => ['inbraak', 'braak', 'diefstal met braak', 'inklimming'],
        /vol.*qualifié|cambriolage/i => ['vol', 'vol qualifié', 'effraction', 'cambriolage', 'diefstal'],
        /coups.*blessures|violence/i => %w[coups blessures violence slagen verwondingen],
        /stupéfiants|drogue|détention.*drogue/i => ['stupéfiants', 'drogue', 'détention', 'drugs', 'verdovende middelen'],
        /meurtre|homicide/i => %w[meurtre homicide moord doodslag],
        /escroquerie|fraude/i => %w[escroquerie fraude oplichting tromperie],
        /huurwaarborg|waarborg/i => %w[huurwaarborg waarborg borgsom garantie teruggave],
        /opzeg.*huur|huur.*opzeg/i => ['opzegtermijn', 'opzeg', 'huurovereenkomst', 'beëindiging huur'],
        /renovatie|verbouwing/i => %w[renovatie verbouwing herstellingswerken onderhoud],

        # Colloquial / branded scheme names → the formal statutory vocabulary
        # the corpus is actually indexed on (added 2026-07-15 after the 3k
        # coverage run showed these named schemes hedged despite being in the
        # legislation, just under formal names the question never uses).
        /\bwco\b|continu[iï]teit.*ondernem|gerechtelijke.*reorganisatie/i =>
          ['continuïteit ondernemingen', 'gerechtelijke reorganisatie', 'insolventie', 'Boek XX economisch recht'],
        /flexi.?job/i => ['flexi-job', 'flexijob', 'gelegenheidsarbeid', 'bijkomende tewerkstelling'],
        /plus.?minus.?conto/i => ['plus-minus conto', 'arbeidsduur op jaarbasis', 'arbeidstijdregeling'],
        /niet.?recurrente.*bonus|cao.?90/i => ['niet-recurrente resultaatsgebonden voordelen', 'loonbonus', 'cao 90'],
        /bonus.?malus/i => ['bonus-malus', 'premiegraad', 'verzekering burgerlijke aansprakelijkheid motorrijtuigen'],
        /renault.?procedure|wet.?renault/i => ['collectief ontslag', 'informatie en raadpleging', 'sluiting onderneming'],
        /kaasroute/i => ['registratierecht schenking', 'buitenlandse schenkingsakte', 'notariële schenking'],
        /rijbewijs.*proef|voorlopig.*rijbewijs/i => ['rijbewijs op proef', 'proefperiode rijbewijs', 'terugkommoment'],
        /enkelband|elektronisch.*toezicht/i => ['elektronisch toezicht', 'enkelband', 'strafuitvoering'],
        /probatie/i => ['probatie', 'probatieuitstel', 'opschorting met voorwaarden'],
        /\bipt\b|individuele.*pensioentoezegging/i => ['individuele pensioentoezegging', 'aanvullend pensioen', 'tweede pensioenpijler'],
        /groepsverzekering/i => ['groepsverzekering', 'aanvullend pensioen', 'pensioentoezegging'],
        /single.?permit|gecombineerde.*vergunning/i => ['gecombineerde vergunning', 'single permit', 'verblijf en arbeid'],
        /schengen.?visum|kort.*verblijf.*visum/i => ['visum kort verblijf', 'Schengenvisum', 'visumcode'],
        /inreisverbod/i => ['inreisverbod', 'terugkeerbesluit', 'verwijdering vreemdeling'],
        /epc|energieprestatie/i => ['energieprestatiecertificaat', 'EPC', 'energieprestatie gebouwen'],
        /bindend.*studieadvies|\bbsa\b/i => ['bindend studieadvies', 'studievoortgang', 'inschrijving hoger onderwijs'],
        /reservefonds|\bvme\b|mede.?eigendom/i => ['reservefonds', 'vereniging van mede-eigenaars', 'gedwongen mede-eigendom'],
        /informed.?consent|geïnformeerde.?toestemming/i => ['geïnformeerde toestemming', 'patiëntenrechten', 'toestemming behandeling'],
        /extralegale.?voordelen|extra.?legaal/i => ['extralegale voordelen', 'voordelen alle aard', 'aanvullende voordelen'],
        /aanrijdingsformulier|europees.*aanrijding/i => ['aanrijdingsformulier', 'aangifte schadegeval', 'verkeersongeval'],
        /wapenvergunning|wapenwit/i => ['wapenvergunning', 'vergunning wapen', 'wapenwet'],
        /phishing|internetfraude/i => ['phishing', 'informaticabedrog', 'oplichting', 'computercriminaliteit'],
        /bemiddeling|mediation/i => ['bemiddeling', 'mediation', 'minnelijke schikking', 'alternatieve geschillenbeslechting'],
        /incasso|onbetaalde.*factuur|invordering/i => ['invordering', 'onbetaalde schuld', 'IOS-procedure', 'betalingsachterstand']
      }
    end
  end
end
