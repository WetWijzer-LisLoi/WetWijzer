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

    def initialize(embedding_service:, language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @chamber_db = nil
    end

    # Find similar parliamentary documents using FAISS vector search
    def search(question_embedding, limit: 5)
      search_faiss(question_embedding, limit: limit)
    end

    # Build context from parliamentary documents
    def build_context(docs)
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

        text = doc[:content].to_s[0..6000]
        parts << "[Bron #{index + 1} - #{parl_label}]\nParlement: #{parliament_name}\nDossier: #{doc[:dossier]}/#{doc[:document_number]}\nTitel: #{doc[:title]}\n\n#{text}"
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
          url: doc[:url],
          similarity: doc[:similarity]&.round(3)
        }
      end
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
    def search_faiss(question_embedding, limit: 5)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30, open_timeout: 5) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Parliamentary FAISS] HTTP error: #{response.code}")
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
          'SELECT parliament, dossier_number, document_number, title, content, url FROM documents WHERE id = ?',
          [doc_id]
        )
        next unless row

        docs << {
          document_id: doc_id,
          parliament: row[0],
          dossier: row[1],
          document_number: row[2],
          title: row[3],
          content: row[4],
          url: row[5],
          similarity: similarity
        }
      end

      Rails.logger.info("[Parliamentary] #{faiss_results.size} FAISS results → #{docs.size} above threshold #{SIMILARITY_THRESHOLD}")
      docs
    rescue StandardError => e
      Rails.logger.warn("[Parliamentary FAISS] Error: #{e.class}")
      []
    end
  end
end
