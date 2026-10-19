# frozen_string_literal: true

module LegalChatbot
  # Searches case law (jurisprudence) via FAISS vector search
  # against the jurisprudence embeddings database.
  #
  # Sources: Belgian court decisions (Cass, RvS, Grondwettelijk Hof,
  # Hoven van Beroep, etc.) indexed via ECLI numbers.
  #
  # Architecture:
  #   FAISS service (port 8765) returns [case_id, similarity] pairs
  #   Source DB lookup for case metadata (court, date, text)
  class JurisprudenceSearch
    include TextProcessing

    # CHATBOT_JURISPRUDENCE_DB, deliberately NOT the JURISPRUDENCE_SOURCE_DB
    # name the website paths read: the site needs storage/jurisprudence.db
    # while this resolver needs the compact DB whose ids the FAISS index is
    # keyed on - the two id spaces differ, so one shared variable set for
    # either consumer's benefit silently made the other cite WRONG cases.
    # Default is the canonical volume path, not the retired
    # HC_Volume_104299669 symlink chain it used to depend on.
    JURISPRUDENCE_SOURCE_DB = ENV.fetch(
      'CHATBOT_JURISPRUDENCE_DB',
      '/mnt/HC_Volume_105488593/embeddings/jurisprudence_compact.db'
    )

    # Minimum similarity threshold for jurisprudence to be considered relevant
    # 0.40 allows general questions to get case mentions, 0.55 was too strict
    SIMILARITY_THRESHOLD = 0.40
    # Hydrate and validate a bounded pool BEFORE taking the answer budget.
    # Orphaned ids and unsuitable neighbours must not consume that budget.
    MAX_CANDIDATES = 200

    # Staff-specific railway employment/safety material is not a rule for
    # an office employee who happens to work during a train commute. Require
    # a positively identified railway employment relationship, not "train",
    # NMBS, a union or an ordinary employer mentioned somewhere in the text.
    RAILWAY_STAFF_SUBJECT_PATTERN = /
      \b(?:spoorwegpersoneel|spoorwegwerknemer\p{L}*|treinpersoneel|treinbesturingspersoneel|treinbestuurder\p{L}*|treinbegeleider\p{L}*|
          railway\s+(?:staff|workers?|employees?|drivers?)|train\s+(?:crew|drivers?)|
          personnel\s+ferroviaire|cheminot\p{L}*|conducteurs?\s+de\s+train|
          Bahnpersonal\p{L}*|Eisenbahnpersonal\p{L}*|Eisenbahner\p{L}*|Lokführer\p{L}*|Zugpersonal\p{L}*|Zugbegleiter\p{L}*|
          personeel.{0,100}(?:tewerkgesteld|werkzaam).{0,80}(?:Belgische\s+)?spoorwegen|
          personeel.{0,100}(?:Belgische\s+)?spoorwegen.{0,60}(?:tewerkgesteld|werkzaam)|
          (?:mobiele\s+werknemers|mobile\s+workers?|travailleurs?\s+mobiles).{0,100}(?:spoorweg\p{L}*|railway\p{L}*|ferroviaire\p{L}*)|
          personnel.{0,100}(?:employé|occupé|employe|occupe).{0,80}(?:chemins?\s+de\s+fer|SNCB)|
          (?:staff|employees?).{0,100}(?:employed|working).{0,80}(?:Belgian\s+Railways|railway\s+(?:companies|undertakings))|
          Personal.{0,100}(?:beschäftigt|angestellt).{0,80}(?:Eisenbahn|Belgischen\s+Bahnen))\b
    /ixmu
    RAILWAY_STAFF_RULE_PATTERN = /\b(?:arbeidsduur|arbeidstijd\p{L}*|werktijd\p{L}*|werkuren|rusttijd\p{L}*|arbeidsvoorwaarden|ontslag\p{L}*|opzeggingstermijn\p{L}*|veiligheid\p{L}*|working\s+(?:time|hours|conditions)|rest\s+(?:time|periods?)|dismissal|resignation|notice\s+period\p{L}*|safety|durée\s+du\s+travail|temps\s+de\s+travail|repos|conditions\s+de\s+travail|licenciement\p{L}*|démission\p{L}*|préavis|sécurité|Arbeitszeit\p{L}*|Ruhezeit\p{L}*|Arbeitsbedingungen|Kündigung\p{L}*|Sicherheit\p{L}*)\b/iu

    def self.railway_staff_rules?(text)
      text.to_s.match?(RAILWAY_STAFF_SUBJECT_PATTERN) && text.to_s.match?(RAILWAY_STAFF_RULE_PATTERN)
    end

    INCOME_TAX_SUBJECT_PATTERN = /\b(?:inkomstenbelasting\p{L}*|personenbelasting\p{L}*|imp[oô]ts?\s+(?:sur\s+les?\s+revenus?|des?\s+personnes\s+physiques)|income\s+tax\p{L}*|Einkommensteuer\p{L}*)\b/iu
    DIRECT_TAX_SOURCE_PATTERN = /\b(?:directe\s+belastingen|imp[oô]ts?\s+directs?|direct\s+taxes?|direkte\s+Steuern)\b/iu
    INCOME_SOURCE_PATTERN = /\b(?:inkomsten|revenus?|income|Einkünfte\p{L}*|Einkommen)\b/iu
    TAX_ARREARS_PROCEDURE_PATTERN = /\b(?:nalatigheidsinterest\p{L}*|nalatigheidsintrest\p{L}*|verwijlint\p{L}*|kwijtschelding\p{L}*|belastingschuld\p{L}*|belastingachterstand\p{L}*|int[ée]r[êe]ts?\s+de\s+retard|remise\s+(?:des?\s+)?(?:int[ée]r[êe]ts?|imp[oô]ts?|majorations)|late[\s-]+(?:payment\s+)?interest|tax\s+arrears|interest\s+waiver|waiver\s+of\s+(?:tax|interest)|Verzugszinsen|Säumniszuschlag\p{L}*|Steuererlass|Erlass\s+(?:der?\s+)?(?:Steuer\p{L}*|Zinsen))\b/iu
    MARITAL_PROPERTY_SUBJECT_PATTERN = /\b(?:huwelijksgemeenschap\p{L}*|huwelijksvermogen\p{L}*|huwelijksvermogensstelsel\p{L}*|huwelijkscontract\p{L}*|huwelijksovereenkomst\p{L}*|gemeenschap\s+van\s+(?:goederen|vermogen)|r[ée]gime\s+matrimonial|communaut[ée]\s+(?:matrimoniale|de\s+biens)|contrat\s+de\s+mariage|marital\s+(?:community|property|regime)|community\s+(?:property|of\s+property)|marriage\s+(?:contract|agreement)|Gütergemeinschaft\p{L}*|Güterstand\p{L}*|Ehevertrag\p{L}*)\b/iu
    SURVIVING_SPOUSE_SUBJECT_PATTERN = /\b(?:(?:langstlevende|overlevende)\s+(?:echtgeno(?:ot|te)\p{L}*|huwelijkspartner\p{L}*)|conjoint\p{L}*\s+survivant\p{L}*|[ée]pou[xs]\p{L}*\s+survivant\p{L}*|surviving\s+(?:spouse|husband|wife)|überlebend\p{L}*\s+(?:Ehegatte\p{L}*|Ehepartner\p{L}*))\b/iu
    UNEQUAL_MARITAL_PARTITION_PATTERN = /\b(?:beding\s+van\s+ongelijke\s+verdeling|ongelijk\p{L}*\s+(?:verdeling|toebedeling)|verblijvingsbeding\p{L}*|clause\s+de\s+partage\s+in[ée]gal|partage\s+in[ée]gal|unequal\s+(?:partition|division|distribution)|Ungleich\p{L}*\s+(?:Teilung|Aufteilung)|ungleiche\s+Verteilung)\b/iu
    RECEIVABLE_SUBJECT_PATTERN = /\b(?:schuldvordering\p{L}*|cr[ée]ances?|receivables?|debt\s+claims?|Forderung\p{L}*)\b/iu
    RECEIVABLE_VALUATION_PATTERN = /\b(?:verkoopwaarde|nominaal\s+bedrag|nominale\s+waarde|waard(?:eer|er)\p{L}*|gewaard\p{L}*|waardevermindering\p{L}*|taxatie\p{L}*|valeur\s+(?:v[ée]nale|nominale)|[ée]valu\p{L}*|d[ée]pr[ée]ciation\p{L}*|valuation\p{L}*|valuing|nominal\s+(?:value|amount)|market\s+value|depreciation|Bewert\p{L}*|Nennwert\p{L}*|Verkehrswert\p{L}*|Wertminderung\p{L}*)\b/iu
    RECEIVABLE_VALUATION_QUERY_PATTERN = Regexp.union(
      RECEIVABLE_VALUATION_PATTERN,
      /\A(?=.*#{RECEIVABLE_SUBJECT_PATTERN.source})(?=.*\b(?:waarde|value|valeur|Wert)\b).*\z/imxu
    ).freeze
    DEBTOR_INSOLVENCY_PATTERN = /\b(?:onvermogen|onvermogend\p{L}*|insolv\p{L}*|faill\p{L}*|bankrupt\p{L}*|unable\s+to\s+pay|Zahlungsunf[äa]higkeit|zahlungsunf[äa]hig\p{L}*)\b/iu
    RECEIVABLE_DISPUTE_PATTERN = Regexp.union(
      DEBTOR_INSOLVENCY_PATTERN,
      /\b(?:hoger\s+beroep|vonnis\p{L}*|gerechtelijk\p{L}*|invorder\p{L}*|jugement\p{L}*|recouvrement|appel|judgments?|court\s+(?:order|ruling|debt)|recovery|collection|Urteil\p{L}*|gerichtlich\p{L}*|Berufung|Beitreibung)\b/iu
    ).freeze
    JUDGMENT_DEBT_QUERY_PATTERN = /\b(?:schuld\p{L}*|cr[ée]ances?|receivables?|debt\p{L}*|Forderung\p{L}*)\b.{0,100}\b(?:vonnis\p{L}*|gerechtelijk\p{L}*|jugement\p{L}*|judgments?|court|Urteil\p{L}*|gerichtlich\p{L}*)\b|\b(?:vonnis\p{L}*|gerechtelijk\p{L}*|jugement\p{L}*|judgments?|court|Urteil\p{L}*|gerichtlich\p{L}*)\b.{0,100}\b(?:schuld\p{L}*|cr[ée]ances?|receivables?|debt\p{L}*|Forderung\p{L}*)\b/imu

    # A deceased litigant or an estate paying costs does not turn an ordinary
    # income-tax document into inheritance-tax evidence. Likewise, a
    # wife receiving a foreign cousin's money is not the deceased's spouse.
    # These are positive specialist families, not a whitelist of tax cases.
    def self.foreign_succession_source_relevant?(text, question, source_subject: nil)
      return true unless question.to_s.match?(LegislationSearch::FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)

      # Prefer the title/summary subject: an incidental income-tax citation
      # in an inheritance-tax judgment does not identify its main subject.
      subject = source_subject.presence || text
      arrears = text.match?(TAX_ARREARS_PROCEDURE_PATTERN)
      income_tax = subject.match?(INCOME_TAX_SUBJECT_PATTERN) ||
                   (text.match?(DIRECT_TAX_SOURCE_PATTERN) && text.match?(INCOME_SOURCE_PATTERN) && arrears)
      if income_tax && !question.match?(INCOME_TAX_SUBJECT_PATTERN) &&
         !(arrears && question.match?(TAX_ARREARS_PROCEDURE_PATTERN))
        return false
      end

      disputed_receivable_valuation = text.match?(RECEIVABLE_SUBJECT_PATTERN) &&
                                      text.match?(RECEIVABLE_VALUATION_PATTERN) && text.match?(RECEIVABLE_DISPUTE_PATTERN)
      if disputed_receivable_valuation &&
         !question.match?(RECEIVABLE_VALUATION_QUERY_PATTERN) && !question.match?(DEBTOR_INSOLVENCY_PATTERN) &&
         !question.match?(JUDGMENT_DEBT_QUERY_PATTERN)
        return false
      end

      marital_partition = text.match?(UNEQUAL_MARITAL_PARTITION_PATTERN) &&
                          (text.match?(MARITAL_PROPERTY_SUBJECT_PATTERN) || text.match?(SURVIVING_SPOUSE_SUBJECT_PATTERN))
      spouse_fiscal_estate = text.match?(SURVIVING_SPOUSE_SUBJECT_PATTERN) &&
                             text.match?(LegislationSearch::FOREIGN_SUCCESSION_TAX_SUBJECT_PATTERN)
      if (marital_partition || spouse_fiscal_estate) &&
         !question.match?(MARITAL_PROPERTY_SUBJECT_PATTERN) && !question.match?(SURVIVING_SPOUSE_SUBJECT_PATTERN)
        return false
      end

      true
    end

    COURT_NAME_MAP = {
      'CASS' => 'Hof van Cassatie', 'RVSCE' => 'Raad van State',
      'RvS' => 'Raad van State', 'GHCC' => 'Grondwettelijk Hof',
      'CABRL' => 'Hof van Beroep Brussel', 'CALIE' => 'Hof van Beroep Luik',
      'CAMON' => 'Hof van Beroep Bergen', 'AHANT' => 'Hof van Beroep Antwerpen',
      'AHGNT' => 'Hof van Beroep Gent', 'CTBRL' => 'Arbeidsrechtbank Brussel',
      'HBANT' => 'Handelsrechtbank Antwerpen', 'HBGNT' => 'Handelsrechtbank Gent',
      'HBBRL' => 'Handelsrechtbank Brussel',
      'COHSAV' => 'Commissie voor de Bescherming van de Persoonlijke Levenssfeer'
    }.freeze

    def initialize(embedding_service:, language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @jurisprudence_source_db = nil
    end

    # nil after a search the FAISS service answered, 'semantic_unavailable'
    # when it did not. Read by the fan-out right after #search returns.
    attr_reader :retrieval_degradation

    # Find similar jurisprudence cases using FAISS vector search
    def search(question_embedding, limit: 5, question: nil)
      # Reset first: one service instance can serve more than one ask.
      @retrieval_degradation = nil
      limit = limit.to_i.clamp(0, MAX_CANDIDATES)
      return [] if limit.zero?

      source_db = jurisprudence_source_db

      # FAISS service (fast path) - request more to filter by threshold
      candidate_limit = [limit * 8, 32].max.clamp(1, MAX_CANDIDATES)
      top_cases = search_faiss(question_embedding, candidate_limit)
      # nil is "the service did not answer", which the [] below would make
      # indistinguishable from "no case is close enough". The 30 s read equals
      # the fan-out deadline, so a cold index surfaces there as a timeout; this
      # catches the fast failures (connection refused during a unit restart or
      # its warm-up scan, HTTP 5xx).
      @retrieval_degradation = 'semantic_unavailable' if top_cases.nil?
      top_cases ||= [] # FAISS unavailable - return empty rather than degraded random results

      # Keep rank order, but do not truncate before DB hydration/relevance.
      top_cases = top_cases.first(candidate_limit).select { |_, sim| sim.to_f >= SIMILARITY_THRESHOLD }
                           .uniq { |case_id, _| case_id.to_s }
      Rails.logger.info("Jurisprudence: #{top_cases.length} cases above threshold #{SIMILARITY_THRESHOLD}")

      # Fetch case details
      selected = []
      top_cases.each do |case_id, similarity|
        case_data = source_db.execute(
          'SELECT id, case_number, court, decision_date, summary, full_text, url, language_id FROM cases WHERE id = ?',
          [case_id]
        ).first

        next unless case_data

        candidate = {
          id: case_data[0],
          case_number: case_data[1],
          court: case_data[2],
          decision_date: case_data[3],
          summary: case_data[4],
          full_text: case_data[5],
          url: case_data[6],
          language_id: case_data[7],
          source_language: { 1 => 'nl', 2 => 'fr', 3 => 'de' }[case_data[7].to_i],
          similarity: similarity
        }.merge(self.class.source_metadata(case_number: case_data[1], court: case_data[2]))
        begin
          next unless secondary_source_relevant?(candidate, question)
        rescue Regexp::TimeoutError
          # An unclassifiable source is not relevant by default. Keep healthy
          # neighbours, but report the incomplete validation so the response
          # pipeline still displays its degradation/refund signal.
          @retrieval_degradation ||= 'source_validation_unavailable'
          Rails.logger.warn('[Jurisprudence relevance] candidate skipped: Regexp::TimeoutError')
          next
        end

        selected << candidate
        break if selected.length >= limit
      end
      selected
    end

    # The corpus contains opinions and administrative decisions as well as
    # judgments. Preserve that distinction without inferring a judgment from
    # a free-text court name (or inventing an effective date from its date).
    def self.source_metadata(case_number:, court: nil)
      number = case_number.to_s
      kind = if AdvisoryOpinions.advisory?(number)
               'legislative_opinion'
             elsif number.match?(/:AVIS[.:]/i)
               'advisory_opinion'
             elsif number.match?(/:(?:ARR|JUG)[.:]/i)
               'judgment'
             elsif number.match?(/:ORD[.:]/i)
               'order'
             elsif number.match?(/:DEC[.:]/i)
               'decision'
             end
      { source_kind: 'jurisprudence', judicial_kind: kind,
        authority_kind: kind&.end_with?('opinion') ? 'advisory' : 'case_law_collection',
        authority: court, jurisdiction: 'BE' }
    end

    # Build jurisprudence context from external DB results
    def build_context(cases, question: nil, max_chars: 2000)
      cases.map.with_index do |c, index|
        lang_label = { 1 => 'NL', 2 => 'FR', 3 => 'DE' }[c[:language_id].to_i] || 'unknown'
        text = SourcePassageExcerpt.excerpt(c[:full_text], question, max_chars: max_chars, summary: c[:summary])
        metadata = self.class.source_metadata(case_number: c[:case_number], court: c[:court])
        kind_notice = "Source kind: #{metadata[:judicial_kind] || 'unclassified case-law collection record'}"
        kind_notice += '; advice, not a judgment or binding legislation.' if metadata[:authority_kind] == 'advisory'

        if AdvisoryOpinions.advisory?(c[:case_number])
          header = AdvisoryOpinions.context_header(c[:case_number], c[:court], @language)
          <<~CONTEXT
            [Bron #{index + 1} - #{AdvisoryOpinions.source_label(@language)} (#{lang_label})]
            #{header.join("\n")}
            Datum: #{c[:decision_date]}
            #{kind_notice}

            #{text}
          CONTEXT
        else
          source_label = if metadata[:authority_kind] == 'advisory'
                           { 'fr' => 'AVIS CONSULTATIF', 'en' => 'ADVISORY OPINION', 'de' => 'GUTACHTEN' }.fetch(@language, 'ADVIES')
                         else
                           @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
                         end
          <<~CONTEXT
            [Bron #{index + 1} - #{source_label} (#{lang_label})]
            ECLI: #{c[:case_number]}
            Hof: #{c[:court]}
            Datum: #{c[:decision_date]}
            #{kind_notice}

            #{text}
          CONTEXT
        end
      end.join("\n---\n")
    end

    # Format jurisprudence sources from external DB results
    def format_sources(cases)
      cases.map do |c|
        # Build WetWijzer URL using ECLI case_number, fallback to JuPortal URL if available
        wetwijzer_url = c[:case_number] ? "https://wetwijzer.be/jurisprudence/#{c[:case_number]}" : nil
        juportal_url = c[:url].presence

        # Extract court code from ECLI and map to readable name
        court_name = c[:court]
        if court_name.nil? || court_name == 'Unknown'
          ecli = c[:case_number].to_s
          if ecli.start_with?('ECLI:BE:')
            court_code = ecli.split(':')[2]
            court_name = COURT_NAME_MAP[court_code] || court_code
          elsif ecli.start_with?('RvS-')
            court_name = 'Raad van State'
          end
        end

        {
          type: self.class.source_metadata(case_number: c[:case_number])[:authority_kind] == 'advisory' ? 'ADVIES' : 'RECHTSPRAAK',
          ecli: c[:case_number],
          court: court_name,
          date: c[:decision_date],
          url: wetwijzer_url || juportal_url,
          language: { 1 => 'NL', 2 => 'FR', 3 => 'DE' }[c[:language_id].to_i],
          relevance: c[:similarity]&.round(2)
        }.merge(self.class.source_metadata(case_number: c[:case_number], court: court_name))
      end
    end

    private

    # Call FAISS service for fast similarity search
    def search_faiss(question_embedding, limit)
      require 'net/http'
      require 'json'

      faiss_url = ENV.fetch('FAISS_SERVICE_URL', 'http://127.0.0.1:8765')
      uri = URI("#{faiss_url}/search")

      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 30) do |http|
        http.request(request)
      end

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        Rails.logger.info("FAISS search completed in #{data['search_time_ms']&.round(1)}ms")

        # Convert to [case_id, similarity] format
        # FAISS service returns 'id' (not 'case_id') - maps to cases.id in source DB
        data['results'].map { |r| [r['id'], r['similarity']] }
      else
        Rails.logger.error("FAISS service error: #{response.code} #{response.message}")
        nil
      end
    rescue StandardError => e
      # Class only: a JSON::ParserError message can echo response-body text.
      # A warning, like its parliamentary and regional siblings: at debug a
      # failed semantic search is invisible in production.
      Rails.logger.warn("[Jurisprudence FAISS] unavailable: #{e.class}")
      nil
    end

    def jurisprudence_source_db
      @jurisprudence_source_db ||= SQLite3::Database.new(JURISPRUDENCE_SOURCE_DB)
    end

    # Case-law neighbours can be useful analogies, but should still concern
    # the legal relationship in the question. This rejects a semantically
    # nearby case that only shares a product/repair word before it is included
    # in the prompt or displayed as a source. It deliberately leaves ordinary
    # questions fail-open and preserves an explicitly requested ECLI.
    def secondary_source_relevant?(case_record, question)
      return true if question.blank? || explicit_reference?(case_record, question)

      return false unless MunicipalSanctionsSourceScope.source_relevant?(case_record, question: question)
      return false unless VehicleHeadlightGlareSourceScope.source_relevant?(case_record, question)
      return false unless CommercialWebsiteIntent.secondary_source_relevant?(case_record, question)
      return false unless PlatformModerationSourceScope.source_relevant?(case_record, question)
      return false unless MarketplaceCivilClaimIntent.secondary_source_relevant?(case_record, question)

      text = [case_record[:summary], case_record[:full_text], case_record[:case_number], case_record[:court]].compact.join("\n")
      return false unless self.class.foreign_succession_source_relevant?(text, question, source_subject: case_record[:summary])

      if question.match?(LegislationSearch::OFFICE_COMMUTE_WORK_PATTERN)
        # PDF soft-wrap normalization is only relevant to this occupational
        # classifier. Never regex-scan an unrelated complete judgment (e.g.
        # GDPR) merely to discover the question is outside that scope.
        occupational_text = [case_record[:summary], case_record[:full_text]].map do |source_part|
          LegislationSearch.normalize_occupational_source_layout(source_part)
        end.join("\n")
        return false unless LegislationSearch.office_commute_specialist_source_relevant?(
          occupational_text, question, source_subject: case_record[:summary]
        )
        return false if self.class.railway_staff_rules?(text)
      end
      return text.match?(consumer_remedy_evidence_pattern) if consumer_repair_damage_question?(question)

      return true unless residential_tenancy_question?(question)

      text.match?(residential_tenancy_evidence_pattern)
    end

    def explicit_reference?(case_record, question)
      case_number = case_record[:case_number].to_s
      return true if case_number.present? && question.to_s.downcase.include?(case_number.downcase)
      return false unless AdvisoryOpinions.advisory?(case_number)

      # Readers normally name an opinion as "advies 78.678/16", not by the
      # corpus's RVSADV language key. An unrelated amount is not a reference.
      number = Regexp.escape(AdvisoryOpinions.number(case_number))
      question.to_s.match?(%r{\b(?:advies|avis|advice|opinion|Gutachten|Stellungnahme)\s*(?:(?:nr\.?|no\.?|n[°º])\s*)?#{number}(?:/\d+)?(?![\d.])}iu)
    end

    def consumer_repair_damage_question?(question)
      question.match?(LegalChatbot::LegislationSearch::CONSUMER_GOODS_WARRANTY_PATTERN) ||
        (question.match?(LegalChatbot::LegislationSearch::CONSUMER_GOODS_DISPUTE_PATTERN) &&
          (question.match?(LegalChatbot::LegislationSearch::REPAIR_NEW_DAMAGE_RELATION_PATTERN) ||
            question.match?(/(?:garantie|warrant\w*|conform(?:iteit|ity|ité)?|gewährleistung)/i)))
    end

    def residential_tenancy_question?(question)
      question.match?(LegalChatbot::LegislationSearch::REGIONAL_HOUSING_SUBJECT_PATTERN)
    end

    def consumer_remedy_evidence_pattern
      /\b(?:garantie|warrant\w*|conform(?:iteit|ity|ité)?|aansprak\w*|responsab\w*|liabilit\w*|schade|damage\w*|vergoeding\w*|compensat\w*|indemni[st]\w*|refund\w*|terugbetal\w*|rembours\w*|vervang\w*|replacement\w*|remplace\w*|ontbind\w*|résili\w*|prijsverminder\w*|reduction\s+du\s+prix)\b/i
    end

    def residential_tenancy_evidence_pattern
      /\b(?:woninghuur|huurcontract|huurovereenkomst|huurder|verhuurder|huurprijs|huurwaarborg|huur|lease|tenan\w*|landlord|rent\w*|rental|bail(?:leur)?|locataire|logement|habitation|residential|miet\w*|wohnung)\b/i
    end
  end
end
