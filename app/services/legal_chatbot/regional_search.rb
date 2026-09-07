# frozen_string_literal: true

module LegalChatbot
  # Searches regional legislation from the three Belgian regions:
  # - Vlaamse Codex (Flanders)
  # - Wallex (Wallonia)
  # - Brussels legislation
  #
  # Uses a dedicated FAISS index for regional legislation embeddings (port 8770).
  # No SQLite lookup needed - FAISS returns results with metadata directly.
  class RegionalSearch
    include TextProcessing

    FAISS_URL = ENV.fetch('FAISS_REGIONAL_URL', 'http://localhost:8770')

    # Minimum similarity for regional legislation to be relevant
    SIMILARITY_THRESHOLD = 0.35

    # The regional index is shared by three independent sources.  Region names
    # are recognised in every language supported by the chatbot so an explicit
    # request can never leak evidence from a different regional regime.
    REGION_SOURCES = %w[vlaamse_codex wallex brussels].freeze
    REGION_PATTERNS = {
      'vlaamse_codex' => /(?<![[:alnum:]])(?:vlaanderen|vlaams(?:e)?|flandre|flamand(?:e)?s?|flandern|fl[aä]misch(?:e[rsnm]?)?|flanders|flemish)(?![[:alnum:]])/iu,
      'wallex' => /(?<![[:alnum:]])(?:walloni[eë]|waals(?:e)?|wallonie|wallon(?:ne)?s?|wallonien|wallonisch(?:e[rsnm]?)?|wallonia|walloon)(?![[:alnum:]])/iu,
      'brussels' => /(?<![[:alnum:]])(?:brussel(?:s|se)?|bruxelles|bruxellois(?:e|es)?|brüssel|brüsseler|brussels)(?![[:alnum:]])/iu
    }.freeze
    UNSUPPORTED_GERMAN_COMMUNITY_PATTERN = /(?<![[:alnum:]])(?:deutschsprachige(?:n|r|s)?\s+gemeinschaft|ostbelgien|communaut[eé]\s+germanophone|duitstalige\s+gemeenschap|german-speaking\s+community)(?![[:alnum:]])/iu

    def initialize(embedding_service:, language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
    end

    # Search regional legislation via FAISS
    # Returns array of document hashes with source, title, similarity, metadata.
    def search(question_embedding, question: nil, limit: 5)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      # Filtering a top-three response after the fact frequently retained only
      # one arbitrary region.  Over-fetch enough candidates to find one sound
      # hit per source before applying the caller's result limit.
      # The rebuilt index contains both languages and all three regions.
      # Over-fetch enough that post-search language filtering and three-way
      # stratification do not reduce a valid generic query to one regime.
      retrieval_limit = (limit * 40).clamp(60, 200)
      request.body = { embedding: question_embedding, limit: retrieval_limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30, open_timeout: 5) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Regional FAISS] HTTP error: #{response.code}")
        return []
      end

      result = JSON.parse(response.body)
      faiss_results = result['results'] || []
      return [] if faiss_results.empty?

      # Convert to standard format, filtering by similarity threshold.
      # The faiss server merges the regional_meta.json sidecar into each
      # result (source/title/article_number at TOP level — there is no nested
      # 'metadata' key). Similarity is cosine (higher=better) since the
      # metric-aware server conversion of 2026-07-13.
      docs = faiss_results.filter_map do |fr|
        next if fr['similarity'].to_f < SIMILARITY_THRESHOLD
        next if fr['title'].blank? # no sidecar entry -> useless blank source
        # The rebuilt regional index is bilingual. Do not let a Dutch/French
        # query quote the other language merely because multilingual vectors
        # happen to rank it slightly higher. Legacy sidecars have no language
        # marker and remain subject to the evidence/url fail-closed checks.
        next unless result_language_matches?(fr)

        metadata = fr['metadata'] || fr.slice('article_number', 'article_id', 'chunk_index', 'numac', 'language_id', 'url', 'text', 'article_text', 'content')
        text = fr['text'].presence || fr['article_text'].presence || fr['content'].presence ||
               metadata['text'].presence || metadata['article_text'].presence || metadata['content'].presence
        url = fr['url'].presence || metadata['url'].presence

        # A title/article number is not evidence the model may quote. Until
        # the regional index is hydrated with the actual provision and a
        # canonical link, omit the hit instead of inviting fabricated text.
        next if text.blank? || url.blank?

        {
          source: fr['source'],
          title: fr['title'],
          text: text,
          url: url,
          numac: fr['numac'].presence || metadata['numac'].presence,
          similarity: fr['similarity'],
          metadata: metadata
        }
      end

      scoped_docs = scope_to_question_region(docs, question, limit: limit)
      Rails.logger.info(
        "[Regional] #{faiss_results.size} FAISS results → #{docs.size} hydrated → " \
        "#{scoped_docs.size} region-scoped"
      )
      scoped_docs
    rescue StandardError => e
      Rails.logger.warn("[Regional FAISS] Error: #{e.class}")
      []
    end

    private

    def result_language_matches?(result)
      result_language = result['language_id'] || result.dig('metadata', 'language_id')
      result_language.blank? || result_language.to_i == @language_id
    end

    # Explicit region names are authoritative.  If the user did not name a
    # region, returning the semantic top hit would silently choose a regime for
    # them.  Require one hydrated hit from each region and stratify the first
    # three results instead.  If the index cannot provide that coverage, no
    # regional evidence is safer than arbitrary one-region evidence.
    def scope_to_question_region(docs, question, limit:)
      # The current regional corpus has no German-speaking Community source.
      # Supplying Flemish/Walloon/Brussels neighbours would state the wrong
      # family-benefit regime with apparent legal support.
      return [] if question.to_s.match?(UNSUPPORTED_GERMAN_COMMUNITY_PATTERN)

      requested_sources = REGION_SOURCES.select do |source|
        question.to_s.match?(REGION_PATTERNS.fetch(source))
      end

      if requested_sources.any?
        matching = docs.select { |doc| requested_sources.include?(canonical_source(doc[:source])) }
        return stratify_sources(matching, requested_sources, limit: limit) if requested_sources.many?

        return matching.first(limit)
      end

      by_source = docs.group_by { |doc| canonical_source(doc[:source]) }
      return [] unless REGION_SOURCES.all? { |source| by_source[source].present? }

      stratify_sources(docs, REGION_SOURCES, limit: limit)
    end

    def stratify_sources(docs, sources, limit:)
      selected = sources.filter_map do |source|
        docs.find { |doc| canonical_source(doc[:source]) == source }
      end
      selected.sort_by! { |doc| docs.index(doc) }

      selected.concat(docs.reject { |doc| selected.include?(doc) }.first(limit - selected.size)) if selected.size < limit
      selected.first(limit)
    end

    def canonical_source(source)
      value = source.to_s.downcase
      return 'vlaamse_codex' if value.include?('vlaam') || value.include?('fland')
      return 'wallex' if value.include?('wallex') || value.include?('wallon')
      return 'brussels' if value.include?('bruss') || value.include?('brux')

      value
    end

    public

    # Build context from regional legislation results
    def build_context(docs)
      return '' if docs.empty?

      parts = []
      label = @language == 'fr' ? 'LÉGISLATION RÉGIONALE' : 'REGIONALE WETGEVING'

      docs.each_with_index do |doc, index|
        source_name = case doc[:source]
                      when 'vlaamse_codex' then 'Vlaamse Codex'
                      when 'wallex' then 'Wallex (Wallonië)'
                      when 'brussels' then 'Brusselse wetgeving'
                      else doc[:source]
                      end

        meta = doc[:metadata] || {}
        article_info = meta['article_number'] ? "Artikel #{meta['article_number']}" : ''
        text = doc[:text].to_s[0, 4000]
        link = doc[:url].presence

        parts << "[Bron #{index + 1} - #{label}]\nBron: #{source_name}\nTitel: #{doc[:title]}\n#{article_info}#{"\nLINK: #{link}" if link}\n#{text}"
      end

      parts.join("\n\n")
    end

    # Format regional sources for response
    def format_sources(docs)
      docs.map do |doc|
        source_abbr = case doc[:source]
                      when 'vlaamse_codex' then 'Vlaams'
                      when 'wallex' then 'Waals'
                      when 'brussels' then 'Brussels'
                      else doc[:source]
                      end

        {
          type: 'regional',
          region: source_abbr,
          title: doc[:title],
          numac: doc[:numac],
          # Without this key a regional hit contributes no citation pair, so
          # every "Art. N" citing a regional decree was structurally rejected
          # even with the article text in context (2026-08-04 withheld-answer
          # mining, 6 answers). The value is already fetched and populated on
          # every sidecar row; the guard reads it via
          # retrieved_source_article_number.
          article_number: doc.dig(:metadata, 'article_number').presence,
          url: doc[:url],
          excerpt: doc[:text].to_s.gsub(/\s+/, ' ').strip[0, 201],
          # UI renderers read :relevance for the percentage badge
          relevance: doc[:similarity]&.round(3),
          similarity: doc[:similarity]&.round(3)
        }
      end
    end
  end
end
