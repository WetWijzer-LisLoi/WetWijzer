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
    # Family benefits, in every language the chatbot takes. Asked for the
    # German-speaking Community, they are refused before retrieval
    # (.unsupported_corpus_question?).
    UNSUPPORTED_CORPUS_SUBJECT_PATTERN = /\b(?:groeipakket|kinderbijslag|allocations?\s+familiales|kindergeld|child\s+benefit|family\s+allowance)\b/i
    GERMAN_COMMUNITY = 'german_community'

    # A regulation solely for the social-housing regime is not evidence for a
    # question which expressly says that the landlord is private. The patterns
    # are deliberately narrow: a generic housing source may still be useful,
    # and questions that themselves mention social housing remain mixed-topic
    # questions rather than having one side silently removed.
    SOCIAL_HOUSING_SOURCE_PATTERN = /\b(?:sociale?\s+(?:huur\w*|woning\w*|huurstelsel|huisvesting)|sociaal\s+huurstelsel|social\s+housing|social\s+rent(?:al)?|logement\s+social|bail\s+social|soziale[rs]?\s+(?:wohn|miet)|sozialwohn)\b/i
    SOCIAL_HOUSING_QUESTION_PATTERN = /\b(?:sociale?\s+(?:huur\w*|woning\w*|huisvesting)|social\s+housing|social\s+rent(?:al)?|public\s+housing|logement\s+social|bail\s+social|soziale[rs]?\s+(?:wohnung|miete)|sozialwohn)\b/i
    EXPLICIT_PRIVATE_TENANCY_PATTERN = /\b(?:private\s+(?:landlord|verhuurder|huisbaas|bailleur|vermieter)|(?:verhuurder|huisbaas|bailleur|vermieter)\s+(?:is|est|is\s+een)\s+priv[ée]e?|priv[ée]e?\s+(?:eigenaar|propri[ée]taire))\b/i

    # The regions and the Community a question names, as the guards read the
    # question text: REGION_SOURCES keys in their order, then
    # GERMAN_COMMUNITY. The German question translation keeps the reader's
    # question when its French names others
    # (GermanQuestionTranslation#check_failure).
    def self.named_regions(question)
      text = question.to_s
      named = REGION_SOURCES.select { |source| text.match?(REGION_PATTERNS.fetch(source)) }
      named << GERMAN_COMMUNITY if text.match?(UNSUPPORTED_GERMAN_COMMUNITY_PATTERN)
      named
    end

    # Family benefits in the German-speaking Community. The regional corpus
    # has no source of that Community, so the answer path refuses such a
    # question before any retrieval (SearchFanOut#unsupported_regional_corpus_question?).
    def self.unsupported_corpus_question?(question)
      text = question.to_s
      text.match?(UNSUPPORTED_GERMAN_COMMUNITY_PATTERN) && text.match?(UNSUPPORTED_CORPUS_SUBJECT_PATTERN)
    end

    # Regional leases that the residential patterns do not name: agricultural
    # (regionalised in 2014, its own decrees in Flanders and Wallonia since
    # 2019), student and social housing. An ordinary commercial lease is not
    # one: the 1951 Handelshuurwet still applies unchanged in all three
    # regions, and only the short-term commercial lease
    # (SHORT_COMMERCIAL_SUBJECT_PATTERN) has regional rules.
    REGIONAL_LEASE_SUBJECT_PATTERN = /\b(?:pacht\w*|bail\s+à\s+ferme|fermage|landpacht|studentenhuur\w*|studentenkamer\w*|kot(?:en)?|bail\s+étudiant|logement\s+étudiant|student\s+(?:room|housing|lease)|sociale?\s+(?:huur)?woning\w*|sociale\s+huur\w*|sociaal\s+(?:wonen|huren)|logements?\s+sociaux|logement\s+social|social\s+housing|sozialwohnung\w*)\b/i
    # An acronym or an agency's name is not a legal subject (Codex review,
    # 2026-10-17): "EPC" is also the European Patent Convention and an
    # engineering contract, and an agency can be the employer. The building's
    # energy certificate needs a property or energy cue, the agencies their
    # jobseeker services.
    ENERGY_CERTIFICATE_PATTERN = /\b(?:energieprestatie\w*|energieprestatiecertificaat|certificat\s+(?:de\s+)?peb|performance\s+énergétique|energy\s+performance\s+certificate|energieausweis\w*)\b/i
    ENERGY_CERTIFICATE_ACRONYM_PATTERN = /\b(?:epc|peb)\b/i
    ENERGY_PROPERTY_CUE_PATTERN = /\b(?:woning\w*|huis|appartement\w*|gebouw\w*|verko\w*|verkocht|verhuur\w*|huur\w*|koper\w*|energie\w*|renovatie\w*|logement\w*|maison\w*|bâtiment\w*|vente|vendre|vendu|location|louer|énergie\w*|house|home|apartment\w*|building\w*|sale|sell\w*|let|rent\w*|energy|wohnung\w*|haus|gebäude\w*|verkauf\w*|vermiet\w*|energie\w*)\b/i
    ENERGY_CERTIFICATE_OTHER_PATTERN = /\b(?:octrooi\w*|patent\w*|brevet\w*|engineering|procurement|aanbested\w*|marché\s+public|construction\s+contract|epc[-\s](?:contract\w*|aannem\w*|contrat\w*))\b/i
    REGIONAL_AGENCY_PATTERN = /\b(?:vdab|forem|le\s+forem|actiris)\b/i
    REGIONAL_AGENCY_SERVICE_PATTERN = /\b(?:inschrij\w*|ingeschreven|werkzoekend\w*|werkloos\w*|opleiding\w*|begeleiding\w*|vacature\w*|sollicit\w*|beschikbaar\w*|demandeurs?\s+d['’]emploi|inscri\w*|formation\w*|accompagnement\w*|offre\s+d['’]emploi|jobseek\w*|job\s+seek\w*|register\w*|training\w*|vacanc\w*|arbeitsuchend\w*|arbeitslos\w*|anmeld\w*|weiterbildung\w*)\b/i
    REGIONAL_AGENCY_EMPLOYER_PATTERN = /\b(?:ontsla\w*|ontslag\w*|mijn\s+werkgever|als\s+werkgever|arbeidsovereenkomst\w*|licenci\w*|employeur|my\s+employer|dismiss\w*|fired|kündig\w*|arbeitgeber\w*)\b/i

    # Owner rule (2026-10-17): an answer on a regional subject always mentions
    # all three regions, a named region first. The subject decides, not a
    # region's name: "Ik woon in Brussel" does not make a federal question
    # regional. Shared by the regional lane's admission (SearchFanOut), its
    # selection and the all-regions prompt task, so they cannot disagree.
    def self.regional_subject_question?(question)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      return true if regional_lease_question?(text)

      [
        LegislationSearch::REGIONAL_TAX_SUBJECT_PATTERN, LegislationSearch::REGIONAL_TAX_GIFT_CONTEXT_PATTERN,
        LegislationSearch::REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN, LegislationSearch::REGIONAL_FAMILY_BENEFIT_PATTERN,
        LegislationSearch::SHORT_COMMERCIAL_SUBJECT_PATTERN, LegislationSearch::REGIONAL_PLANNING_SUBJECT_PATTERN
      ].any? { |pattern| text.match?(pattern) } || energy_certificate_question?(text) || regional_agency_service_question?(text)
    end

    # Any lease of a dwelling, a student, social or agricultural lease; not a
    # rented car, machine or parking space (federal civil law) nor an ordinary
    # commercial lease (the Handelshuurwet, unchanged in all three regions).
    def self.regional_lease_question?(text)
      topic = LegislationSearch.rent_increase_question?(text) || LegislationSearch.rental_deposit_question?(text) ||
              LegislationSearch.rental_termination_question?(text)
      lease = topic || text.match?(LegislationSearch::REGIONAL_HOUSING_SUBJECT_PATTERN) ||
              text.match?(REGIONAL_LEASE_SUBJECT_PATTERN)
      return false unless lease && !%i[other_object commercial].include?(LegislationSearch.rental_regime(text))

      # "Ik huur een appartement. Mijn werkgever zegt mijn arbeidsovereenkomst
      # op." asks about the dismissal: a tenancy mentioned beside an
      # employment subject is only a fact unless the lease itself is asked about.
      topic || !text.match?(LegislationSearch::EMPLOYMENT_SUBJECT_PATTERN)
    end

    def self.energy_certificate_question?(text)
      return false if text.match?(ENERGY_CERTIFICATE_OTHER_PATTERN)

      text.match?(ENERGY_CERTIFICATE_PATTERN) ||
        (text.match?(ENERGY_CERTIFICATE_ACRONYM_PATTERN) && text.match?(ENERGY_PROPERTY_CUE_PATTERN))
    end

    def self.regional_agency_service_question?(text)
      text.match?(REGIONAL_AGENCY_PATTERN) && text.match?(REGIONAL_AGENCY_SERVICE_PATTERN) &&
        !text.match?(REGIONAL_AGENCY_EMPLOYER_PATTERN)
    end

    # Partial coverage is an exception for housing, not permission for an
    # incidental tenancy fact to relax another subject's complete-region gate.
    # Share this eligibility check with the prompt so both layers make the
    # same decision; an ordinary tenancy/purchase-finance question still fits.
    def self.partial_housing_coverage_question?(question)
      text = question.to_s
      return false unless text.match?(LegislationSearch::REGIONAL_HOUSING_SUBJECT_PATTERN)

      strict_subjects = [
        LegislationSearch::REGIONAL_FAMILY_BENEFIT_PATTERN,
        LegislationSearch::REGIONAL_TAX_SUBJECT_PATTERN,
        LegislationSearch::REGIONAL_TAX_GIFT_CONTEXT_PATTERN,
        LegislationSearch::REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN,
        LegislationSearch::REGIONAL_PLANNING_SUBJECT_PATTERN
      ]
      strict_text = text.gsub(/[[:space:]]+/, ' ')
      strict_subjects.none? { |pattern| strict_text.match?(pattern) }
    end

    def initialize(embedding_service:, language: 'nl', context_numacs: [])
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      # Regional rows are normally selected semantically, but a controller may
      # pass the law currently being viewed. Keep that deliberate selection
      # above the narrow private/social distinction below.
      @context_numacs = Array(context_numacs).map(&:to_s)
    end

    # nil after a search the FAISS service answered, 'semantic_unavailable'
    # when it did not. Read by the fan-out right after #search returns.
    attr_reader :retrieval_degradation

    # Search regional legislation via FAISS
    # Returns array of document hashes with source, title, similarity, metadata.
    def search(question_embedding, question: nil, limit: 5)
      # Reset first: one service instance can serve more than one ask.
      @retrieval_degradation = nil
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

      # Both failure branches return the same [] as "no regional hit", so they
      # say so here; the empty-result return below deliberately does not.
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Regional FAISS] HTTP error: #{response.code}")
        @retrieval_degradation = 'semantic_unavailable'
        return []
      end

      result = JSON.parse(response.body)
      faiss_results = result['results'] || []
      return [] if faiss_results.empty?

      # Convert to standard format, filtering by similarity threshold.
      # The faiss server merges the regional_meta.json sidecar into each
      # result (source/title/article_number at TOP level; there is no nested
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

      # This source-level gate runs before stratification and before any
      # context/source-card formatting. It therefore removes irrelevant social
      # housing material from the evidence pool itself rather than merely
      # hiding its card after the answer has already seen it.
      docs = docs.select { |doc| contextually_relevant_to_question?(doc, question) }
      scoped_docs = scope_to_question_region(docs, question, limit: limit)
      Rails.logger.info(
        "[Regional] #{faiss_results.size} FAISS results → #{docs.size} hydrated → " \
        "#{scoped_docs.size} region-scoped"
      )
      scoped_docs
    rescue StandardError => e
      Rails.logger.warn("[Regional FAISS] Error: #{e.class}")
      @retrieval_degradation = 'semantic_unavailable'
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

      if requested_sources.any? && self.class.regional_subject_question?(question)
        # Owner rule (2026-10-17): always mention all regions. The named
        # regions lead; the others follow instead of being dropped.
        named_first = docs.each_with_index.sort_by do |doc, index|
          [requested_sources.include?(canonical_source(doc[:source])) ? 0 : 1, index]
        end.map(&:first)
        return stratify_sources(named_first, requested_sources + (REGION_SOURCES - requested_sources), limit: limit)
      end

      if requested_sources.any?
        matching = docs.select { |doc| requested_sources.include?(canonical_source(doc[:source])) }
        return stratify_sources(matching, requested_sources, limit: limit) if requested_sources.many?

        return matching.first(limit)
      end

      by_source = docs.group_by { |doc| canonical_source(doc[:source]) }
      if self.class.partial_housing_coverage_question?(question)
        # Residential tenancy is regional, but an unqualified question should
        # still receive every available, explicitly labelled regime.  Do not
        # turn a partial corpus into a national answer: the prompt names the
        # absent regions, while the context/source cards retain each source's
        # jurisdiction.  Other regional subjects keep the complete-set gate
        # below because their existing guards depend on full coverage.
        known_regions = docs.select { |doc| REGION_SOURCES.include?(canonical_source(doc[:source])) }
        return stratify_sources(known_regions, REGION_SOURCES, limit: limit)
      end

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

    def contextually_relevant_to_question?(document, question)
      question = question.to_s
      return true if question.blank?
      return true unless question.match?(EXPLICIT_PRIVATE_TENANCY_PATTERN)
      return true if question.match?(SOCIAL_HOUSING_QUESTION_PATTERN)
      return true if explicitly_selected_document?(document, question)

      source_text = [document[:title], document['title'], document.dig(:metadata, 'title'), document.dig('metadata', 'title')]
                    .compact.join(' ')
      !source_text.match?(SOCIAL_HOUSING_SOURCE_PATTERN)
    end

    def explicitly_selected_document?(document, question)
      numac = document[:numac] || document['numac'] || document.dig(:metadata, 'numac') || document.dig('metadata', 'numac')
      return true if numac.present? && (question.downcase.include?(numac.to_s.downcase) || @context_numacs.include?(numac.to_s))

      document[:pinned] == true || document['pinned'] == true ||
        document.dig(:metadata, 'pinned') == true || document.dig('metadata', 'pinned') == true
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
