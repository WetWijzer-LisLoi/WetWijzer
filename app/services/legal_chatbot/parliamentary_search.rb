# frozen_string_literal: true

module LegalChatbot
  # Searches parliamentary preparation documents (voorbereidende werken /
  # travaux préparatoires) via FAISS vector embeddings.
  #
  # Sources: Chamber/Senate documents, committee reports, amendments,
  # mémoires exposé des motifs, Council of State advice.
  #
  # Architecture:
  #   FAISS service (port 8769) returns document IDs → SQLite lookup for metadata
  class ParliamentarySearch
    include TextProcessing

    # Minimum similarity for a parliamentary doc to be considered relevant.
    # Below this, FAISS nearest-neighbors are noise (e.g. unrelated French bills).
    # Raised from 0.35 → 0.45: old threshold let completely unrelated documents
    # (e.g. vehicle inspections) appear in family law answers.
    SIMILARITY_THRESHOLD = 0.45

    FAISS_URL = ENV.fetch('FAISS_PARLIAMENTARY_URL', 'http://localhost:8769')
    # Older chamber snapshots have only the six base columns. Missing
    # metadata stays unknown, rather than failing all parliamentary retrieval.
    METADATA_COLUMNS = %w[document_type status document_date publication_date language language_id legislature legislation_numac].freeze

    LIBERATING_PAYMENT_SOURCE_PATTERN = /\b(?:bevrijdende\s+betaling|paiement\s+lib[ée]ratoire|(?:liberating|discharging)\s+payment|schuldbefreiende\s+Zahlung)\b/iu
    SURVIVOR_PAYMENT_SUBJECT_PATTERN = /\b(?:langstlevende\p{L}*|overlevende\s+echtgeno\p{L}*|wettelijk\p{L}*\s+samenwonend\p{L}*|conjoint\p{L}*\s+survivant\p{L}*|cohabitant\p{L}*\s+l[ée]gal\p{L}*|surviving\s+(?:spouse|cohabitant)|überlebend\p{L}*\s+(?:Ehegatte\p{L}*|Lebenspartner\p{L}*))\b/iu
    INHERITED_FUNDS_RELEASE_QUERY_PATTERN = /
      #{LIBERATING_PAYMENT_SOURCE_PATTERN.source}|
      \b(?:vrijgav\p{L}*|deblokker\p{L}*|geblokkeerd\p{L}*|bevroren|d[ée]blocage|d[ée]bloqu\p{L}*|unblock\p{L}*|frozen|Freigabe|Entsperr\p{L}*|gesperrt\p{L}*)\b|
      \b(?:geld|tegoeden?|fondsen|bedrag|rekening\p{L}*|money|funds|cash|balance|account\p{L}*|argent|fonds|compte\p{L}*|Geld|Guthaben|Konto\p{L}*)\b.{0,70}\b(?:opnemen|opvragen|vrijgeven|uitbetalen|uitbetaling|release\p{L}*|withdraw\p{L}*|retir\p{L}*|abheben|auszahl\p{L}*)\b|
      \b(?:opnemen|opvragen|vrijgeven|uitbetalen|uitbetaling|release\p{L}*|withdraw\p{L}*|retir\p{L}*|abheben|auszahl\p{L}*)\b.{0,70}\b(?:geld|tegoeden?|fondsen|bedrag|rekening\p{L}*|money|funds|cash|balance|account\p{L}*|argent|fonds|compte\p{L}*|Geld|Guthaben|Konto\p{L}*)\b
    /ixmu
    ESTATE_CERTIFICATE_PATTERN = /
      \b(?:akte|attest|certificaat)\s+(?:(?:van|voor)\s+)?erfopvolging\b|
      \b(?:acte|attestation|certificat)\s+d['’]\s*h[ée]r[ée]dit[ée]\b|
      \b(?:acte|attestation|certificat)\s+(?:de\s+)?succession\b|
      \b(?:inheritance|succession|heirship)\s+certificate\p{L}*\b|
      \bcertificate\s+of\s+(?:inheritance|succession|heirship)\b|
      \b(?:Erbschein\p{L}*|Erbfolgezeugnis\p{L}*|Erbbescheinigung\p{L}*)\b
    /ixu
    ESTATE_ACTOR_PATTERN = /\b(?:erflater\p{L}*|overledene\p{L}*|nalatenschap\p{L}*|erfgena\p{L}*|rechtverkrijgend\p{L}*|d[ée]funt\p{L}*|succession|h[ée]ritier\p{L}*|deceased|estate|heirs?|Erblasser\p{L}*|Verstorbene\p{L}*|Nachlass\p{L}*|Erben)\b/iu
    ESTATE_DEBT_PATTERN = /\b(?:schulden?|belastingschuld\p{L}*|belastingachterstand\p{L}*|dettes?|debt\p{L}*|tax\s+arrears|Schuld\p{L}*|Steuerrückstand\p{L}*)\b/iu
    NOTARY_PATTERN = /\b(?:notaris\p{L}*|notaire\p{L}*|notary|notaries|Notar\p{L}*)\b/iu
    TAX_NOTIFICATION_PATTERN = /\b(?:kennisgeving\p{L}*|notificati\p{L}*|melding\p{L}*|melden|meedelen|notification\p{L}*|notify|notifies|notified|notifying|notifi\p{L}*|signaler|Mitteilung\p{L}*|Benachrichtigung\p{L}*|melden|gemeldet)\b/iu
    ESTATE_FUNDS_RELEASE_SOURCE_PATTERN = /\b(?:deblokker\p{L}*|vrijgav\p{L}*|geblokkeerd\p{L}*|d[ée]blocage|d[ée]bloqu\p{L}*|unblock\p{L}*|frozen\s+(?:funds|accounts?)|Freigabe|Entsperr\p{L}*|gesperrt\p{L}*)\b/iu
    INHERITANCE_TAX_CONNECTING_FACTOR_PATTERN = /\b(?:rijksinwoner\p{L}*|niet[-\s]?(?:rijks)?inwoner\p{L}*|woonplaats|fiscale\s+(?:woonplaats|domicilie)|bevoegd\p{L}*\s+gewest|territorial\p{L}*|non[-\s]?r[ée]sident\p{L}*|r[ée]sidence\s+fiscale|domicile\s+fiscal|habitant\p{L}*\s+du\s+royaume|tax\s+residence|fiscal\s+domicile|tax\s+jurisdiction|Wohnsitz|Ansässigkeit|Steuerhoheit)\b/iu
    INHERITANCE_TAX_TARIFF_PATTERN = /\b(?:tarief|tarieven|taux|tarif\p{L}*|tax\s+rates?|rates?|Steuers[aä]tz\p{L}*)\b/iu
    INHERITANCE_TAX_COMPOUND_TARIFF_PATTERN = /\b(?:erfbelasting|successie(?:recht(?:en)?)?)tarie[fv]\p{L}*\b/iu
    FUTURE_HOUSING_SALE_SOURCE_PATTERN = /\b(?:habitations?|maisons?|logements?)\s+(?:[àa]\s+construire|en\s+(?:voie|cours)\s+de\s+construction)\b|\b(?:woningen?|huizen?)\s+(?:te\s+bouwen|in\s+aanbouw)\b|\b(?:houses?|homes?|dwellings?)\s+(?:to\s+be\s+built|under\s+construction)\b|\b(?:Häuser|Haus|Wohnungen?)\s+(?:im\s+Bau|zu\s+errichten)\b/iu
    FUTURE_HOUSING_SALE_QUERY_PATTERN = Regexp.union(
      FUTURE_HOUSING_SALE_SOURCE_PATTERN,
      /\b(?:Breyne\p{L}*|nieuwbouw\p{L}*|(?:woning|huis)\s+op\s+plan|(?:onvoltooide|onafgewerkte)\s+(?:woning|huis)|(?:construction|habitation|maison|logement)\s+neu(?:f|ve)\p{L}*|(?:achat|vente)\s+sur\s+plan|new[-\s]?build\p{L}*|off[-\s]plan|unfinished\s+(?:house|home|dwelling)|under\s+construction|Neubau\p{L}*|Bauträgervertrag\p{L}*|unfertig\p{L}*\s+(?:Haus|Wohnung))\b/iu
    ).freeze
    AIRPORT_POLICY_RESOLUTION_TITLE_PATTERN = /\b(?:resolutie|r[ée]solution|resolution|Entschlie(?:ß|ss)ung)\p{L}*\b/iu
    AIRPORT_TITLE_PATTERN = /\b(?:luchthaven|airport|a[ée]roport|Flughafen)\p{L}*\b/iu
    AIRPORT_POLICY_OR_FUTURE_TITLE_PATTERN = /\b(?:toekomst|future|avenir|Zukunft|beleid|policy|politique|Politik|governance|beheer|management|capaciteit|capacity|capacit[ée]|Kapazit[äa]t|slots?|geluid|noise|bruit|L[äa]rm)\p{L}*\b/iu
    AIRPORT_POLICY_QUERY_PATTERN = /\b(?:luchthaven(?:beleid|beheer)\p{L}*|airport\s+(?:policy|governance|management|future|capacity|slots?|noise)|a[ée]roport\s+(?:politique|gouvernance|avenir|capacit[ée]|cr[ée]neaux|bruit)|Flughafen(?:politik|verwaltung|zukunft|kapazit[äa]t|slots?|l[äa]rm)|(?:toekomst|future|avenir|Zukunft)\p{L}*\s+(?:van\s+(?:de\s+)?|of\s+(?:the\s+)?|de\s+(?:l['’])?|des\s+)?(?:luchthaven|airport|a[ée]roport|Flughafen)|(?:luchthaven|airport|a[ée]roport|Flughafen)\p{L}*\s+(?:capaciteit|capacity|capacit[ée]|Kapazit[äa]t|slots?|geluid|noise|bruit|L[äa]rm))\b/iu

    def initialize(embedding_service:, language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @chamber_db = nil
    end

    # nil after a search the FAISS service answered, 'semantic_unavailable'
    # when it did not. Read by the fan-out right after #search returns.
    attr_reader :retrieval_degradation

    # Find similar parliamentary documents using FAISS vector search
    def search(question_embedding, limit: 5, question: nil)
      # Reset first: one service instance can serve more than one ask.
      @retrieval_degradation = nil
      search_faiss(question_embedding, limit: limit, question: question)
    end

    # Build context from parliamentary documents
    def build_context(docs, question: nil, max_chars: 6000)
      parts = []
      parl_label = @language == 'fr' ? 'TRAVAUX PRÉPARATOIRES' : 'PARLEMENTAIRE VOORBEREIDING'

      docs.each_with_index do |doc, index|
        # DB stores 'chamber'/'senate' (verified against storage/chamber.sqlite3)
        parliament_name = case doc[:parliament]
                          when 'chamber' then 'Kamer van Volksvertegenwoordigers'
                          when 'senate' then 'Senaat'
                          when 'vlaams' then 'Vlaams Parlement'
                          when 'brussels' then 'Brussels Parlement'
                          when 'waals' then 'Waals Parlement'
                          else doc[:parliament]&.capitalize
                          end

        text = SourcePassageExcerpt.excerpt(doc[:content], question, max_chars: max_chars, summary: doc[:summary])
        link = source_url(doc)
        resolution_note = resolution_context_note(doc)
        metadata = source_metadata(doc).except(:language).map { |key, value| "#{key}: #{value}" }.join("\n")
        parts << "[Bron #{index + 1} - #{parl_label}]\nParlement: #{parliament_name}\nDossier: #{doc[:dossier]}/#{doc[:document_number]}\nTitel: #{doc[:title]}\nSOURCE METADATA (not literal text):\n#{metadata}\nSTATUS RULE: parliamentary preparation, not enacted legislation.#{"\n#{resolution_note}" if resolution_note}#{"\nLINK: #{link}" if link}\n\n#{text}"
      end

      parts.join("\n\n---\n\n")
    end

    # Format parliamentary sources for response
    def format_sources(docs)
      docs.map do |doc|
        parliament_abbr = case doc[:parliament]
                          when 'chamber' then 'Kamer'
                          when 'senate' then 'Senaat'
                          when 'vlaams' then 'Vlaams'
                          when 'brussels' then 'Brussels'
                          when 'waals' then 'Waals'
                          else doc[:parliament]&.capitalize
                          end

        {
          type: 'parliamentary',
          parliament: parliament_abbr,
          dossier: "#{doc[:dossier]}/#{doc[:document_number]}",
          title: doc[:title],
          url: source_url(doc),
          similarity: doc[:similarity]&.round(3)
        }.merge(source_metadata(doc))
      end
    end

    def source_metadata(doc)
      language = doc[:source_language].presence || doc[:language].presence
      language ||= { 1 => 'nl', 2 => 'fr', 3 => 'de', 4 => 'en' }[doc[:language_id].to_i]
      {
        source_kind: 'parliamentary', authority_kind: 'parliamentary_preparation',
        document_type: doc[:document_type], status: doc[:status],
        document_date: doc[:document_date], publication_date: doc[:publication_date],
        language: language&.upcase, source_language: language&.downcase,
        legislature: doc[:legislature], legislation_numac: doc[:legislation_numac],
        jurisdiction: { 'chamber' => 'BE', 'senate' => 'BE', 'vlaams' => 'vlaams',
                        'waals' => 'waals', 'brussels' => 'brussels' }[doc[:parliament]]
      }.compact
    end

    # Newly imported documents can have text but no official landing URL.
    # Give the model and the source card the same real, unique document page
    # rather than inviting a guessed slug based on a non-unique dossier number.
    def source_url(doc)
      return doc[:url] if doc[:url].present?

      document_id = doc[:document_id].to_s
      return nil unless document_id.match?(/\A[1-9]\d*\z/)

      Rails.application.routes.url_helpers.parliamentary_path(document_id)
    end

    # The stored title, unless it is a site page title (the search page's
    # heading, the firewall's "Request Rejected") or empty: then the dossier
    # reference, so neither the prompt nor the source card carries a page
    # title as the document's. Same list as the parliamentary pages.
    def display_title(title, dossier, document_number)
      return title unless ParliamentaryHelper.generic_parl_title?(title)

      ['Dossier', [dossier, document_number].compact_blank.join('/')].compact_blank.join(' ')
    end

    private

    # Lazy-initialize connection to parliamentary SQLite DB
    def chamber_db
      @chamber_db ||= begin
        # ENV override → THIS app's own storage (symlinked to the correct
        # per-environment volume by the deploy hook) → cross-env absolute paths
        # as a last resort. Probing the staging absolute path FIRST made
        # production serve STAGING's parliamentary data on the shared host,
        # since both files exist there.
        local_path = Rails.root.join('storage', 'chamber.sqlite3').to_s
        staging_path = '/var/www/wetwijzer-staging/current/storage/chamber.sqlite3'
        prod_path = '/var/www/wetwijzer/current/storage/chamber.sqlite3'
        db_path = ENV['CHAMBER_DB'] ||
                  [local_path, prod_path, staging_path].find { |p| File.size?(p).to_i.positive? } ||
                  local_path
        Rails.logger.info("[Parliamentary DB] Connecting to: #{db_path}")
        db = SQLite3::Database.new(db_path)
        tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
        Rails.logger.info("[Parliamentary DB] Tables found: #{tables.join(', ')}")
        db
      end
    end

    # Search parliamentary via FAISS service (port 8769)
    def search_faiss(question_embedding, limit: 5, question: nil)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30, open_timeout: 5) do |http|
        http.request(request)
      end

      # Both failure branches return the same [] as "nothing above the
      # threshold" a few lines down, so they say so here; the empty-result
      # return deliberately does not.
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Parliamentary FAISS] HTTP error: #{response.code}")
        @retrieval_degradation = 'semantic_unavailable'
        return []
      end

      result = JSON.parse(response.body)
      faiss_results = result['results'] || []
      return [] if faiss_results.empty?

      # Look up document details from SQLite
      db = chamber_db
      docs = []

      faiss_results.each do |fr|
        doc_id = fr['document_id'] || fr['id'] || fr['article_id']
        similarity = fr['similarity'] || fr['score']

        # Skip low-relevance results (prevents irrelevant French bills from polluting sources)
        next if similarity.to_f < SIMILARITY_THRESHOLD

        row = db.get_first_row(
          "SELECT parliament, dossier_number, document_number, title, content, url, #{metadata_select(db)} FROM documents WHERE id = ?",
          [doc_id]
        )
        next unless row

        doc = {
          document_id: doc_id,
          parliament: row[0],
          dossier: row[1],
          document_number: row[2],
          title: display_title(row[3], row[1], row[2]),
          content: row[4],
          url: row[5],
          similarity: similarity
        }.merge(METADATA_COLUMNS.zip(row[6, METADATA_COLUMNS.length]).to_h.symbolize_keys)
        doc.merge!(source_metadata(doc))
        doc[:url] = source_url(doc)
        next unless secondary_source_relevant?(doc, question)

        docs << doc
      end

      Rails.logger.info("[Parliamentary] #{faiss_results.size} FAISS results → #{docs.size} above threshold #{SIMILARITY_THRESHOLD}")
      # Repeated vector hits and duplicate imports must not repeat an identical
      # source in either context or cards. Preserve differing literal content,
      # editions, languages and official identities, even when a URL is shared.
      docs.uniq { |doc| doc.except(:document_id, :similarity) }
    rescue StandardError => e
      Rails.logger.warn("[Parliamentary FAISS] Error: #{e.class}")
      @retrieval_degradation = 'semantic_unavailable'
      []
    end

    def metadata_select(db)
      @document_columns ||= db.execute('PRAGMA table_info(documents)').map { |row| row[1] }
      METADATA_COLUMNS.map { |name| @document_columns.include?(name) ? name : "NULL AS #{name}" }.join(', ')
    end

    # Parliamentary preparation is supporting material, not an alternative
    # authority. A vector neighbour about the repairability of a bicycle can
    # be useful for that policy debate, yet it is not evidence for a buyer's
    # warranty or for damage caused by a repair shop. Keep the narrow check at
    # this retrieval boundary so excluded rows never reach either LLM context
    # or response cards.
    #
    # The gate is intentionally topic-specific and fail-open for other
    # questions: generic lexical overlap is still useful for broad research,
    # and an explicit dossier/document reference always wins.
    def secondary_source_relevant?(doc, question)
      pinned = [true, 1, 'true', '1'].include?(doc[:pinned]) || [true, 1, 'true', '1'].include?(doc['pinned'])
      return true if pinned || question.blank? || explicit_reference?(doc, question)

      return false unless MunicipalSanctionsSourceScope.source_relevant?(doc, question: question)
      return false unless VehicleHeadlightGlareSourceScope.source_relevant?(doc, question)
      return false unless CommercialWebsiteIntent.secondary_source_relevant?(doc, question)
      return false unless PlatformModerationSourceScope.source_relevant?(doc, question)
      return false unless MarketplaceCivilClaimIntent.secondary_source_relevant?(doc, question)

      airport_policy_resolution = AirPassengerSourceScope.topic?(question) && airport_policy_resolution_title?(doc[:title])
      return false if airport_policy_resolution && !question.match?(AIRPORT_POLICY_QUERY_PATTERN)

      text = [doc[:title], doc[:content]].compact.join("\n")
      if question.match?(LegislationSearch::HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN) &&
         doc[:title].to_s.match?(FUTURE_HOUSING_SALE_SOURCE_PATTERN) && !question.match?(FUTURE_HOUSING_SALE_QUERY_PATTERN)
        return false
      end

      if question.match?(LegislationSearch::FOREIGN_DECEASED_SUCCESSION_TAX_PATTERN)
        survivor_payment = text.match?(LIBERATING_PAYMENT_SOURCE_PATTERN) && text.match?(SURVIVOR_PAYMENT_SUBJECT_PATTERN)
        estate_procedure = estate_access_procedure_source?(text)
        requested_estate_part = estate_procedure &&
                                (estate_access_procedure_question?(question) ||
                                 (text.match?(JurisprudenceSearch::INCOME_TAX_SUBJECT_PATTERN) &&
                                  question.match?(JurisprudenceSearch::INCOME_TAX_SUBJECT_PATTERN)))
        if estate_procedure && !requested_estate_part && !inheritance_tax_scope_or_tariff_evidence?(text)
          # A populated omnibus can discuss estate certificates and heirs'
          # fiscal debts without saying anything about the tax connecting
          # factor or tariff. It is supporting evidence only for that actual
          # procedure (or an expressly requested income-tax part of the same
          # document), not for a bare "how much inheritance tax?" question.
          return false
        end

        unless requested_estate_part
          # Actual tax evidence only suppresses the certificate-family check;
          # it does not waive the established survivor, income-tax or disputed
          # receivable filters. Only a requested part of the procedure omnibus
          # earns the narrow exception above.
          if survivor_payment
            return false unless question.match?(INHERITED_FUNDS_RELEASE_QUERY_PATTERN)
          else
            subject = ParliamentaryHelper.generic_parl_title?(doc[:title]) ? nil : doc[:title]
            return false unless JurisprudenceSearch.foreign_succession_source_relevant?(text, question, source_subject: subject)
          end
        end
      end
      return false if question.match?(LegislationSearch::OFFICE_COMMUTE_WORK_PATTERN) && JurisprudenceSearch.railway_staff_rules?(text)

      if consumer_repair_damage_question?(question)
        # A repairability-index proposal can naturally mention warranties,
        # spare parts and replacement while regulating consumer information,
        # rather than the contractual remedy for this individual dispute.
        # It remains available when the user actually asks about the index.
        return false if repairability_policy_title?(doc[:title]) && !repairability_policy_question?(question)

        return text.match?(consumer_remedy_evidence_pattern)
      end

      return true unless residential_tenancy_question?(question)

      text.match?(residential_tenancy_evidence_pattern)
    end

    def airport_policy_resolution_title?(title)
      text = title.to_s
      text.match?(AIRPORT_POLICY_RESOLUTION_TITLE_PATTERN) && text.match?(AIRPORT_TITLE_PATTERN) &&
        text.match?(AIRPORT_POLICY_OR_FUTURE_TITLE_PATTERN)
    end

    def estate_access_procedure_source?(text)
      return true if text.match?(ESTATE_CERTIFICATE_PATTERN)
      return false unless text.match?(ESTATE_ACTOR_PATTERN)

      text.match?(ESTATE_FUNDS_RELEASE_SOURCE_PATTERN) ||
        (text.match?(ESTATE_DEBT_PATTERN) && text.match?(NOTARY_PATTERN) && text.match?(TAX_NOTIFICATION_PATTERN))
    end

    def inheritance_tax_scope_or_tariff_evidence?(text)
      text = text.gsub(/\s+/, ' ')
      return true if text.match?(INHERITANCE_TAX_COMPOUND_TARIFF_PATTERN)

      subject = LegislationSearch::SUCCESSION_TAX_SOURCE_SUBJECT_PATTERN.source
      evidence = Regexp.union(INHERITANCE_TAX_CONNECTING_FACTOR_PATTERN, INHERITANCE_TAX_TARIFF_PATTERN).source
      # Require the tax subject and actual scope/tariff concept in the same
      # short sentence, not an inheritance footnote plus an income-tax rate
      # elsewhere in a long programme bill. PDF line wraps are normalised.
      text.match?(/(?:#{subject})[^.!?;]{0,180}(?:#{evidence})|(?:#{evidence})[^.!?;]{0,180}(?:#{subject})/iu)
    end

    def estate_access_procedure_question?(question)
      return true if question.match?(ESTATE_CERTIFICATE_PATTERN) || question.match?(INHERITED_FUNDS_RELEASE_QUERY_PATTERN)
      return true if question.match?(NOTARY_PATTERN) && question.match?(TAX_NOTIFICATION_PATTERN)

      actor = ESTATE_ACTOR_PATTERN.source
      debt = ESTATE_DEBT_PATTERN.source
      question.match?(/#{actor}[^\n.!?;]{0,90}#{debt}|#{debt}[^\n.!?;]{0,90}#{actor}/iu)
    end

    # The teletreinwerken dossier is useful policy context, including its
    # amendment/report. Adoption of a resolution does not make it an Act.
    # Infer only this document kind from the title; do not invent a dossier
    # status that the secondary-search hydration does not supply.
    def resolution_context_note(doc)
      return nil unless doc[:title].to_s.match?(/\b(?:resolutie|résolution|resolution|Entschließung)\b/iu)

      amendment = doc[:title].to_s.match?(/\b(?:amendement|amendment|Änderungsantrag)\b/iu)
      case @language
      when 'fr'
        kind = amendment ? 'amendement relatif à une résolution' : 'document parlementaire relatif à une résolution'
        "Nature: #{kind}. Force juridique: une résolution, même adoptée, n'est pas une loi et ne crée pas à elle seule un droit légal au salaire ou aux heures supplémentaires; vérifiez la législation applicable."
      when 'de'
        kind = amendment ? 'Änderungsantrag zu einer Entschließung' : 'parlamentarisches Dokument zu einer Entschließung'
        "Art: #{kind}. Rechtswirkung: Eine Entschließung ist auch nach ihrer Annahme kein Gesetz und begründet für sich allein keinen gesetzlichen Anspruch auf Lohn oder Überstundenvergütung; prüfen Sie die geltenden Rechtsvorschriften."
      when 'en'
        kind = amendment ? 'amendment concerning a resolution' : 'parliamentary document concerning a resolution'
        "Nature: #{kind}. Legal force: a resolution, even when adopted, is not an Act and does not by itself create a statutory right to pay or overtime; verify the applicable legislation."
      else
        kind = amendment ? 'amendement bij een resolutie' : 'parlementair stuk over een resolutie'
        "Aard: #{kind}. Rechtskracht: een resolutie, ook als die is aangenomen, is geen wet en schept op zichzelf geen wettelijk recht op loon of overuren; controleer de geldende wetgeving."
      end
    end
    public :resolution_context_note

    def explicit_reference?(doc, question)
      normalized_question = question.to_s.downcase
      dossier = doc[:dossier].presence
      document_number = doc[:document_number].presence
      if dossier && document_number
        dossier_reference = "#{dossier}/#{document_number}"
        return true if normalized_question.match?(/(?<!\d)#{Regexp.escape(dossier_reference)}(?!\d)/)
      end

      document_id = doc[:document_id].to_s
      document_id.present? && normalized_question.match?(/\b(?:document|doc|stuk|piece|pi[èe]ce|dokument|id)(?:\s+(?:id|n[°ºr.]?))?\s*#{Regexp.escape(document_id)}\b/i)
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

    def repairability_policy_title?(title)
      title.to_s.match?(/\b(?:herstelbaarheidsindex|indice\s+de\s+r[ée]parabilit[ée]|repairability\s+index|reparierbarkeitsindex)\b/i)
    end

    def repairability_policy_question?(question)
      question.to_s.match?(/\b(?:herstelbaar\w*|r[ée]parabilit[ée]\w*|repairability\w*|reparierbarkeit\w*)\b/i)
    end

    def consumer_remedy_evidence_pattern
      /\b(?:garantie|warrant\w*|conform(?:iteit|ity|ité)?|aansprak\w*|responsab\w*|liabilit\w*|schade|damage\w*|vergoeding\w*|compensat\w*|indemni[st]\w*|refund\w*|terugbetal\w*|rembours\w*|vervang\w*|replacement\w*|remplace\w*|ontbind\w*|résili\w*|prijsverminder\w*|reduction\s+du\s+prix)\b/i
    end

    def residential_tenancy_evidence_pattern
      /\b(?:woninghuur|huurcontract|huurovereenkomst|huurder|verhuurder|huurprijs|huurwaarborg|huur|lease|tenan\w*|landlord|rent\w*|rental|bail(?:leur)?|locataire|logement|habitation|residential|miet\w*|wohnung)\b/i
    end
  end
end
