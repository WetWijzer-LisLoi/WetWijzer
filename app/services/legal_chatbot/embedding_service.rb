# frozen_string_literal: true

module LegalChatbot
  # Handles embedding generation and HyDE (Hypothetical Document Embedding).
  #
  # Extracted from LegalChatbotService to enable independent testing
  # and reuse across search services.
  class EmbeddingService
    include ModelsConfig

    # Question vectors are deliberately never written to Rails.cache. The
    # public privacy notice promises that neither question text nor a
    # deterministic question fingerprint is retained. A single service
    # instance may reuse only its immediately preceding vector in memory so
    # the orchestrator and reference-sheet pass do not make the same provider
    # request twice. Service instances are request-scoped.
    CACHE_NAMESPACE_VERSION = 3
    DEFAULT_API_VERSION = '2024-02-15-preview'

    def initialize(language: 'nl', endpoint: nil, deployment: nil, model: nil, dimensions: nil, api_version: nil,
                   mistral_api_key_env: 'MISTRAL_API_KEY')
      @language = language
      @endpoint = (endpoint || ENV.fetch('AZURE_OPENAI_ENDPOINT', nil)).to_s.chomp('/')
      @model = (model || ENV.fetch('AZURE_OPENAI_EMBEDDING_MODEL', nil)).presence || EMBEDDING_MODEL
      @deployment = (deployment || ENV.fetch('AZURE_OPENAI_EMBEDDING_DEPLOYMENT', nil)).presence || @model
      @dimensions = Integer(dimensions || EMBEDDING_DIMENSIONS)
      @api_version = (api_version || ENV['AZURE_OPENAI_EMBEDDING_API_VERSION'] ||
                      ENV.fetch('AZURE_OPENAI_API_VERSION', nil)).presence || DEFAULT_API_VERSION
      @mistral_api_key_env = mistral_api_key_env
    end

    # Public, secret-free identity used by cache namespaces and quality
    # provenance. Azure deployment names are routing configuration while the
    # model and dimensions describe vector compatibility; neither may be
    # omitted from a reproducible embedding generation.
    def identity
      @identity ||= begin
        configuration = {
          provider: 'azure_openai',
          endpoint_sha256: Digest::SHA256.hexdigest(@endpoint.downcase),
          deployment: @deployment,
          model: @model,
          dimensions: @dimensions,
          api_version: @api_version,
          cache_namespace_version: CACHE_NAMESPACE_VERSION
        }
        configuration.merge(
          config_digest: Digest::SHA256.hexdigest(JSON.generate(configuration))
        ).freeze
      end
    end

    def self.current_identity
      new.identity
    end

    # Generate an embedding with bounded, request-local memoization and retry
    # logic. `use_cache` is retained for call-site compatibility, but it never
    # reads or writes a persistent/shared cache.
    def generate(text, use_cache: true)
      input = text.to_s
      if use_cache && @memoized_input == input && valid_embedding?(@memoized_embedding)
        Rails.logger.debug("[Embedding] Request-local reuse (input_length=#{input.length})")
        # Do not hand callers the memoized mutable object. A search service
        # must never be able to corrupt the later reference-sheet pass.
        return @memoized_embedding.dup
      end

      max_retries = 3
      base_delay = 1

      embedding = nil
      max_retries.times do |attempt|
        embedding = Timeout.timeout(20) do
          generate_internal(input)
        end
        break
      rescue StandardError => e
        # Retry on TRANSIENT failures — not just 429. A single slow Azure
        # response (Timeout) or a network blip used to break the entire chatbot
        # request because only rate-limit errors were retried; a normal
        # embedding is ~0.3s, so a >20s call is an anomaly that a retry recovers.
        transient = e.is_a?(Timeout::Error) || e.is_a?(Net::OpenTimeout) ||
                    e.is_a?(Net::ReadTimeout) || e.is_a?(Errno::ECONNRESET) ||
                    e.is_a?(Errno::ECONNREFUSED) || e.is_a?(EOFError) ||
                    e.is_a?(SocketError) || e.message.include?('429')
        raise e unless transient && attempt < max_retries - 1

        delay = (base_delay * (2**attempt)) + rand(0.3..1.0)
        Rails.logger.warn("Azure embedding transient error (#{e.class}), retry #{attempt + 1}/#{max_retries} after #{delay.round(1)}s")
        sleep(delay)
      end

      unless valid_embedding?(embedding)
        actual_dimensions = embedding.is_a?(Array) ? embedding.length : nil
        raise "Embedding response is incompatible (expected #{@dimensions} dimensions, got #{actual_dimensions || embedding.class})"
      end

      # Keep at most one raw input/vector pair in this request-scoped object.
      # HyDE passes `use_cache: false`, so its combined prompt is never kept
      # and does not evict the original question needed by the later pass.
      if use_cache
        @memoized_input = input.dup.freeze
        @memoized_embedding = embedding.dup.freeze
      end

      embedding.dup
    rescue Timeout::Error
      Rails.logger.error("Embedding generation timeout (input_length=#{text.to_s.length})")
      raise 'Embedding generation timeout'
    end

    # Generate HyDE embedding: create a hypothetical legal article that would
    # answer the question, then embed that - bridges colloquial → legal text gap
    def generate_hyde(question)
      hyde_prompt = if @language == 'fr'
                      "Tu es un expert en droit belge. Rédige un court extrait d'article de loi belge (3 phrases) qui répondrait à cette question. N'inclus PAS la réponse elle-même, seulement le texte juridique pertinent.\n\nQuestion: #{question}\n\nExtrait d'article:"
                    else
                      "Je bent een expert in Belgisch recht. Schrijf een kort fragment uit een Belgisch wetsartikel (3 zinnen) dat deze vraag zou beantwoorden. Geef NIET het antwoord zelf, alleen de relevante juridische tekst.\n\nVraag: #{question}\n\nArtikelFragment:"
                    end

      # HyDE is a distinct, billable provider call. Route it through LlmClient
      # so it receives its own reservation/reconciliation without being folded
      # into (or double-counting) the later final-answer reservation.
      # GPT-5 Mini is a reasoning model: even at low effort it repeatedly
      # consumed the entire 500-token HyDE envelope as hidden reasoning and
      # returned no text. Mistral Small's non-reasoning mode produces the
      # requested three-sentence search variant directly, faster and cheaper,
      # through the dedicated EU endpoint.
      model = 'mistral-small'
      hyde_text = LlmClient.new(
        model_override: model,
        language: @language,
        reasoning_effort: 'low',
        concise: true,
        mistral_api_key_env: @mistral_api_key_env
      ).call_llm(
        [{ role: 'user', content: hyde_prompt }],
        max_tokens: 500
      )
      if hyde_text.blank?
        Rails.logger.warn('[HyDE] Empty completion - falling back to direct embedding')
        return nil
      end

      # Combine original question with hypothetical document for richer embedding
      combined = "#{question}\n\n#{hyde_text}"
      generate(combined, use_cache: false)
    rescue ModelsConfig::BudgetLimitExceeded
      # Budget accounting must fail closed; silently falling back would allow
      # the final-answer provider call after an authoritative ceiling rejection.
      raise
    rescue StandardError => e
      Rails.logger.warn("[HyDE] Failed: #{e.class} - falling back to direct embedding")
      nil
    end

    # Calculate cosine similarity between two vectors
    def cosine_similarity(vec1, vec2)
      return 0.0 if vec1.empty? || vec2.empty? || vec1.length != vec2.length

      dot_product = vec1.zip(vec2).sum { |a, b| a * b }
      magnitude1 = Math.sqrt(vec1.sum { |a| a**2 })
      magnitude2 = Math.sqrt(vec2.sum { |a| a**2 })

      return 0.0 if magnitude1.zero? || magnitude2.zero?

      dot_product / (magnitude1 * magnitude2)
    end

    private

    def valid_embedding?(value)
      value.is_a?(Array) && value.length == @dimensions && value.all? do |component|
        component.is_a?(Numeric) && (!component.respond_to?(:finite?) || component.finite?)
      end
    end

    def generate_internal(text)
      api_key = ENV.fetch('AZURE_OPENAI_KEY', nil)
      reservation = LegalChatbotService.reserve_auxiliary_provider_budget!(
        provider: :openai,
        operation: :question_embedding,
        reserved_units: LegalChatbotService.embedding_budget_reservation_units(text)
      )
      provider_request_started = false

      uri = URI("#{@endpoint}/openai/deployments/#{@deployment}/embeddings?api-version=#{@api_version}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      # Kept below the caller's Timeout.timeout(20): Net::HTTP's own socket
      # timeout raises Net::ReadTimeout reliably even from the streaming
      # (non-main) thread, where Timeout.timeout's async raise can be delayed
      # while blocked in the native socket read.
      http.read_timeout = 15

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['api-key'] = api_key
      request.body = { input: text, dimensions: @dimensions }.to_json

      provider_request_started = true
      response = http.request(request)

      raise "Azure OpenAI error #{response.code}" unless response.code == '200'

      result = JSON.parse(response.body)
      usage = result['usage'] || {}
      input_tokens = usage['prompt_tokens'] || usage['total_tokens']
      actual_units = if input_tokens.nil?
                       nil
                     else
                       LegalChatbotService.embedding_token_cost_units(input_tokens)
                     end
      LegalChatbotService.reconcile_auxiliary_provider_budget!(reservation, actual_units: actual_units)
      result.dig('data', 0, 'embedding')
    rescue StandardError
      LegalChatbotService.release_model_budget!(reservation) if reservation && !provider_request_started
      raise
    end
  end
end
