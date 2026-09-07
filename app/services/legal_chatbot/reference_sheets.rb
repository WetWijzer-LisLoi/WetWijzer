# frozen_string_literal: true

module LegalChatbot
  # Handles legal reference data loading, section matching,
  # and imperative fact extraction for LLM context injection.
  #
  # Belgian facts are sourced from the DB via LegalFactProvider. Narrow EU
  # topics may use sealed excerpts of the official EUR-Lex text when that
  # legislation is absent from the Belgian corpus.
  class ReferenceSheets
    # Maps question keywords to topic keys for lookup.
    # Topic keys match FACT_SOURCES in LegalFactProvider.
    SECTION_KEYWORD_MAP = {
      'proeftijd' => ['proeftijd', 'proefperiode', 'proefbeding', "période d'essai", 'trial period', 'probation'],
      'carensdag' => ['carensdag', 'jour de carence'],
      'eenheidsstatuut' => ['eenheidsstatuut', 'arbeider', 'bediende', 'statut unique', 'ouvrier', 'employé'],
      'bv_kapitaal' => ['bv', 'besloten vennootschap', 'srl', 'société à responsabilité', 'kapitaal', 'capital'],
      'puntensysteem' => ['puntensysteem', 'puntenrijbewijs', 'points system', 'permis à points'],
      'erfrecht' => %w[erfrecht erfenis reserve nalatenschap succession héritage erben erbrecht],
      'feestdagen' => ['feestdag', 'feestdagen', 'jours fériés', 'public holiday', 'feiertag'],
      # Compounds listed explicitly: the word-boundary matcher cannot see
      # 'boete' inside 'snelheidsboete'. Safe to broaden because the
      # contextually_applicable? gate limits this pack to criminal context.
      'opdeciemen' => %w[opdeciemen décimes geldboete amende boete snelheidsboete verkeersboete],
      'vakantiedagen' => ['vakantie', 'vakantiedagen', 'jaarlijkse vakantie', 'congé', 'vacances', 'verlof', 'urlaub'],
      'arbeidsduur' => ['arbeidsduur', 'werkweek', '38 uur', 'arbeidsuren', 'durée du travail', 'heures de travail'],
      'klein_verlet' => ['klein verlet', 'kort verzuim', 'huwelijk verlof', 'overlijden verlof', 'congé de circonstance', 'rouwverlof'],
      'moederschapsverlof' => ['moederschapsverlof', 'zwangerschapsverlof', 'congé de maternité', 'maternity', 'moederschap', 'bevalling'],
      'vaderschapsverlof' => ['vaderschapsverlof', 'geboorteverlof', 'congé de paternité', 'congé de naissance', 'paternity', 'geboorte vader'],
      'ouderschapsverlof' => ['ouderschapsverlof', 'congé parental', 'parental leave'],
      'opzegtermijn' => ['opzegtermijn', 'opzeg', 'préavis', 'notice period', 'kündigung', 'ontslagen', 'ontslag'],
      'leefloon' => ['leefloon', 'ocmw', 'cpas', "revenu d'intégration", 'sociaal tarief'],
      'minimumloon' => ['minimumloon', 'ggmmi', 'salaire minimum', 'minimum wage', 'mindestlohn'],
      'werkloosheid' => %w[werkloosheid werkloosheidsuitkering chômage unemployment arbeitslosigkeit rva onem],
      'ziekte_uitkering' => ['ziekte-uitkering', 'ziekteverlof', 'arbeidsongeschikt', 'gewaarborgd loon', 'indemnité maladie', 'mutualiteit'],
      'pensioenleeftijd' => %w[pensioenleeftijd pension pensionering retraite retirement rente],
      'vervroegd_pensioen' => ['vervroegd pensioen', 'prepensie', 'retraite anticipée', 'early retirement'],
      'minimumpensioen' => ['minimumpensioen', 'pension minimum', 'minimum pension'],
      # Family benefits are regionalized. Do not inject the obsolete federal
      # employee scheme without knowing the user's region; regional retrieval
      # supplies the applicable Groeipakket/Walloon/Brussels rules instead.
      'bijzondere_bijdrage' => ['bijzondere bijdrage', 'cotisation spéciale'],
      # 'tarief' was removed: it is the generic Dutch word for any rate, and it
      # injected income-tax brackets into btw-tarief questions with override
      # authority (2026-07-29 spot check, wrong-pack family).
      'belastingschijven' => ['belastingschijven', 'personenbelasting', 'impôt des personnes', 'tax brackets', 'einkommensteuer'],
      'btw' => %w[btw tva vat mehrwertsteuer],
      'vennootschapsbelasting' => ['vennootschapsbelasting', 'isoc', 'corporate tax', 'körperschaftsteuer'],
      'roerende_voorheffing' => ['roerende voorheffing', 'dividenden', 'précompte mobilier', 'withholding tax', 'vvprbis'],
      'pensioensparen' => ['pensioensparen', 'épargne-pension', 'pension savings'],
      'maaltijdcheques' => ['maaltijdcheque', 'chèque-repas', 'meal voucher'],
      # 'wettelijke rente' is what lay users actually type; its absence sent
      # interest-rate questions to the pension pack via the bare 'rente'
      # keyword there (2026-07-29 spot check).
      'wettelijke_interest' => ['wettelijke interest', 'wettelijke rente', 'verwijlinterest', 'verwijlintrest',
                                'nalatigheidsinterest', 'intérêt légal', 'intérêt de retard', 'legal interest', 'interestvoet'],
      'registratierechten' => ['registratierecht', "droits d'enregistrement", 'registration fee', 'grunderwerbsteuer'],
      'erfbelasting' => ['erfbelasting', 'successierecht', 'droits de succession', 'inheritance tax', 'erbschaftsteuer'],
      'garantie' => ['garantie', 'warranty', 'gewährleistung', 'wettelijke garantie'],
      'herroepingsrecht' => ['herroepingsrecht', 'herroeping', 'rétractation', 'withdrawal right', 'widerruf'],
      # 'arrest' was removed: in Dutch it is primarily a COURT JUDGMENT
      # (arrest van het Hof), and it injected pre-trial detention limits into
      # ordinary case-law questions (2026-07-29 spot check). It was also the
      # list's only ENGLISH coverage, so the review (2026-08-03) added the
      # unambiguous phrases and inflections instead of the bare token.
      'voorlopige_hechtenis' => ['voorlopige hechtenis', 'aanhouding', 'détention préventive', 'hechtenis',
                                 'onder arrest', 'arrestatie', 'gearresteerd', 'arrestation', 'arrested',
                                 'under arrest', 'pre-trial detention', 'police custody', 'untersuchungshaft'],
      'meerderjarigheid' => %w[meerderjarig minderjarig majorité mineur majeur majority],
      'verjaring' => %w[verjaring prescription limitation verjaringstermijn],
      'orgaandonatie' => ['orgaandonatie', 'orgaan donor', "don d'organes", 'organ donation'],
      # 'dronken'/'gedronken' added for colloquial phrasings; safe to broaden
      # because the gate requires an alcohol term AND a driving term together.
      'alcohol_rijden' => ['alcohol', 'rijden', 'promille', 'dronken', 'gedronken', 'alcool volant', 'drunk driving'],
      'huur' => %w[huur huurder verhuurder huurcontract huurwaarborg loyer bail locataire bailleur miete],
      'naturalisatie' => %w[naturalisatie nationaliteit nationaliteitsverklaring naturalisation nationality staatsbürgerschaft],
      'gezinshereniging' => ['gezinshereniging', 'regroupement familial', 'family reunification', 'familiennachzug'],
      'verblijfskaart' => ['verblijfsvergunning', 'verblijfskaart', 'a-kaart', 'b-kaart', 'f-kaart', 'titre de séjour', 'residence permit', 'aufenthaltstitel'],
      'single_permit' => ['single permit', 'gecombineerde vergunning', 'permis unique', 'arbeidsvergunning'],
      'asiel' => ['asiel', 'vluchtelingen', 'internationale bescherming', 'asile', 'réfugié', 'asylum', 'refugee', 'cgvs', 'fedasil'],
      'inburgering' => ['inburgering', 'integratie', "parcours d'intégration", 'integration'],
      'omgevingsvergunning' => ['omgevingsvergunning', 'bouwvergunning', 'stedenbouwkundig', "permis d'environnement", "permis d'urbanisme", 'building permit'],
      'epc' => ['epc', 'energieprestatiecertificaat', 'energielabel', 'peb', 'energy performance', 'renovatie verplichting'],
      'asbest' => %w[asbest amiante asbestos asbestattest],
      'bodemattest' => ['bodemattest', 'bodemverontreiniging', 'bodemsanering', 'ovam', 'attestation de sol'],
      'geluid' => ['geluid', 'geluidsnorm', 'nachtlawaai', 'geluidsoverlast', 'bruit', 'nuisance sonore', 'noise', 'vlarem', 'decibel'],
      'kapvergunning' => ['kapvergunning', 'boom kappen', 'bomen kappen', 'ontbossing', 'abattage', 'felling permit'],
      'zonnepanelen' => ['zonnepanelen', 'zonnepaneel', 'solar panel', 'panneau solaire', 'prosument', 'terugdraaiende teller'],
      'loonbescherming' => ['loonbescherming', 'loonbeslag', 'loonoverdracht', 'saisie sur salaire', 'wage protection'],
      'gdpr_processor' => ['verwerker', 'verwerkersovereenkomst', 'gegevensverwerker', 'subverwerker',
                           'processor', 'data processor', 'sous-traitant', 'auftragsverarbeiter'],
      'gdpr' => ['gdpr', 'avg', 'privacy', 'gegevensbescherming', 'rgpd', 'data protection', 'datenschutz', 'dpo', 'datalek']
    }.freeze

    # ── Semantic topic matching ──
    # Cosine similarity against precomputed topic embeddings supplements the
    # keyword layer: it matches phrasings the hardcoded lists can never
    # enumerate (synonyms, inflections, paraphrases in any language).
    # Facts override retrieved sources, so the threshold is conservative and
    # at most SEMANTIC_TOP_K semantic topics are admitted per question.
    #
    # Threshold calibrated against real embeddings on staging (July 2026):
    # off-topic questions top out ~0.21; correct-topic paraphrases reach
    # 0.46+ ("betaalde rust per jaar" -> vakantiedagen 0.46); but the
    # 0.30-0.42 band contains WRONG topics (vacation question -> carensdag
    # 0.389). 0.45 admits only strong correct matches — do not lower it
    # without re-running the calibration in scripts/ against real vectors.
    SEMANTIC_SIMILARITY_THRESHOLD = 0.45
    SEMANTIC_TOP_K = 2
    # Deep-analysis prompts (question+answer+instructions) are not questions —
    # don't burn embedding tokens on them; the keyword layer still applies.
    SEMANTIC_MAX_QUESTION_LENGTH = 500
    TOPIC_EMBEDDINGS_TTL = 7.days
    SEMANTIC_CACHE_SCHEMA_VERSION = 1

    # These fact blocks contain one region's legislation. They may only
    # override retrieval when the question names that region; otherwise the
    # regional retriever must compare/ask for the applicable regime.
    REGION_SCOPED_FACT_KEYS = {
      'huur' => :flanders,
      'registratierechten' => :flanders,
      'erfbelasting' => :flanders,
      'omgevingsvergunning' => :flanders,
      'epc' => :flanders,
      'asbest' => :flanders,
      'bodemattest' => :flanders,
      'geluid' => :flanders,
      'kapvergunning' => :flanders,
      'zonnepanelen' => :flanders,
      'inburgering' => :brussels
    }.freeze

    # These terms identify a Flemish instrument even when the user does not
    # redundantly name the region. Broader terms (PEB, asbestos, soil
    # contamination) remain region-gated.
    IMPLICIT_FLANDERS_TOPIC_PATTERNS = {
      'epc' => /(?<![[:alnum:]])(?:epc|energieprestatiecertificaat)(?![[:alnum:]])/iu,
      'asbest' => /(?<![[:alnum:]])asbest(?:inventaris)?attest(?![[:alnum:]])/iu,
      'bodemattest' => /(?<![[:alnum:]])(?:bodemattest|ovam)(?![[:alnum:]])/iu
    }.freeze

    REGION_PATTERNS = {
      flanders: RegionalSearch::REGION_PATTERNS.fetch('vlaamse_codex'),
      brussels: RegionalSearch::REGION_PATTERNS.fetch('brussels')
    }.freeze

    def initialize(language: 'nl', embedding_service: nil)
      @language = language
      @fact_provider = LegalFactProvider.new(language: language)
      @embedding_service = embedding_service || EmbeddingService.new(language: language)
    end

    def self.semantic_cache_state
      new.semantic_cache_state
    end

    # Secret-free state seal used by quality provenance. Missing or malformed
    # topic vectors are reported as not ready (rather than silently looking
    # like a valid empty generation), and every valid generation binds the
    # descriptor set to the exact embedding configuration and vector bytes.
    def semantic_cache_state
      payload = Rails.cache.read(topic_embeddings_cache_key)
      ready = valid_topic_embeddings_payload?(payload)
      embeddings = payload.is_a?(Hash) ? payload_value(payload, :embeddings) : nil
      generation = if ready
                     payload_value(payload, :generation)
                   elsif payload.nil?
                     'missing'
                   else
                     Digest::SHA256.hexdigest(Marshal.dump(payload))
                   end

      {
        ready: ready,
        generation: generation,
        descriptor_digest: topic_descriptors_digest,
        embedding_config_digest: embedding_identity.fetch(:config_digest),
        expected_topic_count: SECTION_KEYWORD_MAP.size,
        topic_count: embeddings.respond_to?(:size) ? embeddings.size : 0,
        cache_key_sha256: Digest::SHA256.hexdigest(topic_embeddings_cache_key)
      }
    rescue StandardError => e
      raise "semantic reference cache state is unavailable: #{e.class}"
    end

    # Match question to topics (keyword layer + semantic layer), then fetch
    # facts from DB. Returns array of text sections.
    def select_relevant_sections(question)
      return [] if question.blank?

      keyword_keys = keyword_matched_keys(question.downcase).select do |key|
        contextually_applicable?(key, question)
      end
      semantic_keys = (semantic_matched_keys(question) - keyword_keys).select do |key|
        contextually_applicable?(key, question)
      end
      matched_keys = keyword_keys + semantic_keys

      return [] if matched_keys.empty?

      matched_sections = []
      missing_sections = 0

      matched_keys.each do |key|
        db_fact = @fact_provider.fetch_facts(key, question: question)
        if db_fact.present?
          matched_sections << db_fact
        else
          missing_sections += 1
        end
      end

      Rails.logger.info(
        "[REFSHEET] matched=#{matched_sections.size} missing=#{missing_sections} " \
        "keyword=#{keyword_keys.size} semantic=#{semantic_keys.size}"
      )

      matched_sections.uniq
    end

    # Deterministic, keyword-gated official source records for the
    # orchestrator. Semantic matching is intentionally excluded here: these
    # records become citation authority, so a fuzzy neighbour must never be
    # enough to admit them.
    def select_authoritative_sources(question)
      return [] if question.blank?

      keyword_matched_keys(question.downcase).select do |key|
        contextually_applicable?(key, question)
      end.flat_map { |key| @fact_provider.authoritative_sources_for(key) }.uniq { |source| source[:url] }
    rescue StandardError => e
      Rails.logger.warn("[REFSHEET] Official source selection failed: #{e.class}")
      []
    end

    # Precompute and cache embeddings for every topic descriptor.
    # Called synchronously as a deploy prerequisite (and again by the broader
    # background cache warmup) so an activated release always has the complete
    # current generation. Requests only read this cache and safely skip the
    # semantic layer when it is absent outside the managed deploy path.
    def warm_topic_embeddings!
      embeddings = SECTION_KEYWORD_MAP.filter_map do |key, keywords|
        vector = @embedding_service.generate(topic_descriptor(key, keywords))
        [key, vector] if valid_topic_vector?(vector)
      end.to_h
      return 0 unless embeddings.size == SECTION_KEYWORD_MAP.size

      generation = topic_embeddings_generation(embeddings)
      payload = {
        schema_version: SEMANTIC_CACHE_SCHEMA_VERSION,
        descriptor_digest: topic_descriptors_digest,
        embedding_config_digest: embedding_identity.fetch(:config_digest),
        generation: generation,
        embeddings: embeddings
      }
      Rails.cache.write(topic_embeddings_cache_key, payload, expires_in: TOPIC_EMBEDDINGS_TTL)
      embeddings.size
    end

    # Extract key facts from DB-sourced section text.
    # DB-sourced sections start with [Label] format.
    def extract_imperative_facts(sections)
      facts = []
      sections.each do |section_text|
        next unless section_text.start_with?('[')

        label = section_text.lines.first&.strip&.gsub(/[\[\]]/, '') || ''
        content_lines = section_text.lines.drop(1)
        content_lines.each do |line|
          line = line.strip
          next if line.blank?

          facts << "#{label}: #{line}" unless line.length > 2000
        end
      end
      facts
    end

    def log_usage(question, answer)
      return unless answer && question

      Rails.logger.debug(
        "[REFSHEET] usage question_length=#{question.to_s.length} answer_length=#{answer.to_s.length}"
      )
    end

    private

    def contextually_applicable?(key, question)
      q = question.to_s.downcase

      processor_question = LegalFactProvider.gdpr_processor_question?(question)
      return processor_question if key == LegalFactProvider::GDPR_PROCESSOR_TOPIC_KEY
      # The Belgian 2018 Act supplements the EU regulation. For a processor
      # definition/duties question, admitting its unrelated article numbers as
      # an "AVG" fact is precisely the source-confusion failure we must avoid.
      return false if key == 'gdpr' && processor_question

      # "opzeg(termijn)" is shared by employment, leases, insurance, telecom,
      # and subscriptions. Do not inject the employment ladder into a
      # non-employment cancellation question merely because the same noun is
      # present.
      if key == 'opzegtermijn'
        non_employment = q.match?(/\b(?:woninghuur|handelshuur|huurcontract|huur|huurder|verhuurder|bail|locataire|verzekering|assurance|abonnement|telecom|energiecontract)\w*\b/i)
        employment = q.match?(/\b(?:werkgever|werknemer|arbeid|ontslag|anci[eë]nniteit|employeur|travailleur|licenciement|démission)\w*\b/i)
        return false if non_employment && !employment
      end

      # The gates below exist because facts are injected with override
      # authority, so a wrong pack is worse than no pack (2026-07-29 spot
      # check, wrong-pack/regime-conflation families; details and exemplar
      # keys in docs/ops/legal-merit-fixes-2026-08-03.md). Each follows the
      # opzegtermijn pattern above: reject only when the question is clearly
      # about the colliding domain and shows none of this pack's own context.

      # 'pension' is also FR child support (pension alimentaire), and 'rente'
      # is everyday Dutch for INTEREST while being everyday German for
      # PENSION. Keep both keywords for FR/DE recall, gate the collisions.
      if key == 'pensioenleeftijd'
        # Child-support detection must stay a phrase or an exact NL term:
        # the earlier \balimentati\w*\b also matched FR 'alimentation' (the
        # food industry) and hard-rejected genuine pension questions from
        # food-sector workers (review finding, 2026-08-03).
        return false if q.match?(/\b(?:pension|pensioen)s?\s+alimentaires?\b|\bonderhoudsgeld\b|\bonderhoudsbijdrage\w*\b|\balimentatie(?:geld|plicht|regeling|bedrag)?\b/i)

        # 'wettelijke rente'/'rentevoet' mark the interest reading directly:
        # terse questions like "Wat is de wettelijke rente?" contain no
        # payment word, and the gate missed them (review finding, 2026-08-03).
        interest_context = q.match?(/\b(?:factuur|facture|invoice|betaling|paiement|lening|prêt|krediet|crédit|intrest|interest|intérêt|verwijl|nalatigheids)\w*\b/i) ||
                           q.match?(/\bwettelijke\s+rente\b|\brentevoet\w*\b/i)
        pension_context = q.match?(/\b(?:pensioen|pension|pensionering|retraite|retirement|ruhestand|rentenalter|altersrente)\w*\b/i)
        return false if interest_context && !pension_context
      end

      # Bare 'verlof'/'congé' must not answer a SPECIFIC leave question with
      # the annual-vacation pack. Two triggers, deliberately narrow after the
      # first version over-rejected (review findings, 2026-08-03):
      # - a COMPETING leave pack's own keywords fired, so the right pack
      #   exists and conflation is the real risk (ouderschapsverlof etc.);
      # - the question names a klein-verlet EVENT (marriage, bereavement)
      #   whose pack keywords are too phrase-bound to fire on natural word
      #   order, where a miss (plain retrieval) still beats the wrong pack.
      # Sickness deliberately does NOT reject: vacation accrual and retention
      # during illness IS annual-vacation law (2024 reform) and has no
      # competing pack, so those questions must keep this one.
      if key == 'vakantiedagen'
        competing_pack = %w[moederschapsverlof vaderschapsverlof ouderschapsverlof klein_verlet].any? do |pack|
          pack_keyword_fired?(pack, q)
        end
        event_leave = q.match?(/\b(?:huwelijk|trouwen|mariage|wedding|overlijden|begrafenis|uitvaart|deuil|fun[eé]railles)\w*\b/i)
        return false if competing_pack || event_leave
      end

      # Drunk-driving facts need BOTH families present: bare 'rijden' fired on
      # every driving question, bare 'alcohol' on every alcohol question.
      # Legal-measurement terms (promille, breathalyser) are sufficient ALONE:
      # "Hoeveel promille mag ik hebben?" needs no driving word to be a
      # drunk-driving question, and the first gate version rejected it along
      # with "twee glazen wijn ... rijden" phrasings (review, 2026-08-03).
      if key == 'alcohol_rijden'
        legal_measure = q.match?(/\b(?:promille|bloedalcohol|ademtest|alcoholgehalte|alcoholcontrole|alcoholslot)\w*\b/i)
        alcohol = legal_measure ||
                  q.match?(/\b(?:alcohol|alcool|dronken|drunk|betrunken|gedronken|drinken|wijn|vin|bier|bi[eè]re|glas|glazen|pintje)\w*\b/i)
        driving = q.match?(/\b(?:rijden|rijd|reed|rijbewijs|sturen|stuur|steuer|auto|wagen|voiture|conduire|conduite|volant|driving|drive|fahren|verkeer)\w*\b/i)
        return false unless legal_measure || (alcohol && driving)
      end

      # 'reserve' is also the corporate legal reserve; inheritance facts do
      # not belong in company-law questions. 'kapitaal'/'capital' were removed
      # from the corporate markers: families give away capital too ("vader
      # heeft zijn kapitaal weggeschonken ... mijn reserve?") and the word
      # alone mis-classified genuine hereditary-reserve questions (review,
      # 2026-08-03). Family and gift words now count as inheritance context.
      if key == 'erfrecht'
        corporate = q.match?(/\b(?:vennootschap|bv|nv|srl|aandeelhouder|shareholder|société|company|dividend|balans|boekhouding)\w*\b/i)
        inheritance = q.match?(/\b(?:erf|erfenis|erven|nalatenschap|overlijden|overleden|succession|héritage|hériter|erben|testament|legaat|reservatair|schenking|geschonken|weggeschonken|erfgenaam|erfdeel|vader|moeder|ouders|kinderen)\w*\b/i)
        return false if corporate && !inheritance
      end

      # 'majority'/'majorité' are also voting thresholds, and FR 'majeure'
      # appears in force majeure; the age-of-majority pack needs age context
      # whenever those other readings are on the table.
      if key == 'meerderjarigheid'
        # No bare 'jaar'/'ans'/'18' here: any duration ("bail de 9 ans")
        # counted as age context and defeated the force-majeure rejection
        # (review finding, 2026-08-03). Age words must actually be about age.
        age_context = q.match?(/\b(?:leeftijd|âge|minderjarig|mineur|meerderjarig|volljährig|minderjährig|kind)\w*\b|\b18\s*(?:jaar|ans|jahre|years?)\b/i)
        return false if q.match?(/\bforce\s+majeure\b|\bovermacht\b/i) && !age_context

        corporate_vote = q.match?(/\b(?:aandeelhouder|shareholder|vergadering|assemblée|meeting|stem|vote|voix|statuten|statuts|bestuur|raad)\w*\b/i)
        return false if corporate_vote && !age_context
      end

      # Opdeciemen multiply CRIMINAL fines only; contractual and consumer
      # penalty clauses ('boete' in everyday Dutch) are a different regime.
      # 'flits'/'flash'/'radar' match as SUBSTRINGS on purpose: the standard
      # Dutch participle is 'geflitst', whose ge- prefix defeats a \b anchor,
      # and FR users say 'flashé' (review finding, 2026-08-03). The lay
      # traffic phrasings (rood licht, gsm achter het stuur) are criminal
      # fines and belong in this pack.
      if key == 'opdeciemen'
        explicit = q.match?(/\b(?:opdeciem|décime)\w*\b/i)
        criminal = q.match?(/flits|flash|radar/i) ||
                   q.match?(/\b(?:strafrecht|strafbaar|misdrijf|overtreding|proces-verbaal|rechtbank|rechter|politie|veroordeel|verkeer|snelheid|stuur|gsm|pénal|infraction|tribunal|condamn|vitesse|gerecht)\w*\b/i) ||
                   q.match?(/\broo?de?\s+licht\b|\bfeu\s+rouge\b/i)
        return false unless explicit || criminal
      end

      region = REGION_SCOPED_FACT_KEYS[key]
      return true unless region

      implicit_pattern = IMPLICIT_FLANDERS_TOPIC_PATTERNS[key]
      return true if region == :flanders && implicit_pattern && q.match?(implicit_pattern)

      q.match?(REGION_PATTERNS.fetch(region))
    end

    # Keyword layer: precise word-boundary matching.
    # Substring matching made 'bv' fire on "subvention" and 'minimum' (via
    # bv_kapitaal) fire on minimum-wage questions. [[:alpha:]] lookarounds are
    # Unicode-aware (\b mis-handles accented keywords like "congé").
    # The (?:s|es|en|e|n)? suffix admits NL/FR plurals/inflections while still
    # rejecting compound continuations like "minimumloon".
    def keyword_matched_keys(q_down)
      SECTION_KEYWORD_MAP.select do |_key, keywords|
        keywords.any? { |kw| q_down.match?(keyword_pattern(kw)) }
      end.keys
    end

    def keyword_pattern(keyword)
      /(?<![[:alpha:]])#{Regexp.escape(keyword.downcase)}(?:s|es|en|e|n)?(?![[:alpha:]])/
    end

    def pack_keyword_fired?(key, q_down)
      SECTION_KEYWORD_MAP.fetch(key, []).any? { |kw| q_down.match?(keyword_pattern(kw)) }
    end

    # Semantic layer: embedding similarity against precomputed topic vectors.
    # Read-only at request time — the request-scoped embedding service reuses
    # the vector generated by the orchestrator moments earlier, while only the
    # code-defined topic vectors live in Rails.cache. User question text,
    # hashes, and vectors are never written there. Any failure degrades
    # silently to keyword-only matching.
    def semantic_matched_keys(question)
      return [] if question.length > SEMANTIC_MAX_QUESTION_LENGTH
      return [] unless defined?(Rails) && Rails.cache

      payload = Rails.cache.read(topic_embeddings_cache_key)
      return [] unless valid_topic_embeddings_payload?(payload)

      topics = payload_value(payload, :embeddings)

      q_embedding = @embedding_service.generate(question)
      return [] if q_embedding.blank?

      scored = topics.filter_map do |key, vector|
        sim = @embedding_service.cosine_similarity(q_embedding, vector)
        [key, sim.round(3)] if sim >= SEMANTIC_SIMILARITY_THRESHOLD
      end

      top = scored.sort_by { |_, sim| -sim }.first(SEMANTIC_TOP_K)
      Rails.logger.info("[REFSHEET] semantic_matches=#{top.size}") if top.any?
      top.map(&:first)
    rescue ModelsConfig::BudgetLimitExceeded
      # An embedding cache miss is billable. Let the controller settle the
      # request as a cap rejection instead of silently continuing to the final
      # answer provider after authoritative budget enforcement said no.
      raise
    rescue StandardError => e
      Rails.logger.debug("[REFSHEET] Semantic matching unavailable: #{e.class}")
      []
    end

    def topic_descriptor(key, keywords)
      "#{key.tr('_', ' ')}: #{keywords.join(', ')}"
    end

    def embedding_identity
      @embedding_identity ||= if @embedding_service.respond_to?(:identity)
                                @embedding_service.identity
                              else
                                EmbeddingService.current_identity
                              end
    end

    def topic_descriptors_digest
      @topic_descriptors_digest ||= Digest::SHA256.hexdigest(
        SECTION_KEYWORD_MAP.map { |key, keywords| topic_descriptor(key, keywords) }.join('|')
      )
    end

    def valid_topic_vector?(vector)
      expected_dimensions = Integer(embedding_identity.fetch(:dimensions))
      vector.is_a?(Array) && vector.length == expected_dimensions && vector.all? do |component|
        component.is_a?(Numeric) && (!component.respond_to?(:finite?) || component.finite?)
      end
    end

    def topic_embeddings_generation(embeddings)
      digest = Digest::SHA256.new
      digest << "semantic-reference-v#{SEMANTIC_CACHE_SCHEMA_VERSION}\0"
      digest << topic_descriptors_digest << "\0"
      digest << embedding_identity.fetch(:config_digest) << "\0"
      embeddings.sort_by { |key, _vector| key.to_s }.each do |key, vector|
        digest << key.to_s << "\0" << [vector.length].pack('N') << vector.map(&:to_f).pack('G*')
      end
      digest.hexdigest
    end

    def valid_topic_embeddings_payload?(payload)
      return false unless payload.is_a?(Hash)
      return false unless payload_value(payload, :schema_version) == SEMANTIC_CACHE_SCHEMA_VERSION
      return false unless payload_value(payload, :descriptor_digest) == topic_descriptors_digest
      return false unless payload_value(payload, :embedding_config_digest) == embedding_identity.fetch(:config_digest)

      embeddings = payload_value(payload, :embeddings)
      return false unless embeddings.is_a?(Hash) && embeddings.keys.map(&:to_s).sort == SECTION_KEYWORD_MAP.keys.sort
      return false unless embeddings.values.all? { |vector| valid_topic_vector?(vector) }

      ActiveSupport::SecurityUtils.secure_compare(
        payload_value(payload, :generation).to_s,
        topic_embeddings_generation(embeddings)
      )
    end

    def payload_value(payload, key)
      payload.key?(key) ? payload[key] : payload[key.to_s]
    end

    # Digest of all descriptors: editing any keyword list automatically
    # invalidates the cached vectors (the warmup writes under the new key).
    def topic_embeddings_cache_key
      @topic_embeddings_cache_key ||=
        "refsheet_topic_embeddings:v#{SEMANTIC_CACHE_SCHEMA_VERSION}:#{topic_descriptors_digest}:#{embedding_identity.fetch(:config_digest)}"
    end
  end
end
