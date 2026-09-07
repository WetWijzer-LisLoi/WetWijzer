# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'uri'

module Api
  class ChatbotController < ChatbotBaseController
    include Api::BrowserChatBilling
    include Api::ChatbotAnalytics
    include Api::StreamingQuerySupervision




    # ActionController::Live makes response.stream.write reach the client
    # immediately. Without it response.stream is a plain buffer: the SSE
    # progress events and 10s heartbeats (whose purpose is to reset Nginx's
    # proxy_read_timeout) were only flushed after the action finished, so the
    # whole anti-timeout design was inert.
    include ActionController::Live


    # ===========================================
    # COST PROTECTION LIMITS - TARGET: €200/month
    # Standard-envelope estimates (12K input + 3K output; verified 2026-07-22):
    #   mistral-small: ~€0.004/query
    #   gpt-5-mini:    ~€0.010/query
    # Embeddings and provider billing adjustments are additional. These are
    # conservative application estimates, not invoice guarantees.
    #
    # PREMIUM MODEL COSTS (per query):
    #   gpt-5.6-luna:  ~€0.033
    #   gpt-5:         ~€0.050
    #   claude-haiku:  ~€0.027
    #   gpt-5.6-terra: ~€0.083
    #   claude-sonnet: ~€0.081
    #   claude-opus:   ~€0.135
    #   gpt-5.6-sol:   ~€0.165
    #
    # PROTECTION LAYERS:
    #   1. Global rate limits (daily/hourly/monthly)
    #   2. Per-IP burst/hourly limits
    #   3. Per-model daily caps (MODEL_DAILY_CAPS in models_config.rb)
    #   4. Credit reservation/refund system
    #   5. Token usage tracking (input_tokens, output_tokens, estimated_cost_eur)
    #
    # NOTE: HMAC service auth = app-level access (no per-user account needed).
    # Regular users authenticate via session cookie and use WetWijzer credits.
    # ===========================================
    DAILY_GLOBAL_LIMIT = 2500         # ~€22/day max (gpt-5-mini), budget-safe
    HOURLY_GLOBAL_LIMIT = 600         # spike protection (was 300, too strict for testing)
    MONTHLY_GLOBAL_LIMIT = 25_000 # request-count circuit breaker; actual model mix determines cost
    PER_IP_BURST_LIMIT = 30           # 30/minute per IP (anti-bot, not user-facing)
    PER_IP_HOURLY_LIMIT = 500         # 500/hour per IP (effectively unlimited for humans)
    PER_IP_PREMIUM_BURST_LIMIT = 15   # 15/minute per IP (Level III/IV models only)
    PER_IP_PREMIUM_HOURLY_LIMIT = 120 # 120/hour per IP (Level III/IV models only)
    SERVICE_DAILY_LIMIT = ENV.fetch('CHATBOT_SERVICE_DAILY_LIMIT', 1000).to_i # app-level service access

    # FileStore#increment rewrites an entry without retaining the expiry that
    # was set by a preceding write. A plain "write with TTL, then increment"
    # therefore turns a one-minute counter into a permanent production
    # counter. Fixed-window keys remain correct even if a cache backend loses
    # the cleanup TTL, because the next window necessarily uses a new key.
    def self.windowed_rate_limit_key(key, expires_in:, now: Time.current)
      window_seconds = expires_in.to_i
      raise ArgumentError, 'expires_in must be positive' unless window_seconds.positive?

      "#{key}:window:#{now.to_i.div(window_seconds)}"
    end

    # Rate limiting: 30 requests/hour per IP, 5 requests/minute burst protection
    # IMPORTANT: Only rate-limit the expensive LLM-calling actions.
    # Lightweight CRUD endpoints (conversations, consent, save, feedback, zk_key_material)
    # must NOT count toward the burst limit — the frontend fires 3-4 of these on page load,
    # which would exhaust the 5/min burst budget before the user even asks a question.
    # Only provider-calling actions sit behind the credit/subscription gate.
    # History, consent, feedback, and encrypted-payload endpoints must remain
    # usable after a question spends the user's final credits; otherwise a paid
    # zero-knowledge answer can reach the browser but cannot be persisted.
    before_action :check_access, only: :ask
    before_action :rate_limit_check, only: :ask

    # POST /api/chatbot/ask (or GET for SSE streaming)
    # Params: { question: "...", language: "nl", source: "legislation|jurisprudence|all", stream: true/false, conversation_id: "..." }
    #
    # Source options:
    # - "legislation" (default): Fast (~15-30s), searches written law only
    # - "jurisprudence": Fast (~15-30s), searches case law/court rulings only
    # - "all": Comprehensive (~30-50s), searches both sources - slower but more complete
    #
    # Conversation support:
    # - First question: don't send conversation_id, response includes new conversation_id
    # - Follow-up questions: send conversation_id to maintain context
    def ask
      # FBL-065 admission control: a slot is held for the FULL provider
      # lifetime, acquired before any credit reservation so a refusal never
      # needs a refund. Saturation is a fast, retryable 503 for both the
      # JSON and stream forms (pre-stream, like the ZK-conflict refusal).
      unless ChatbotApi::AskAdmission.try_acquire
        response.set_header('Retry-After', '5')
        return render json: { error: 'server_busy', code: 'server_busy', retry_after: 5 },
                      status: :service_unavailable
      end

      begin
        perform_ask
      ensure
        ChatbotApi::AskAdmission.release
      end
    end

    def perform_ask
      conversation = nil
      analytic = nil
      conversation_delivery_receipt = nil
      conversation_persistence_outcome = nil
      answer_delivery_accepted = false
      billing_delivery_token = nil
      billing_delivery_abort_allowed = false
      new_conversation_for_request = false
      keep_new_conversation = false
      question = params[:question]&.strip
      requested_language = params[:language].presence || 'nl'
      stream = ['true', true].include?(params[:stream])
      conversation_id = params[:conversation_id]&.strip

      # Handle sources array (new checkbox UI) or single source (legacy dropdown)
      sources_array = params[:sources]
      # NOT `params[:source] || 'legislation'`. Ruby has exactly two falsey
      # values, so that `||` masked exactly one client input: a JSON body
      # carrying `"source": false` had its value replaced with a valid one
      # before anything could reject it, and the helper's :unsupported_source
      # verdict was never asked for. Other non-string values - true, 0, 42, an
      # array, an object - are truthy and did reach validation; they are
      # covered here to keep that true rather than because they were broken.
      # The helper already treats nil and blank as absent, which is the only
      # case that should default, so the `||` was doing nothing else.
      source_param = params[:source]

      # Determine effective source from checkboxes or dropdown.
      #
      # BOTH values come from the same canonical allowlist. They used to
      # disagree: the effective `source` was filtered, while @selected_sources
      # was built from the RAW request array, so anything a client put in
      # sources[] was stored in analytics and joined into the orchestrator's
      # log line verbatim. See ChatbotSourceCategories for what that did and
      # did not reach.
      canonical_sources = ChatbotSourceCategories.canonical(sources_array)

      source = if sources_array.is_a?(Array) && sources_array.any?
                 canonical_sources.length > 1 ? :custom : canonical_sources.first.to_sym
               else
                 # Validated BEFORE symbolizing. The array path was canonicalized
                 # while this one still turned arbitrary request text into a
                 # symbol and only then checked it against the allowlist below.
                 ChatbotSourceCategories.legacy_symbol(source_param)
               end

      @selected_sources = if sources_array.is_a?(Array) && sources_array.any?
                            canonical_sources.map(&:to_sym)
                          else
                            # `all` reached the fan-out as the literal [:all] and
                            # therefore searched nothing at all; it now means what
                            # it says.
                            ChatbotSourceCategories.expand_legacy(source)
                          end

      # Validation
      return render json: { error: 'Question is required' }, status: :bad_request if question.blank?

      # Input length validation - prevents oversized prompts from reaching LLM
      max_question_length = 2000
      if question.length > max_question_length
        return render json: {
          error: "Question too long (#{question.length} chars, max #{max_question_length})"
        }, status: :bad_request
      end

      # Browser requests remain bound to their domain. A signed service request
      # may explicitly benchmark either supported legal corpus on one host.
      language = effective_request_language(requested_language, host: request.host)

      # Accept any language - LLM will respond in user's language
      # Default to 'nl' for source search if language not nl/fr
      @search_language = %w[nl fr].include?(language) ? language : 'nl'

      valid_sources = %i[legislation parliamentary jurisprudence all custom]
      unless valid_sources.include?(source)
        return render json: {
          error: 'Source must be: legislation, parliamentary, or jurisprudence'
        }, status: :bad_request
      end

      # Get or create conversation for context. A zero-knowledge conversation
      # is useful only while the account key generation and encrypted snapshot
      # revision still match what the browser decrypted. Validate that state
      # before model selection, credit reservation, or any provider call.
      begin
        conversation = find_or_create_conversation(conversation_id, language)
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end
      new_conversation_for_request = conversation&.instance_variable_get(:@created_for_chat_request) == true
      return unless validate_zero_knowledge_chat_state!(conversation)
      zk_claim = nil

      # ── Intelligence / model / credit calculation (shared with non-streaming) ──
      # Extracted to ChatbotApi::ModelSelection (FBL-060 step 1); the locals
      # keep their names so the downstream flow is unchanged.
      selection = ChatbotApi::ModelSelection.new(
        params: params,
        conversation: conversation,
        service_bypass: @service_bypass,
        user_tier: current_user&.current_tier || :free
      )
      intelligence = selection.intelligence
      model = selection.model
      model_override = selection.model_override
      credits_to_deduct = selection.credits_to_deduct
      reasoning_effort = selection.reasoning_effort
      requested_reasoning_effort = selection.requested_reasoning_effort
      model_tier_denied = selection.model_tier_denied?
      model_tier_mismatch = selection.model_tier_mismatch?

      if model_tier_mismatch
        return render json: {
          error: 'model_tier_mismatch',
          model: model_override,
          intelligence: intelligence
        }, status: :bad_request
      end

      reasoning_effort_used = reasoning_effort || 'none'
      if quality_evidence_requested? && requested_reasoning_effort.present? &&
         requested_reasoning_effort != reasoning_effort_used
        return render json: {
          error: 'unsupported_reasoning_effort',
          model: model,
          requested_reasoning_effort: requested_reasoning_effort,
          reasoning_effort_used: reasoning_effort_used
        }, status: :bad_request
      end

      if stream
        # Stream with progress updates
        streaming_timeout_seconds = streaming_query_timeout_seconds
        response.headers['Content-Type'] = 'text/event-stream'
        response.headers['Cache-Control'] = 'no-cache'
        response.headers['X-Accel-Buffering'] = 'no'
        # The browser keeps its abort deadline beyond this supervisor so the
        # server can emit the terminal timeout event and refund reserved
        # credits before the connection is cancelled client-side.
        response.headers[STREAMING_QUERY_TIMEOUT_HEADER] = streaming_timeout_seconds.to_s

        # ── Access & credit enforcement (streaming) ──
        unless @service_bypass
          unless current_user
            response.stream.write("data: #{JSON.generate({ type: 'error', error: 'login_required' })}\n\n")
            response.stream.close
            return
          end

          # Tier access check (streaming) - mirrors non-streaming path
          if intelligence.present? && LegalChatbotService.valid_intelligence_level?(intelligence)
            tier = LegalChatbotService::INTELLIGENCE_LEVELS.dig(intelligence, :tier)
            access_denied = !LegalChatbotService.intelligence_tier_accessible?(
              tier,
              pro: current_user.pro?,
              purchased: current_user.advanced_intelligence_access?
            )
            if access_denied
              response.stream.write("data: #{JSON.generate({ type: 'error', error: 'upgrade_required', intelligence: intelligence, tier: tier.to_s })}\n\n")
              response.stream.close
              return
            end
          end

          if model_tier_denied
            response.stream.write("data: #{JSON.generate({ type: 'error', error: 'upgrade_required', model: model_override.presence || model })}\n\n")
            response.stream.close
            return
          end

          # Source entitlement, before any reservation or provider call.
          denied_source = denied_pro_source(current_user, source, @selected_sources)
          if denied_source
            response.stream.write("data: #{JSON.generate({ type: 'error' }.merge(source_requires_pro_payload(denied_source)))}\n\n")
            response.stream.close
            return
          end

          unless reconcile_browser_chat_billing!(current_user)
            response.stream.write("data: #{JSON.generate({ type: 'error' }.merge(browser_chat_billing_unavailable_payload))}\n\n")
            response.stream.close
            return
          end

          unless current_user.has_credits?(credits_to_deduct)
            response.stream.write("data: #{JSON.generate({ type: 'error', error: 'insufficient_credits', credits_required: credits_to_deduct, credits_available: current_user.credits })}\n\n")
            response.stream.close
            return
          end
        end



        # Per-model daily circuit breaker (e.g. Opus ~12/day). The shared
        # provider budget is enforced separately below. The deep_analysis /
        # legacy paths enforced this check but #ask did not.
        if !benchmark_cap_bypass? && LegalChatbotService.model_at_daily_cap?(model)
          response.stream.write("data: #{JSON.generate({ type: 'error', error: 'model_daily_cap', model: model.to_s })}\n\n")
          response.stream.close
          return
        end

        # Application-side provider estimated-spend ceiling (not a cloud billing hard cap)
        if !benchmark_cap_bypass? && LegalChatbotService.provider_at_monthly_cap?(model)
          provider = LegalChatbotService.provider_for_model(model)
          response.stream.write("data: #{JSON.generate({ type: 'error', error: 'provider_monthly_cap', provider: provider.to_s })}\n\n")
          response.stream.close
          return
        end

        # Reserve credits and create the durable ledger row in one accounts
        # transaction, AFTER all access/provider checks and BEFORE the LLM call.
        # The row remains available to every rescue until it is durably settled
        # after delivery or idempotently refunded.
        reservation = nil
        unless @service_bypass
          reservation = reserve_browser_chat_credits!(
            current_user,
            amount: credits_to_deduct,
            intelligence: intelligence || 'smart',
            model: model
          )
          unless reservation
            response.stream.write("data: #{JSON.generate({ type: 'error', error: 'insufficient_credits', credits_required: credits_to_deduct, credits_available: current_user.reload.credits })}\n\n")
            response.stream.close
            return
          end
        end

        # Atomically claim the conversation revision only after every access/
        # budget check and any credit reservation. This fences both encrypted
        # snapshots and standard history against concurrent send/clear races.
        begin
          zk_claim = claim_zero_knowledge_chat_revision!(conversation)
        rescue ZeroKnowledgeStateConflict
          streaming_user = current_user
          refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'zero_knowledge_claim_conflict')
          credits_info = credit_balance_info(streaming_user, deducted: 0) if reservation
          response.stream.write("data: #{JSON.generate({ type: 'error', error: 'zero_knowledge_state_conflict', key_generation: zero_knowledge_key_generation(current_user), credits_info: credits_info })}\n\n")
          response.stream.close
          return
        end

        # Capture user reference before streaming block (thread-safety)
        streaming_user = current_user
        query_thread = nil

        begin
          start_time = Time.current
          # ZK mode: client provides conversation context (server cannot read stored messages)
          context_override = nil
          if params[:context_messages].is_a?(Array) && params[:context_messages].any?
            context_override = params[:context_messages].map { |m| h = m.permit(:role, :content).to_h; h['role'] = 'user' unless %w[user assistant].include?(h['role']); h }.last(6)
          end
          quality_provenance_before = quality_capture_provenance
          chatbot = LegalChatbotService.new(language: language, conversation: conversation, model: model, domain: request.host, reasoning_effort: reasoning_effort, profile: requested_profile, context_messages_override: context_override, law_numac: params[:law_numac].to_s.presence, include_quality_evidence: quality_evidence_requested?, **mistral_credential_options)

          # Send immediate progress event so client knows connection is alive
          response.stream.write("data: #{JSON.generate({ type: 'progress', step: 'searching' })}\n\n")

          # Run the LLM query in a thread so we can send heartbeats
          # This prevents Nginx from killing the connection during long queries
          result = nil
          query_error = nil
          query_tokens = nil
          # With ActionController::Live the action itself runs off the main
          # thread, so pass the request id down explicitly (Thread.main would
          # be the wrong thread).
          parent_request_id = Thread.current[:request_id]
          benchmark_cap_bypass_enabled = benchmark_cap_bypass?
          query_thread = Thread.new do
            Thread.current[:request_id] = parent_request_id
            with_benchmark_cap_bypass(benchmark_cap_bypass_enabled) do
              result = if source == :custom
                         chatbot.ask_with_sources(question, sources: @selected_sources)
                       else
                         chatbot.ask(question, source: source)
                       end
            end
            # Token usage is thread-local to the LLM call — capture it here;
            # the request thread never sees this thread's locals.
            query_tokens = Thread.current[:last_chat_tokens]
          rescue StandardError => e
            query_error = e
          end

          # Send heartbeats while the query runs. The hard supervisor deadline
          # is deliberately shorter than the browser/proxy timeout: provider
          # calls can otherwise remain blocked after the client disconnects,
          # leaving the up-front credit reservation permanently unsettled.
          # Relay the orchestrator's REAL phase when it changes, and fall back
          # to a heartbeat otherwise. Before this, the client ran a simulated
          # animation to 95% in about 19 seconds and then sat there: on a
          # 78-second answer that is a minute of apparently frozen progress,
          # while the server knew perfectly well it was on regeneration
          # attempt 2 of 3.
          last_phase = nil
          query_completed = wait_for_streaming_query(query_thread, timeout_seconds: streaming_timeout_seconds) do |elapsed|
            phase = chatbot.respond_to?(:current_phase) ? chatbot.current_phase : nil
            attempt = chatbot.respond_to?(:current_phase_attempt) ? chatbot.current_phase_attempt : nil

            if phase && [phase, attempt] != last_phase
              last_phase = [phase, attempt]
              event = { type: 'progress', step: phase.to_s }
              if attempt
                event[:attempt] = attempt
                event[:max_attempts] = LegalChatbot::Orchestrator::CITATION_GUARD_MAX_RETRIES
              end
              response.stream.write("data: #{JSON.generate(event)}\n\n")
            else
              response.stream.write("data: #{JSON.generate({ type: 'heartbeat', elapsed: elapsed })}\n\n")
            end
          end

          unless query_completed
            Rails.logger.warn(
              "Chatbot streaming hard timeout after #{streaming_timeout_seconds}s " \
              "(model=#{model}, user=#{streaming_user&.id || 'service'})"
            )
            terminate_chatbot_query_thread(query_thread)
            result = {
              answer: chatbot.timeout_answer,
              sources: [],
              response_time: (Time.current - start_time).round(2),
              error: 'timeout'
            }
            query_error = nil
            query_tokens = {}
          end

          # On a query exception, just re-raise — the method-level rescue is the
          # single idempotent refund point for the reserved credits.
          raise query_error if query_error

          # Account erasure fences active=false while provider work is in
          # flight. Re-check immediately on return, while the durable row is
          # still reserved and before conversation/analytics persistence.
          unless @service_bypass || browser_chat_account_active?(streaming_user)
            refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'account_fenced')
            rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
            zk_claim = nil
            credits_info = credit_balance_info(streaming_user, deducted: 0) if reservation
            response.stream.write("data: #{JSON.generate({ type: 'error' }.merge(browser_chat_account_fenced_payload(credits_info: credits_info)))}\n\n")
            response.stream.close
            return
          end

          # Echo the actual routing decision so automated quality checks can
          # detect a model or language silently falling back to another tier.
          attach_execution_metadata(
            result,
            model: model,
            intelligence: intelligence,
            language: language,
            reasoning_effort_used: reasoning_effort_used
          )
          attach_quality_capture_metadata(result, expected_provenance: quality_provenance_before)

          if result[:error] && zk_claim
            rollback_zero_knowledge_chat_revision!(conversation, zk_claim)
            zk_claim = nil
          end

          # Another tab may explicitly clear this conversation while the model
          # is running. Never deliver (and charge for) a ZK answer whose lease
          # has already been cancelled, expired, or fenced by that request.
          if !result[:error] && zk_claim && !conversation_claim_owned?(zk_claim)
            refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'zero_knowledge_claim_lost')
            credits_info = credit_balance_info(streaming_user, deducted: 0) if reservation
            zk_claim = nil
            response.stream.write("data: #{JSON.generate({ type: 'error', error: 'zero_knowledge_state_conflict', key_generation: zero_knowledge_key_generation(streaming_user), credits_info: credits_info })}\n\n")
            response.stream.close
            return
          end

          if reservation && !result[:error]
            billing_delivery_token = begin_browser_chat_delivery!(reservation)
            # No result event has been attempted yet. Failures before that
            # boundary may abort only after exact history rollback below.
            billing_delivery_abort_allowed = true
          end

          # Save standard history under the same claimed revision. ZK payloads
          # are encrypted and finalized separately by the browser.
          unless conversation&.zero_knowledge?
            begin
              saved_delivery_receipt = save_to_conversation(conversation, question, result, claim: zk_claim)
            rescue ConversationPersistenceError => e
              conversation_persistence_outcome = e.outcome
              raise
            end
            conversation_delivery_receipt = saved_delivery_receipt if reservation && !result[:error]
            # Standard history is immediately retrievable by another request;
            # that durable value is itself delivery. It may no longer be rolled
            # back/refunded merely because the later transport write fails.
            billing_delivery_abort_allowed = false if conversation_delivery_receipt
            zk_claim = nil # the standard claim was consumed by the atomic save
          end
          attach_conversation_state(result, conversation, zk_claim: zk_claim)

          # Log analytics at zero first. The charged amount is recorded only
          # after delivery and durable settlement, so abandoned/refunded rows
          # cannot become false revenue.
          analytic = log_analytic(
            question,
            result,
            language,
            source,
            conversation,
            model: model,
            credits: 0,
            token_info: query_tokens,
            billing_reservation_token: reservation&.reservation_token,
            generation_trace: generation_trace_for(chatbot),
            reasoning_effort_requested: requested_reasoning_effort,
            provider_calls: provider_calls_for(chatbot)
          )
          result[:analytic_id] = analytic&.id
          attach_rating_token(result, analytic)

          # Error/timeout/safety results are never billable. Keep the durable
          # reservation object in scope after refund so a later operation raising
          # can safely retry refund! without applying a second credit mutation.
          # A successful result stays reserved until the result event is written.
          if reservation
            if result[:error]
              refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'provider_result_error')
              result[:credits_info] = credit_balance_info(streaming_user, deducted: 0)
            else
              result[:credits_info] = credit_balance_info(
                streaming_user,
                deducted: credits_to_deduct,
                intelligence: intelligence
              )
            end
          end

          # Attach token usage for client-side transparency
          token_info = query_tokens || {}
          if token_info[:input].to_i.positive? || token_info[:output].to_i.positive?
            result[:token_usage] = {
              input: token_info[:input] || 0,
              output: token_info[:output] || 0,
              total: (token_info[:input] || 0) + (token_info[:output] || 0)
            }
          end

          # A streaming write can fail after bytes reached the client, so from
          # this point non-delivery is ambiguous and the pending charge stays.
          result_event_payload = "data: #{JSON.generate({ type: 'result', data: result })}\n\n"
          billing_delivery_abort_allowed = false unless result[:error]
          response.stream.write(result_event_payload)
          answer_delivery_accepted = true unless result[:error]
          settle_browser_chat_reservation!(reservation, delivery_token: billing_delivery_token) unless result[:error]
          conversation_delivery_receipt = nil unless result[:error]
          project_browser_chat_analytic!(reservation, analytic) if reservation && !result[:error]
          zk_claim = nil # the client now owns the claimed revision
          keep_new_conversation = true unless result[:error]
          response.stream.close
        end
      else
        # ── Non-streaming JSON path (stream=false) ──
        # This branch was missing entirely: stream=false fell through to an
        # implicit 204 with no answer and no error.

        # Access & credit enforcement (mirrors the streaming path with JSON errors)
        unless @service_bypass
          unless current_user
            return render json: { error: 'login_required', login_required: true }, status: :unauthorized
          end

          if intelligence.present? && LegalChatbotService.valid_intelligence_level?(intelligence)
            tier = LegalChatbotService::INTELLIGENCE_LEVELS.dig(intelligence, :tier)
            access_denied = !LegalChatbotService.intelligence_tier_accessible?(
              tier,
              pro: current_user.pro?,
              purchased: current_user.advanced_intelligence_access?
            )
            if access_denied
              return render json: { error: 'upgrade_required', intelligence: intelligence, tier: tier.to_s }, status: :forbidden
            end
          end

          if model_tier_denied
            return render json: { error: 'upgrade_required', model: model_override.presence || model }, status: :forbidden
          end

          # Source entitlement, before any reservation or provider call.
          denied_source = denied_pro_source(current_user, source, @selected_sources)
          if denied_source
            return render json: source_requires_pro_payload(denied_source), status: :forbidden
          end

          unless reconcile_browser_chat_billing!(current_user)
            return render json: browser_chat_billing_unavailable_payload, status: :service_unavailable
          end

          unless current_user.has_credits?(credits_to_deduct)
            return render json: {
              error: 'insufficient_credits',
              credits_required: credits_to_deduct,
              credits_available: current_user.credits
            }, status: :payment_required
          end
        end

        # Per-model daily circuit breaker; the shared provider/month budget is
        # enforced separately below (this check was missing from this path).
        if !benchmark_cap_bypass? && LegalChatbotService.model_at_daily_cap?(model)
          return render json: { error: 'model_daily_cap', model: model.to_s }, status: :too_many_requests
        end

        # Application-side provider estimated-spend ceiling (not a cloud billing hard cap)
        if !benchmark_cap_bypass? && LegalChatbotService.provider_at_monthly_cap?(model)
          provider = LegalChatbotService.provider_for_model(model)
          return render json: { error: 'provider_monthly_cap', provider: provider.to_s }, status: :too_many_requests
        end

        # Reserve credits and create the durable ledger row atomically after all
        # access/provider checks and before the LLM call.
        reservation = nil
        unless @service_bypass
          reservation = reserve_browser_chat_credits!(
            current_user,
            amount: credits_to_deduct,
            intelligence: intelligence || 'smart',
            model: model
          )
          unless reservation
            return render json: { error: 'insufficient_credits', credits_required: credits_to_deduct, credits_available: current_user.reload.credits }, status: :payment_required
          end
        end

        begin
          zk_claim = claim_zero_knowledge_chat_revision!(conversation)
        rescue ZeroKnowledgeStateConflict
          refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'zero_knowledge_claim_conflict')
          credits_info = credit_balance_info(current_user, deducted: 0) if reservation
          return render_zero_knowledge_state_conflict(credits_info: credits_info)
        end

        # ZK mode: client provides conversation context (server cannot read stored messages)
        context_override = nil
        if params[:context_messages].is_a?(Array) && params[:context_messages].any?
          context_override = params[:context_messages].map { |m| h = m.permit(:role, :content).to_h; h['role'] = 'user' unless %w[user assistant].include?(h['role']); h }.last(6)
        end
        quality_provenance_before = quality_capture_provenance
        chatbot = LegalChatbotService.new(language: language, conversation: conversation, model: model, domain: request.host, reasoning_effort: reasoning_effort, profile: requested_profile, context_messages_override: context_override, law_numac: params[:law_numac].to_s.presence, include_quality_evidence: quality_evidence_requested?, **mistral_credential_options)

        result = with_benchmark_cap_bypass(benchmark_cap_bypass?) do
          if source == :custom
            chatbot.ask_with_sources(question, sources: @selected_sources)
          else
            chatbot.ask(question, source: source)
          end
        end

        # Keep the reservation open and verify the erasure fence immediately
        # after provider return, before saving history or analytics.
        unless @service_bypass || browser_chat_account_active?(current_user)
          refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'account_fenced')
          rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
          zk_claim = nil
          credits_info = credit_balance_info(current_user, deducted: 0) if reservation
          return render json: browser_chat_account_fenced_payload(credits_info: credits_info), status: :forbidden
        end

        attach_execution_metadata(
          result,
          model: model,
          intelligence: intelligence,
          language: language,
          reasoning_effort_used: reasoning_effort_used
        )
        attach_quality_capture_metadata(result, expected_provenance: quality_provenance_before)

        if result[:error] && zk_claim
          rollback_zero_knowledge_chat_revision!(conversation, zk_claim)
          zk_claim = nil
        end


        # Re-check the claimed tuple after the provider returns. A concurrent
        # clear/revoke request is the winning operation if it has already
        # fenced the lease, so the undeliverable answer must be refunded.
        if !result[:error] && zk_claim && !conversation_claim_owned?(zk_claim)
          refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'zero_knowledge_claim_lost')
          credits_info = credit_balance_info(current_user, deducted: 0) if reservation
          zk_claim = nil
          return render_zero_knowledge_state_conflict(credits_info: credits_info)
        end

        if reservation && !result[:error]
          billing_delivery_token = begin_browser_chat_delivery!(reservation)
          billing_delivery_abort_allowed = true
        end

        # Synchronous call - token usage is on this thread
        token_info = Thread.current[:last_chat_tokens] || {}

        # Save standard history under the claimed revision. ZK conversations
        # remain client-managed and retain their lease for encrypted PATCH.
        unless conversation&.zero_knowledge?
          begin
            saved_delivery_receipt = save_to_conversation(conversation, question, result, claim: zk_claim)
          rescue ConversationPersistenceError => e
            conversation_persistence_outcome = e.outcome
            raise
          end
          conversation_delivery_receipt = saved_delivery_receipt if reservation && !result[:error]
          billing_delivery_abort_allowed = false if conversation_delivery_receipt
          zk_claim = nil
        end
        attach_conversation_state(result, conversation, zk_claim: zk_claim)

        analytic = log_analytic(
          question,
          result,
          language,
          source,
          conversation,
          model: model,
          credits: 0,
          token_info: token_info,
          billing_reservation_token: reservation&.reservation_token,
          generation_trace: generation_trace_for(chatbot),
          reasoning_effort_requested: requested_reasoning_effort,
          provider_calls: provider_calls_for(chatbot)
        )
        result[:analytic_id] = analytic&.id
        attach_rating_token(result, analytic)

        # Error/timeout/safety results are refunded before rendering. Successful
        # results remain reserved through render. Durable standard history is
        # already accepted value; ZK/no-history may still abort on proven failure.
        if reservation
          if result[:error]
            refund_browser_chat_reservation!(reservation, analytic: analytic, reason: 'provider_result_error')
            result[:credits_info] = credit_balance_info(current_user, deducted: 0)
          else
            result[:credits_info] = credit_balance_info(
              current_user,
              deducted: credits_to_deduct,
              intelligence: intelligence
            )
          end
        end

        if token_info[:input].to_i.positive? || token_info[:output].to_i.positive?
          result[:token_usage] = {
            input: token_info[:input] || 0,
            output: token_info[:output] || 0,
            total: (token_info[:input] || 0) + (token_info[:output] || 0)
          }
        end

        render json: result
        answer_delivery_accepted = true unless result[:error]
        billing_delivery_abort_allowed = false unless result[:error]
        settle_browser_chat_reservation!(reservation, delivery_token: billing_delivery_token) unless result[:error]
        conversation_delivery_receipt = nil unless result[:error]
        project_browser_chat_analytic!(reservation, analytic) if reservation && !result[:error]
        zk_claim = nil # render accepted the answer; the client owns this revision
        keep_new_conversation = true unless result[:error]
      end
    rescue ArgumentError => e
      terminate_chatbot_query_thread(query_thread)
      rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
      if reservation
        billing_resolution = resolve_failed_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          conversation: conversation,
          delivery_receipt: conversation_delivery_receipt,
          persistence_outcome: conversation_persistence_outcome,
          delivery_accepted: answer_delivery_accepted,
          delivery_token: billing_delivery_token,
          delivery_abort_allowed: billing_delivery_abort_allowed,
          user: streaming_user || current_user,
          reason: 'invalid_request'
        )
        failure_credits_info = billing_resolution[:credits_info]
        keep_new_conversation = true if billing_resolution[:outcome] == :settled
      end
      # FBL-044: the raw ArgumentError text reaches neither the client (it
      # names internals) nor the log (the privacy-logging guard forbids
      # exception MESSAGES here - they can echo the user's legal question).
      Rails.logger.error("Chatbot ask rejected: #{e.class}")
      if response.committed?
        response.stream.write("data: #{JSON.generate({ type: 'error', error: 'bad_request', credits_info: failure_credits_info })}\n\n") rescue nil
        response.stream.close rescue nil
      else
        render json: { error: 'bad_request', credits_info: failure_credits_info }, status: :bad_request
      end
    rescue LegalChatbot::ModelsConfig::BudgetLimitExceeded => e
      terminate_chatbot_query_thread(query_thread)
      rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
      if reservation
        billing_resolution = resolve_failed_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          conversation: conversation,
          delivery_receipt: conversation_delivery_receipt,
          persistence_outcome: conversation_persistence_outcome,
          delivery_accepted: answer_delivery_accepted,
          delivery_token: billing_delivery_token,
          delivery_abort_allowed: billing_delivery_abort_allowed,
          user: streaming_user || current_user,
          reason: 'provider_budget_rejected'
        )
        failure_credits_info = billing_resolution[:credits_info]
        keep_new_conversation = true if billing_resolution[:outcome] == :settled
      end
      render_chatbot_budget_limit(e, credits_info: failure_credits_info)
    rescue StandardError => e
      terminate_chatbot_query_thread(query_thread)
      rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
      if reservation
        billing_resolution = resolve_failed_browser_chat_delivery!(
          reservation,
          analytic: analytic,
          conversation: conversation,
          delivery_receipt: conversation_delivery_receipt,
          persistence_outcome: conversation_persistence_outcome,
          delivery_accepted: answer_delivery_accepted,
          delivery_token: billing_delivery_token,
          delivery_abort_allowed: billing_delivery_abort_allowed,
          user: streaming_user || current_user,
          reason: "request_exception_#{e.class.name}"
        )
        failure_credits_info = billing_resolution[:credits_info]
        keep_new_conversation = true if billing_resolution[:outcome] == :settled
      end
      Rails.logger.error("Chatbot controller error: #{e.class}")
      Rails.logger.error(e.backtrace&.first(5)&.join("\n")) if e.backtrace
      if answer_delivery_accepted && billing_resolution&.dig(:outcome) == :settled
        # The successful result body/event was already accepted before the
        # post-delivery accounting exception. Retrying settlement above is the
        # only safe recovery; emitting a second JSON body/SSE error would either
        # double-render or tell the client that a delivered, charged answer
        # failed. Closing an SSE stream is best-effort at this point.
        response.stream.close rescue nil if stream
        return
      end
      if response.committed?
        # Stream already open - send error as SSE event so client sees it
        response.stream.write("data: #{JSON.generate({ type: 'error', error: 'server_error', message: 'Er is een fout opgetreden. Probeer opnieuw.', credits_info: failure_credits_info })}\n\n") rescue nil
        response.stream.close rescue nil
      else
        render json: { error: 'Internal server error', credits_info: failure_credits_info }, status: :internal_server_error
      end
    ensure
      if new_conversation_for_request && !keep_new_conversation
        cleanup_uncommitted_chat_conversation!(conversation)
      end
    end

    # GET /api/chatbot/health
    # Public health is deliberately minimal (FBL-044): corpus counts and
    # index details are reconnaissance material. Host-local monitors (the
    # freshness checks curl 127.0.0.1 directly, bypassing nginx) still get
    # the full payload.
    def health
      unless request.local?
        return render json: { status: 'ok', ready: chatbot_health_faiss_status.fetch(:available, false) }
      end

      faiss_status = chatbot_health_faiss_status
      render json: {
        status: 'ok',
        version: '1.0',
        articles_count: Article.count,
        faiss: faiss_status,
        faiss_index_exists: faiss_status.fetch(:available),
        faiss_index_size: faiss_status.fetch(:index_size_mb)
      }
    end

    # POST /api/chatbot/feedback
    # Store user feedback on chatbot answers (GDPR: no question/answer text stored)
    def feedback
      ChatbotFeedback.ensure_table_exists

      feedback = ChatbotFeedback.new(
        feedback_type: params[:feedback_type],
        language: params[:language],
        source: params[:source],
        user: current_user,
        ip_hash: Digest::SHA256.hexdigest("#{request.remote_ip}#{Rails.application.secret_key_base}")
      )

      if feedback.save
        # Also update the linked ChatbotAnalytic record if analytic_id provided.
        # Ownership check: analytic ids are sequential, so without it anyone
        # could flip the satisfaction rating on other users' query records.
        if params[:analytic_id].present?
          ChatbotAnalytic.ensure_table_exists
          analytic = ChatbotAnalytic.find_by(id: params[:analytic_id])
          owner_ok = analytic && if analytic.user_id.present?
                                   analytic.user_id == current_user&.id
                                 else
                                   analytic.ip_hash == Digest::SHA256.hexdigest("#{request.remote_ip}#{Rails.application.secret_key_base}")
                                 end
          analytic.update(feedback_type: params[:feedback_type]) if owner_ok
        end
        render json: { success: true }
      else
        render json: { error: feedback.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # POST /api/chatbot/report
    # User-initiated report of a failed/bad chatbot answer.
    # GDPR: This endpoint intentionally stores question+answer text.
    # The user must explicitly consent via a confirm dialog in the frontend.
    # Rate-limited to 10 reports per user per day.
    def report
      # Must be logged in
      unless current_user
        lang = params[:language].to_s
        return render json: {
          error: case lang when 'fr' then 'Authentification requise' when 'de' then 'Authentifizierung erforderlich' when 'en' then 'Authentication required' else 'Authenticatie vereist' end
        }, status: :unauthorized
      end

      ChatbotReport.ensure_table_exists

      # Rate limit: max 10 reports per user per day
      today_count = ChatbotReport.where(user_id: current_user.id)
                                 .where('created_at >= ?', Time.current.beginning_of_day)
                                 .count
      return render json: { error: 'Daily report limit reached (max 10)' }, status: :too_many_requests if today_count >= 10

      question = params[:question].to_s.strip
      return render json: { error: 'Question text is required' }, status: :unprocessable_entity if question.blank?

      report = ChatbotReport.new(
        question: question,
        answer: params[:answer].to_s.strip.presence,
        language: params[:language],
        source: params[:source],
        intelligence: params[:intelligence],
        user: current_user,
        analytic_id: params[:analytic_id],
        status: 'pending'
      )

      if report.save
        Rails.logger.info("[REPORT] Chatbot report ##{report.id} by user #{current_user.id}")
        render json: { success: true, report_id: report.id }
      else
        render json: { error: report.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # GET /api/chatbot/cost_dashboard
    # Admin-only cost monitoring dashboard (service auth or admin user required)
    def cost_dashboard
      return render json: { error: 'Admin access required' }, status: :forbidden unless @service_bypass || current_user&.admin?

      ChatbotAnalytic.ensure_table_exists
      ChatbotAnalytic.ensure_cost_columns!

      period = (params[:period] || 'month').to_sym

      render json: {
        cost_stats: ChatbotAnalytic.cost_stats(period: period),
        daily_model_usage: LegalChatbotService.model_daily_usage,
        rate_limits: {
          daily_global: DAILY_GLOBAL_LIMIT,
          hourly_global: HOURLY_GLOBAL_LIMIT,
          monthly_global: MONTHLY_GLOBAL_LIMIT
        },
        model_daily_caps: LegalChatbotService::MODEL_DAILY_CAPS,
        current_counters: {
          # Keys must match what rate_limit_check increments — the old
          # "chatbot_global:*" names never existed, so the dashboard showed 0
          daily: Rails.cache.read('chatbot_daily_global') || 0,
          hourly: Rails.cache.read("chatbot_hourly_global:#{Time.current.strftime('%Y-%m-%d-%H')}") || 0,
          monthly: Rails.cache.read("chatbot_monthly_global:#{Time.current.strftime('%Y-%m')}") || 0
        }
      }
    end

    # POST /api/chatbot/deep_analysis
    # "Diepere Analyse" - re-analyzes a standard answer with any model
    # Accepts: question, original_answer, language, source, pass, deep_model
    # Returns: deeper analysis with structured legal reasoning
    # Multi-provider deep analysis models (June 2026)
    # Credit costs aligned with INTELLIGENCE_LEVELS tier costs.
    # Provider routing handled automatically via ModelsConfig::AVAILABLE_MODELS.
    #
    # ✅ AUTO-DERIVED from INTELLIGENCE_LEVELS - no manual sync needed.
    # When models change in models_config.rb, this constant auto-updates.
    #
    # Label overrides for models that need localized suffixes.
    # Everything else gets "{name}" or "{name} (EU/UE)" for Mistral models.
    DEEP_LABEL_OVERRIDES = {
      'gpt-5.6-luna' => { label_nl: 'GPT-5.6 Luna Redeneermodel', label_fr: 'Modèle de raisonnement GPT-5.6 Luna', label_en: 'GPT-5.6 Luna Reasoning Model' },
      'gpt-5' => { label_nl: 'GPT-5 Premium', label_fr: 'GPT-5 Premium', label_en: 'GPT-5 Premium' }
    }.freeze

    DEEP_ANALYSIS_MODELS = LegalChatbot::ModelsConfig::INTELLIGENCE_LEVELS.each_with_object({}) do |(_tier, level), hash|
      level[:models].each do |model_id, model_cfg|
        credit_cost = model_cfg[:credits] || level[:credits]
        available = LegalChatbot::ModelsConfig::AVAILABLE_MODELS[model_id]
        next unless available # model must exist in AVAILABLE_MODELS
        next if available[:deployed] == false # skip undeployed models

        # Labels: use override if present, otherwise auto-generate from name + provider
        if DEEP_LABEL_OVERRIDES.key?(model_id)
          labels = DEEP_LABEL_OVERRIDES[model_id]
        else
          name = model_cfg[:name]
          # Only Mistral gets (EU/UE) suffix - EU-native provider, key selling point.
          # Azure/Bedrock are US companies with EU regions - suffix would be misleading.
          labels = if available[:provider] == :mistral
                     { label_nl: "#{name} (EU)", label_fr: "#{name} (UE)", label_en: "#{name} (EU)" }
                   else
                     { label_nl: name, label_fr: name, label_en: name }
                   end
        end

        hash[model_id] = { credit_cost: credit_cost, coming_soon: (available[:deployed] == false) }.merge(labels)
      end
    end.freeze

    def deep_analysis
      # The public UI no longer exposes this legacy second-pass endpoint. Its
      # zero-knowledge flow could not make a paid response durable atomically:
      # a browser crash after delivery but before the encrypted snapshot PATCH
      # could leave the user charged with no saved answer. Keep the route as a
      # compatibility tombstone so stale clients fail safely without consuming
      # access/rate-limit counters, credits, or provider budget. The separately
      # authenticated service endpoint is unaffected.
      return render json: {
        error: 'deep_analysis_retired',
        message: 'Public deep analysis is no longer available.'
      }, status: :gone unless public_deep_analysis_available?

      analytic = nil
      reservation = nil
      conversation = nil
      zk_claim = nil
      new_conversation_for_request = false
      keep_new_conversation = false
      question = params[:question]&.strip
      original_answer = params[:original_answer]&.strip
      language = params[:language] || 'nl'
      source = (params[:source] || 'legislation').to_sym
      deep_model = params[:deep_model] || 'gpt-5.6-luna'

      return render json: { error: 'Question is required' }, status: :bad_request if question.blank?
      return render json: { error: 'Original answer is required' }, status: :bad_request if original_answer.blank?

      # Validate deep_model
      unless DEEP_ANALYSIS_MODELS.key?(deep_model)
        return render json: { error: "Invalid model. Choose: #{DEEP_ANALYSIS_MODELS.keys.join(', ')}" }, status: :bad_request
      end

      # Guard: coming soon models
      if DEEP_ANALYSIS_MODELS[deep_model][:coming_soon]
        return render json: {
          error: language == 'fr' ? 'Ce modèle sera bientôt disponible.' : 'Dit model is binnenkort beschikbaar.'
        }, status: :service_unavailable
      end

      model_config = DEEP_ANALYSIS_MODELS[deep_model]
      credit_cost = model_config[:credit_cost]

      # Deep analysis is another way to invoke the selected model, not a tier
      # bypass. Apply the exact model authorization used by normal chat before
      # reserving credits or constructing a provider client. Signed service
      # requests retain their narrowly-scoped account bypass.
      unless @service_bypass
        user_tier = current_user&.current_tier || :free
        unless LegalChatbotService.model_allowed?(deep_model, user_tier)
          return render json: { error: 'upgrade_required', model: deep_model }, status: :forbidden
        end

        # Deep analysis re-queries the same corpus, so it carries the same
        # source entitlement as a normal question.
        denied_source = denied_pro_source(current_user, source, [source])
        if denied_source
          return render json: source_requires_pro_payload(denied_source), status: :forbidden
        end
      end

      # Consented deep analyses participate in the same conversation protocol
      # as normal answers. Without consent this deliberately returns nil, so the
      # result remains browser-only and no server history row is created.
      begin
        conversation = find_or_create_conversation(params[:conversation_id]&.strip, language)
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end
      new_conversation_for_request = conversation&.instance_variable_get(:@created_for_chat_request) == true
      return unless validate_zero_knowledge_chat_state!(conversation)

      # Check per-model daily cap (always enforced, even for admin)
      if LegalChatbotService.model_at_daily_cap?(deep_model)
        return render json: {
          error: if language == 'fr'
                   "Limite quotidienne pour #{model_config[:label_fr]} atteinte."
                 else
                   "Dagelijks limiet voor #{model_config[:label_nl]} bereikt."
                 end,
          daily_cap: LegalChatbotService.daily_cap_for(deep_model)
        }, status: :too_many_requests
      end

      # Application-side provider estimated-spend ceiling (€50/provider)
      if LegalChatbotService.provider_at_monthly_cap?(deep_model)
        provider = LegalChatbotService.provider_for_model(deep_model)
        return render json: {
          error: if language == 'fr'
                   "Le budget mensuel pour #{provider} est épuisé."
                 else
                   "Het maandbudget voor #{provider} is bereikt."
                 end,
          code: 'provider_monthly_cap',
          provider: provider.to_s
        }, status: :too_many_requests
      end

      # Credit check - service auth bypasses, regular users need credits
      unless @service_bypass
        if current_user
          unless current_user.has_credits?(credit_cost)
            return render json: {
              error: if language == 'fr'
                       "Crédits insuffisants pour l'analyse approfondie (#{credit_cost} crédits requis)."
                     else
                       "Onvoldoende credits voor diepere analyse (#{credit_cost} credits vereist)."
                     end,
              credits_required: credit_cost,
              credits_available: current_user.credits
            }, status: :payment_required
          end
        else
          return render json: {
            error: if language == 'fr'
                     'Connectez-vous pour utiliser l\'analyse approfondie.'
                   else
                     'Log in om diepere analyse te gebruiken.'
                   end,
            login_required: true
          }, status: :unauthorized
        end
      end

      # Reserve credits up-front (atomic guarded UPDATE), after all caps/credit
      # checks and before the LLM call — closes the concurrent free-answer TOCTOU.
      # Refunded on error/exception below.
      unless @service_bypass
        reservation = current_user.deduct_credits_with_priority!(credit_cost, intelligence: 'genius')
        unless reservation
          return render json: {
            error: language == 'fr' ? "Crédits insuffisants pour l'analyse approfondie (#{credit_cost} crédits requis)." : "Onvoldoende credits voor diepere analyse (#{credit_cost} credits vereist).",
            credits_required: credit_cost,
            credits_available: current_user.reload.credits
          }, status: :payment_required
        end
      end

      begin
        zk_claim = claim_zero_knowledge_chat_revision!(conversation)
      rescue ZeroKnowledgeStateConflict
        current_user&.add_credits!(credit_cost) if reservation
        credits_info = credit_balance_info(current_user, deducted: 0) if reservation
        reservation = nil
        return render_zero_knowledge_state_conflict(credits_info: credits_info)
      end

      # Build the deep analysis prompt
      deep_prompt = build_deep_analysis_prompt(question, original_answer, language)

      # Use the selected premium model
      chatbot = LegalChatbotService.new(
        language: language,
        model: deep_model,
        domain: request.host,
        **mistral_credential_options
      )

      # Ask with the enhanced prompt - use the same source for RAG context
      # Deep prompts are long (question + answer + instructions) so use higher limit
      result = chatbot.ask(deep_prompt, source: source, max_length: LegalChatbotService::DEEP_ANALYSIS_MAX_LENGTH)

      if result[:error] && zk_claim
        rollback_zero_knowledge_chat_revision!(conversation, zk_claim)
        zk_claim = nil
      end

      # Clear, consent revocation, and another tab taking this revision are
      # cancellation fences. The losing provider request is never delivered or
      # charged, and clearing `reservation` makes the refund exact-once.
      if !result[:error] && zk_claim && !conversation_claim_owned?(zk_claim)
        current_user&.add_credits!(credit_cost) if reservation
        credits_info = credit_balance_info(current_user, deducted: 0) if reservation
        reservation = nil
        zk_claim = nil
        return render_zero_knowledge_state_conflict(credits_info: credits_info)
      end

      # Standard history consumes the lease in one optimistic-lock append. ZK
      # history keeps the lease until the browser encrypts and PATCHes the full
      # snapshot using the tuple attached below.
      if !result[:error] && conversation && !conversation.zero_knowledge?
        save_deep_analysis_to_conversation(
          conversation,
          question,
          original_answer,
          result,
          model: deep_model,
          claim: zk_claim
        )
        zk_claim = nil
      end
      attach_conversation_state(result, conversation, zk_claim: zk_claim)

      # Credits were reserved up-front. Refund on error/timeout; otherwise report
      # the charge from the reservation. A raced request never reaches here.
      charged = false
      if reservation
        if result[:error]
          current_user.add_credits!(credit_cost)
          result[:credits_info] = credit_balance_info(current_user, deducted: 0)
          reservation = nil # settled (refunded) — the method-level rescue won't refund again
        else
          charged = true
          result[:credits_info] = credit_balance_info(
            current_user,
            deducted: credit_cost,
            model: deep_model
          )
        end
      end

      # Tag the result
      result[:deep_analysis] = true
      result[:model_used] = deep_model

      # Log analytics (record only credits actually charged)
      analytic = log_analytic(deep_prompt, result, language, source, conversation, model: deep_model, credits: charged ? credit_cost : 0)
      result[:analytic_id] = analytic&.id

      render json: result
      reservation = nil # delivery accepted; the charge stands
      zk_claim = nil # a ZK browser now owns the returned lease tuple
      keep_new_conversation = true unless result[:error]
    rescue LegalChatbot::ModelsConfig::BudgetLimitExceeded => e
      rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
      if reservation && !@service_bypass
        current_user.add_credits!(credit_cost)
        refunded_credits_info = credit_balance_info(current_user, deducted: 0)
        mark_analytic_refunded!(analytic)
      end
      render_chatbot_budget_limit(e, credits_info: refunded_credits_info)
    rescue StandardError => e
      rollback_zero_knowledge_chat_revision!(conversation, zk_claim) if zk_claim
      # Refund any reserved credits — the analysis failed before delivery.
      if reservation && !@service_bypass
        current_user.add_credits!(credit_cost)
        refunded_credits_info = credit_balance_info(current_user, deducted: 0)
        mark_analytic_refunded!(analytic)
      end
      Rails.logger.error("Deep analysis error [#{e.class}]\n#{e.backtrace&.first(5)&.join("\n")}")
      render json: {
        error: 'Deep analysis failed. Please try again.',
        credits_info: refunded_credits_info
      }, status: :internal_server_error
    ensure
      if new_conversation_for_request && !keep_new_conversation
        cleanup_uncommitted_chat_conversation!(conversation)
      end
    end

    # Receives client-side timing reports when a query exceeds the estimated time.
    # Fire-and-forget - always returns 200 OK.
    def log_slow_query
      data = params.permit(:model, :intelligence, :reasoning, :sources,
                           :elapsed_seconds, :estimated_seconds, :overage_seconds, :language)

      user_info = current_user ? "user=#{current_user.id}" : 'service'
      Rails.logger.warn(
        "[SLOW QUERY] #{user_info} | " \
        "model=#{data[:model]} intelligence=#{data[:intelligence]} reasoning=#{data[:reasoning]} | " \
        "sources=#{data[:sources]} lang=#{data[:language]} | " \
        "elapsed=#{data[:elapsed_seconds]}s estimated=#{data[:estimated_seconds]}s " \
        "overage=+#{data[:overage_seconds]}s"
      )

      head :ok
    end

    private

    # Source entitlement (owner decision 2026-09-04): via the chatbot,
    # legislation is open to every account with credits, while case law and
    # parliamentary documents are Pro-only. Browsing either database on the
    # site stays public and is unaffected.
    #
    # This path had NO source gate at all before: only the HTML controller
    # checked can_access_source?, and the JS UI talks to this API, so the
    # entitlement was decorative. Both branches below call this BEFORE any
    # billing reservation, credit deduction or provider call.
    #
    # Returns the first source the user may not use, or nil when allowed.
    def denied_pro_source(user, source, selected_sources)
      return nil unless user

      candidates = if %i[all custom].include?(source.to_sym)
                     Array(selected_sources)
                   else
                     [source]
                   end

      candidates.compact.map(&:to_sym).uniq.find { |candidate| !user.can_access_source?(candidate) }
    end

    def source_requires_pro_payload(denied_source)
      message_key = denied_source == :parliamentary ? 'chatbot.parliamentary_paid_only' : 'chatbot.jurisprudence_paid_only'

      {
        error: I18n.t(message_key),
        error_code: 'source_requires_pro',
        source: denied_source.to_s
      }
    end

    def chatbot_health_faiss_status
      enabled = ENV.fetch('LEGISLATION_FAISS_ENABLED', nil) == 'true'
      return { enabled: false, available: false, index_size_mb: nil } unless enabled

      deployment = ChatbotQualityProvenance.main_embedding_deployment
      service = chatbot_health_faiss_service
      index_file = deployment.fetch(:files).find { |file| file.fetch(:role) == 'index' }
      generation = deployment.fetch(:generation)
      available = service.fetch('status', nil) == 'ok' &&
                  service.fetch('generation', generation) == generation &&
                  service.fetch('index_size', nil).to_i.positive?

      {
        enabled: true,
        available: available,
        generation: generation,
        service_status: service.fetch('status', nil),
        vectors: service.fetch('index_size', nil),
        index_size_mb: index_file ? (index_file.fetch(:size) / 1_048_576.0).round(1) : nil
      }
    rescue ChatbotQualityProvenance::Unavailable => e
      { enabled: enabled, available: false, error: e.message, index_size_mb: nil }
    rescue StandardError => e
      Rails.logger.warn("Chatbot health FAISS check unavailable: #{e.class}")
      { enabled: enabled, available: false, error: 'faiss_unavailable', index_size_mb: nil }
    end

    def chatbot_health_faiss_service
      base_url = ENV.fetch('FAISS_LARGE_URL', 'http://127.0.0.1:8767').sub(%r{/\z}, '')
      uri = URI("#{base_url}/health")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 1, read_timeout: 2) do |http|
        response = http.get(uri.request_uri)
        return {} unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    rescue JSON::ParserError
      {}
    end

    # Deliberately code-owned rather than environment-controlled: re-enabling
    # the legacy paid flow requires a reviewed durable-delivery protocol, its
    # access/rate-limit callbacks, and browser tests in the same change.
    def public_deep_analysis_available?
      false
    end

    def render_chatbot_budget_limit(error, credits_info: nil)
      code = chatbot_budget_error_code(error)
      payload = {
        type: 'error',
        error: code,
        code: code,
        model: error.model,
        provider: error.provider&.to_s,
        credits_info: credits_info
      }.compact

      if response.committed?
        response.stream.write("data: #{JSON.generate(payload)}\n\n")
        response.stream.close
      else
        render json: payload.except(:type), status: :too_many_requests
      end
    rescue IOError, ActionController::Live::ClientDisconnected
      response.stream.close rescue nil
    end

    def chatbot_budget_error_code(error)
      reason = error.reason.to_s
      return 'model_daily_cap' if reason.start_with?('model_daily')
      return 'provider_monthly_cap' if reason.start_with?('provider_monthly')

      'provider_budget_unavailable'
    end

    def effective_request_language(requested_language, host:)
      requested = requested_language.to_s.downcase
      supported = %w[nl fr]

      return requested if @service_bypass && supported.include?(requested)

      normalized_host = host.to_s.downcase
      return 'fr' if normalized_host.include?('lisloi')
      return 'fr' if normalized_host.include?('gesetzguide') # DE UI, FR legal corpus
      return supported.include?(requested) ? requested : 'nl' if normalized_host.include?('lexlibera')

      'nl'
    end

    def attach_execution_metadata(result, model:, intelligence:, language:, reasoning_effort_used:)
      result[:model_used] ||= model
      result[:intelligence] ||= intelligence
      result[:language] ||= language
      result[:reasoning_effort_used] ||= reasoning_effort_used
      result
    end


    def build_deep_analysis_prompt(question, original_answer, language)
      if language == 'fr'
        <<~PROMPT
          Un utilisateur a posé la question juridique suivante et a reçu une réponse standard.
          Effectuez une analyse juridique approfondie en utilisant un raisonnement multi-étapes.

          QUESTION ORIGINALE: #{question}

          RÉPONSE STANDARD: #{original_answer}

          Fournissez une analyse approfondie structurée comme suit:
          ## 1. Règle principale
          Identifiez la disposition légale centrale avec la référence exacte de l'article.

          ## 2. Exceptions et nuances
          Listez toutes les exceptions, cas particuliers et dispositions transitoires.

          ## 3. Jurisprudence pertinente
          Citez la jurisprudence récente qui clarifie ou modifie la règle.

          ## 4. Évolutions récentes
          Mentionnez les modifications législatives récentes ou projets de loi pertinents.

          ## 5. Conseils pratiques
          Formulez des recommandations concrètes basées sur l'analyse.

          Répondez en français. Citez les articles de loi exacts. Soyez exhaustif mais structuré.
        PROMPT
      else
        <<~PROMPT
          Een gebruiker stelde de volgende juridische vraag en ontving een standaard antwoord.
          Voer een diepgaande juridische analyse uit met meerstapsredenering.

          ORIGINELE VRAAG: #{question}

          STANDAARD ANTWOORD: #{original_answer}

          Geef een gestructureerde diepere analyse volgens dit format:
          ## 1. Hoofdregel
          Identificeer de centrale wettelijke bepaling met exact wetsartikel.

          ## 2. Uitzonderingen en nuances
          Lijst alle uitzonderingen, bijzondere gevallen en overgangsbepalingen op.

          ## 3. Relevante rechtspraak
          Citeer recente rechtspraak die de regel verduidelijkt of nuanceert.

          ## 4. Recente ontwikkelingen
          Vermeld recente wetswijzigingen of relevante wetsvoorstellen.

          ## 5. Praktisch advies
          Formuleer concrete aanbevelingen op basis van de analyse.

          Antwoord in het Nederlands. Citeer exacte wetsartikelen. Wees grondig maar gestructureerd.
        PROMPT
      end
    end

    def rate_limit_check
      # Service-authenticated requests (HMAC) - separate daily limit
      if @service_bypass
        service_daily_key = "chatbot_daily_service:#{@service_app}"
        count = atomic_increment(service_daily_key, expires_in: seconds_until_midnight_utc.seconds)
        if count > SERVICE_DAILY_LIMIT
          render json: {
            error: "Service daily limit reached (#{SERVICE_DAILY_LIMIT}/day). Resets at midnight UTC.",
            retry_after: seconds_until_midnight_utc
          }, status: :too_many_requests
          return false
        end
        return true
      end

      ip = request.remote_ip

      # ── Per-IP rate limits FIRST (tier-aware) ──────────────────────
      # These run BEFORE the global cost caps below: a request rejected by a
      # per-IP limit never reaches the LLM, so it must NOT consume the shared
      # global budget — otherwise one IP could exhaust the global caps with
      # cheap, rejected requests and 429 every other user.
      # Expensive models (Level III/IV) get stricter per-IP limits to prevent
      # cost abuse, while cheap models (Level I/II) stay generous.
      # deep_analysis always counts as premium since it uses reasoning models.
      is_premium = premium_model_request?

      if is_premium
        # Premium models: stricter limits (GPT-5, Sonnet 4, GPT-5.6 Terra,
        # Opus 4, GPT-5.6 Sol)
        premium_burst_key = "chatbot_burst_premium:#{ip}"
        premium_burst = atomic_increment(premium_burst_key, expires_in: 1.minute)
        if premium_burst > PER_IP_PREMIUM_BURST_LIMIT
          render json: {
            error: 'Premium model rate limit. Please wait a minute or use a faster model.',
            retry_after: 60
          }, status: :too_many_requests
          return false
        end

        premium_hourly_key = "chatbot_hourly_premium:#{ip}"
        premium_hourly = atomic_increment(premium_hourly_key, expires_in: 1.hour)
        if premium_hourly > PER_IP_PREMIUM_HOURLY_LIMIT
          render json: {
            error: "Premium model hourly limit reached (#{PER_IP_PREMIUM_HOURLY_LIMIT}/hr). Use Slim or Geniaal for more questions.",
            retry_after: 3600
          }, status: :too_many_requests
          return false
        end
      end

      # All models: general per-IP burst and hourly
      burst_key = "chatbot_burst:#{ip}"
      burst_count = atomic_increment(burst_key, expires_in: 1.minute)
      if burst_count > PER_IP_BURST_LIMIT
        render json: {
          error: 'Too many requests. Please wait a minute.',
          retry_after: 60
        }, status: :too_many_requests
        return false
      end

      hourly_key = "chatbot_hourly:#{ip}"
      hourly_count = atomic_increment(hourly_key, expires_in: 1.hour)
      if hourly_count > PER_IP_HOURLY_LIMIT
        render json: {
          error: "Rate limit exceeded. Maximum #{PER_IP_HOURLY_LIMIT} requests per hour.",
          retry_after: 3600
        }, status: :too_many_requests
        return false
      end

      # ── Global cost caps ───────────────────────────────────────────
      # Only reached after the per-IP gates pass, i.e. requests that will
      # actually hit the LLM. Incrementing these here (not up-front) keeps a
      # per-IP-throttled flood from burning the shared budget.
      # MONTHLY BUDGET CAP - hard limit on total API calls
      monthly_key = "chatbot_monthly_global:#{Time.current.strftime('%Y-%m')}"
      monthly_count = atomic_increment(monthly_key, expires_in: 32.days)
      if monthly_count > MONTHLY_GLOBAL_LIMIT
        Rails.logger.error({ event: 'monthly_limit_reached', count: monthly_count }.to_json)
        render json: {
          error: 'Monthly API limit reached. Service will reset next month.',
          limit_type: 'monthly_budget'
        }, status: :too_many_requests
        return false
      end

      # HOURLY SPIKE PROTECTION - prevents sudden attack costs
      hourly_global_key = "chatbot_hourly_global:#{Time.current.strftime('%Y-%m-%d-%H')}"
      hourly_global_count = atomic_increment(hourly_global_key, expires_in: 1.hour)
      if hourly_global_count > HOURLY_GLOBAL_LIMIT
        render json: {
          error: 'Hourly API limit reached. Please try again in an hour.',
          retry_after: 3600
        }, status: :too_many_requests
        return false
      end

      # Global daily limit
      daily_key = 'chatbot_daily_global'
      daily_count = atomic_increment(daily_key, expires_in: seconds_until_midnight_utc.seconds)
      if daily_count > DAILY_GLOBAL_LIMIT
        render json: {
          error: 'Daily API limit reached. Service will reset at midnight UTC.',
          retry_after: seconds_until_midnight_utc
        }, status: :too_many_requests
        return false
      end

      # Check and send alerts (async, non-blocking)
      check_and_send_usage_alerts(monthly_count, hourly_global_count)

      true
    end

    # Detect if the current request targets a premium (expensive) model.
    # Level III (mastermind): GPT-5, Sonnet 4, GPT-5.6 Terra — €0.05-0.09/query
    # Level IV (omniscient): Opus 4, GPT-5.6 Sol — €0.13-0.17/query
    # deep_analysis: always premium (uses reasoning models)
    PREMIUM_INTELLIGENCE_LEVELS = %w[mastermind omniscient].freeze
    PREMIUM_MODELS = %w[gpt-5 gpt-5.6-terra gpt-5.6-sol claude-sonnet-4-6 claude-opus-4-6].freeze

    def premium_model_request?
      return true if action_name == 'deep_analysis'

      intelligence = params[:intelligence].to_s
      return true if PREMIUM_INTELLIGENCE_LEVELS.include?(intelligence)

      model = params[:model].to_s
      return true if PREMIUM_MODELS.include?(model)

      false
    end

    # Atomic increment - avoids TOCTOU race conditions in rate limiting.
    # Fixed-window keys are required for FileStore: its increment operation
    # does not preserve a TTL previously assigned with write.
    def atomic_increment(key, expires_in:)
      window_seconds = expires_in.to_i
      windowed_key = self.class.windowed_rate_limit_key(key, expires_in: window_seconds)
      cleanup_ttl = (window_seconds * 2).seconds

      Rails.cache.increment(windowed_key, 1, expires_in: cleanup_ttl) ||
        begin
          written = Rails.cache.write(windowed_key, 1, expires_in: cleanup_ttl, unless_exist: true)
          written ? 1 : Rails.cache.increment(windowed_key, 1, expires_in: cleanup_ttl)
        end
    end

    # Send alerts when approaching limits
    def check_and_send_usage_alerts(monthly_count, hourly_count)
      return if Rails.env.test? || Rails.env.development?

      # Monthly alerts: 75%, 90%, and 100%
      monthly_pct = (monthly_count.to_f / MONTHLY_GLOBAL_LIMIT * 100).round
      alert_key = "chatbot_monthly_alert:#{Time.current.strftime('%Y-%m')}"
      last_alert_pct = Rails.cache.read(alert_key) || 0

      if monthly_count >= MONTHLY_GLOBAL_LIMIT && last_alert_pct < 100
        Rails.cache.write(alert_key, 100, expires_in: 32.days)
        AdminAlertMailer.monthly_limit_reached(monthly_count, MONTHLY_GLOBAL_LIMIT).deliver_later
      elsif monthly_pct >= 90 && last_alert_pct < 90
        Rails.cache.write(alert_key, 90, expires_in: 32.days)
        AdminAlertMailer.monthly_limit_warning(monthly_count, MONTHLY_GLOBAL_LIMIT).deliver_later
      elsif monthly_pct >= 75 && last_alert_pct < 75
        Rails.cache.write(alert_key, 75, expires_in: 32.days)
        AdminAlertMailer.monthly_limit_warning(monthly_count, MONTHLY_GLOBAL_LIMIT).deliver_later
      end

      # Hourly spike alert: at 80% of hourly limit
      hourly_alert_key = "chatbot_hourly_alert:#{Time.current.strftime('%Y-%m-%d-%H')}"
      if hourly_count >= (HOURLY_GLOBAL_LIMIT * 0.8).to_i && !Rails.cache.read(hourly_alert_key)
        Rails.cache.write(hourly_alert_key, true, expires_in: 1.hour)
        AdminAlertMailer.hourly_spike_alert(hourly_count, HOURLY_GLOBAL_LIMIT).deliver_later
      end
    rescue StandardError => e
      Rails.logger.error("Failed to send usage alert: #{e.class}")
    end

    def seconds_until_midnight_utc
      now = Time.now.utc
      midnight = (now + 1.day).beginning_of_day
      (midnight - now).to_i
    end

    def check_access
      # 1. HMAC service auth - signed per-request, no user account needed
      if @service_bypass || authenticate_service_request
        @service_bypass = true
        return true
      end

      # 2. Authenticated user with credits/subscription
      if current_user
        return true if current_user.can_use_chatbot?

        # User out of credits
        lang = params[:language].to_s
        if current_user.subscription&.free?
          render json: {
            error: case lang
                   when 'fr' then 'Vos crédits sont épuisés. Achetez des crédits ou passez à Pro pour continuer.'
                   when 'de' then 'Ihre Credits sind aufgebraucht. Kaufen Sie Credits oder wechseln Sie zu Pro.'
                   when 'en' then "You're out of credits. Buy credits or upgrade to Pro to continue."
                   else 'Uw credits zijn op. Koop credits of upgrade naar Pro om verder te gaan.'
                   end,
            credits_exhausted: true,
            buy_credits_url: '/pricing',
            praxis_upsell: case lang
                           when 'fr' then 'Avec Praxis, posez des questions juridiques illimitées. Découvrez Praxis →'
                           when 'de' then 'Mit Praxis stellen Sie unbegrenzt juristische Fragen. Entdecken Sie Praxis →'
                           when 'en' then 'With Praxis, ask unlimited legal questions. Discover Praxis →'
                           else 'Met Praxis stelt u onbeperkt juridische vragen. Ontdek Praxis →'
                           end,
            praxis_url: 'https://praxislegal.be'
          }, status: :payment_required
        else
          render json: {
            error: case lang
                   when 'fr' then "Votre abonnement n'est plus actif. Renouvelez-le pour continuer."
                   when 'de' then 'Ihr Abonnement ist nicht mehr aktiv. Verlängern Sie es, um fortzufahren.'
                   when 'en' then 'Your subscription is no longer active. Renew to continue.'
                   else 'Uw abonnement is niet meer actief. Verleng het om verder te gaan.'
                   end,
            buy_credits_url: '/pricing'
          }, status: :payment_required
        end
        return false
      end

      # 3. No auth at all - require login
      lang = params[:language].to_s
      starter = RegistrationsController::STARTER_CREDITS
      render json: {
        error: case lang
               when 'fr' then "Créez un compte gratuit pour utiliser le chatbot (#{starter} crédits offerts)."
               when 'de' then "Erstellen Sie ein kostenloses Konto, um den Chatbot zu nutzen (#{starter} Credits geschenkt)."
               when 'en' then "Create a free account to use the chatbot (#{starter} starter credits included)."
               else "Maak een gratis account aan om de chatbot te gebruiken (#{starter} startcredits inbegrepen)."
               end,
        login_required: true,
        signup_url: '/signup',
        login_url: '/login'
      }, status: :unauthorized
      false
    end

    # RAT-003. The selected profile is a GENERATION PARAMETER that now gets
    # persisted and folded into the configuration fingerprint, so it can no
    # longer be raw user text: an unvalidated value would put arbitrary input
    # into the analytics database and the admin comparison table, and would
    # fragment the grouping into one bucket per typo. Falls back to the same
    # 'general' default the call sites always used.
    # RAT-003. log_analytic rescues its own failures, but arguments are
    # evaluated BEFORE it is called, so reading the trace here had to be made
    # unfailable in its own right: a service object that does not expose one
    # (an alternative implementation, or a test double) must not turn a
    # delivered answer into a 500. Analytics is never answer authority.
    # RAT-004. One helper for both transports, so JSON and SSE can never drift
    # apart on eligibility or purpose.
    #
    # @service_bypass is THE exclusion for HMAC/service traffic. request_source
    # cannot serve that purpose: log_analytic writes the literal 'web' for
    # every ask, service requests included, so a request_source check would be
    # a guard that can never fire.
    #
    # The field is omitted entirely when unavailable rather than sent as null:
    # its presence IS the browser's signal that a control should render.
    def attach_rating_token(result, analytic)
      return if @service_bypass

      token = ChatbotRating::Token.issue!(analytic)
      result[:rating_token] = token if token.present?
    rescue StandardError => e
      Rails.logger.warn("[ChatbotRating] token not attached: #{e.class}")
    end

    # Unfailable like the trace read beside it: analytics must never be able to
    # turn a delivered answer into an error.
    def provider_calls_for(chatbot)
      return nil unless chatbot.respond_to?(:provider_call_count)

      chatbot.provider_call_count
    rescue StandardError
      nil
    end

    def generation_trace_for(chatbot)
      return nil unless chatbot.respond_to?(:generation_trace)

      chatbot.generation_trace
    rescue StandardError => e
      Rails.logger.warn("[GenerationTrace] unavailable: #{e.class}")
      nil
    end

    def requested_profile
      candidate = params[:profile].to_s.strip
      return 'general' if candidate.blank?

      LegalChatbotService.profile_exists?(candidate) ? candidate : 'general'
    end

    def benchmark_cap_bypass?
      @service_bypass == true &&
        request.headers['X-Benchmark-Run'].to_s == '1' &&
        ENV['CHATBOT_BENCHMARK_CAP_BYPASS'].to_s == '1'
    end

    def with_benchmark_cap_bypass(enabled)
      previous = Thread.current[:chatbot_benchmark_cap_bypass]
      Thread.current[:chatbot_benchmark_cap_bypass] = true if enabled
      yield
    ensure
      Thread.current[:chatbot_benchmark_cap_bypass] = previous
    end



    def credit_balance_info(user, deducted:, **extra)
      return nil unless user

      user.reload
      {
        credits_deducted: deducted,
        credits_remaining: user.total_available_credits,
        balance_version: user.credit_balance_version.to_i,
        event_id: request.request_id
      }.merge(extra)
    end
  end
end
