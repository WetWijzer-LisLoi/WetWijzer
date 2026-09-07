# frozen_string_literal: true

module Api
  # Per-query analytics and quality-capture provenance for the chatbot API.
  # Extracted verbatim from Api::ChatbotController (FBL-060 step 5) as a
  # concern; method names and receiver are unchanged because the white-box
  # suites stub quality_capture_provenance and log_analytic on the controller
  # instance. GDPR by design: analytics rows carry NO question or answer
  # text, only metadata.
  module ChatbotAnalytics
    extend ActiveSupport::Concern

    private

    def quality_evidence_requested?
      @service_bypass == true && %w[1 true yes].include?(params[:quality_evidence].to_s.downcase)
    end

    def quality_capture_provenance
      return unless quality_evidence_requested?

      ChatbotQualityProvenance.snapshot
    end

    def attach_quality_capture_metadata(result, expected_provenance:)
      return result unless quality_evidence_requested?

      observed_provenance = ChatbotQualityProvenance.snapshot
      unless expected_provenance.is_a?(Hash) && observed_provenance == expected_provenance
        raise ChatbotQualityProvenance::Unavailable,
              'quality provenance changed while the answer was being generated'
      end
      result[:quality_provenance] = observed_provenance
      result
    end

    # Persist per-query analytics to the database
    # GDPR by design: NO question text, NO answer text - metadata only
    # token_info: pass explicitly when the LLM ran on another thread —
    # Thread.current only sees this thread's locals.
    def log_analytic(
      _question,
      result,
      language,
      source,
      conversation,
      model: nil,
      credits: 0,
      origin: 'wetwijzer',
      token_info: nil,
      billing_reservation_token: nil,
      generation_trace: nil,
      reasoning_effort_requested: nil,
      provider_calls: nil
    )
      ChatbotAnalytic.ensure_table_exists
      ChatbotAnalytic.ensure_cost_columns!

      # Capture token usage from the last chat completion
      token_info ||= Thread.current[:last_chat_tokens] || {}
      used_model = model || params[:model] || LegalChatbotService::CHAT_MODEL
      # An answer can cost MORE THAN ONE generation: the citation guard
      # rejects and regenerates, and a measured ask ran the provider three
      # times. cost_per_query_eur is a per-CALL constant, so charging it once
      # understated a retried answer threefold - and made a retry-happy
      # configuration look as cheap as one that never retries, in the very
      # table used to compare them.
      calls = provider_calls.to_i.positive? ? provider_calls.to_i : 1
      estimated_cost = LegalChatbotService.cost_per_query_eur(used_model) * calls
      # The cost is charged either way; only the column is conditional.
      counter = ChatbotAnalytic.provider_calls_supported? ? { provider_calls: calls } : {}
      # What the guard decided for THIS answer. The orchestrator has computed
      # both of these since the guard shipped and returned them in the result
      # hash; nothing ever stored them, so nothing could be measured across
      # answers. Read from the result rather than plumbed through the
      # controller, because that is where they already are.
      counter = counter.merge(supported_analytics_attributes(citation_guard_attributes(result)))

      ChatbotAnalytic.create(
        **generation_attributes(generation_trace, reasoning_effort_requested),
        language: language,
        source: source.to_s,
        # Defence in depth: the controller already canonicalizes, but this is
        # the writer that put arbitrary client strings into a content-free
        # table, so it validates again rather than trusting an instance
        # variable it does not own.
        sources_list: ChatbotSourceCategories.storage_value(@selected_sources),
        model_used: used_model,
        intelligence_level: params[:intelligence],
        response_time: result[:response_time],
        sources_count: result[:sources]&.length || 0,
        user: current_user,
        ip_hash: Digest::SHA256.hexdigest("#{request.remote_ip}#{Rails.application.secret_key_base}"),
        conversation_token: conversation&.token,
        has_error: result[:error].present?,
        input_tokens: token_info[:input] || 0,
        output_tokens: token_info[:output] || 0,
        estimated_cost_eur: estimated_cost,
        estimated_cost_microeur: ChatbotAnalytic.to_microeur(estimated_cost),
        credits_deducted: credits,
        billing_reservation_token: billing_reservation_token,
        request_source: 'web',
        domain: request.host,
        **counter
      )
    rescue StandardError => e
      # Never let analytics logging break the chatbot
      Rails.logger.error("ChatbotAnalytic logging failed: #{e.class}")
      nil
    end

    # RAT-003. The effective generation snapshot, or nothing at all.
    #
    # The requested effort is merged HERE rather than plumbed through the
    # client, because ModelSelection owns it and the client only ever knows
    # the effective value. Merging before reading the fingerprint matters:
    # requested effort is a fingerprint field, so a fingerprint taken before
    # the merge would describe a different configuration.
    #
    # Errors are swallowed with the class only. A trace is best-effort
    # analytics and must never be able to fail an answer, and on PostgreSQL a
    # constraint violation carries the whole failing row in its message.
    def generation_attributes(trace, reasoning_effort_requested)
      return {} unless trace.respond_to?(:recorded?) && trace.recorded?

      trace.record_request!(reasoning_effort_requested: reasoning_effort_requested) if reasoning_effort_requested.present?
      supported_analytics_attributes(trace.to_analytics_attributes)
    rescue StandardError => e
      Rails.logger.warn("[GenerationTrace] not persisted: #{e.class}")
      {}
    end

    # The guard's verdict and the regenerations IT caused.
    #
    # citation_guard_retries is NOT provider_calls: a quote-repair pass also
    # increments provider_calls, so the two answer different questions - how
    # many generations did this answer cost, and how many of them did the guard
    # ask for. Tuning CITATION_GUARD_MAX_RETRIES needs the second.
    GUARD_OUTCOMES = %w[analysis verified_sources_fallback refusal].freeze

    def citation_guard_attributes(result)
      return {} unless result.is_a?(Hash)

      outcome = result[:citation_guard_outcome].to_s
      attributes = {}
      # Allowlisted: the column is read back as a category, and an unexpected
      # value would quietly become one.
      attributes[:citation_guard_outcome] = outcome if GUARD_OUTCOMES.include?(outcome)
      retries = result[:citation_guard_retries]
      attributes[:citation_guard_retries] = retries if valid_guard_retries?(retries)
      attributes
    rescue StandardError
      {}
    end

    # The counter is bounded by construction - the orchestrator's retry loop
    # runs `while attempts < CITATION_GUARD_MAX_RETRIES` - so anything outside
    # 0..max did not come from that loop, and `to_i` was quietly making it look
    # as though it had: -1 stored as -1, 2.7 truncated to a plausible 2, and a
    # huge value stored whole. Each would land in the denominator that tunes
    # the very constant it violates.
    #
    # Out of range is dropped, not clamped, and the column is nullable: a
    # missing verdict is visibly missing, while a clamped one is indistinguish-
    # able from a real measurement. Integer only, since a Float here means the
    # value did not come from the counter.
    def valid_guard_retries?(value)
      return false unless value.is_a?(Integer)

      value >= 0 && value <= LegalChatbot::Orchestrator::CITATION_GUARD_MAX_RETRIES
    rescue StandardError
      # false, not {}. This is a predicate, and the caller stores the value
      # when it returns truthy - so the {} inherited from the surrounding
      # method's rescue would have admitted the very value that raised.
      false
    end

    # Only the trace fields this database actually has.
    #
    # The retry counter got this guard when it shipped, because passing an
    # unknown attribute raises inside create and log_analytic rescues
    # everything - so the whole analytics row disappears, not just the column.
    # The seventeen trace attributes had no such guard, which meant a database
    # that predates their migration lost EVERY row silently. Analytics
    # migrations are applied by hand, so "the code arrived before the column"
    # is a state this app really does pass through.
    #
    # The input is the hash this server just built from its own trace object.
    # No request or client hash is ever sliced here, and nothing is added -
    # only removed.
    def supported_analytics_attributes(attributes)
      return {} unless attributes.is_a?(Hash)

      columns = ChatbotAnalytic.column_names
      supported = attributes.select { |key, _value| columns.include?(key.to_s) }
      dropped = attributes.keys - supported.keys
      # The column names only. A value could carry the trace of a real request.
      Rails.logger.warn("[GenerationTrace] columns missing: #{dropped.join(',')}") if dropped.any?
      supported
    rescue StandardError
      # Schema introspection itself failed. A minimal row beats no row.
      {}
    end
  end
end
