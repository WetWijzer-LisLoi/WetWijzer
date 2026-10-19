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
  #  7. models_config.rb  → :bedrock_inference_profile (if Bedrock: exact EU profile)
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

    attr_reader :last_evidence_context, :last_provider_model, :generation_trace, :provider_call_count,
                :last_provider_duration_seconds
    # The browser question's dispatch receipt (owner policy 2026-10-18) and
    # what this client's requests are for it. Assigned explicitly by whoever
    # builds the client for a billed question; nil sends untracked (service
    # traffic, rake tasks).
    attr_accessor :provider_work_receipt, :provider_work_kind

    def self.incomplete_response_message(language)
      case language.to_s
      when 'fr'
        "Le fournisseur d'IA n'a pas renvoyé de réponse complète. Veuillez réessayer."
      when 'de'
        'Der KI-Anbieter hat keine vollständige Antwort geliefert. Bitte versuchen Sie es erneut.'
      when 'en'
        'The AI provider did not return a complete answer. Please try again.'
      else
        'De AI-provider gaf geen volledig antwoord. Probeer opnieuw.'
      end
    end

    # Whether the last provider call came back empty or cut off at its output
    # ceiling. #query raises on it; GermanAnswerTranslation calls call_llm
    # directly and reads it here.
    def last_response_incomplete?
      @provider_response_incomplete == true
    end

    def initialize(model_override: nil, language: 'nl', concise: false, international_mode: false,
                   case_context: nil, reasoning_effort: nil, research_depth: nil, profile: 'general',
                   embedding_service: nil, mistral_api_key_env: 'MISTRAL_API_KEY')
      @model_override = model_override
      @language = language
      @concise = concise
      @international_mode = international_mode == true
      @case_context = case_context
      @reasoning_effort = reasoning_effort || 'low'
      @research_depth = self.class.normalize_research_depth(research_depth)
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
      @prompt_builder = SystemPromptBuilder.new(language: language, concise: concise, case_context: case_context, profile: profile, international_mode: @international_mode)
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

      user_sections = ["#{sources_label}:\n#{context}"]
      # Topic-local instructions are grounded in this exact rendered context,
      # not a canned fact sheet or a law the search failed to supply.
      childcare_guidance = ChildcareExpenseGrounding.guidance(question, context)
      user_sections << childcare_guidance if childcare_guidance.present?
      telephone_guidance = telephone_marketing_privacy_guidance(question, context)
      user_sections << telephone_guidance if telephone_guidance.present?
      municipal_guidance = municipal_sidewalk_fine_guidance(question, context)
      user_sections << municipal_guidance if municipal_guidance.present?
      headlight_guidance = VehicleHeadlightGlareGuidance.guidance(question, context)
      user_sections << headlight_guidance if headlight_guidance.present?
      # Put practical-task constraints after the full evidence block and its
      # topic-local guidance. Smaller models otherwise follow the older generic
      # quote/citation policy more readily than the scoped fact ledger.
      practical_guidance = @prompt_builder.practical_generation_guidance(question)
      user_sections << practical_guidance if practical_guidance.present?
      user_sections << @prompt_builder.practical_quick_scope_guidance if practical_guidance.present? && @research_depth == 'quick'
      citable_units = citable_unit_guidance(context) if practical_guidance.present?
      user_sections << citable_units if citable_units.present?
      # A guard-rejection retry carries the rejected references back to the
      # model. Placed before the question so the correction reads as part of
      # the task constraints, not as an answer suffix to be echoed.
      user_sections << corrective_feedback.to_s.strip if corrective_feedback.present?
      # Repeat the resolved language after topic/repair guidance too. Those
      # instructions may be written in another language, but they never select
      # the language of this generation or its verified literal source quotes.
      user_sections << lang_instruction
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
      model_config = AVAILABLE_MODELS.fetch(model)
      raise ArgumentError, 'The requested AI model is not available for WetWijzer' if model_config[:deployed] == false

      provider = model_config.fetch(:provider)
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
      provider_max_tokens ||= provider_output_token_ceiling(model, max_tokens, messages: messages)
      reservation = nil
      unless Thread.current[:chatbot_benchmark_cap_bypass]
        reservation = LegalChatbotService.reserve_model_budget!(
          model,
          reasoning_effort: effective_request_reasoning_effort(model, messages: messages),
          max_output_tokens: provider_max_tokens,
          messages: messages
        )
      end
      @provider_request_started = false
      @provider_dispatch_written = false
      @last_provider_duration_seconds = nil
      provider_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      provider_error_class = nil

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
    rescue StandardError => e
      provider_error_class = e.class.name
      # A refusal at the dispatch receipt wrote nothing in this call, even where
      # @provider_request_started was already set before connecting.
      refused_unsent = e.is_a?(ProviderWorkReceipt::PreDispatchRefused) && !@provider_dispatch_written
      LegalChatbotService.release_model_budget!(reservation) if reservation && (!@provider_request_started || refused_unsent)
      raise
    ensure
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - provider_started_at) * 1000).round if provider_started_at
      @last_provider_duration_seconds = duration_ms.to_f / 1000 if duration_ms
      status = if provider_started_at.nil?
                 'skip'
               elsif Thread.current[:chatbot_cancelled]
                 'cancelled'
               elsif provider_error_class
                 'error'
               else
                 'ok'
               end
      error_suffix = provider_error_class ? " error_class=#{provider_error_class}" : nil
      Rails.logger.info(
        "[LLMProvider] provider=#{provider} model=#{model} effort=#{@reasoning_effort} " \
        "attempt=#{@provider_call_count} duration_ms=#{duration_ms || 0} status=#{status}#{error_suffix}"
      )
      @provider_request_started = nil
    end

    # ─── Azure OpenAI (EU Data Zone) ─────────────────────────────────────
    # Keep this mapping explicit: the product-facing IDs are stable internal
    # identifiers, while the right-hand values are exact Azure deployment names.
    # Only the API URL uses the deployment name; billing and analytics retain
    # the internal model ID.
    AZURE_DEPLOYMENT_NAMES = {
      'gpt-6-luna' => 'gpt-6-luna',
      'gpt-6.1-sol' => 'gpt-6.1-sol'
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
        candidate = send_provider_request(http, request)
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
        max_tokens: max_tokens
      }
      body[:temperature] = temperature || 0.3 unless model == 'mistral-large-4'

      # A preview can be fixed to the documented minimal-thinking mode without
      # exposing an adjustable selector or charging a reasoning surcharge.
      body[:reasoning_effort] = model_config[:fixed_reasoning_effort] if model_config&.dig(:fixed_reasoning_effort)

      # Mistral Small exposes exactly two documented efforts: none and high.
      if self.class.reasoning_support_type(model) == :mistral_effort
        effort = effective_request_reasoning_effort(model, messages: messages) || 'low'
        if effort == 'low' && self.class.effective_reasoning_effort_for_model(model, @reasoning_effort) == 'high'
          # Mistral high-reasoning follow-ups require replaying provider-private
          # ThinkChunk state. WetWijzer intentionally never stores or sends that
          # state, so force documented non-reasoning mode instead of submitting
          # an invalid or semantically incomplete high-reasoning continuation.
          Rails.logger.warn('[MISTRAL] High reasoning disabled for follow-up without preserved ThinkChunk state')
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
      response = send_provider_request(http, request)
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

      # Exact geographic profiles live in the active registry. Retired IDs,
      # raw model IDs and global profiles cannot become a fallback route.
      config = AVAILABLE_MODELS.fetch(model)
      raise ArgumentError, 'The requested AI model is not available for WetWijzer' if config[:deployed] == false

      bedrock_model_id = config.fetch(:bedrock_inference_profile)
      unless config[:provider] == :bedrock && bedrock_model_id.start_with?('eu.anthropic.') && region == 'eu-central-1'
        raise ArgumentError, 'WetWijzer Bedrock requires its approved EU profile from Frankfurt'
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

      # Pending Claude 5.5 accepts adaptive thinking plus output_config effort.
      # Keep the capability dispatch explicit; do not send it manual budgets.
      # No sampling parameters, forced tools or private thinking replay are sent.
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
      response = send_provider_request(http, request)
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
      # A 5.5 safeguard refusal may be HTTP 200 with nonempty text. It is not
      # a completed legal answer and must enter the existing no-charge path.
      @provider_response_incomplete = answer.strip.empty? || %w[max_tokens refusal].include?(stop_reason)
      if @provider_response_incomplete
        Rails.logger.warn(
          "[BEDROCK] Empty/truncated response from #{model}: " \
          "stop_reason=#{stop_reason.presence || 'missing'}"
        )
      end
      answer
    end

    private

    # One attempt's write to the provider. The connection is opened first, so
    # a Net::OpenTimeout stays a request that was never sent (Azure keeps
    # retrying it in its own loop, exactly as before). Then the question's
    # receipt records the dispatch durably or refuses; only after that is the
    # request written. Each attempt still uses a fresh connection, as
    # Net::HTTP#request on an unstarted session did. (Transport doubles that
    # implement only #request are written to directly.)
    def send_provider_request(http, request)
      manages_session = http.respond_to?(:started?)
      http.start if manages_session && !http.started?
      @provider_work_receipt&.before_provider_dispatch!(@provider_work_kind || 'generation')
      @provider_dispatch_written = true
      http.request(request)
    ensure
      http.finish if manages_session && http.started?
    end

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
        retrieval_version: LegalChatbot::Orchestrator.retrieval_version_for(@research_depth)
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
    def provider_output_token_ceiling(model, requested_max_tokens, messages: nil)
      requested = Integer(requested_max_tokens)
      effort = effective_request_reasoning_effort(model, messages: messages) || 'low'

      case self.class.reasoning_support_type(model)
      when :mistral_effort
        # Mistral's max_tokens covers the whole completion: thinking chunks
        # and the visible answer. A 4K answer target previously exhausted
        # that shared cap before high reasoning could finish. Add at most
        # 4K thinking headroom (double smaller targets), reserved before I/O.
        # A privacy-clamped follow-up uses none and needs no extra allowance.
        effort == 'high' ? requested + [requested, 4096].min : requested
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

    # Resolve the request's actual mode before both spend reservation and
    # payload construction. We never retain/replay Mistral ThinkChunk state,
    # so history-bearing requests keep the existing non-reasoning safeguard.
    def effective_request_reasoning_effort(model, messages: nil)
      effort = self.class.effective_reasoning_effort_for_model(model, @reasoning_effort)
      return effort unless self.class.reasoning_support_type(model) == :mistral_effort && effort == 'high' && messages

      history_present = messages.length > 2 || messages.any? { |message| message[:role].to_s == 'assistant' }
      history_present ? 'low' : effort
    end

    def detect_prompt_language(question)
      # LegalChatbotService resolves the original question once, including
      # short follow-ups. Use that same language on every corrective retry.
      case @language
      when 'fr' then :fr
      when 'de' then :de
      when 'en'
        :en
      when 'nl' then :nl
      else :nl
      end
    end

    def build_language_instruction(question, prompt_lang)
      language = { nl: 'Dutch', fr: 'French', de: 'German', en: 'English' }.fetch(prompt_lang, 'Dutch')
      instruction = if @concise
                      "Respond in #{language}, briefly (maximum 5 sentences), with the direct legal answer from the provided sources. Avoid repetition. Preserve literal source quotations in their original language."
                    else
                      # No third "legal basis/sources" header: the UI source cards carry the
                      # citations (commits 95a3c34e/c0151db4), and sanitize_answer strips the
                      # section server-side as a safety net, so asking for it only wasted
                      # tokens on content that was deleted before display.
                      direction = case prompt_lang
                                  when :de then 'KRITISCH: Antworten Sie VOLLSTÄNDIG auf DEUTSCH. Verwenden Sie: HAUPTREGEL, AUSNAHMEN.'
                                  when :en then 'CRITICAL: Write your analysis, headings and closing guidance in ENGLISH. Use headers: MAIN RULE, EXCEPTIONS.'
                                  when :fr then 'CRITIQUE ABSOLUE: Répondez ENTIÈREMENT et UNIQUEMENT en FRANÇAIS. Utilisez: RÈGLE PRINCIPALE, EXCEPTIONS.'
                                  else 'BELANGRIJK: Antwoord in het NEDERLANDS. Gebruik: HOOFDREGEL, UITZONDERINGEN.'
                                  end
                      "#{direction} Preserve exact source quotations and citation labels in their original language; never translate them as verified literal quotes."
                    end
      @international_mode ? "#{instruction}\n#{LanguageDetection::INTERNATIONAL_LANGUAGE_EXCEPTION}" : instruction
    end

    # The exact citable units of THIS evidence block, read from its own
    # LINK lines, repeated after it for the practical tasks. On 2026-10-17 the
    # short model's refused drafts named supplied articles with malformed
    # labels or links ("(Art. 732 en 733)", "https://laws/...", "sub b") and
    # articles it was never given (Art. 2262 BW, DSA Art. 33). This lists only
    # what was admitted; it adds no source and loosens no check.
    CITABLE_UNIT_LIMIT = 40
    def citable_unit_guidance(context)
      units = context.to_s.split(/\n(?=\[Bron \d+ - )/).filter_map do |block|
        link = block[/^LINK: (\S+)/, 1]
        next unless link

        lines = block.lines.map(&:strip)
        unit = if lines.first.to_s.include?('OFFICIAL GUIDANCE')
                 block[/^Title: (.+)$/, 1].to_s.strip[0, 120]
               elsif (wet = lines.index { |line| line.start_with?('Wet: ') })
                 lines[wet + 1].to_s.sub(/\AArt\.\s*/, 'art. ')
               elsif (title = lines.index { |line| line.start_with?('Title: ') })
                 kind = lines[title + 1].to_s
                 ecli = block[/^ECLI: (\S+)/, 1]
                 kind == 'Dictum' && ecli ? ecli : kind
               elsif (dossier = block[/^Dossier: (\S+)/, 1])
                 "dossier #{dossier} (parliamentary preparation)"
               elsif (ecli = block[/^ECLI: (\S+)/, 1])
                 ecli
               end
        next if unit.blank? || unit.start_with?('LINK:')

        "- [#{unit}](#{link})"
      end.uniq.first(CITABLE_UNIT_LIMIT)
      return nil if units.empty?

      "CITABLE UNITS OF THIS EVIDENCE (the only ones you may cite): copy a link below exactly, label and target, " \
        "at every mention; you may add the act's name to the label and, for an article, at most its paragraph " \
        "(\"art. 7(1)\"), never a point or letter. A number that only appears inside a source text (a " \
        "cross-reference) and any article not listed here is not citable: explain the rule in words instead.\n" \
        "#{units.join("\n")}"
    end

    # The low-cost telephone QA missed the topic task in the long system
    # prompt and lost its GDPR quotations despite the complete excerpt pack.
    # Repeat source-use instructions next to this question only when the
    # complete native sealed pack is actually present in the evidence block.
    # This adds no source, prescribed answer or relaxation of QuoteGuard.
    def telephone_marketing_privacy_guidance(question, context)
      return nil unless TelemarketingPrivacyIntent.topic?(question)

      records = LegalFactProvider::GDPR_DIRECT_MARKETING_OFFICIAL_SOURCES.fetch(@language.to_s, [])
      return nil if records.empty?

      blocks = context.to_s.split("\n\n---\n\n")
      complete = records.all? do |record|
        blocks.any? do |block|
          block.match?(/^LINK: #{Regexp.escape(record.fetch(:url))}\r?$/) &&
            block.match?(/^#{Regexp.escape(record.fetch(:article_title))}\r?$/) &&
            block.include?(record.fetch(:article_text))
        end
      end
      return nil unless complete

      <<~GUIDANCE.strip
        TELEPHONE-MARKETING APPLICATION CHECK (task instruction, not an additional legal source; do not reproduce this instruction):
        - Answer the caller-origin and stop-marketing questions directly and concisely from the supplied official excerpts, in the resolved answer language.
        - Apply supplied Article 21(2)-(3) to objection to direct-marketing processing and stopping that purpose. Do not replace this question with only Article 17 erasure conditions or Article 14 disclosure exceptions.
        - Distinguish Article 14 indirect-collection information and first-contact timing from Article 15(1)(g) access to available origin information. Apply Article 17 erasure and its supplied exceptions separately, without treating another retention purpose as permission to continue marketing.
        - For Article 12(3)-(4), explain information on action taken, any extension notice and refusal information from the supplied text, not merely starting to process a request. Do not promise instantaneous telephone deletion or compliance by an unidentified scammer.
        - Prefer a concise paraphrase OUTSIDE quotation marks with an inline link copied exactly from that provision's LINK field. Quotations are OPTIONAL for these selected excerpts, even when article text is present. If quoting, copy only a SHORT CONTIGUOUS fragment actually present above, in its native source language; never reconstruct a full paragraph from memory, join separated clauses or translate it as a literal quote.
        - Keep Belgian telephone-marketing provisions separate from these GDPR rights, and give practical request wording only as a suggestion, not a statutory quotation or personal experience.
      GUIDANCE
    end

    # An article may have reached retrieval but lost its operative paragraph
    # during excerpting. Bind paragraph-specific task instructions to the
    # rendered canonical source block, never the full row or article number
    # alone. Missing clauses stay an evidence gap, not a fabricated deadline.
    def municipal_sidewalk_fine_guidance(question, context)
      return nil unless MunicipalSanctionsSourceScope.topic?(question)

      supplied = context.to_s.split("\n\n---\n\n").filter_map do |block|
        next unless block.match?(/^NUMAC: 2013000441\r?$/)

        link = block.match(%r{^LINK: /laws/2013000441#art-(2|4|25|31)\r?$})
        next unless link && block.match?(/^Art\.?\s*#{link[1]}\.?\r?$/i)

        body = block[link.end(0)..].to_s.strip
        [link[1], body] if body.present?
      end
      return nil unless %w[2 4 25 31].all? { |number| supplied.any? { |entry| entry.first == number } }

      # Differing native copies of the same article cannot be combined into
      # one apparently complete paragraph. Leave ambiguous contexts alone.
      return nil unless supplied.group_by(&:first).values.all? { |copies| copies.map(&:last).uniq.one? }

      bodies = supplied.to_h
      defense = municipal_source_paragraph(bodies.fetch('25'), '2')
      defense_present = defense&.match?(/vijftien dagen|quinze jours/i) &&
                        defense.match?(/kennisgeving|notification/i) &&
                        defense.match?(/verweermiddelen|moyens de d[ée]fense/i) &&
                        defense.match?(/aangetekende brief|lettre recommand[ée]e/i)
      defense_rights_present = defense&.match?(/raadsman|par un conseil/i) &&
                               defense.match?(/dossier/i) &&
                               defense.match?(/kopie van het proces-verbaal|copie du proc[èe]s-verbal/i)
      hearing = municipal_source_paragraph(bodies.fetch('25'), '4')
      hearing_present = hearing&.match?(/70\s+euros?/i) &&
                        hearing.match?(/meerderjarige|majeur/i) &&
                        hearing.match?(/niet hoger|n['’]exc[ée]dant pas/i) &&
                        hearing.match?(/recht niet|n['’]a pas le droit/i) &&
                        hearing.match?(/mondeling|oralement/i)
      penal = municipal_source_paragraph(bodies.fetch('4'), '3')
      penal_present = penal&.match?(/politiestraffen|peines de police/i)
      appeal = bodies.fetch('31')
      adult_appeal_present = appeal.match?(/politierechtbank|tribunal de police/i) &&
                             appeal.match?(/geschreven verzoekschrift|requ[êe]te [ée]crite/i) &&
                             appeal.match?(/binnen een maand|dans le mois/i) &&
                             appeal.match?(/kennisgeving|notification/i)
      youth_present = appeal.match?(/minderjarigen|mineurs/i) &&
                      appeal.match?(/jeugdrechtbank|tribunal de la jeunesse/i) &&
                      appeal.match?(/kosteloos verzoekschrift|requ[êe]te gratuite/i)

      lines = [
        'MUNICIPAL-SIDEWALK APPLICATION CHECK (task instruction, not an additional legal source; do not reproduce this instruction):',
        '- Answer in the resolved answer language from the supplied canonical Articles 2, 4, 25 and 31. Establish the municipality, applicable local rule, age and notification/decision stage without assuming them or declaring the fine valid.',
        '- Keep the initial administrative defense stage separate from court appeal against a final sanctioning-officer decision. Prefer concise paraphrase with the exact corresponding LINK; quotations are optional and must be short contiguous native fragments actually supplied above.'
      ]
      lines << if defense_present
                 '- Apply the actually supplied Article 25 § 2 written-defense provision: explain its registered-letter procedure and fifteen-day notification-based window. Do not attribute this defense provision to § 1 register access or replace it with the later court-appeal period.'
               else
                 '- The operative written-defense deadline clause is not fully supplied in rendered Article 25. Do not invent a deadline, procedure or paragraph label from the article number or register-access text; identify the missing source detail and cite only what is actually supplied.'
               end
      if defense_rights_present
        label = defense_present ? 'Article 25 § 2' : 'Article 25'
        lines << "- Explain the actual dossier/counsel/report rights supplied in #{label}; do not invent additional missing procedural rights."
      end
      lines << if hearing_present
                 '- Apply the supplied Article 25 § 4 adult/not-higher-than-70-euro limitation only to the request for oral defense. Keep it separate from written defense, and do not assume adulthood or apply that threshold to a 100-euro allegation.'
               else
                 '- Do not assert an oral-hearing threshold or paragraph number that is absent from the rendered source.'
               end
      lines << if youth_present && adult_appeal_present
                 '- Apply Article 31 only at the final-decision appeal stage, using the actually supplied notification-based period and written-petition requirements. Distinguish the supplied police-court route from the free youth-court petition for a decision concerning a minor; do not assume the user is an adult.'
               else
                 '- Use only the appeal conditions and court route actually supplied in Article 31. Do not infer an age-specific route or paragraph label from an incomplete excerpt; acknowledge missing detail.'
               end
      lines << if penal_present
                 '- The supplied Article 4 § 3 concerns criminal police penalties, not the administrative-fine ceiling. Use the actual administrative-fine clause in Article 4 for that separate question; never turn the police-penalty limit into a general GAS administrative maximum.'
               else
                 '- Do not infer an administrative-fine ceiling from an unverified criminal-penalty paragraph. Read the actual administrative-fine clause supplied in Article 4.'
               end
      lines.join("\n")
    end

    def municipal_source_paragraph(body, number)
      headings = body.to_s.to_enum(:scan, %r{(?:\A|\n)[[:blank:]]*(?:Art(?:ikel|icle)?\.?[[:blank:]]*\d+\.?[[:blank:]]*)?(?:\[\d+\]?[[:blank:]]*)?§[[:blank:]]*(\d+(?:/\d+)?)(?:er)?\.[[:blank:]]*}i).map do
        match = Regexp.last_match
        [match[1], match.begin(0)]
      end
      return nil unless headings.one? { |heading| heading.first == number }

      index = headings.index { |heading| heading.first == number }
      return nil unless index

      body[headings[index].last...(headings[index + 1]&.last || body.length)]
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
