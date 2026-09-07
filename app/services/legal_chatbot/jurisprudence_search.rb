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

    # Find similar jurisprudence cases using FAISS vector search
    def search(question_embedding, limit: 5)
      source_db = jurisprudence_source_db

      # FAISS service (fast path) - request more to filter by threshold
      top_cases = search_faiss(question_embedding, limit * 2)
      top_cases ||= [] # FAISS unavailable - return empty rather than degraded random results

      # Filter by similarity threshold and limit
      top_cases = top_cases.select { |_, sim| sim >= SIMILARITY_THRESHOLD }.first(limit)
      Rails.logger.info("Jurisprudence: #{top_cases.length} cases above threshold #{SIMILARITY_THRESHOLD}")

      # Fetch case details
      top_cases.map do |case_id, similarity|
        case_data = source_db.execute(
          'SELECT id, case_number, court, decision_date, summary, full_text, url, language_id FROM cases WHERE id = ?',
          [case_id]
        ).first

        next unless case_data

        {
          id: case_data[0],
          case_number: case_data[1],
          court: case_data[2],
          decision_date: case_data[3],
          summary: case_data[4],
          full_text: case_data[5],
          url: case_data[6],
          language_id: case_data[7],
          similarity: similarity
        }
      end.compact
    end

    # Build jurisprudence context from external DB results
    def build_context(cases)
      cases.map.with_index do |c, index|
        lang_label = c[:language_id] == 1 ? 'NL' : 'FR'
        source_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'

        # Use summary if available, otherwise truncate full_text
        text = c[:summary].present? ? c[:summary] : c[:full_text].to_s[0, 2000]

        <<~CONTEXT
          [Bron #{index + 1} - #{source_label} (#{lang_label})]
          ECLI: #{c[:case_number]}
          Hof: #{c[:court]}
          Datum: #{c[:decision_date]}

          #{text}
        CONTEXT
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
          type: 'RECHTSPRAAK',
          ecli: c[:case_number],
          court: court_name,
          date: c[:decision_date],
          url: wetwijzer_url || juportal_url,
          language: c[:language_id] == 1 ? 'NL' : 'FR',
          relevance: c[:similarity].round(2)
        }
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
      Rails.logger.debug("FAISS service unavailable: #{e.class}")
      nil
    end

    def jurisprudence_source_db
      @jurisprudence_source_db ||= SQLite3::Database.new(JURISPRUDENCE_SOURCE_DB)
    end
  end
end
