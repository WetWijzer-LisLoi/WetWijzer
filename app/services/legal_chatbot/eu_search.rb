# frozen_string_literal: true

module LegalChatbot
  # Provider-free lexical EU retrieval. No semantic similarity fiction: admit
  # exact identities or genuine multi-term matches, then prefer the site language.
  class EuSearch
    DEPTH_QUOTAS = { 'quick' => 2, 'balanced' => 3, 'thorough' => 4, 'extensive' => 5 }.freeze
    COMPLEMENTARY_STATUTORY_TOPICS = %i[flight_disruption platform_redress].freeze
    DSA_RECITAL_REQUEST = /\b(?:overweging(?:en)?|recitals?|considerants?|erwagungsgrund(?:e|en)?)\b/u
    WARRANTY_SUBJECT = /\b(?:gebrek\p{L}*|gebreken|defect\p{L}*|conform\p{L}*|herstel\p{L}*|repar\p{L}*|garantie\p{L}*|waarborg|ondeugd\p{L}*|warrant\p{L}*|guarantees?|faulty|broken|defaut\p{L}*|mangel\p{L}*|gewahrleist\p{L}*|nacherfull\p{L}*)\b/u
    # Bounded legal-intent routing, not generated evidence. Each target must be
    # resolved and verified by the ordinary corpus reader before it is ranked.
    COMMERCIAL_WEBSITE_TARGETS = [
      %w[32000L0031 5], %w[32016R0679 13], %w[32011L0083 6],
      %w[32000L0031 10], %w[32016R0679 32]
    ].map(&:freeze).freeze
    WEBSITE_CONSUMER_CELEX = '32011L0083'
    STOP_WORDS = %w[wat zijn moet moeten welke hoe kan kunnen mag mijn onze jullie deze dit dat een het de en of in op aan
                    voor van met als bij tot niet ook wel maar niets doen doet deed gedaan uit juridisch juridische vereisten regels vraag antwoord
                    what which how can should must legal law rules requirements are is the a an and or but nothing do does did done doing out for of to in on with
                    que quoi quels quelles comment peut doivent mais rien faire fait font juridique juridiques exigences règles le la les des du une un et
                    de à au pour dans sur avec est sont ich was welche wie kann muss aber nichts tun tut tat getan aus recht rechtliche anforderungen der die das
                    ein eine und oder von für mit im ist sind].freeze
    # These generic legal/contract words can help retrieve candidates, but do
    # not establish their subject. In a quoted employment clause, for example,
    # "uitvoering" and "overeenkomst" also occur in unrelated GDPR/AI units.
    # Do not let two such neighbours become an EU source card. Keep this
    # separate from retrieval tokens so exact references and topical searches
    # retain their ordinary candidate vocabulary.
    GENERIC_CONTEXT_WORDS = %w[heeft hebben zal gehele eigen rekening derden zonder voorafgaand schriftelijk akkoord
                               uitvoering overeenkomst overeenkomsten verbintenis clausule legaal beoordeel huidig huidige
                               recht rechten verplichting verplichtingen regel regels wet wetgeving artikel artikelen bepaling bepalingen
                               belgie belgisch belgische andere onderscheid gaat hij zij om door naar kunnen geldt gelden
                               has have shall whole own behalf third prior written agreement agreements contract contracts clause
                               legal assess current right rights obligation obligations rule rules act article articles provision provisions
                               belgium belgian other distinguish under applicable applies apply
                               a ont doit entier propre compte tiers sans prealable ecrit accord execution convention conventions
                               contrat contrats clause droit droits obligation obligations regle regles loi legislation article articles
                               disposition dispositions belgique belge autres actuel actuelle applicable
                               hat haben soll gesamte eigene rechnung dritten ohne vorherige schriftliche zustimmung ausfuhrung
                               vereinbarung vereinbarungen vertrag vertrage klausel recht rechte pflicht pflichten regel regeln
                               gesetz gesetzgebung artikel bestimmung bestimmungen belgien belgisch andere aktuell aktuelle].freeze
    # Words that frame a question rather than name its subject: question words
    # and pronouns, numbers and units of time, and the vocabulary every EU act
    # shares. Measured 2026-10-14 (ledger item 32): "vijf", "jaar" and "dienst"
    # carried the e-commerce directive under a dismissal question; "welk",
    # "land", "meerdere" and "lidstaten" the Air Passenger Regulation and the
    # GDPR under an insolvency question; "quelle" and "2020" the AI Act under a
    # matrimonial-regime question. Like the words above they still retrieve
    # candidates; they only stop counting as subject evidence. Digits count as
    # such words too.
    QUESTION_FRAME_WORDS = %w[welk waar wanneer waarom hoeveel wie wiens mij jij jou jouw uw hun
                              quel quelle qui quand combien pourquoi moi mon mes ton tes votre vos notre nos leur leurs
                              welcher welches welchen welchem wer wann warum wieviel mich mir mein meine meinen meiner unser unsere
                              who where when why much many my mine your our their
                              twee drie vier vijf zes zeven acht negen tien elf twaalf honderd duizend
                              deux trois quatre cinq six sept huit neuf dix douze cent mille
                              zwei drei funf sechs sieben neun zehn zwolf hundert tausend
                              one two three four five six seven eight nine ten eleven twelve hundred thousand
                              jaar jaren maand maanden week weken dag dagen uur uren
                              ans annee annees mois semaine semaines jour jours heure heures
                              jahr jahre jahren monat monate woche wochen tag tage tagen stunde stunden
                              year years month months weeks day days hour hours
                              lidstaat lidstaten etat etats membre membres mitgliedstaat mitgliedstaaten member members state states
                              meerdere verschillende plusieurs differents mehrere verschiedene several multiple various
                              land landen pays country countries].freeze
    IDENTITY_ALIASES = {
      /\b(?:avg|gdpr|rgpd|dsgvo)\b/i => '32016R0679',
      /\b(?:AI\s+Act|AI[-\s]verordening|KI[-\s]Verordnung)\b/i => '32024R1689',
      /\b(?:DSA|Digital\s+Services\s+Act|digitaledienstenverordening)\b/i => '32022R2065',
      /\bnilsson\b/i => '61997CJ0162', /\bplanet49\b/i => '62017CJ0673'
    }.freeze
    # Search-only concept vocabulary. This neither translates source text nor
    # changes the answer language. Two concepts must occur in BOTH question
    # and literal unit before an alternative-language match is admitted.
    CONCEPT_GROUPS = {
      /\b(?:vlucht\p{L}*|flight\p{L}*|flug\p{L}*)\b|\bvol\p{L}*\b.*\b(?:retard|annul\p{L}*|aerien)\b|\b(?:retard|annul\p{L}*|aerien)\b.*\bvol\p{L}*\b/u => [
        [/\b(?:vlucht\p{L}*|flight\p{L}*|vols?|flug\p{L}*)\b/u, %w[vlucht flight vol flug]],
        [/\b(?:vertra[ag]\p{L}*|delay\p{L}*|retard\p{L}*|verspat\p{L}*)\b/u, %w[vertraging vertraag delay retard verspatung]],
        [/\b(?:compens\p{L}*|schadevergoeding\p{L}*|indemnis\p{L}*|ausgleich\p{L}*)\b/u, %w[compensatie compensation indemnisation ausgleich]],
        [/\b(?:annuler\p{L}*|annulat\p{L}*|cancel\p{L}*|annul\p{L}*|anull\p{L}*)\b/u, %w[annulering cancellation annulation annullierung]]
      ],
      /\b(?:arbeidstijd\p{L}*|working time|working hours|arbeitszeit\p{L}*|temps de travail|overuren|overtime)\b/u => [
        [/\b(?:arbeidstijd\p{L}*|working time|working hours|arbeitszeit\p{L}*|temps de travail)\b/u, %w[arbeidstijd working arbeitszeit travail]],
        [/\b(?:rust\p{L}*|rest\p{L}*|repos|ruhe\p{L}*)\b/u, %w[rust rest repos ruhe]],
        [/\b(?:wekel\p{L}*|week\p{L}*|hebdomad\p{L}*|woch\p{L}*)\b/u, %w[wekelijkse weekly hebdomadaire wochentliche]],
        [/\b(?:uur|uren|hours?|heures?|stunden?)\b/u, %w[uren hours heures stunden]]
      ],
      /\b(?:privacy|personal data|persoonsgegevens|donnees personnelles|datenschutz|gdpr|avg|rgpd|dsgvo)\b/u => [
        [/\b(?:persoonsgegevens|personal data|donnees personnelles|personenbezogen\p{L}*)\b/u, %w[persoonsgegevens personal donnees personenbezogene]],
        [/\b(?:verwerk\p{L}*|process\p{L}*|traitement\p{L}*|verarbeit\p{L}*)\b/u, %w[verwerking processing traitement verarbeitung]],
        [/\b(?:toestemming|consent\p{L}*|einwillig\p{L}*)\b/u, %w[toestemming consent consentement einwilligung]],
        [/\b(?:wis\p{L}*|eras\p{L}*|effac\p{L}*|losch\p{L}*)\b/u, %w[wissing erasure effacement loschung]]
      ]
    }.freeze
    UNIT_PATTERN = %r{\b(art(?:ikel|icle)?\.?|artikel|article|overweging|consid[eé]rant|erw[aä]gungsgrund|recital|punt|point|randnummer|paragraph)\s*(\d+[a-z]*(?:[.:/-]\d+[a-z]*)*(?:\s+(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies))?)}i

    def initialize(language: 'nl', depth: nil, corpus: nil, history: [], live_corpus: nil, discovery: nil)
      @language = %w[nl fr de en].include?(language.to_s) ? language.to_s : 'en'
      @depth = depth.to_s
      @corpus = corpus || EuCorpus.default
      # Explicit injected corpora stay isolated/offline (tests and reviewed
      # batch checks). Normal requests also read the independently verified
      # bounded cache, without remote I/O in a retrieval worker.
      @live_corpus = live_corpus || (EuLiveCorpus.default unless corpus)
      @discovery = discovery || (EuDiscovery.new unless corpus)
      @discoveries = %i[legislation jurisprudence].to_h { |source| [source, @discovery&.dup] }
      @pending_sources = {}
      @history = history
    end

    def quota
      DEPTH_QUOTAS.fetch(@depth, 3)
    end

    def search(question, source:, limit: nil, exclusive_unit_scope: true)
      return [] unless %i[legislation jurisprudence].include?(source.to_sym)
      return [] unless @corpus.configured? || @live_corpus&.configured? || @discovery

      q = question.to_s[0, 6000]
      judicial = source.to_sym == :jurisprudence
      identities = q.scan(/\b(?:CELEX\s*:?\s*)?([036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?(?:R\(\d{2}\))?)\b/i).flatten.map(&:upcase)
      identities.concat(EuDiscovery.named_act_identifiers(q))
      celex = identities.find { |identity| identity.start_with?('6') == judicial }
      celex ||= IDENTITY_ALIASES.find { |pattern, id| id.start_with?('6') == judicial && q.match?(pattern) }&.last
      if judicial && (case_number = q.match(%r{\b([CTF])\s*[-–]?\s*(\d{1,4})/(\d{2}|\d{4})\b}i))
        court, number, year = case_number.captures
        year = "#{year.to_i >= 50 ? '19' : '20'}#{year}" if year.length == 2
        celex = "6#{year}#{court.upcase}J#{number.rjust(4, '0')}"
      end
      ecli = q[/\bECLI:EU:[A-Z]+:\d{4}:\d+\b/i]&.upcase
      ecli = nil unless judicial
      units = extract_units(q)
      unit = judicial ? units.find { |kind, _number| kind == 'paragraph' } : units.find { |kind, _number| %w[article recital].include?(kind) }
      if exclusive_unit_scope && self.class.unit_only_question?(q) && celex.nil? && ecli.nil?
        # Dropping the opposite lane's identifier must not turn an explicitly
        # scoped judgment paragraph into generic legislative cookie neighbours
        # (or an exact statutory article into generic EU case-law neighbours).
        # A requested mixed law/case lane and selected national context remain
        # searchable; the native backends still run and report their failures.
        opposite_identity = identities.any? { |id| id.start_with?('6') != judicial } ||
                            IDENTITY_ALIASES.any? { |pattern, id| id.start_with?('6') != judicial && q.match?(pattern) } ||
                            (!judicial && q.match?(%r{\bECLI:EU:[A-Z]+:\d{4}:\d+\b|\b[CTF]\s*[-–]?\s*\d{1,4}/\d{2,4}\b}i))
        opposite_unit = units.any? { |kind, _number| judicial ? %w[article recital].include?(kind) : kind == 'paragraph' }
        return [] if opposite_identity && opposite_unit && !requested_lane?(q, judicial)
      end
      if celex.nil? && ecli.nil? && unit && q.length <= 200 && q.match?(/\A\s*(?:en|et|and|und|also|daarnaast)\b/i)
        # Only the immediately preceding HUMAN question can scope an explicit
        # short unit follow-up. Model-generated URLs/source claims are never an
        # identity authority and cannot turn arbitrary prose into EU evidence.
        messages = @history.respond_to?(:call) ? @history.call : @history
        previous = Array(messages).last(6).rfind do |message|
          message.is_a?(Hash) && (message[:role] || message['role']).to_s == 'user'
        end
        prior = previous && (previous[:content] || previous['content']).to_s[0, 6000]
        if prior
          prior_ids = prior.scan(/\b([036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?)\b/i).flatten.map(&:upcase)
          prior_ids.concat(IDENTITY_ALIASES.filter_map { |pattern, id| id if prior.match?(pattern) })
          prior_ids = prior_ids.select { |id| id.start_with?('6') == judicial }.uniq
          celex = prior_ids.sole if prior_ids.length == 1
          ecli = prior[/\bECLI:EU:[A-Z]+:\d{4}:\d+\b/i]&.upcase if judicial && celex.nil?
        end
      end
      historical = explicit_original_recital?(q, celex, unit)
      plan = topic_plan(q, identities: identities, celex: celex, ecli: ecli, units: units)
      topic_targets = planned_targets(plan, question: q, judicial: judicial)
      if judicial && plan && topic_targets.empty?
        # This topic deliberately requests no EU case authority. Native case
        # retrieval is independent; do not report an acquisition failure here.
        @pending_sources[source.to_sym] = nil
        return []
      end
      result_limit = if limit.nil?
                       !judicial && plan && COMPLEMENTARY_STATUTORY_TOPICS.include?(plan[:topic]) ? [quota, topic_targets.length].max : quota
                     else
                       [Integer(limit), quota].min
                     end
      marketplace_non_warranty = !judicial && celex.nil? && units.empty? && identities.empty? &&
                                 MarketplaceCivilClaimIntent.topic?(q) && !normalize(q).match?(WARRANTY_SUBJECT)
      overview_targets = website_overview_targets(q, source: source, identities: identities, celex: celex, units: units)
      overview_targets = [] if plan
      business_only_website = overview_targets.any? && CommercialWebsiteIntent.business_only?(q)
      tokens = query_tokens(q)
      relevance_tokens = relevance_tokens(q)
      concepts = question_concepts(q)
      return [] if tokens.empty? && celex.nil? && ecli.nil?

      # Generic queries never perform a zero-match backfill. Expansions are
      # topic-specific lexical vocabulary, not evidence fetched by another LLM.
      expanded = tokens + topic_tokens(q) + concepts.flat_map(&:last)
      match_tokens = if concepts.empty?
                       expanded.uniq.take(12)
                     else
                       (tokens.take(6) + concepts.flat_map(&:last) + topic_tokens(q)).uniq.take(18)
                     end
      match = match_tokens.map { |token| "\"#{token.delete('"')}\"*" }.join(' OR ')
      candidates = @corpus.candidates(match: match, source_kinds: [source.to_s], limit: 150,
                                      celex: celex, ecli: ecli, unit: unit, language: @language, historical: historical)
      overview_priorities = {}
      rejected_overview_ids = []
      if overview_targets.any?
        rows, priorities, rejected = website_overview_candidates(@corpus, overview_targets)
        candidates += rows
        overview_priorities.merge!(priorities)
        rejected_overview_ids.concat(rejected)
      end
      if plan
        rows, priorities, rejected = topic_candidates(@corpus, topic_targets, source: source)
        candidates += rows
        overview_priorities.merge!(priorities)
        rejected_overview_ids.concat(rejected)
      end
      if @live_corpus&.configured?
        candidates += @live_corpus.candidates(match: match, source_kinds: [source.to_s], limit: 150,
                                              celex: celex, ecli: ecli, unit: unit, language: @language, historical: historical)
        if overview_targets.any?
          rows, priorities, rejected = website_overview_candidates(@live_corpus, overview_targets)
          candidates += rows
          overview_priorities.merge!(priorities)
          rejected_overview_ids.concat(rejected)
        end
        if plan
          rows, priorities, rejected = topic_candidates(@live_corpus, topic_targets, source: source)
          candidates += rows
          overview_priorities.merge!(priorities)
          rejected_overview_ids.concat(rejected)
        end
      end
      if @live_corpus&.configured? || overview_targets.any? || plan
        # Exact overview reads cannot restore a conflicting static/live unit.
        # Copies are harmless only if their sealed text identities agree.
        candidates = candidates.group_by { |row| row[:eu_chunk_id] }.values.filter_map do |rows|
          rows.last if rows.map { |row| EuCorpus::TEXT_IDENTITY_FIELDS.map { |key| row[key] } }.uniq.length == 1
        end
      end
      # Observe the document edition BEFORE applying unit filters. A newer
      # verified edition that lacks this provision must not resurrect old text.
      # These are routing observations, not a certificate of current validity.
      families = if judicial || historical
                   []
                 else
                   overview_targets.map(&:first) + topic_targets.map { |target| target[:celex] } +
                     (EuCorpus::BASE_ACT_ID.match?(celex.to_s) ? [celex] : [])
                 end
      latest = latest_observed_editions(families.uniq, candidates)
      ranked = candidates.filter_map do |record|
        next if rejected_overview_ids.include?(record[:eu_chunk_id])
        next if business_only_website && celex_family?(record[:celex], WEBSITE_CONSUMER_CELEX)
        next if marketplace_non_warranty && celex_family?(record[:celex], '32019L0771')

        family = families.find { |base| celex_family?(record[:celex], base) }
        # Consolidations commonly omit the original preamble. A literal recital
        # with a reader-verified other-language corrigendum certificate remains
        # usable as labelled original interpretive context. This exception can
        # never restore old operative articles or unverified historical text.
        next if family && record[:celex] != latest[family] && !verified_unchanged_recital?(record)

        if unit
          numbers = [record[:unit_number], record[:unit_identity_number]].map { |number| number.to_s.delete(' ') }
          next unless record[:kind] == unit.first && numbers.include?(unit.last.delete(' '))
        end
        overview_priority = overview_priorities[overview_identity(record)] if overview_targets.any? || plan
        # An overview quota is a ceiling, not an obligation to fill missing
        # targets with lexically neighbouring definitions or unrelated acts.
        next if (overview_targets.any? || plan) && overview_priority.nil?

        evidence = lexical_evidence(record, expanded, original_tokens: relevance_tokens, concepts: concepts)
        next unless celex || ecli || overview_priority || topic_relevant?(evidence, original_tokens: relevance_tokens)

        score = (evidence[:hits].length * 10) + (evidence[:title_hits] * 3)
        score += evidence[:concept_hits] * 10
        score += 80 if celex || ecli
        score += 25 if unit
        score += 8 if record[:kind] == 'article'
        score -= 10 if record[:kind] == 'recital'
        score += judicial_priority(record) if judicial && !unit
        [score, record, overview_priority]
      end
      # Keep one literal language per exact unit/edition, never combine text
      # from translations. Missing preferred wording uses an explicitly labelled
      # source language; no machine translation is passed off as a native source.
      units = ranked.group_by { |_score, record| [record[:celex], record[:kind], record[:unit_number]] }
      preferred = units.values.map do |rows|
        rows.max_by do |score, record, overview_priority|
          authentic = Array(record[:authentic_language]).include?(record[:language])
          [record[:language] == @language ? 1 : 0, authentic ? 1 : 0, record[:language] == 'en' ? 1 : 0,
           overview_priority.nil? ? 0 : 1, score]
        end
      end
      if overview_targets.any? || plan
        overview, ordinary = preferred.partition { |_score, _record, priority| !priority.nil? }
        # A base act and several consolidations are one overview obligation,
        # not several quota slots. Keep the latest observed nonfuture edition;
        # its language choice and all source-status fields remain untouched.
        preferred = ordinary + overview.group_by { |_score, _record, priority| priority }.values.map do |rows|
          rows.max_by { |_score, record| overview_edition_date(record) || Date.new(1) }
        end
      end
      # Quotas must not invent a missing planned judgment. Inspect the full
      # eligible preferred pool, then acquire at most one absent exact target.
      missing_case_target = judicial && plan && topic_targets.find do |target|
        preferred.none? do |_score, record, _priority|
          record.values_at(:celex, :kind, :unit_number, :unit_identity_number) ==
            target.values_at(:celex, :kind, :number, :number) &&
            [@corpus, @live_corpus].compact.any? { |reader| reader.respond_to?(:verified_record?) && reader.verified_record?(record) }
        end
      end
      result = preferred.sort_by do |score, record, overview_priority|
        [overview_priority.nil? ? 1 : 0, overview_priority || 0, -score, record[:celex], record[:unit_number].to_s.to_i]
      end
                        .take(result_limit)
                        .map { |score, record| eu_result_record(record, score, website_overview: overview_targets.any?) }
      # Generic questions may already match the small core while still needing
      # broader EU coverage. Discover in the background without branding an
      # existing verified answer as failed. Base/named acts also request bounded
      # freshness discovery; exact dated and historical editions stay pinned.
      refresh_family = !judicial && !historical && EuCorpus::BASE_ACT_ID.match?(celex.to_s)
      needs_discovery = !judicial || !plan || missing_case_target
      @pending_sources[source.to_sym] = nil unless needs_discovery
      if needs_discovery && (result.empty? || refresh_family || (celex.nil? && ecli.nil?) || result.any? { |row| row[:language] != @language }) && (discovery = @discoveries[source.to_sym])
        discovery_query = missing_case_target ? "CELEX:#{missing_case_target[:celex]}" : q
        discovery.enqueue(discovery_query, source: source, language: @language, depth: @depth)
        @pending_sources[source.to_sym] = result.empty? ? discovery.retrieval_degradation : nil
      end
      result
    end

    def retrieval_degradation(source = nil)
      return 'eu_corpus_unavailable' if @corpus.configured? && !@corpus.available?
      return 'eu_live_corpus_unavailable' if @live_corpus&.configured? && !@live_corpus.healthy?

      source ? @pending_sources[source.to_sym] : @pending_sources.values.compact.first
    end

    def self.unit_only_question?(question, context_numacs: [])
      return false if Array(context_numacs).any?

      text = question.to_s
      return false unless text.match?(UNIT_PATTERN)

      identity = text.match?(%r{\b(?:CELEX\s*:?\s*)?[036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?\b|\bECLI:EU:[A-Z]+:\d{4}:\d+\b|\b[CTF]\s*[-–]?\s*\d{1,4}/\d{2,4}\b}i) ||
                 EuDiscovery.named_act_identifiers(text).any? ||
                 IDENTITY_ALIASES.keys.any? { |pattern| text.match?(pattern) }
      return false unless identity

      national = /\b(?:belg\p{L}*|vlaams\p{L}*|vlaanderen|flanders|flandre\p{L}*|flamand\p{L}*|wallon\p{L}*|walloni\p{L}*|brussel\p{L}*|bruxell\p{L}*|Ostbelgien|national\p{L}*|nationaal\p{L}*|nationaux|innerstaatlich\p{L}*|transpos\p{L}*|omzetting|Umsetzung|NUMAC|Wetboek|WER|WIB|Kamerstuk\p{L}*|dossier|parliamentary|Parlamentsdrucksache\p{L}*|travaux\s+pr[ée]paratoires|code\s+(?:civil|judiciaire|p[ée]nal|de\s+droit\s+[ée]conomique)|wet\s+(?:van|uit)|loi\s+du|Gesetz\s+vom)\b|\bECLI:BE:|\b\d{4}[A-Z]?\d{6}\b/iu
      return false if text.match?(national)

      true
    end

    private

    def planned_targets(plan, question:, judicial:)
      return [] unless plan
      return plan[:case_targets] if judicial

      targets = plan[:legislation_targets].map { |id, number| { celex: id, kind: 'article', number: number } }
      if plan[:topic] == :platform_redress && normalize(question).match?(DSA_RECITAL_REQUEST)
        targets += %w[58 59].map { |number| { celex: '32022R2065', kind: 'recital', number: number } }
      end
      targets
    end

    def topic_plan(question, identities:, celex:, ecli:, units:)
      identity = %r{\b(?:CELEX\s*:?\s*)?[036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?\b|\bECLI:EU:|\b[CTF]\s*[-–]?\s*\d{1,4}/\d{2,4}\b}i
      return nil if units.any? || ecli || question.match?(identity)

      plan = EuTopicIntent.plan(question)
      return nil unless plan

      # A named base act may refine this topic, but cannot be ignored in favor
      # of another regime. Explicit editions/cases are handled only above.
      scoped = identities + IDENTITY_ALIASES.filter_map { |pattern, id| id if question.match?(pattern) }
      scoped << celex if celex
      families = plan[:legislation_targets].map(&:first).uniq
      return nil if scoped.any? && !families.one?
      return nil if scoped.uniq.any? { |id| !families.include?(id) }

      plan
    end

    def topic_candidates(reader, targets, source:)
      rows = []
      priorities = {}
      rejected_ids = []
      targets.each_with_index do |target, priority|
        kind, number, celex = target.values_at(:kind, :number, :celex)
        reader.candidates(match: nil, source_kinds: [source.to_s], limit: 150, celex: celex,
                          unit: [kind, number], language: @language, historical: false).each do |record|
          next unless record.is_a?(Hash)

          correct_identity = record[:source_kind] == source.to_s && record[:kind] == kind &&
                             record[:unit_number] == number && record[:unit_identity_number] == number &&
                             record[:historical] == false && record[:retrieval_scope] == 'eligible_source_edition'
          correct_identity &&= if source.to_sym == :legislation
                                 legislative_unit = if kind == 'recital'
                                                      record[:article_number].nil? && verified_unchanged_recital?(record)
                                                    else
                                                      kind == 'article' && record[:article_number] == number
                                                    end
                                 legislative_unit && celex_family?(record[:celex], celex) &&
                                   (overview_edition_date(record).nil? || overview_edition_date(record) <= Date.current)
                               else
                                 record[:celex] == celex && record[:article_number].nil? && record[:document_type] == 'judgment'
                               end
          if correct_identity && reader.respond_to?(:verified_record?) && reader.verified_record?(record)
            rows << record
            priorities[overview_identity(record)] = priority
          elsif record[:eu_chunk_id]
            rejected_ids << record[:eu_chunk_id]
          end
        end
      end
      [rows, priorities, rejected_ids]
    end

    def latest_observed_editions(families, candidates)
      families.to_h do |family|
        readers = [@corpus, @live_corpus].compact
        observations = readers.flat_map do |reader|
          reader.respond_to?(:observed_editions) ? reader.observed_editions(celex: family) : []
        end
        ids = if readers.any? { |reader| reader.respond_to?(:observed_editions) }
                observations.filter_map { |row| row[:celex] if row.is_a?(Hash) }
              else
                # Minimal injected readers may have no edition-inventory API.
                # Production readers never bypass their sealed inventory guard.
                candidates.filter_map { |row| row[:celex] if celex_family?(row[:celex], family) }
              end
        ids.select! do |id|
          celex_family?(id, family) && (id == family || overview_edition_date(celex: id) <= Date.current)
        end
        [family, ids.uniq.max_by { |id| overview_edition_date(celex: id) || Date.new(1) }]
      end
    end

    def website_overview_targets(question, source:, identities:, celex:, units:)
      return [] unless source.to_sym == :legislation && identities.empty? && celex.nil? && units.empty?
      return [] if question.match?(%r{\bECLI:EU:[A-Z]+:\d{4}:\d+\b|\b[CTF]\s*[-–]?\s*\d{1,4}/\d{2,4}\b}i)
      return [] unless CommercialWebsiteIntent.topic?(question)
      return [] if question.match?(CommercialWebsiteIntent::PUBLIC_PORTAL_PATTERN) || question.match?(CommercialWebsiteIntent::TECHNICAL_PATTERN)

      targets = COMMERCIAL_WEBSITE_TARGETS
      CommercialWebsiteIntent.business_only?(question) ? targets.reject { |celex_id, _number| celex_id == WEBSITE_CONSUMER_CELEX } : targets
    end

    def website_overview_candidates(reader, targets)
      rows = []
      priorities = {}
      rejected_ids = []
      targets.each_with_index do |(celex, number), priority|
        reader.candidates(match: nil, source_kinds: ['legislation'], limit: 150, celex: celex,
                          unit: ['article', number], language: @language, historical: false).each do |record|
          next unless record.is_a?(Hash)

          if website_overview_record?(record, reader, celex, number)
            rows << record
            priorities[overview_identity(record)] = priority
          elsif record[:eu_chunk_id]
            # A bad exact-read response cannot borrow an otherwise lexical copy
            # of the same chunk identity to acquire an overview priority.
            rejected_ids << record[:eu_chunk_id]
          end
        end
      end
      [rows, priorities, rejected_ids]
    end

    def website_overview_record?(record, reader, celex, number)
      record[:source_kind] == 'legislation' && record[:kind] == 'article' &&
        record[:unit_number] == number && record[:unit_identity_number] == number && record[:article_number] == number &&
        record[:historical] == false && record[:retrieval_scope] == 'eligible_source_edition' &&
        celex_family?(record[:celex], celex) && (overview_edition_date(record).nil? || overview_edition_date(record) <= Date.current) &&
        reader.respond_to?(:verified_record?) && reader.verified_record?(record)
    end

    def celex_family?(actual, base)
      actual.to_s == base || actual.to_s.match?(/\A0#{Regexp.escape(base[1..])}-\d{8}\z/)
    end

    def verified_unchanged_recital?(record)
      record[:kind] == 'recital' && record[:correction_status] == 'verified_unchanged_recitals' &&
        record[:correction_verification] == 'explicit_other_language_correction_closure' &&
        [@corpus, @live_corpus].compact.any? { |reader| reader.respond_to?(:verified_record?) && reader.verified_record?(record) }
    end

    # A website-overview unit is breadth: "an overview quota is a ceiling, not
    # an obligation" (search). The Belgian pins and the sealed GDPR texts
    # govern that topic, so the unit is marked optional for the statutory
    # allowance, which may leave it out whole (r47, root 2026-10-19
    # 21:51:37 and 22:11:41). Topic-plan targets and named units carry no
    # mark and stay required.
    def eu_result_record(record, score, website_overview:)
      result = record.merge(keyword_hit: true, eu_lexical_score: score)
      website_overview ? result.merge(eu_website_overview: true) : result
    end

    def overview_identity(record)
      EuCorpus::IDENTITY_FIELDS.map { |key| record[key] } + [record[:article_number]]
    end

    def overview_edition_date(record)
      date = record[:celex].to_s[/\A0\d{4}[A-Z]{1,2}\d{4}-(\d{8})\z/, 1]
      Date.strptime(date, '%Y%m%d') if date
    rescue Date::Error
      Date.new(9999)
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase
    end

    def query_tokens(question, limit: 10)
      # Unit headings, numbering suffixes and identifier labels are routing
      # syntax, not topical evidence. Without a scoped CELEX/ECLI/act identity,
      # 'article 75 ter' must not select arbitrary legislation just because its
      # heading repeats 'article' and 'ter'. Exact identity paths stay separate.
      topical = question.to_s.gsub(UNIT_PATTERN, ' ')
                        .gsub(/\b(?:CELEX\s*:?\s*)?[036]\d{4}[A-Z]{1,2}\d{4}(?:-\d{8})?(?:R\(\d{2}\))?\b/i, ' ')
                        .gsub(/\bECLI:EU:[A-Z]+:\d{4}:\d+\b/i, ' ')
      normalize(topical).scan(/[\p{L}\p{N}]{3,}/).reject { |token| STOP_WORDS.include?(token) }.uniq.take(limit)
    end

    # The question's subject words: what a kept unit must share with it.
    def relevance_tokens(question)
      query_tokens(question, limit: 48).reject do |token|
        GENERIC_CONTEXT_WORDS.include?(token) || QUESTION_FRAME_WORDS.include?(token) || token.match?(/\A\p{N}+\z/)
      end
    end

    def extract_units(question)
      question.scan(UNIT_PATTERN).map do |prefix, number|
        word = normalize(prefix)
        kind = if word.match?(/\A(?:art|artikel|article)/)
                 'article'
               elsif word.match?(/\A(?:overweging|considerant|erwagungsgrund|recital)/)
                 'recital'
               else
                 'paragraph'
               end
        [kind, number]
      end
    end

    def explicit_original_recital?(question, celex, unit)
      return false unless celex&.start_with?('3') && unit&.first == 'recital'

      q = normalize(question)
      q.match?(/\b(?:oorspronkelijke|originele|original|originale|initial|initiale|ursprunglich|ursprungliche|basisversie|base edition)\b/) &&
        !q.match?(/\b(?:current|latest|actueel|huidige|bijgewerkt|actuelle|aktuell|nieuwste)\b/)
    end

    def topic_tokens(question)
      q = normalize(question)
      if q.match?(/\b(?:website|webshop|online|site internet|internetauftritt)\b/) &&
         q.match?(/\b(?:dienst|dienstenverlening|services?|dienstleistungen|verkopen|vente|commerce|commercial|commerciele|handel)\b/)
        %w[dienstverlener informatiemaatschappij elektronische dienstleistung commerce consumer]
      elsif q.match?(/\b(?:avg|gdpr|rgpd|dsgvo|persoonsgegevens|privacy|datenschutz|donnees personnelles)\b/)
        %w[persoonsgegevens processing traitement personenbezogener]
      else
        []
      end
    end

    def requested_lane?(question, judicial)
      if judicial
        question.match?(/\b(?:rechtspraak|jurisprudence|judgments?|case\s+law|Rechtsprechung|arresten|arrest|arr[êe]ts?)\b/iu)
      else
        question.match?(/\b(?:wetgeving|l[ée]gislation|statutes?|regulations?|directives?|Gesetzgebung|verordeningen?|richtlijnen?)\b/iu)
      end
    end

    def lexical_hits(text, tokens)
      tokens.select { |token| text.match?(/\b#{Regexp.escape(token[0, [token.length, 7].min])}[\p{L}\p{N}]*/u) }
    end

    # Broad prefixes are useful for candidate recall, not subject admission:
    # "werk" must not certify "werkingssfeer", nor "arbeidscontract" certify
    # "arbeidsverhouding". Retain whole words and small grammatical suffixes
    # without inventing a semantic equivalence between neighbouring concepts.
    def strong_literal_hits(text, tokens)
      tokens.select do |token|
        forms = [token]
        forms << token.delete_suffix('s') if token.length > 4 && token.end_with?('s') && !token.end_with?('ss')
        roots = forms.map { |form| Regexp.escape(form) }.join('|')
        text.match?(/\b(?:#{roots})(?:s|en|e|n)?\b/u)
      end
    end

    def question_concepts(question)
      q = normalize(question)
      CONCEPT_GROUPS.filter_map { |selector, entries| entries if q.match?(selector) }
                    .flatten(1).select { |pattern, _words| q.match?(pattern) }.uniq
    end

    def lexical_evidence(record, tokens, original_tokens:, concepts: [])
      # The full knowledge graph/provenance is carried into source evidence,
      # not searched as paragraph text. Normalizing its ~170KB once per match
      # and repeatedly per candidate made a generic case lane take seconds.
      # Normalize literal unit/title once; only short verified identity aliases
      # can supplement them. Never alter or truncate the sealed source body.
      # A legacy case-law final unit may carry the complete holding in
      # ``heading`` (older shards were built before the Dictum boundary was
      # separated).  That body is literal evidence, not an independent title
      # signal; otherwise its generic words can certify an unrelated query.
      title_fields = if record[:source_kind].to_s == 'jurisprudence' && record[:kind].to_s == 'final'
                       [record[:law_title]]
                     else
                       [record[:law_title], record[:heading]]
                     end
      title = normalize(title_fields.join(' '))
      literal = normalize([record[:heading], record[:article_text]].join(' '))
      aliases = Array(record[:aliases]).grep(String).take(32).map { |entry| entry[0, 400] }
      text = [title, literal, normalize(aliases.join(' '))].join(' ')
      hits = lexical_hits(text, tokens)
      { hits: hits, original_hits: lexical_hits(text, original_tokens),
        literal_original_hits: strong_literal_hits(literal, original_tokens), title_original_hits: strong_literal_hits(title, original_tokens),
        concept_hits: concepts.count { |pattern, _words| literal.match?(pattern) },
        literal_hits: lexical_hits(literal, hits).length, title_hits: tokens.count { |token| title.include?(token) } }
    end

    def topic_relevant?(evidence, original_tokens:)
      return true if evidence[:concept_hits].to_i >= 2
      return false if original_tokens.length < 2

      # Unplanned searches still work, including acts outside our finite topic
      # plans, but need affirmative subject evidence: an informative title term
      # plus two literal question terms, or at least three terms covering half
      # of the bounded full question's informative terms in the unit itself.
      # The first ten candidate tokens alone must not hide the actual question
      # at the end of a quote.
      # Aliases/provenance cannot certify arbitrary paragraphs as relevant.
      literal_hits = evidence[:literal_original_hits].length
      return false if literal_hits < 2

      # A recognized subject with complete literal same-language coverage also
      # supports short queries such as "privacy protection". One translated
      # concept alone never establishes that complete original-term coverage.
      if literal_hits == original_tokens.length
        subject = original_tokens.join(' ')
        return true if evidence[:concept_hits].positive? || CONCEPT_GROUPS.keys.any? { |pattern| subject.match?(pattern) }
      end

      evidence[:title_original_hits].any? || literal_hits >= [(original_tokens.length / 2.0).ceil, 3].max
    end

    def judicial_priority(record)
      return 50 if record[:kind] == 'final'

      opening = normalize(record[:article_text].to_s[0, 260])
      # This is a ranking distinction, never an eligibility override: a court
      # quoting a statute is different from the court deciding the dispute.
      statutory = opening.match?(/\A(?:(?:volgens|according to|selon|nach)\s+)?(?:artikel|article|art\.)\s*\d+/) &&
                  opening.match?(/\b(?:bepaalt|luidt|provides|reads|dispose|libelle|lautet|bestimmt)\b/)
      return -35 if statutory

      opening.match?(/\b(?:aldus.*uitgelegd|dient.*vastgesteld|aanspraak.*maken|must.*interpreted|doit.*interprete|auszulegen)\b/) ? 15 : 0
    end
  end
end
