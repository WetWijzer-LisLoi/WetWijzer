# frozen_string_literal: true

module LegalChatbot
  # Handles all LLM API interactions across multiple providers:
  #   - Azure OpenAI (EU-scoped DataZoneStandard deployments)
  #   - Mistral AI (La Plateforme, EU-native France)
  #   - AWS Bedrock (eu-central-1 Frankfurt) - Anthropic Claude
  #
  # Routes based on :provider field in AVAILABLE_MODELS (ModelsConfig).
  # Manages token tracking, cost cap enforcement, and response post-processing.
  #
  # ═══════════════════════════════════════════════════════════════════
  # WHEN ADDING/REMOVING AI MODELS - checklist:
  # ═══════════════════════════════════════════════════════════════════
  #  1. models_config.rb  → AVAILABLE_MODELS         (model definition, provider, cost)
  #  2. models_config.rb  → INTELLIGENCE_LEVELS      (tier assignment + credit cost)
  #  3. models_config.rb  → MODEL_DAILY_CAPS         (per-model daily limit)
  #  4. models_config.rb  → REASONING_CAPABLE_MODELS (auto-derived - no manual edit needed)
  #  5. llm_client.rb     → AZURE_DEPLOYMENT_NAMES   (if Azure deployment name ≠ model ID)
  #  6. models_config.rb  → :api_model               (if Mistral: pin the API model ID)
  #  7. llm_client.rb     → bedrock_model_id case    (if Bedrock: map to Bedrock ARN)
  #  8. index.html.erb    → data-supports-reasoning   (auto-derived via REASONING_CAPABLE_MODELS)
  #  9. chatbot_controller.js → deep-think model names (line ~2326, display-name map)
  # 10. api/chatbot_controller.rb → DEEP_ANALYSIS_MODELS (auto-derived - no manual edit)
  # 11. api/partner_controller.rb → DEEP_MODELS (auto-derived - no manual edit)
  # 12. legal_chatbot_service.rb → reasoning checks (auto-derived - no manual edit)
  # ═══════════════════════════════════════════════════════════════════
  #
  # Extracted from LegalChatbotService to enable independent testing.
  class LlmClient
    include ModelsConfig
    include TextProcessing

    INCOMPLETE_RESPONSE_ERROR_CODE = 'provider_response_incomplete'

    class IncompleteProviderResponse < StandardError; end

    attr_reader :last_evidence_context, :last_provider_model, :generation_trace, :provider_call_count

    def self.incomplete_response_message(language)
      case language.to_s
      when 'fr'
        "Le fournisseur d'IA n'a pas renvoyé de réponse complète. Aucun crédit n'a été facturé. Veuillez réessayer."
      when 'de'
        'Der KI-Anbieter hat keine vollständige Antwort geliefert. Es wurden keine Credits berechnet. Bitte versuchen Sie es erneut.'
      when 'en'
        'The AI provider did not return a complete answer. No credits were charged. Please try again.'
      else
        'De AI-provider gaf geen volledig antwoord. Er zijn geen credits aangerekend. Probeer opnieuw.'
      end
    end

    def initialize(model_override: nil, language: 'nl', concise: false,
                   case_context: nil, reasoning_effort: nil, profile: 'general',
                   embedding_service: nil, mistral_api_key_env: 'MISTRAL_API_KEY')
      @model_override = model_override
      @language = language
      @concise = concise
      @case_context = case_context
      @reasoning_effort = reasoning_effort || 'low'
      @profile = profile
      # RAT-003. Lives on the client, which the orchestrator memoizes, so the
      # controller can read it after thread.join. Deliberately NOT a
      # thread-local and NOT attached to the result hash: HyDE builds its own
      # throwaway client before the answer call and would clobber a shared
      # slot, and the result hash is serialized verbatim to the browser.
      @generation_trace = GenerationTrace.new
      # Counts provider generations for ONE visible answer. Deliberately not
      # reset per call: a citation-guard retry regenerates the whole answer,
      # and a measured 78-second ask ran three times while analytics recorded
      # a single flat per-query cost. HyDE builds its own client, so its extra
      # call cannot inflate this.
      @provider_call_count = 0
      # The authenticated service path used to receive its own workspace key; it no longer does.
      # This keeps Mistral usage/caps separate while provider calls remain
      # centralised in WetWijzer.
      @mistral_api_key_env = mistral_api_key_env
      @prompt_builder = SystemPromptBuilder.new(language: language, concise: concise, case_context: case_context, profile: profile)
      @reference_sheets = ReferenceSheets.new(
        language: language,
        embedding_service: embedding_service
      )
    end

    # Query the LLM with context and question
    def query(question, context, source_type: :legislation, conversation_messages: [], corrective_feedback: nil)
      detected_lang = detect_prompt_language(question)

      # Build system prompt
      system_prompt = @prompt_builder.build(source_type, detected_lang: detected_lang, question: question)

      # Inject reference sheet corrections into context
      context = inject_reference_corrections(question, context)
      # Preserve the exact legal evidence block supplied to the model. It is
      # returned only through the controller's HMAC-only quality mode.
      @last_evidence_context = context.dup.freeze

      # Build language instruction
      lang_instruction = build_language_instruction(question, detected_lang)

      # Build message list
      sources_label = detected_lang == :fr ? 'Sources juridiques' : 'Sources'
      question_label = 'Question' # identical in NL/FR/EN/DE

      user_sections = ["#{sources_label}:\n#{context}", lang_instruction]
      # A guard-rejection retry carries the rejected references back to the
      # model. Placed before the question so the correction reads as part of
      # the task constraints, not as an answer suffix to be echoed.
      user_sections << corrective_feedback.to_s.strip if corrective_feedback.present?
      user_sections << "#{question_label}: #{question}"
      messages = [
        { role: 'system', content: system_prompt },
        *conversation_messages,
        { role: 'user', content: user_sections.join("\n\n").strip }
      ]

      answer = call_llm(messages, temperature: 0.1, max_tokens: 4096)
      if answer.to_s.strip.empty? || @provider_response_incomplete
        Rails.logger.error(
          "LLM returned an empty or truncated response " \
          "(model=#{@model_override || CHAT_MODEL}, language=#{@language})"
        )
        raise IncompleteProviderResponse, INCOMPLETE_RESPONSE_ERROR_CODE
      end

      # Log reference-sheet usage only for a complete answer that can enter the
      # visible-answer pipeline. Empty/truncated provider output is a
      # non-billable error, never a successful localized fallback.
      @reference_sheets.log_usage(question, answer)
      answer
    end

    # ─── Multi-provider router ───────────────────────────────────────────
    # Dispatches to the correct API based on :provider field in AVAILABLE_MODELS.
    # Providers: :openai (Azure), :mistral (La Plateforme), :bedrock (AWS Claude)
    def call_llm(messages, temperature: nil, max_tokens: 2000, provider_max_tokens: nil)
      model = @model_override || CHAT_MODEL
      model_config = AVAILABLE_MODELS[model]
      provider = model_config&.dig(:provider) || :openai
      # Puma reuses threads. Never reconcile this request against stale usage
      # left by an earlier provider call on the same worker.
      Thread.current[:last_chat_tokens] = nil
      # Same reasoning as the line above: a corrective retry re-enters this
      # method on the same client, so the trace must never describe the
      # previous request.
      @generation_trace.reset!
      @provider_call_count += 1
      @follow_up_request = messages.any? { |message| message[:role].to_s == 'assistant' }
      @provider_response_incomplete = false
      provider_max_tokens ||= provider_output_token_ceiling(model, max_tokens)
      reservation = nil
      unless Thread.current[:chatbot_benchmark_cap_bypass]
        reservation = LegalChatbotService.reserve_model_budget!(
          model,
          reasoning_effort: self.class.effective_reasoning_effort_for_model(model, @reasoning_effort),
          max_output_tokens: provider_max_tokens,
          messages: messages
        )
      end
      @provider_request_started = false

      answer = case provider
               when :mistral
                 call_mistral_api(messages, model, model_config, temperature: temperature, max_tokens: provider_max_tokens)
               when :bedrock
                 call_bedrock_api(messages, model, max_tokens: max_tokens, provider_max_tokens: provider_max_tokens)
               else # :openai (Azure)
                 azure_openai_completion(
                   messages,
                   model,
                   model_config,
                   temperature: temperature,
                   max_tokens: max_tokens,
                   provider_max_tokens: provider_max_tokens
                 )
               end

      LegalChatbotService.reconcile_model_budget!(reservation, Thread.current[:last_chat_tokens]) if reservation
      answer
    rescue StandardError
      LegalChatbotService.release_model_budget!(reservation) if reservation && !@provider_request_started
      raise
    ensure
      @provider_request_started = nil
    end

    # ─── Azure OpenAI (EU Data Zone) ─────────────────────────────────────
    # Keep this mapping explicit: the product-facing IDs are stable internal
    # identifiers, while the right-hand values are exact Azure deployment names.
    # Only the API URL uses the deployment name; billing and analytics retain
    # the internal model ID.
    AZURE_DEPLOYMENT_NAMES = {
      'gpt-5.6-luna' => 'gpt-5-6-luna',
      'gpt-5.6-terra' => 'gpt-5-6-terra',
      'gpt-5.6-sol' => 'gpt-5-6-sol'
    }.freeze

    def azure_openai_completion(messages, model, model_config, temperature: nil, max_tokens: 2000, provider_max_tokens: nil)
      endpoint_env = model_config&.dig(:endpoint_env) || 'AZURE_OPENAI_ENDPOINT'
      key_env = model_config&.dig(:key_env) || 'AZURE_OPENAI_KEY'
      endpoint = ENV[endpoint_env].to_s.chomp('/')
      api_key = ENV.fetch(key_env, nil)
      api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2025-04-01-preview')

      deployment_name = AZURE_DEPLOYMENT_NAMES[model] || model
      uri = URI("#{endpoint}/openai/deployments/#{deployment_name}/chat/completions?api-version=#{api_version}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      effort = self.class.effective_reasoning_effort_for_model(model, @reasoning_effort) || 'low'
      http_timeout = case effort
                     when 'high' then 165  # leave retrieval/serialization headroom under the 175s supervisor
                     when 'medium' then 90
                     else 60
                     end
      http.read_timeout = http_timeout
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['api-key'] = api_key

      # Uses reasoning_support_type from ModelsConfig (per-model reasoning config).
      # OpenAI models use :openai_effort -> reasoning_effort: low/medium/high
      reasoning_type = self.class.respond_to?(:reasoning_support_type) ?
        self.class.reasoning_support_type(model) :
        AVAILABLE_MODELS.dig(model, :reasoning_support)
      is_reasoning = reasoning_type == :openai_effort
      # Reasoning models split max_completion_tokens between thinking and output.
      # High effort burns most tokens on chain-of-thought, so we need a larger budget.
      effective_max = provider_max_tokens || provider_output_token_ceiling(model, max_tokens)
      body = { messages: messages, max_completion_tokens: effective_max }
      if is_reasoning
        body[:reasoning_effort] = effort
      else
        body[:temperature] = temperature || 0.3
      end
      request.body = body.to_json

      # Read from `body`, never from the arguments: this branch omits
      # temperature entirely for a reasoning model, and the ceiling here is
      # max_completion_tokens, not max_tokens.
      record_generation_request(
        provider: :openai,
        application_model: model,
        reasoning_mode: is_reasoning ? 'effort' : 'none',
        provider_reasoning_value: body[:reasoning_effort],
        temperature: body[:temperature],
        output_token_limit: body[:max_completion_tokens],
        reasoning_effort_used: effort
      )

      @provider_request_started = true
      transient_attempts = 0
      response = loop do
        candidate = http.request(request)
        # A 429 is known not to have executed the completion and is safe to
        # retry. A 5xx, read timeout, or reset can happen after the provider
        # accepted/billed the request, so retrying those risks duplicate spend.
        if candidate.code == '429' && transient_attempts < 2
          transient_attempts += 1
          retry_after = candidate['retry-after'].to_i
          sleep retry_after.positive? ? [retry_after, 10].min : transient_attempts
          next
        end
        break candidate
      rescue Net::OpenTimeout
        raise if transient_attempts >= 2
        transient_attempts += 1
        sleep transient_attempts
        next
      end
      unless response.code == '200'
        body_snippet = response.body.to_s.gsub(/\s+/, ' ')[0, 500]
        Rails.logger.error(
          "[LLM] Azure OpenAI chat error model=#{model} deployment=#{deployment_name} " \
          "status=#{response.code} body=#{body_snippet.inspect}"
        )
        raise "Azure OpenAI chat error #{response.code}"
      end

      result = JSON.parse(response.body)
      @last_provider_model = result['model'].presence || deployment_name
      # The trace gets the SAFE value: expected is the application model, so a
      # deployment-name fallback is rejected rather than persisted.
      record_generation_response(
        result['model'],
        expected: [model],
        reasoning_tokens: result.dig('usage', 'completion_tokens_details', 'reasoning_tokens')
      )

      # Track token usage
      usage = result['usage'] || {}
      track_token_usage(model, usage['prompt_tokens'], usage['completion_tokens'])

      # Diagnostic: detect reasoning token exhaustion or empty responses
      choice = result.dig('choices', 0) || {}
      finish_reason = choice['finish_reason']
      content = choice.dig('message', 'content')
      refusal = choice.dig('message', 'refusal')
      reasoning_tokens = usage.dig('completion_tokens_details', 'reasoning_tokens') || 0
      output_tokens = usage['completion_tokens'] || 0

      @provider_response_incomplete = content.to_s.strip.empty? || finish_reason == 'length'
      if @provider_response_incomplete
        Rails.logger.warn("[LLM] Empty/truncated response from #{model}: finish_reason=#{finish_reason} " \
                          "reasoning_tokens=#{reasoning_tokens} output_tokens=#{output_tokens} " \
                          "max_completion_tokens=#{effective_max} refusal=#{refusal.present?} " \
                          "effort=#{effort} content_nil=#{content.nil?} content_empty=#{content&.strip&.empty?}")
      end

      content
    end

    # ─── Mistral AI (La Plateforme EU regional endpoint) ─────────────────
    # OpenAI-compatible chat completions API.
    # Endpoint: https://api.eu.mistral.ai/v1/chat/completions
    # Deliberately no fallback to the global api.mistral.ai endpoint.
    # Auth: Bearer token (MISTRAL_API_KEY)
    def call_mistral_api(messages, model, model_config, temperature: nil, max_tokens: 4096)
      api_key = ENV.fetch(@mistral_api_key_env, nil)
      raise "Mistral API key not configured (#{@mistral_api_key_env})" if api_key.blank?

      uri = URI('https://api.eu.mistral.ai/v1/chat/completions')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 90
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{api_key}"

      # Internal product names map to immutable provider deployments in
      # ModelsConfig. A moving "-latest" alias would make two captures under
      # one application SHA incomparable.
      mistral_model_id = model_config&.dig(:api_model) || model

      body = {
        model: mistral_model_id,
        messages: messages.map { |m| { role: m[:role].to_s, content: m[:content].to_s } },
        max_tokens: max_tokens,
        temperature: temperature || 0.3
      }

      # Mistral Small exposes exactly two documented efforts: none and high.
      # Large 3 does not document adjustable reasoning, so it must receive no
      # reasoning_effort field at all.
      if self.class.reasoning_support_type(model) == :mistral_effort
        effort = self.class.effective_reasoning_effort_for_model(model, @reasoning_effort) || 'low'
        if effort == 'high' && (messages.length > 2 || messages.any? { |message| message[:role].to_s == 'assistant' })
          # Mistral high-reasoning follow-ups require replaying provider-private
          # ThinkChunk state. WetWijzer intentionally never stores or sends that
          # state, so force documented non-reasoning mode instead of submitting
          # an invalid or semantically incomplete high-reasoning continuation.
          Rails.logger.warn('[MISTRAL] High reasoning disabled for follow-up without preserved ThinkChunk state')
          effort = 'low'
        end
        body[:reasoning_effort] = effort == 'high' ? 'high' : 'none'
        body.delete(:temperature) if effort == 'high' # reasoning mode doesn't use temperature
      end

      request.body = body.to_json

      # body[:temperature] is DELETED above for high reasoning, so reading the
      # body is the only way to record the omission truthfully.
      record_generation_request(
        provider: :mistral,
        application_model: model,
        reasoning_mode: body.key?(:reasoning_effort) ? 'effort' : 'none',
        provider_reasoning_value: body[:reasoning_effort],
        temperature: body[:temperature],
        output_token_limit: body[:max_tokens],
        reasoning_effort_used: effort || self.class.effective_reasoning_effort_for_model(model, @reasoning_effort)
      )

      Rails.logger.info("[MISTRAL] Sending #{messages.length} messages to #{model}")

      @provider_request_started = true
      response = http.request(request)
      unless response.code == '200'
        Rails.logger.error("[MISTRAL] Error #{response.code}")
        raise "Mistral API error #{response.code}"
      end

      result = JSON.parse(response.body)
      @last_provider_model = result['model'].presence || mistral_model_id
      record_generation_response(result['model'], expected: [mistral_model_id, model])

      # Track token usage (OpenAI-compatible format)
      usage = result['usage'] || {}
      track_token_usage(model, usage['prompt_tokens'], usage['completion_tokens'])

      Rails.logger.info("[MISTRAL] Response: #{usage['prompt_tokens']} in / #{usage['completion_tokens']} out tokens")

      choice = result.dig('choices', 0) || {}
      answer = mistral_response_text(choice.dig('message', 'content'))
      finish_reason = choice['finish_reason'].to_s
      @provider_response_incomplete = answer.to_s.strip.empty? || %w[length model_length].include?(finish_reason)
      if @provider_response_incomplete
        Rails.logger.warn(
          "[MISTRAL] Empty/truncated response from #{model}: " \
          "finish_reason=#{finish_reason.presence || 'missing'}"
        )
      end
      answer
    end

    # ─── AWS Bedrock Claude (eu-central-1 Frankfurt) ─────────────────────
    # Uses Anthropic Messages API format via Bedrock's invoke-model endpoint.
    # Auth: AWS Signature V4 (BEDROCK_ACCESS_KEY + BEDROCK_SECRET_KEY)
    # Requests originate in eu-central-1 and use geography-prefixed EU profiles;
    # AWS may route them within the profile's documented EU geography.
    def call_bedrock_api(messages, model, max_tokens: 4096, provider_max_tokens: nil)
      access_key = ENV.fetch('BEDROCK_ACCESS_KEY', nil)
      secret_key = ENV.fetch('BEDROCK_SECRET_KEY', nil)
      region = ENV.fetch('BEDROCK_REGION', 'eu-central-1')

      raise 'AWS Bedrock credentials not configured (BEDROCK_ACCESS_KEY / BEDROCK_SECRET_KEY)' if access_key.blank? || secret_key.blank?

      # Map friendly model names to Bedrock EU inference profile IDs.
      # IMPORTANT: Newer Claude models require inference profile IDs (eu. prefix),
      # not raw model IDs. Raw IDs return 400 "on-demand throughput isn't supported".
      # Use EU profiles for GDPR compliance (data stays in EU regions).
      bedrock_model_id = case model
                         when 'claude-4.5-haiku' then 'eu.anthropic.claude-haiku-4-5-20251001-v1:0'
                         when 'claude-sonnet-4-6' then 'eu.anthropic.claude-sonnet-4-6'
                         when 'claude-opus-4-6' then 'eu.anthropic.claude-opus-4-6-v1'
                         else model
                         end

      host = "bedrock-runtime.#{region}.amazonaws.com"
      # Two paths needed for SigV4:
      # 1. Raw path for the HTTP request (Net::HTTP sends as-is)
      # 2. URI-encoded path for SigV4 canonical request (AWS normalizes to this)
      raw_path = "/model/#{bedrock_model_id}/invoke"
      canonical_path = "/model/#{bedrock_model_id.gsub(':', '%3A')}/invoke"
      uri = URI.parse("https://#{host}#{raw_path}")

      # Build Anthropic Messages API body
      system_content = messages.select { |m| m[:role] == 'system' }
                               .map { |m| m[:content] }
                               .join("\n\n")
      user_messages = messages.reject { |m| m[:role] == 'system' }
                              .map { |m| { role: m[:role].to_s, content: m[:content].to_s } }

      body = {
        anthropic_version: 'bedrock-2023-05-31',
        max_tokens: max_tokens,
        messages: user_messages
      }
      body[:system] = system_content if system_content.present?

      # Claude reasoning is model-specific. Haiku 4.5 supports fixed-budget
      # extended thinking. Sonnet 4.6 and Opus 4.6 support adaptive thinking
      # with output_config effort. Sending the wrong shape is rejected by
      # Bedrock, so dispatch from the capability declared in ModelsConfig.
      effort = self.class.effective_reasoning_effort_for_model(model, @reasoning_effort) || 'low'
      reasoning_type = self.class.reasoning_support_type(model)
      if reasoning_type == :bedrock_budgeted
        thinking_budget = case effort
                          when 'high' then 4096
                          when 'medium' then 2048
                          else 1024
                          end
        body[:thinking] = { type: 'enabled', budget_tokens: thinking_budget }
        # Bedrock requires budget_tokens < max_tokens. Preserve the requested
        # answer headroom by adding the thinking budget to the output ceiling.
        body[:max_tokens] = provider_max_tokens || (max_tokens + thinking_budget)
      elsif reasoning_type == :bedrock_adaptive
        claude_effort = case effort
                        when 'high' then 'high'
                        when 'medium' then 'medium'
                        else 'low'
                        end
        body[:thinking] = { type: 'adaptive' }
        body[:output_config] = { effort: claude_effort }
        # Increase max_tokens to accommodate thinking tokens + output
        body[:max_tokens] = provider_max_tokens || provider_output_token_ceiling(model, max_tokens)
      end

      # Bedrock carries the thinking budget inside body[:thinking] and expands
      # max_tokens to cover it, so both must be read back from the body.
      record_generation_request(
        provider: :bedrock,
        application_model: model,
        reasoning_mode: bedrock_reasoning_mode(reasoning_type),
        provider_reasoning_value: body.dig(:output_config, :effort) || body.dig(:thinking, :type),
        reasoning_token_budget: body.dig(:thinking, :budget_tokens),
        temperature: body[:temperature],
        output_token_limit: body[:max_tokens],
        reasoning_effort_used: effort
      )

      body_json = body.to_json

      # AWS Signature V4
      time = Time.now.utc
      datestamp = time.strftime('%Y%m%d')
      amzdate = time.strftime('%Y%m%dT%H%M%SZ')
      content_hash = Digest::SHA256.hexdigest(body_json)

      # Canonical request - use URI-encoded canonical_path for signature
      canonical_headers = "content-type:application/json\nhost:#{host}\nx-amz-content-sha256:#{content_hash}\nx-amz-date:#{amzdate}\n"
      signed_headers = 'content-type;host;x-amz-content-sha256;x-amz-date'
      canonical_request = "POST\n#{canonical_path}\n\n#{canonical_headers}\n#{signed_headers}\n#{content_hash}"

      # String to sign
      service = 'bedrock'
      credential_scope = "#{datestamp}/#{region}/#{service}/aws4_request"
      string_to_sign = "AWS4-HMAC-SHA256\n#{amzdate}\n#{credential_scope}\n#{Digest::SHA256.hexdigest(canonical_request)}"

      # Signing key
      k_date = OpenSSL::HMAC.digest('SHA256', "AWS4#{secret_key}", datestamp)
      k_region = OpenSSL::HMAC.digest('SHA256', k_date, region)
      k_service = OpenSSL::HMAC.digest('SHA256', k_region, service)
      k_signing = OpenSSL::HMAC.digest('SHA256', k_service, 'aws4_request')
      signature = OpenSSL::HMAC.hexdigest('SHA256', k_signing, string_to_sign)

      authorization = "AWS4-HMAC-SHA256 Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      # Scale timeout with reasoning effort - adaptive thinking takes longer
      http.read_timeout = case effort
                          when 'high' then 170
                          when 'medium' then 120
                          else 90
                          end
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-amz-date'] = amzdate
      request['x-amz-content-sha256'] = content_hash
      request['Authorization'] = authorization
      request.body = body_json

      Rails.logger.info("[BEDROCK] Sending #{user_messages.length} messages to #{bedrock_model_id} (#{region})")

      @provider_request_started = true
      response = http.request(request)
      unless response.code == '200'
        Rails.logger.error("[BEDROCK] Error #{response.code}")
        raise "Bedrock API error #{response.code}"
      end

      result = JSON.parse(response.body)
      @last_provider_model = bedrock_model_id
      record_generation_response(bedrock_model_id, expected: [bedrock_model_id, model],
                                                   reasoning_tokens: result.dig('usage', 'thinking_tokens'))

      # Track token usage (Anthropic format)
      usage = result['usage'] || {}
      track_token_usage(model, usage['input_tokens'], usage['output_tokens'])

      Rails.logger.info("[BEDROCK] Response: #{usage['input_tokens']} in / #{usage['output_tokens']} out tokens")

      content_blocks = result['content'] || []
      text_blocks = content_blocks.select { |b| b['type'] == 'text' }
      answer = text_blocks.map { |b| b['text'] }.join("\n")
      stop_reason = result['stop_reason'].to_s
      @provider_response_incomplete = answer.strip.empty? || stop_reason == 'max_tokens'
      if @provider_response_incomplete
        Rails.logger.warn(
          "[BEDROCK] Empty/truncated response from #{model}: " \
          "stop_reason=#{stop_reason.presence || 'missing'}"
        )
      end
      answer
    end

    private

    # Mistral reasoning responses use an array of typed chunks (thinking +
    # text), while non-reasoning responses use a plain string. Only user-visible
    # text belongs in the answer pipeline; provider thinking must never leak.
    def mistral_response_text(content)
      return content if content.is_a?(String)
      return nil unless content.is_a?(Array)

      content.filter_map do |chunk|
        next unless chunk.is_a?(Hash) && chunk['type'] == 'text'

        chunk['text'].to_s
      end.join
    end

    # Shared token usage tracking across all providers
    # RAT-003 recorders. Analytics must never be able to break answer delivery,
    # so both swallow their own errors and log a class only - never a message,
    # which on some adapters carries the offending row or payload.
    def record_generation_request(provider:, application_model:, reasoning_mode:,
                                  temperature:, output_token_limit:, reasoning_effort_used:,
                                  provider_reasoning_value: nil, reasoning_token_budget: nil)
      @generation_trace.record_request!(
        provider: provider,
        application_model: application_model,
        reasoning_effort_used: reasoning_effort_used,
        provider_reasoning_value: provider_reasoning_value,
        reasoning_mode: reasoning_mode,
        reasoning_token_budget: reasoning_token_budget,
        temperature: temperature,
        output_token_limit: output_token_limit,
        profile: @profile,
        concise_mode: @concise,
        follow_up: @follow_up_request,
        prompt_version: SystemPromptBuilder::PROMPT_VERSION,
        retrieval_version: LegalChatbot::Orchestrator::RETRIEVAL_VERSION
      )
    rescue StandardError => e
      Rails.logger.warn("[GenerationTrace] request capture skipped: #{e.class}")
    end

    def record_generation_response(provider_model, expected:, reasoning_tokens: nil)
      @generation_trace.record_response!(provider_model: provider_model,
                                         expected: expected,
                                         reasoning_tokens: reasoning_tokens)
    rescue StandardError => e
      Rails.logger.warn("[GenerationTrace] response capture skipped: #{e.class}")
    end

    def bedrock_reasoning_mode(reasoning_type)
      case reasoning_type
      when :bedrock_budgeted then 'fixed_budget'
      when :bedrock_adaptive then 'adaptive'
      else 'none'
      end
    end

    def track_token_usage(model, input_tokens, output_tokens)
      billing_complete = !input_tokens.nil? && !output_tokens.nil?
      input = Integer(input_tokens || 0)
      output = Integer(output_tokens || 0)
      billing_complete &&= input >= 0 && output >= 0
      Thread.current[:last_chat_tokens] = {
        input: input,
        output: output,
        model: model,
        billing_complete: billing_complete
      }
    rescue ArgumentError, TypeError
      Thread.current[:last_chat_tokens] = {
        input: 0,
        output: 0,
        model: model,
        billing_complete: false
      }
    end

    # Provider output ceilings must stay identical to request-body limits so
    # the pre-I/O spend reservation includes every billable reasoning token.
    def provider_output_token_ceiling(model, requested_max_tokens)
      requested = Integer(requested_max_tokens)
      effort = self.class.effective_reasoning_effort_for_model(model, @reasoning_effort) || 'low'

      case self.class.reasoning_support_type(model)
      when :openai_effort
        # Azure reasoning tokens share max_completion_tokens with visible
        # output. A bounded ladder leaves ample room for reasoning while
        # preventing high effort from silently expanding a 4K answer into a
        # 32K, multi-minute request.
        multiplier = { 'high' => 4, 'medium' => 3 }.fetch(effort, 2)
        requested * multiplier
      when :bedrock_budgeted
        thinking_budget = { 'high' => 4096, 'medium' => 2048 }.fetch(effort, 1024)
        requested + thinking_budget
      when :bedrock_adaptive
        multiplier = { 'high' => 4, 'medium' => 3 }.fetch(effort, 2)
        requested * multiplier
      else
        requested
      end
    end

    def detect_prompt_language(question)
      case @language
      when 'fr' then :fr
      when 'de' then :de
      when 'en'
        # For EN/INT mode, detect the question language and match it
        # Delegate to LanguageDetection concern if available on the orchestrator
        :en
      when 'nl' then :nl
      else :nl
      end
    end

    def build_language_instruction(question, prompt_lang)
      if @concise
        'Antwoord KORT en BONDIG (max 5 zinnen). Geef alleen het directe juridische antwoord op basis van de bronnen. GEEN caveats, GEEN "raadpleeg een advocaat", GEEN herhalingen.'
      else
        # No third "legal basis/sources" header: the UI source cards carry the
        # citations (commits 95a3c34e/c0151db4), and sanitize_answer strips the
        # section server-side as a safety net — asking for it only wasted
        # tokens on content that was deleted before display.
        case prompt_lang
        when :de then 'KRITISCH: Antworten Sie VOLLSTÄNDIG auf DEUTSCH. Verwenden Sie: HAUPTREGEL, AUSNAHMEN.'
        when :en then 'CRITICAL: Respond ENTIRELY in ENGLISH. Use headers: MAIN RULE, EXCEPTIONS. NO Dutch or French.'
        when :fr then 'CRITIQUE ABSOLUE: Répondez ENTIÈREMENT et UNIQUEMENT en FRANÇAIS. Utilisez: RÈGLE PRINCIPALE, EXCEPTIONS.'
        else 'BELANGRIJK: Antwoord in het NEDERLANDS. Gebruik: HOOFDREGEL, UITZONDERINGEN.'
        end
      end
    end

    def inject_reference_corrections(question, context)
      matched_sections = @reference_sheets.select_relevant_sections(question)
      return context unless matched_sections.present?

      facts = @reference_sheets.extract_imperative_facts(matched_sections)
      return context unless facts.present?

      Rails.logger.info("[REFSHEET] Injecting #{facts.size} facts into context")
      facts_block = facts.map { |f| "- #{f}" }.join("\n")
      "<verified_legal_data>\n#{facts_block}\n</verified_legal_data>\n\n#{context}"
    end
  end
end
