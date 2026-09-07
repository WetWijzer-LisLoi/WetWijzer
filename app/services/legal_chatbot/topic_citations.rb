# frozen_string_literal: true

module LegalChatbot
  # Deterministic topic citations (FBL-061): the drug-regime and
  # GDPR-processor required citations (which SET @required_regime_citations /
  # @required_gdpr_processor_citations for the citation gate and must keep
  # their reset-on-entry), the topic patterns, the declarative
  # TOPIC_CITATION_RULES registry with its engine (which replaced the
  # fifteen hand-written appenders and the drifted parallel matcher table
  # on 2026-08-18, equivalence-proven byte-for-byte plus 15/15 adversarial
  # review), the topic fallback answers, and the localized note and answer
  # cascades. The historical drift (employment_vs_contractor without an
  # appender, mutual_consent_divorce without a fallback) is explicit
  # registry data pinned by legal_chatbot_topic_registry_drift_test.rb;
  # closing either gap is an owner-visible behavior decision.
  module TopicCitations
    extend ActiveSupport::Concern

    # Owned by the orchestrator (its citation gate also reads it); lexical
    # alias because sibling-concern constants do not resolve via ancestry.
    DRUG_CITATION_ARTICLE_PRIORITY = Orchestrator::DRUG_CITATION_ARTICLE_PRIORITY
    ARTICLE_SPACE_SOURCE = Orchestrator::ARTICLE_SPACE_SOURCE

    def ensure_required_drug_regime_citations(text, question, sources)
      @required_regime_citations = nil
      return text unless LegalChatbot::LegislationSearch::DRUG_OFFENCE_PATTERN.match?(question.to_s)

      required_numacs = LegalChatbot::CoreLawMappings::DRUG_REGIME_NUMACS
      allowed_pairs = sources.filter_map do |source|
        numac = retrieved_source_numac(source)
        article_number = retrieved_source_article_number(source)
        [numac, article_number] if numac.present? && article_number.present?
      end.to_set

      cited_pairs = verified_article_citation_pairs(text, allowed_pairs)
      cited_numacs = required_drug_regime_numacs(cited_pairs)
      links = (required_numacs - cited_numacs).filter_map do |numac|
        article_number = DRUG_CITATION_ARTICLE_PRIORITY.fetch(numac).find do |candidate|
          allowed_pairs.include?([numac, normalize_article_number(candidate)])
        end
        next unless article_number

        label = drug_regime_citation_label(numac, article_number)
        "[#{label}](#{chatbot_article_href(numac, normalize_article_number(article_number))})"
      end

      @required_regime_citations = { required_numacs: required_numacs, version: 1 }
      return text if links.empty?

      "#{text.to_s.rstrip}\n\n#{drug_regime_citation_heading}\n#{links.map { |link| "- #{link}" }.join("\n")}"
    end

    def drug_regime_citation_heading
      case @language
      when 'fr' then '**Dispositions légales consultées :**'
      when 'de' then '**Konsultierte gesetzliche Bestimmungen:**'
      when 'en' then '**Statutory provisions consulted:**'
      else '**Geraadpleegde wettelijke bepalingen:**'
      end
    end

    def drug_regime_citation_label(numac, article_number)
      law_name = case @language
                 when 'fr'
                   numac == '2017031231' ? 'AR du 6 septembre 2017' : 'Loi sur les drogues de 1921'
                 when 'de'
                   numac == '2017031231' ? 'KE vom 6. September 2017' : 'Drogengesetz 1921'
                 when 'en'
                   numac == '2017031231' ? 'Royal Decree of 6 September 2017' : 'Belgian Drugs Act 1921'
                 else
                   numac == '2017031231' ? 'KB van 6 september 2017' : 'Drugswet 1921'
                 end
      "Art. #{article_number} — #{law_name}"
    end

    def ensure_required_gdpr_processor_citations(text, question, sources)
      @required_gdpr_processor_citations = nil
      return text unless LegalFactProvider.gdpr_processor_question?(question)

      required_pairs = LegalFactProvider.required_official_citations_for(
        LegalFactProvider::GDPR_PROCESSOR_TOPIC_KEY,
        language: @language
      ).to_set
      return text if required_pairs.empty?

      @required_gdpr_processor_citations = {
        required_external_pairs: required_pairs.to_a,
        forbidden_internal_numacs: ['2018040581'],
        version: 1
      }
      allowed_pairs = sources.filter_map do |source|
        next unless (source[:official_source_id] || source['official_source_id']) ==
                    LegalFactProvider::GDPR_PROCESSOR_OFFICIAL_SOURCE_ID

        url = (source[:url] || source['url']).to_s
        article_number = retrieved_source_article_number(source)
        pair = [url, article_number]
        pair if required_pairs.include?(pair)
      end.to_set
      cited_pairs = verified_external_article_citation_pairs(text, allowed_pairs)
      missing_pairs = required_pairs - cited_pairs
      links = missing_pairs.filter_map do |url, article_number|
        next unless allowed_pairs.include?([url, article_number])

        "[#{gdpr_processor_citation_label(article_number)}](#{url})"
      end
      return text if links.empty?

      "#{text.to_s.rstrip}\n\n#{gdpr_processor_citation_heading}\n#{links.map { |link| "- #{link}" }.join("\n")}"
    end

    def gdpr_processor_citation_heading
      case @language
      when 'fr' then '**Dispositions officielles du RGPD consultées :**'
      when 'de' then '**Konsultierte offizielle DSGVO-Bestimmungen:**'
      when 'en' then '**Official GDPR provisions consulted:**'
      else '**Geraadpleegde officiële AVG-bepalingen:**'
      end
    end

    def gdpr_processor_citation_label(article_number)
      case @language
      when 'fr'
        article_number == '4' ? 'Art. 4, point 8 — RGPD (définition)' : 'Art. 28 — RGPD (sous-traitant)'
      when 'de'
        article_number == '4' ? 'Art. 4 Nr. 8 — DSGVO (Definition)' : 'Art. 28 — DSGVO (Auftragsverarbeiter)'
      when 'en'
        article_number == '4' ? 'Art. 4(8) — GDPR (definition)' : 'Art. 28 — GDPR (processor)'
      else
        article_number == '4' ? 'Art. 4, lid 8 — AVG (definitie)' : 'Art. 28 — AVG (verwerker)'
      end
    end

    VAT_FOOD_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:btw|tva|vat|belasting\s+over\s+de\s+toegevoegde\s+waarde|taxe\s+sur\s+la\s+valeur\s+ajout[eé]e)\b)
      (?=.*\b(?:voeding\w*|voedingsmiddelen|levensmiddel\w*|alimentation\w*|food)\b)
      .*\z
    /ix
    INVOICE_PRESCRIPTION_TOPIC_PATTERN = /
      (?:\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b.{0,80}\bfactu(?:u|re)r\w*\b)|
      (?:\bfactu(?:u|re)r\w*\b.{0,80}\b(?:verjarings?termijn|verjaring|verjaren|verjaart|verjaarde|verjaard)\b)
    /ix
    ALCOHOL_DRIVING_TOPIC_PATTERN = LegalChatbot::LegislationSearch::ALCOHOL_DRIVING_LIMIT_PATTERN
    ONLINE_PURCHASE_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:online|internet|afstand|aankop\w*|aankoop|vente\s+à\s+distance|distance\s+selling)\b)
      (?=.*\b(?:consument\w*|consumer\w*|consommateur\w*|herroep\w*|rétractation|withdraw\w*)\b)
      .*\z
    /ix
    UNILATERAL_EMPLOYMENT_CHANGE_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:werkgever|employeur|employer)\b)
      (?=.*\b(?:eenzijdig|unilat[eé]ral\w*|unilateral\w*)\b)
      (?=.*\b(?:arbeidsvoorwaarden|voorwaarden|conditions?|wijzig\w*|modifier|change)\b)
      .*\z
    /ix
    NOTICE_PERIOD_FIVE_YEARS_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:opzegtermijn|opzeggingstermijn|d[eé]lai\s+de\s+pr[eé]avis|notice\s+period)\b)
      (?=.*\b(?:5|vijf|cinq|five)\s+(?:jaar|jaren|ans|years?)\b)
      (?=.*\b(?:anci[eë]nniteit|anciennet[eé]|seniority)\b)
      .*\z
    /ix
    SUMMARY_PROCEEDINGS_TOPIC_PATTERN = /
      \b(?:kort\s+geding|référé|procedure\s+en\s+référé|summary\s+proceedings?)\b
    /ix
    MATERNITY_LEAVE_TOPIC_PATTERN = /
      \b(?:moederschapsverlof|maternity\s+leave|cong[eé]\s+de\s+maternit[eé]|mutterschaftsurlaub)\b
    /ix
    ANNUAL_VACATION_DURATION_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:jaarlijkse\s+vakantie|vakantiedagen|betaald\s+verlof|wettelijke\s+vakantie|congés?\s+payés?|annual\s+leave|holiday\s+entitlement)\b)
      (?=.*\b(?:hoeveel|aantal|dagen|duur|per\s+jaar|combien|nombre|jours|durée|how\s+many|days?|duration)\b)
      .*\z
    /ix
    SECONDHAND_CAR_WARRANTY_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:tweedehands|occasion|secondhand|used)\b)
      (?=.*\b(?:wagen|auto|voertuig|car|vehicle)\b)
      (?=.*\b(?:garantie|waarborg|warranty|conformiteit|conformity)\b)
      .*\z
    /ix
    PROBATION_PERIOD_TOPIC_PATTERN = /
      \b(?:proefperiode|proeftijd|p[eé]riode\s+d['’]?essai|trial\s+period|probation\s+period)\b
    /ix
    UNEMPLOYMENT_BENEFITS_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:werkloosheidsuitkering\w*|werkloosheid(?:s)?uitkering\w*|allocation\w*\s+de\s+ch[oô]mage|unemployment\s+benefit\w*)\b)
      (?=.*\b(?:ontslag|licenciement|dismissal|be[eë]indiging|termination)\b)
      .*\z
    /ix
    MUTUAL_CONSENT_DIVORCE_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:echtscheiding|divorce)\b)
      (?=.*\b(?:onderlinge\s+toestemming|consentement\s+mutuel|mutual\s+consent)\b)
      .*\z
    /ix
    THEFT_DISTINCTION_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:diefstal|vol|theft)\b)
      (?=.*\b(?:verduistering|d[eé]tournement|embezzlement)\b)
      .*\z
    /ix
    EMPLOYMENT_VS_CONTRACTOR_TOPIC_PATTERN = /
      \A
      (?=.*\b(?:arbeidsovereenkomst|contrat\s+de\s+travail|employment\s+contract|arbeitsvertrag)\b)
      (?=.*\b(?:aannemingsovereenkomst|overeenkomst\s+van\s+aanneming|zelfstandige|contrat\s+d['’]entreprise|ind[eé]pendant|independent\s+contract(?:or)?|werkvertrag|selbst[aä]ndig)\b)
      .*\z
    /ix
    NON_COMPETE_TOPIC_PATTERN = /
      \b(?:concurrentiebeding|niet[- ]?concurrentiebeding|clause\s+de\s+non[- ]?concurrence|non[- ]?compete|wettbewerbsverbot)\b
    /ix
    MINIMUM_WAGE_TOPIC_PATTERN = /
      \b(?:minimumloon|ggmmi|rmmmg|minimum\s+wage|salaire\s+minimum|mindestlohn)\b
    /ix


    # ── Declarative topic registry (FBL-061) ────────────────────────────────
    # One entry per topic, replacing the fifteen hand-written appenders and
    # the parallel matcher table that had drifted apart. Semantics are
    # carried over EXACTLY, deviations included:
    #   guard: :minimum_wage   - historical-question gate plus the
    #                            ggmmi-stale fail-closed suppression
    #                            (owner decision C, 2026-08-03);
    #   probe: :current_ggmmi  - the accepted-renderings pattern DERIVED
    #                            from LegalFactProvider::CURRENT_GGMMI;
    #   probe: [a, b]          - force when EITHER fact is missing
    #                            (secondhand-car warranty);
    #   promille_note: true    - a missed probe also appends the promille
    #                            equivalence to the note (alcohol);
    #   list: [...]            - plural citation (mutual-consent divorce);
    #   appender/fallback      - the pinned drift, now explicit DATA:
    #                            :mutual_consent_divorce has no fallback,
    #                            :employment_vs_contractor no appender.
    # Array order IS appender execution order; fallback matcher order is
    # TOPIC_FALLBACK_ORDER below (they deliberately differ: vacation and
    # secondhand-car were historically swapped).
    TOPIC_CITATION_RULES = [
      {
        topic: :minimum_wage, pattern: MINIMUM_WAGE_TOPIC_PATTERN,
        match: { numac: '1988050250', article: '3' },
        label: 'Art. 3 — CAO nr. 43 (basisregeling)',
        answer: true, probe: :current_ggmmi, guard: :minimum_wage,
        appender: true, fallback: true
      },
      {
        topic: :vat_food, pattern: VAT_FOOD_TOPIC_PATTERN,
        match: { doc_type: 'KB 20', article: '1' },
        label: 'Art. 1 — KB nr. 20',
        answer: false, probe: nil, appender: true, fallback: true
      },
      {
        topic: :invoice_prescription, pattern: INVOICE_PRESCRIPTION_TOPIC_PATTERN,
        match: { numac: '1804032155', article: '2262bis' },
        label: 'Art. 2262bis — Oud Burgerlijk Wetboek',
        answer: false, probe: nil, appender: true, fallback: true
      },
      {
        topic: :alcohol_driving, pattern: ALCOHOL_DRIVING_TOPIC_PATTERN,
        match: { numac: '1968031601', article: '34' },
        label: 'Art. 34 — Wegverkeerswet',
        answer: false, probe: /\b0[,.]5\s*(?:promille|‰)\b/i,
        promille_note: true, appender: true, fallback: true
      },
      {
        topic: :online_purchase, pattern: ONLINE_PURCHASE_TOPIC_PATTERN,
        match: { numac: '2013A11134', article: 'vi-47' },
        label: 'Art. VI.47 — Wetboek economisch recht',
        answer: false, probe: nil, appender: true, fallback: true
      },
      {
        topic: :unilateral_employment_change, pattern: UNILATERAL_EMPLOYMENT_CHANGE_TOPIC_PATTERN,
        match: { numac: '1978070303', article: '25' },
        label: 'Art. 25 — Arbeidsovereenkomstenwet',
        answer: false, probe: nil, appender: true, fallback: true
      },
      {
        topic: :notice_period_five_years, pattern: NOTICE_PERIOD_FIVE_YEARS_TOPIC_PATTERN,
        match: { numac: '1978070303', article: '37-2' },
        label: 'Art. 37/2 — Arbeidsovereenkomstenwet',
        answer: true, probe: /\b(?:18|achttien|dix-huit|eighteen)\s+(?:weken|semaines|weeks?)\b/i,
        appender: true, fallback: true
      },
      {
        topic: :summary_proceedings, pattern: SUMMARY_PROCEEDINGS_TOPIC_PATTERN,
        match: { numac: '1967101054', article: '584' },
        label: 'Art. 584 — Gerechtelijk Wetboek',
        answer: false, probe: nil, appender: true, fallback: true
      },
      {
        topic: :maternity_leave, pattern: MATERNITY_LEAVE_TOPIC_PATTERN,
        match: { numac: '1971031602', article: '39' },
        label: 'Art. 39 — Arbeidswet',
        answer: true, probe: /\b(?:15|vijftien)\s+weken?\b/i,
        appender: true, fallback: true
      },
      {
        topic: :annual_vacation_duration, pattern: ANNUAL_VACATION_DURATION_TOPIC_PATTERN,
        match: { numac: '1971062850', article: '3' },
        label: 'Art. 3 — Jaarlijkse vakantiewet',
        answer: true, probe: /\b(?:24|vierentwintig)\s+(?:dagen|vakantiedagen)\b/i,
        appender: true, fallback: true
      },
      {
        topic: :secondhand_car_warranty, pattern: SECONDHAND_CAR_WARRANTY_TOPIC_PATTERN,
        match: { numac: '1804032154', article: '1649quater' },
        label: 'Art. 1649quater — Oud Burgerlijk Wetboek',
        answer: true,
        probe: [
          /\b(?:2|twee|deux|two|zwei)\s*(?:jaar|ans?|années?|years?|Jahre)\b/i,
          /\b(?:uitdrukkelijk|overeengekomen|overeenkomen|overeenkomst|verkort|beperk\w*|duidelijk|ondubbelzinnig)\b/i
        ],
        appender: true, fallback: true
      },
      {
        topic: :probation_period, pattern: PROBATION_PERIOD_TOPIC_PATTERN,
        match: { numac: '1978070303', article: '127' },
        label: 'Art. 127 — Arbeidsovereenkomstenwet',
        answer: true, probe: /\b(?:afgeschaft|supprim[eé]e?|abolished|abgeschafft)\b/i,
        appender: true, fallback: true
      },
      {
        topic: :unemployment_benefits, pattern: UNEMPLOYMENT_BENEFITS_TOPIC_PATTERN,
        match: { numac: '1991013192', article: '44' },
        label: 'Art. 44 — Werkloosheidsbesluit',
        answer: true, probe: nil, appender: true, fallback: true
      },
      {
        topic: :mutual_consent_divorce, pattern: MUTUAL_CONSENT_DIVORCE_TOPIC_PATTERN,
        list: [
          [{ numac: '1967101055', article: '1287' }, 'Art. 1287 — Gerechtelijk Wetboek', :mutual_consent_divorce_1287],
          [{ numac: '1967101055', article: '1288' }, 'Art. 1288 — Gerechtelijk Wetboek', :mutual_consent_divorce_1288]
        ],
        appender: true, fallback: false
      },
      {
        topic: :theft_distinction, pattern: THEFT_DISTINCTION_TOPIC_PATTERN,
        match: { numac: '2024002088', article: '463' },
        label: 'Art. 463 — Strafwetboek Boek II',
        answer: true, probe: /\b(?:wegnemen|weggenomen|enl[eè]vement|taking)\b/i,
        appender: true, fallback: true
      },
      {
        topic: :employment_vs_contractor, pattern: EMPLOYMENT_VS_CONTRACTOR_TOPIC_PATTERN,
        match: { numac: '1978070303', article: '2' },
        label: 'Art. 2 — Arbeidsovereenkomstenwet',
        answer: false, probe: nil, appender: false, fallback: true
      }
    ].map(&:freeze).freeze

    TOPIC_CITATION_RULES_BY_TOPIC = TOPIC_CITATION_RULES.index_by { |rule| rule[:topic] }.freeze

    # The historical matcher order: vacation ran after unemployment here
    # while the appender chain ran it before secondhand-car.
    TOPIC_FALLBACK_ORDER = %i[
      minimum_wage vat_food invoice_prescription alcohol_driving
      online_purchase unilateral_employment_change notice_period_five_years
      summary_proceedings maternity_leave secondhand_car_warranty
      probation_period unemployment_benefits annual_vacation_duration
      theft_distinction employment_vs_contractor
    ].freeze

    def ensure_high_confidence_topic_citations(text, question, sources)
      TOPIC_CITATION_RULES.inject(text.to_s) do |answer, rule|
        next answer unless rule[:appender]

        apply_topic_citation_rule(answer, question, sources, rule)
      end
    end

    def apply_topic_citation_rule(text, question, sources, rule)
      return text unless rule[:pattern].match?(question.to_s)

      if rule[:guard] == :minimum_wage
        return text if historical_minimum_wage_question?(question)

        # Past the recorded validity window the note itself would restate an
        # outdated amount as verified current law; degrade to silence, never
        # to poisoning a correct answer with a stale figure.
        if LegalFactProvider.ggmmi_stale?
          Rails.logger.warn('[Orchestrator] CURRENT_GGMMI is past stale_after; minimum-wage note suppressed')
          return text
        end
      end

      if rule[:list]
        entries = rule[:list].map do |match, label, note_key|
          [find_topic_source(sources, match), label, localized_citation_note(note_key)]
        end
        return append_retrieved_source_citation_list(text, entries)
      end

      source = find_topic_source(sources, rule[:match])
      force = case rule[:probe]
              when nil then false
              when :current_ggmmi then !text.to_s.match?(current_ggmmi_pattern)
              when Array then rule[:probe].any? { |pattern| !text.to_s.match?(pattern) }
              else !text.to_s.match?(rule[:probe])
              end
      note = localized_citation_note(rule[:topic])
      note = "#{note} #{localized_promille_equivalence}" if rule[:promille_note] && force
      note = "#{note} #{localized_high_confidence_topic_answer(rule[:topic])}" if rule[:answer]
      append_retrieved_source_citation(text, source, label: rule[:label], note: note, force: force)
    end

    # Identity first, article second, short-circuiting - the exact legacy
    # conjunct order. It matters beyond style: the article reader runs
    # regexes and unrescued accessor paths, so a candidate with a raising
    # article reader but a mismatching identity must be SKIPPED, never raise
    # (adversarial verification finding, 15/15 skeptics, 2026-08-18).
    def find_topic_source(sources, match)
      sources.find do |candidate|
        if match[:doc_type]
          source_document_type(candidate).casecmp?(match[:doc_type]) &&
            retrieved_source_article_number(candidate) == match[:article]
        else
          retrieved_source_numac(candidate) == match[:numac] &&
            retrieved_source_article_number(candidate) == match[:article]
        end
      end
    end

    def high_confidence_topic_matchers
      TOPIC_FALLBACK_ORDER.map do |topic|
        rule = TOPIC_CITATION_RULES_BY_TOPIC.fetch(topic)
        [
          rule[:pattern],
          topic,
          rule[:label],
          ->(candidate) { !find_topic_source([candidate], rule[:match]).nil? }
        ]
      end
    end

    def high_confidence_topic_fallback_answer(question, sources)
      multi_source_fallback = high_confidence_multi_source_fallback_answer(question, sources)
      return multi_source_fallback if multi_source_fallback

      source, topic, label = high_confidence_topic_source(question, sources)
      return nil unless source

      note = localized_citation_note(topic)
      note = "#{note} #{localized_promille_equivalence}" if topic == :alcohol_driving
      build_verified_topic_fallback(
        body: localized_high_confidence_topic_answer(topic),
        source: source,
        label: label,
        note: note
      )
    end

    def high_confidence_topic_source(question, sources)
      high_confidence_topic_matchers.each do |pattern, topic, label, matcher|
        next unless pattern.match?(question.to_s)
        next if topic == :minimum_wage && historical_minimum_wage_question?(question)
        # Same staleness rule as append_minimum_wage_citation: past the
        # record's validity window the canonical answer would serve an
        # outdated amount as a VERIFIED fallback, which is worse than the
        # generic fallback it degrades to (review finding, 2026-08-03).
        next if topic == :minimum_wage && LegalFactProvider.ggmmi_stale?

        source = sources.find { |candidate| matcher.call(candidate) }
        return [source, topic, label] if source
      end

      nil
    end

    def high_confidence_multi_source_fallback_answer(question, sources)
      if NON_COMPETE_TOPIC_PATTERN.match?(question.to_s)
        article_65 = sources.find do |candidate|
          retrieved_source_numac(candidate) == '1978070303' &&
            retrieved_source_article_number(candidate) == '65'
        end
        article_86 = sources.find do |candidate|
          retrieved_source_numac(candidate) == '1978070303' &&
            retrieved_source_article_number(candidate) == '86'
        end
        if article_65 && article_86
          return build_verified_multi_source_fallback(
            body: localized_high_confidence_topic_answer(:non_compete),
            entries: [
              [article_65, 'Art. 65 — Arbeidsovereenkomstenwet', localized_citation_note(:non_compete_65)],
              [article_86, 'Art. 86 — Arbeidsovereenkomstenwet', localized_citation_note(:non_compete_86)]
            ]
          )
        end
      end

      return nil unless MUTUAL_CONSENT_DIVORCE_TOPIC_PATTERN.match?(question.to_s)

      article_1287 = sources.find do |candidate|
        retrieved_source_numac(candidate) == '1967101055' &&
          retrieved_source_article_number(candidate) == '1287'
      end
      article_1288 = sources.find do |candidate|
        retrieved_source_numac(candidate) == '1967101055' &&
          retrieved_source_article_number(candidate) == '1288'
      end
      return nil unless article_1287 && article_1288

      build_verified_multi_source_fallback(
        body: localized_high_confidence_topic_answer(:mutual_consent_divorce),
        entries: [
          [article_1287, 'Art. 1287 — Gerechtelijk Wetboek', localized_citation_note(:mutual_consent_divorce_1287)],
          [article_1288, 'Art. 1288 — Gerechtelijk Wetboek', localized_citation_note(:mutual_consent_divorce_1288)]
        ]
      )
    end

    def build_verified_topic_fallback(body:, source:, label:, note:)
      append_retrieved_source_citation(
        "#{localized_verified_fallback_heading}\n#{body}",
        source,
        label: label,
        note: note,
        force: true
      )
    end

    def build_verified_multi_source_fallback(body:, entries:)
      append_retrieved_source_citation_list(
        "#{localized_verified_fallback_heading}\n#{body}",
        entries,
        force: true
      )
    end

    def citation_guard_source_list_fallback_answer(sources)
      entries = sources.filter_map do |source|
        label = retrieved_source_link_label(source)
        next if label.blank?

        [source, label, localized_consulted_source_note]
      end.first(5)
      return nil if entries.empty?

      append_retrieved_source_citation_list(
        "#{localized_verified_fallback_heading}\n#{localized_guarded_source_list_fallback_intro}",
        entries,
        force: true
      )
    end

    def localized_verified_fallback_heading
      case @language
      when 'fr' then '**Réponse vérifiée :**'
      when 'de' then '**Geprüfte Antwort:**'
      when 'en' then '**Verified answer:**'
      else '**Geverifieerd antwoord:**'
      end
    end

    # ── Localized topic copy (FBL-061 cascade fold) ─────────────────────────
    # The two 300-line case-[language, topic] cascades are data now, generated
    # by RUNNING the originals so every string is exact by construction. Only
    # the minimum-wage answer stays a method: it interpolates
    # LegalFactProvider::CURRENT_GGMMI so an indexation update flows through
    # without touching copy. The historical cascades' else returned the
    # ALCOHOL NL strings for any unknown [language, topic] pair; that quirk is
    # preserved verbatim via the two defaults below.
    TOPIC_CITATION_NOTES = {
      minimum_wage: {
        'nl' => 'Voor de cao-basis van het GGMMI, zie',
        'fr' => 'Pour la base conventionnelle du RMMMG, voyez',
        'de' => 'Zur kollektivvertraglichen Grundlage des durchschnittlichen Mindestmonatseinkommens siehe',
        'en' => 'For the collective-agreement basis of the guaranteed average minimum monthly income, see'
      }.freeze,
      vat_food: {
        'nl' => 'Voor het verlaagde btw-tarief op voedingsmiddelen, zie',
        'fr' => 'Pour le taux TVA réduit applicable aux denrées alimentaires, voyez',
        'de' => 'Zum ermäßigten Mehrwertsteuersatz für Lebensmittel siehe',
        'en' => 'For the reduced VAT rate on food, see'
      }.freeze,
      invoice_prescription: {
        'nl' => 'Voor de algemene burgerlijke verjaringstermijn voor factuurvorderingen, zie',
        'fr' => 'Pour le délai civil général de prescription des créances de facture, voyez',
        'de' => 'Zur allgemeinen zivilrechtlichen Verjährung von Rechnungsforderungen siehe',
        'en' => 'For the general civil prescription period for invoice claims, see'
      }.freeze,
      alcohol_driving: {
        'nl' => 'Voor de alcohollimiet in het verkeer, zie',
        'fr' => 'Pour la limite d\'alcool au volant, voyez',
        'de' => 'Zur Alkoholgrenze im Straßenverkehr siehe',
        'en' => 'For the drink-driving alcohol limit, see'
      }.freeze,
      online_purchase: {
        'nl' => 'Voor het herroepingsrecht bij consumentenkoop op afstand, zie',
        'fr' => 'Pour le droit de rétractation des consommateurs lors des achats à distance, voyez',
        'de' => 'Zum Widerrufsrecht bei Fernabsatzkäufen von Verbrauchern siehe',
        'en' => 'For the consumer withdrawal right in distance purchases, see'
      }.freeze,
      unilateral_employment_change: {
        'nl' => 'Voor de nietigheid van eenzijdige wijzigingsbedingen in arbeidsovereenkomsten, zie',
        'fr' => 'Pour la nullité des clauses de modification unilatérale du contrat de travail, voyez',
        'de' => 'Zur Nichtigkeit einseitiger Änderungsklauseln im Arbeitsvertrag siehe',
        'en' => 'For the nullity of unilateral employment-contract change clauses, see'
      }.freeze,
      notice_period_five_years: {
        'nl' => 'Voor de opzegtermijn na vijf jaar anciënniteit, zie',
        'fr' => 'Pour le délai de préavis après cinq ans d\'ancienneté, voyez',
        'de' => 'Zur Kündigungsfrist nach fünf Jahren Betriebszugehörigkeit siehe',
        'en' => 'For the notice period after five years of seniority, see'
      }.freeze,
      summary_proceedings: {
        'nl' => 'Voor de bevoegdheid in kort geding, zie',
        'fr' => 'Pour la compétence en référé, voyez',
        'de' => 'Zur Zuständigkeit im Eilverfahren siehe',
        'en' => 'For summary-proceedings jurisdiction, see'
      }.freeze,
      maternity_leave: {
        'nl' => 'Voor de standaardduur van het moederschapsverlof, zie',
        'fr' => 'Pour la durée standard du congé de maternité, voyez',
        'de' => 'Zur Standarddauer des Mutterschaftsurlaubs siehe',
        'en' => 'For the standard maternity-leave duration, see'
      }.freeze,
      annual_vacation_duration: {
        'nl' => 'Voor de wettelijke duur van de jaarlijkse vakantie, zie',
        'fr' => 'Pour la durée légale des vacances annuelles, voyez',
        'de' => 'Zur gesetzlichen Dauer des Jahresurlaubs siehe',
        'en' => 'For the statutory annual-leave duration, see'
      }.freeze,
      secondhand_car_warranty: {
        'nl' => 'Voor de wettelijke garantie bij consumentenkoop van een tweedehands wagen, zie',
        'fr' => 'Pour la garantie légale des voitures d\'occasion vendues aux consommateurs, voyez',
        'de' => 'Zur gesetzlichen Garantie bei Gebrauchtwagenkäufen von Verbrauchern siehe',
        'en' => 'For the legal warranty on consumer secondhand-car purchases, see'
      }.freeze,
      probation_period: {
        'nl' => 'Voor de studentenuitzondering op de proeftijd, zie',
        'fr' => 'Pour l\'exception relative à la période d\'essai dans les contrats d\'étudiant, voyez',
        'de' => 'Zur Ausnahme für die Probezeit in Studentenverträgen siehe',
        'en' => 'For the student-contract exception to the trial-period rule, see'
      }.freeze,
      unemployment_benefits: {
        'nl' => 'Voor de werkloosheidsvoorwaarde in de werkloosheidsreglementering, zie',
        'fr' => 'Pour la condition de chômage dans le règlement chômage, voyez',
        'de' => 'Zur Arbeitslosigkeitsbedingung in der Arbeitslosenregelung siehe',
        'en' => 'For the unemployment condition in the unemployment-benefits regulation, see'
      }.freeze,
      mutual_consent_divorce_1287: {
        'nl' => 'Voor de voorafgaande overeenkomsten tussen echtgenoten, zie',
        'fr' => 'Pour les conventions préalables entre époux, voyez',
        'de' => 'Zu den vorherigen Vereinbarungen der Ehegatten siehe',
        'en' => 'For the spouses’ prior agreements, see'
      }.freeze,
      mutual_consent_divorce_1288: {
        'nl' => 'Voor de bijkomende neer te leggen regeling, zie',
        'fr' => 'Pour les autres conventions à déposer, voyez',
        'de' => 'Zu den weiteren einzureichenden Vereinbarungen siehe',
        'en' => 'For the further agreements to be filed, see'
      }.freeze,
      theft_distinction: {
        'nl' => 'Voor de definitie van diefstal, zie',
        'fr' => 'Pour la définition du vol, voyez',
        'de' => 'Zur Definition des Diebstahls siehe',
        'en' => 'For the definition of theft, see'
      }.freeze,
      employment_vs_contractor: {
        'nl' => 'Voor het gezagsverband bij een arbeidsovereenkomst, zie',
        'fr' => 'Pour le lien d\'autorité propre au contrat de travail, voyez',
        'de' => 'Zum Autoritätsverhältnis im Arbeitsvertrag siehe',
        'en' => 'For the authority relationship in an employment contract, see'
      }.freeze,
      non_compete_65: {
        'nl' => 'Voor de algemene voorwaarden van een concurrentiebeding, zie',
        'fr' => 'Pour les conditions générales de la clause de non-concurrence, voyez',
        'de' => 'Zu den allgemeinen Voraussetzungen des Wettbewerbsverbots siehe',
        'en' => 'For the general conditions governing non-compete clauses, see'
      }.freeze,
      non_compete_86: {
        'nl' => 'Voor de toepassing op bedienden, zie',
        'fr' => 'Pour son application aux employés, voyez',
        'de' => 'Zur Anwendung auf Angestellte siehe',
        'en' => 'For their application to white-collar employees, see'
      }.freeze
    }.freeze

    DEFAULT_TOPIC_NOTE = TOPIC_CITATION_NOTES.fetch(:alcohol_driving).fetch('nl')

    TOPIC_ANSWERS = {
      alcohol_driving: {
        'nl' => 'Voor bestuurders ligt de strafbare basisgrens op 0,22 mg/l uitgeademde alveolaire lucht of 0,5 g/l bloed; dat wordt doorgaans uitgedrukt als 0,5 promille.',
        'fr' => 'Pour les conducteurs, la limite punissable de base correspond à 0,22 mg/l d\'air alvéolaire expiré ou 0,5 g/l de sang, ce qui est couramment exprimé comme 0,5 promille.',
        'de' => 'Für Fahrer entspricht die strafbare Grundgrenze 0,22 mg/l ausgeatmeter Alveolarluft oder 0,5 g/l Blut; das wird üblicherweise als 0,5 Promille bezeichnet.',
        'en' => 'For drivers, the basic punishable limit is 0.22 mg/l of exhaled alveolar air or 0.5 g/l of blood, commonly expressed as 0.5 promille.'
      }.freeze,
      annual_vacation_duration: {
        'nl' => 'Voor een volledig vakantiedienstjaar bedraagt de wettelijke jaarlijkse vakantie 24 dagen in het zesdagenweekstelsel; in een gewone vijfdagenweek komt dat praktisch overeen met 20 vakantiedagen.',
        'fr' => 'Pour une année complète de service de vacances, la durée légale des vacances annuelles est de 24 jours dans le régime de six jours; dans une semaine de cinq jours, cela correspond en pratique à 20 jours.',
        'de' => 'Für ein volles Urlaubsjahr beträgt der gesetzliche Jahresurlaub 24 Tage im Sechstagewochen-System; bei einer Fünftagewoche entspricht das praktisch 20 Tagen.',
        'en' => 'For a full holiday-service year, statutory annual leave is 24 days in the six-day-week system; in an ordinary five-day week this corresponds in practice to 20 days.'
      }.freeze,
      employment_vs_contractor: {
        'nl' => 'Het kernverschil is het gezagsverband: bij een arbeidsovereenkomst wordt tegen loon gewerkt onder het gezag van een werkgever; zelfstandige uitvoering zonder dat gezag valt in principe onder een aannemings- of dienstenovereenkomst.',
        'fr' => 'Le critère central est le lien d\'autorité : dans un contrat de travail, une personne travaille contre rémunération sous l\'autorité d\'un employeur; une exécution indépendante sans cette autorité relève en principe d\'un contrat d\'entreprise ou de services.',
        'de' => 'Das zentrale Kriterium ist das Weisungs- und Autoritätsverhältnis: Bei einem Arbeitsvertrag wird gegen Vergütung unter der Autorität eines Arbeitgebers gearbeitet; eine selbständige Ausführung ohne dieses Verhältnis fällt grundsätzlich unter einen Werk- oder Dienstvertrag.',
        'en' => 'The central distinction is the relationship of authority: under an employment contract, work is performed for pay under an employer\'s authority; independent performance without that authority generally falls under a works or services contract.'
      }.freeze,
      invoice_prescription: {
        'nl' => 'Voor veel factuurvorderingen geldt in principe de algemene burgerlijke verjaringstermijn voor persoonlijke rechtsvorderingen van tien jaar. Bepaalde facturen of rechtsverhoudingen kunnen onder kortere bijzondere termijnen vallen.',
        'fr' => 'Pour de nombreuses créances de facture, le délai civil général de prescription des actions personnelles est en principe de dix ans. Certaines factures ou relations peuvent relever de délais particuliers plus courts.',
        'de' => 'Für viele Rechnungsforderungen gilt grundsätzlich die allgemeine zivilrechtliche Verjährungsfrist für persönliche Klagen von zehn Jahren. Bestimmte Rechnungen oder Rechtsverhältnisse können kürzeren Sonderfristen unterliegen.',
        'en' => 'For many invoice claims, the general civil prescription period for personal actions is in principle ten years. Specific invoices or legal relationships may be subject to shorter special periods.'
      }.freeze,
      maternity_leave: {
        'nl' => 'Het standaard moederschapsverlof bedraagt in principe 15 weken voor een eenling.',
        'fr' => 'Le congé de maternité standard est en principe de 15 semaines pour une naissance simple.',
        'de' => 'Der Standard-Mutterschaftsurlaub beträgt bei einer Einlingsgeburt grundsätzlich 15 Wochen.',
        'en' => 'The standard maternity leave period is in principle 15 weeks for a single birth.'
      }.freeze,
      mutual_consent_divorce: {
        'nl' => 'Bij een echtscheiding door onderlinge toestemming moeten de echtgenoten de door het Gerechtelijk Wetboek vereiste overeenkomsten voorbereiden, waaronder de regelingen in de twee hieronder gelinkte bronnen.',
        'fr' => 'Pour un divorce par consentement mutuel, les époux doivent préparer les conventions requises par le Code judiciaire, notamment les arrangements visés dans les deux sources liées ci-dessous.',
        'de' => 'Bei einer Scheidung im gegenseitigen Einvernehmen müssen die Ehegatten die im Gerichtsgesetzbuch vorgesehenen Vereinbarungen vorbereiten, insbesondere die Regelungen in den beiden unten verlinkten Quellen.',
        'en' => 'For divorce by mutual consent, the spouses must prepare the agreements required by the Judicial Code, including the arrangements in the two linked sources below.'
      }.freeze,
      non_compete: {
        'nl' => 'Een concurrentiebeding is alleen geldig onder strikte voorwaarden: soortgelijke activiteiten, een beperkt geografisch bereik, maximaal twaalf maanden, een schriftelijk beding en de wettelijke compensatoire vergoeding. De tweede bron hieronder past die regeling, behoudens wettelijke afwijkingen, toe op bedienden.',
        'fr' => 'Une clause de non-concurrence n\'est valable que sous des conditions strictes : activités similaires, portée géographique limitée, durée maximale de douze mois, écrit et indemnité compensatoire légale. La seconde source ci-dessous applique ce régime aux employés, sous réserve des dérogations légales.',
        'de' => 'Ein Wettbewerbsverbot ist nur unter strengen Voraussetzungen gültig: ähnliche Tätigkeiten, begrenzter räumlicher Geltungsbereich, höchstens zwölf Monate, Schriftform und gesetzliche Ausgleichszahlung. Die zweite unten stehende Quelle wendet diese Regelung vorbehaltlich gesetzlicher Abweichungen auf Angestellte an.',
        'en' => 'A non-compete clause is valid only under strict conditions: similar activities, limited geographic scope, a maximum of twelve months, a written clause and the statutory compensatory payment. The second source below applies this regime to white-collar employees, subject to statutory deviations.'
      }.freeze,
      notice_period_five_years: {
        'nl' => 'Bij opzegging door de werkgever na vijf jaar anciënniteit bedraagt de wettelijke opzegtermijn 18 weken.',
        'fr' => 'Pour un licenciement par l\'employeur après cinq ans d\'ancienneté, le délai de préavis légal est de 18 semaines.',
        'de' => 'Bei Kündigung durch den Arbeitgeber nach fünf Jahren Betriebszugehörigkeit beträgt die gesetzliche Kündigungsfrist 18 Wochen.',
        'en' => 'For employer notice after five years of seniority, the statutory notice period is 18 weeks.'
      }.freeze,
      online_purchase: {
        'nl' => 'Bij een online aankoop door een consument geldt in principe een herroepingsrecht van 14 dagen, behoudens de wettelijke uitzonderingen.',
        'fr' => 'Pour un achat en ligne par un consommateur, le droit de rétractation est en principe de 14 jours, sous réserve des exceptions légales.',
        'de' => 'Bei einem Online-Kauf durch einen Verbraucher beträgt das Widerrufsrecht grundsätzlich 14 Tage, vorbehaltlich gesetzlicher Ausnahmen.',
        'en' => 'For an online purchase by a consumer, the withdrawal period is generally 14 days, subject to statutory exceptions.'
      }.freeze,
      probation_period: {
        'nl' => 'De algemene proeftijd voor gewone arbeidsovereenkomsten is afgeschaft; de geraadpleegde bron vermeldt nog de studentenuitzondering, waarbij de eerste drie arbeidsdagen als proeftijd gelden.',
        'fr' => 'La période d\'essai générale dans les contrats de travail ordinaires a été supprimée; la source consultée mentionne encore l\'exception pour les contrats d\'étudiant, où les trois premiers jours de travail sont considérés comme période d\'essai.',
        'de' => 'Die allgemeine Probezeit in gewöhnlichen Arbeitsverträgen wurde abgeschafft; die geprüfte Quelle nennt noch die Ausnahme für Studentenverträge, bei denen die ersten drei Arbeitstage als Probezeit gelten.',
        'en' => 'The general trial period in ordinary employment contracts has been abolished; the consulted source still contains the student-contract exception, where the first three working days count as a trial period.'
      }.freeze,
      secondhand_car_warranty: {
        'nl' => 'Bij aankoop van een tweedehands wagen door een consument geldt de wettelijke garantie in principe twee jaar; verkorting tot minstens één jaar kan alleen als die uitdrukkelijk is overeengekomen.',
        'fr' => 'Pour une voiture d\'occasion achetée par un consommateur, la garantie légale est en principe de deux ans; elle ne peut être réduite à au moins un an que si cette réduction est expressément convenue.',
        'de' => 'Bei einem Gebrauchtwagenkauf durch einen Verbraucher gilt grundsätzlich eine zweijährige gesetzliche Garantie; sie kann nur bei ausdrücklicher Vereinbarung auf mindestens ein Jahr verkürzt werden.',
        'en' => 'For a secondhand car bought by a consumer, the legal warranty is in principle two years; it can only be shortened to at least one year if that reduction is expressly agreed.'
      }.freeze,
      summary_proceedings: {
        'nl' => 'Een kort geding laat de bevoegde voorzitter toe om in spoedeisende gevallen voorlopige maatregelen te bevelen, zonder de grond van de zaak definitief te beslechten.',
        'fr' => 'Le référé permet au président du tribunal compétent d\'ordonner des mesures provisoires dans les cas urgents, sans trancher définitivement le fond.',
        'de' => 'Im Eilverfahren kann der zuständige Gerichtspräsident in dringenden Fällen vorläufige Maßnahmen anordnen, ohne endgültig über die Hauptsache zu entscheiden.',
        'en' => 'Summary proceedings allow the competent court president to order provisional measures in urgent cases, without finally deciding the merits.'
      }.freeze,
      theft_distinction: {
        'nl' => 'Diefstal veronderstelt het bedrieglijk wegnemen van een zaak die aan een ander toebehoort. Voor een precieze vraag over verduistering moet het toepasselijke misdrijf afzonderlijk aan de geraadpleegde bronnen worden getoetst.',
        'fr' => 'Le vol suppose l\'enlèvement frauduleux de la chose d\'autrui. Pour une question précise sur le détournement, vérifiez séparément l\'infraction applicable dans les sources retrouvées.',
        'de' => 'Diebstahl setzt das betrügerische Wegnehmen einer fremden Sache voraus. Für eine genaue Frage zur Veruntreuung muss der einschlägige Straftatbestand separat anhand der gefundenen Quellen geprüft werden.',
        'en' => 'Theft requires the fraudulent taking of another person\'s property. For a precise question about embezzlement, the applicable offence must be checked separately against the retrieved sources.'
      }.freeze,
      unemployment_benefits: {
        'nl' => 'Na ontslag is er niet automatisch recht op werkloosheidsuitkeringen: het dossier moet onder de werkloosheidsreglementering vallen en aan de voorwaarden van die reglementering voldoen.',
        'fr' => 'Après un licenciement, le droit aux allocations de chômage n\'est pas automatique: le dossier doit notamment relever du régime du chômage et satisfaire aux conditions du règlement chômage.',
        'de' => 'Nach einer Entlassung besteht kein automatischer Anspruch auf Arbeitslosengeld: Der Fall muss unter die Arbeitslosenregelung fallen und die Bedingungen dieser Regelung erfüllen.',
        'en' => 'After dismissal, unemployment benefits are not automatic: the file must fall within the unemployment-benefits regime and satisfy the conditions of the unemployment regulation.'
      }.freeze,
      unilateral_employment_change: {
        'nl' => 'Een werkgever kan zich niet geldig het recht voorbehouden om essentiële voorwaarden van de arbeidsovereenkomst eenzijdig te wijzigen.',
        'fr' => 'Un employeur ne peut pas se réserver valablement le droit de modifier unilatéralement les conditions essentielles du contrat de travail.',
        'de' => 'Ein Arbeitgeber kann sich nicht wirksam das Recht vorbehalten, wesentliche Bedingungen des Arbeitsvertrags einseitig zu ändern.',
        'en' => 'An employer cannot validly reserve the right to unilaterally change essential terms of the employment contract.'
      }.freeze,
      vat_food: {
        'nl' => 'Voor gewone voedingsmiddelen geldt in principe het verlaagde Belgische btw-tarief van 6%. Controleer wel bijzondere uitsluitingen, vooral voor alcoholische dranken.',
        'fr' => 'Pour les denrées alimentaires ordinaires, le taux réduit de TVA est en principe de 6 %. Vérifiez toujours les exclusions particulières, notamment pour les boissons alcoolisées.',
        'de' => 'Für gewöhnliche Lebensmittel gilt grundsätzlich der ermäßigte Mehrwertsteuersatz von 6 %. Besondere Ausnahmen, insbesondere alkoholische Getränke, müssen separat geprüft werden.',
        'en' => 'Ordinary foodstuffs are generally subject to the reduced 6% Belgian VAT rate. Specific exclusions, especially alcoholic beverages, should be checked separately.'
      }.freeze
    }.freeze

    DEFAULT_TOPIC_ANSWER = 'Voor bestuurders ligt de strafbare basisgrens op 0,22 mg/l uitgeademde alveolaire lucht of 0,5 g/l bloed; dat wordt doorgaans uitgedrukt als 0,5 promille.'

    def localized_citation_note(topic)
      notes = TOPIC_CITATION_NOTES[topic]
      (notes && notes[@language]) || DEFAULT_TOPIC_NOTE
    end

    def localized_high_confidence_topic_answer(topic)
      if topic == :minimum_wage
        dynamic = minimum_wage_topic_answer
        return dynamic if dynamic
      end
      answers = TOPIC_ANSWERS[topic]
      (answers && answers[@language]) || DEFAULT_TOPIC_ANSWER
    end

    # Derived from the live GGMMI record; nil for an unknown UI language so
    # the caller falls back exactly like the historical cascade did.
    def minimum_wage_topic_answer
      case @language
      when 'nl'
        ggmmi = LegalFactProvider::CURRENT_GGMMI
        "Sinds #{ggmmi[:effective_nl]} bedraagt het interprofessionele GGMMI €#{ggmmi[:amount_nl]} bruto per maand voor werknemers van 18 jaar en ouder. Het GGMMI is een gemiddeld minimummaandinkomen; een sector- of ondernemings-cao kan een hoger minimum opleggen. [Officiële indexatie van FOD Werkgelegenheid](#{ggmmi[:source_url_nl]})."
      when 'fr'
        ggmmi = LegalFactProvider::CURRENT_GGMMI
        "Depuis le #{ggmmi[:effective_fr]}, le RMMMG interprofessionnel s'élève à #{ggmmi[:amount_fr]} € brut par mois pour les travailleurs âgés d'au moins 18 ans. Il s'agit d'un revenu mensuel minimum moyen; une CCT sectorielle ou d'entreprise peut imposer un minimum plus élevé. [Indexation officielle du SPF Emploi](#{ggmmi[:source_url_fr]})."
      when 'de'
        ggmmi = LegalFactProvider::CURRENT_GGMMI
        "Seit dem #{ggmmi[:effective_de]} beträgt das überberufliche durchschnittliche Mindestmonatseinkommen #{ggmmi[:amount_nl]} € brutto pro Monat für Arbeitnehmer ab 18 Jahren. Ein Branchen- oder Unternehmenskollektivvertrag kann ein höheres Minimum vorsehen. [Offizielle Indexierung des FÖD Beschäftigung (Englisch)](#{ggmmi[:source_url_en]})."
      when 'en'
        ggmmi = LegalFactProvider::CURRENT_GGMMI
        "Since #{ggmmi[:effective_en]}, the interprofessional guaranteed average minimum monthly income is €#{ggmmi[:amount_en]} gross per month for workers aged 18 or over. It is an average minimum monthly income; a sector or company collective agreement may require a higher minimum. [Official FPS Employment indexation](#{ggmmi[:source_url_en]})."
      end
    end

    # Build the accepted-renderings pattern from the digits of the recorded
    # amount: thousands groups may be separated by dot, comma, or any locale
    # space variant (ARTICLE_SPACE_SOURCE exists for exactly those), and
    # either decimal mark is accepted. For '2.233,61' this matches 2.233,61 /
    # 2,233.61 / space-separated forms / 2233,61 / 2233.61, while \b still
    # rejects neighbouring digits ("12.233,61", "2.233,610").
    def current_ggmmi_pattern
      digits = LegalFactProvider::CURRENT_GGMMI[:amount_nl].gsub(/\D/, '')
      integer_digits = digits[0..-3]
      decimal_digits = digits[-2..]
      groups = integer_digits.reverse.scan(/\d{1,3}/).map(&:reverse).reverse
      separator = "(?:[.,]|#{ARTICLE_SPACE_SOURCE})?"
      /\b#{groups.join(separator)}[.,]#{decimal_digits}\b/
    end

    def historical_minimum_wage_question?(question)
      normalized = question.to_s.downcase
      years = normalized.scan(/\b(?:19|20)\d{2}\b/).map(&:to_i)
      historical_wording = normalized.match?(
        /\b(?:historisch|vroeger|destijds|toenmalig|history|historical|previously|anciennement|historique|damals)\b/i
      )
      historical_wording || years.any? { |year| year != Date.current.year }
    end

    def append_retrieved_source_citation(text, source, label:, note:, force: false)
      return text unless source

      numac = retrieved_source_numac(source)
      article_number = retrieved_source_article_number(source)
      return text if numac.blank? || article_number.blank?

      href = verified_citation_href(source, numac, article_number)
      return text if !force && retrieved_source_citation_present?(text, source)

      "#{text.to_s.rstrip}\n\n#{high_confidence_citation_heading}\n- #{note} [#{label}](#{href})"
    end

    def append_retrieved_source_citation_list(text, entries, force: false)
      valid_entries = entries.filter_map do |source, label, note|
        next unless source

        numac = retrieved_source_numac(source)
        article_number = retrieved_source_article_number(source)
        next if numac.blank? || article_number.blank?
        next if !force && retrieved_source_citation_present?(text, source)

        [note, label, verified_citation_href(source, numac, article_number)]
      end
      return text if valid_entries.empty?

      lines = valid_entries.map { |note, label, href| "- #{note} [#{label}](#{href})" }
      "#{text.to_s.rstrip}\n\n#{high_confidence_citation_heading}\n#{lines.join("\n")}"
    end

    # A stored source URL is only trusted for citation emission when it is a
    # site-relative link for this exact NUMAC. A malformed/truncated stored URL
    # (observed in the wild: "/laws/2010A0958" for NUMAC 2010A09589) would
    # otherwise be emitted verbatim and produce a broken markdown link; fall
    # back to the canonical article href built from the full identifiers.
    def verified_citation_href(source, numac, article_number)
      stored = source_field(source, :url, 'url').to_s.strip
      return stored if stored.match?(%r{\A/laws/#{Regexp.escape(numac)}(?:[#?]|\z)})

      chatbot_article_href(numac, article_number)
    end

    def retrieved_source_link_label(source)
      article_number = retrieved_source_article_number(source)
      return nil if article_number.blank?

      title = source_field(source, :law_title, 'law_title', :title, 'title').to_s
      short_title = title
                    .sub(/\A\d{1,2}\s+[[:alpha:]ÉÈÊËÀÂÄÎÏÔÖÙÛÜÇéèêëàâäîïôöùûüç]+\s+\d{4}\.\s*-\s*/i, '')
                    .sub(/\s*\(NOTE\s*:.*\z/i, '')
                    .sub(/\s*\(NOTA\s*:.*\z/i, '')
                    .gsub(/\s*\((?:art\.?|articles?)\s*[^)]*\)/i, '')
                    .tr('[]', '')
                    .strip
      short_title = short_title.truncate(80) if short_title.present?
      short_title.present? ? "Art. #{article_number} — #{short_title}" : "Art. #{article_number}"
    end

    def localized_guarded_source_list_fallback_intro
      case @language
      when 'fr'
        "La réponse générée contenait une référence d'article que je ne pouvais pas vérifier. Je ne l'affiche donc pas comme analyse juridique. Voici les sources exactes consultées pour reprendre la question prudemment."
      when 'de'
        'Die generierte Antwort enthielt einen nicht verifizierbaren Artikelverweis. Ich zeige sie deshalb nicht als Rechtsanalyse an. Hier sind die genau konsultierten Quellen für eine vorsichtige weitere Prüfung.'
      when 'en'
        'The generated answer contained an article reference I could not verify. I am therefore not showing it as legal analysis. These are the exact consulted sources to continue carefully.'
      else
        'Het gegenereerde antwoord bevatte een artikelverwijzing die ik niet kon verifiëren. Ik toon het daarom niet als juridische analyse. Dit zijn de exact geraadpleegde bronnen om de vraag voorzichtig verder te behandelen.'
      end
    end

    def localized_consulted_source_note
      case @language
      when 'fr' then 'Source consultée :'
      when 'de' then 'Konsultierte Quelle:'
      when 'en' then 'Consulted source:'
      else 'Geraadpleegde bron:'
      end
    end

    def retrieved_source_citation_present?(text, source)
      numac = retrieved_source_numac(source)
      article_number = retrieved_source_article_number(source)
      return false if numac.blank? || article_number.blank?

      allowed_pairs = [[numac, article_number]].to_set
      verified_article_citation_pairs(text, allowed_pairs).include?([numac, article_number])
    end

    def source_document_type(source)
      source_field(source, :document_type, 'document_type').to_s.strip
    end

    def high_confidence_citation_heading
      case @language
      when 'fr' then '**Source vérifiée complémentaire :**'
      when 'de' then '**Ergänzende geprüfte Quelle:**'
      when 'en' then '**Additional verified source:**'
      else '**Aanvullende geverifieerde bron:**'
      end
    end


    def localized_promille_equivalence
      case @language
      when 'fr'
        'La limite de 0,5 g/l de sang correspond usuellement à 0,5 promille.'
      when 'de'
        'Die Grenze von 0,5 g/l Blut entspricht üblicherweise 0,5 Promille.'
      when 'en'
        'The 0.5 g/l blood limit is commonly expressed as 0.5 promille.'
      else
        'De grens van 0,5 g/l bloed wordt doorgaans uitgedrukt als 0,5 promille.'
      end
    end
  end
end
