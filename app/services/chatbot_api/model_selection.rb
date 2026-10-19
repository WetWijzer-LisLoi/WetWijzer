# frozen_string_literal: true

module ChatbotApi
  # Resolves the model, reasoning effort and credit price for one ask
  # request. Extracted verbatim from Api::ChatbotController#ask (FBL-060
  # step 1); all inputs are explicit so the resolution is testable without
  # a controller instance. Tier gating decided here is enforced by the
  # caller (it renders upgrade_required / model_tier_mismatch).
  class ModelSelection
    VALID_REASONING_EFFORTS = %w[none low medium high].freeze

    attr_reader :intelligence, :model, :model_override, :credits_to_deduct,
                :reasoning_effort, :requested_reasoning_effort, :unavailable_model, :research_depth

    def self.linked_research_request?(params)
      [true, 'true'].include?(params[:linked_research])
    end

    # A linked option carries its actual model, not a user-controlled group or
    # retrieval budget. A stale group cannot change its model, profile or price.
    def self.linked_requested_model(params)
      explicit = [params[:model_override], params[:model]].find do |value|
        value.is_a?(String) && LegalChatbotService::AVAILABLE_MODELS.key?(value.strip)
      end
      return explicit.strip if explicit

      level = params[:intelligence].to_s.strip
      LegalChatbotService.model_for_intelligence(level) if LegalChatbotService.valid_intelligence_level?(level)
    end

    # Run this before creating a conversation or reserving credits. An explicit
    # pending choice must never silently turn into the tier's cheapest model.
    def self.unavailable_requested_model(params)
      requested = [params[:model_override], params[:model]].map { |value| value.to_s.strip }
      return if requested.any? { |model| LegalChatbot::ModelsConfig::RETIRED_MODEL_REPLACEMENTS.key?(model) }

      pending = requested.find { |model| LegalChatbotService::AVAILABLE_MODELS.dig(model, :deployed) == false }
      return pending if pending

      if linked_research_request?(params)
        selected = linked_requested_model(params)
        return selected if LegalChatbotService::AVAILABLE_MODELS.dig(selected, :deployed) == false

        return
      end

      intelligence = params[:intelligence].to_s.strip
      return unless LegalChatbotService.valid_intelligence_level?(intelligence)

      override = params[:model_override].to_s.strip
      selected = if LegalChatbotService::AVAILABLE_MODELS.key?(override) &&
                    LegalChatbotService.model_in_intelligence_level?(intelligence, override)
                   override
                 else
                   LegalChatbotService.model_for_intelligence(intelligence)
                 end
      selected if LegalChatbotService::AVAILABLE_MODELS.dig(selected, :deployed) == false
    end

    def initialize(params:, conversation:, service_bypass:, user_tier:, reasoning_access: nil)
      @params = params
      @conversation = conversation
      @service_bypass = service_bypass
      @user_tier = user_tier
      @reasoning_access = reasoning_access.nil? ? @user_tier.to_s.in?(%w[pro subscriber]) : reasoning_access == true
      resolve!
    end

    def model_tier_denied?
      @model_tier_denied
    end

    def model_tier_mismatch?
      @model_tier_mismatch
    end

    def retired_model?
      @retired_model
    end

    def linked_research?
      @linked_research
    end

    def research_depth_denied?
      @research_depth_denied
    end

    private

    def resolve!
      @intelligence = @params[:intelligence]&.to_s&.strip
      @model = @params[:model]&.to_s&.strip
      @model_override = @params[:model_override]&.to_s&.strip
      @credits_to_deduct = 1
      @reasoning_effort = nil
      @requested_reasoning_effort = nil
      @linked_research = self.class.linked_research_request?(@params)
      @research_depth = LegalChatbotService.normalize_research_depth(@params[:research_depth])
      @research_depth_denied = false
      @model_tier_denied = false
      @model_tier_mismatch = false
      @retired_model = [@params[:model], @params[:model_override]].any? do |requested|
        LegalChatbot::ModelsConfig::RETIRED_MODEL_REPLACEMENTS.key?(requested.to_s.strip)
      end
      @unavailable_model = self.class.unavailable_requested_model(@params)
      if @unavailable_model
        @model = @unavailable_model
        @credits_to_deduct = 0
        return
      end

      return resolve_linked! if @linked_research

      if @intelligence.present? && LegalChatbotService.valid_intelligence_level?(@intelligence)
        @model = LegalChatbotService.model_for_intelligence(@intelligence)

        if @model_override.present? && LegalChatbotService::AVAILABLE_MODELS.key?(@model_override)
          @model_tier_mismatch = cross_tier_model_override?(@intelligence, @model_override)
          unless @model_tier_mismatch
            if model_override_authorized?(@model_override)
              @model = @model_override
            else
              @model_tier_denied = true
            end
          end
        end

        @requested_reasoning_effort = research_requested_effort || sanitized_requested_effort ||
                                      LegalChatbotService.reasoning_effort_for_intelligence(@intelligence)
        @reasoning_effort = effective_reasoning_effort_for_chat(@model, @requested_reasoning_effort)
        # Charge only reasoning levels that map to a documented, distinct
        # provider behaviour for this model. For example, Mistral medium is
        # not supported and therefore adds no surcharge.
        @credits_to_deduct = LegalChatbotService.credits_with_reasoning(
          @intelligence,
          @reasoning_effort,
          @model
        )
      elsif @model.present? && LegalChatbotService::AVAILABLE_MODELS.key?(@model)
        @requested_reasoning_effort = research_requested_effort || sanitized_requested_effort
        @reasoning_effort = effective_reasoning_effort_for_chat(@model, @requested_reasoning_effort)
        @credits_to_deduct = LegalChatbotService.canonical_credits_for_model(@model) +
                             LegalChatbotService.reasoning_surcharge_for_model(@model, @reasoning_effort)
        # Legacy model params respect the same canonical model access contract.
        @model_tier_denied = !@service_bypass &&
                             !LegalChatbotService.model_allowed?(@model, @user_tier)
      else
        @model = LegalChatbotService::CHAT_MODEL
        @credits_to_deduct = 1
        if @research_depth
          @requested_reasoning_effort = research_requested_effort
          @reasoning_effort = effective_reasoning_effort_for_chat(@model, @requested_reasoning_effort)
          @credits_to_deduct = LegalChatbotService.canonical_credits_for_model(@model) +
                               LegalChatbotService.reasoning_surcharge_for_model(@model, @reasoning_effort)
        end
      end

      @research_depth_denied = !@service_bypass && !@reasoning_access && @research_depth == 'extensive'

      return if @service_bypass || @model_tier_denied

      @model_tier_denied = !LegalChatbotService.model_allowed?(@model, @user_tier)
    end

    def resolve_linked!
      @model = self.class.linked_requested_model(@params) || LegalChatbotService::CHAT_MODEL
      @intelligence = LegalChatbotService.intelligence_level_for_model(@model)
      @model_tier_denied = !@service_bypass && !LegalChatbotService.model_allowed?(@model, @user_tier)
      @requested_reasoning_effort = sanitized_requested_effort || 'low'
      @reasoning_effort = effective_reasoning_effort_for_chat(@model, @requested_reasoning_effort)
      # Resolve the budget after the actual effort, including the private
      # Mistral follow-up clamp. Neither a stale client category nor a mode
      # that will not be used may buy a different research budget.
      @research_depth = LegalChatbotService.research_depth_for_combination(@model, @reasoning_effort)
      @research_depth_denied = !@service_bypass && !@reasoning_access && @research_depth == 'extensive'
      @credits_to_deduct = LegalChatbotService.canonical_credits_for_model(@model) +
                           LegalChatbotService.reasoning_surcharge_for_model(@model, @reasoning_effort)
    end

    def sanitized_requested_effort
      value = @params[:reasoning_effort]
      value = @params[:reasoning_level] if value.nil? && @linked_research
      effort = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s.strip : nil
      VALID_REASONING_EFFORTS.include?(effort) ? effort : nil
    end

    def research_requested_effort
      return nil unless @research_depth

      # Cached, unflagged depth clients preview low effort for regular accounts.
      # Preserve that exact billing contract until they reload the linked UI;
      # linked choices resolve their explicit variant in resolve_linked! instead.
      # Model access and the extensive profile's Pro gate remain independent.
      access = @service_bypass || @reasoning_access
      access ? LegalChatbotService::RESEARCH_DEPTHS.fetch(@research_depth).fetch(:reasoning_effort) : 'low'
    end

    # Mistral Small high-reasoning follow-ups require the provider's typed
    # ThinkChunk state from the preceding assistant turn. WetWijzer
    # deliberately strips and never persists private provider reasoning, so
    # replaying only the visible answer as a high-reasoning assistant turn is
    # not a valid continuation. Downgrade to low/none before credit
    # calculation; the LLM client repeats this guard at dispatch as defence
    # in depth.
    def effective_reasoning_effort_for_chat(model, requested_effort)
      effort = LegalChatbotService.effective_reasoning_effort_for_model(model, requested_effort)
      return effort unless model.to_s == 'mistral-small' && effort == 'high'

      client_context = @params[:context_messages]
      has_client_history = client_context.is_a?(Array) && client_context.any?
      has_server_history = @conversation&.messages_array&.any? == true

      has_client_history || has_server_history ? 'low' : effort
    end

    def cross_tier_model_override?(intelligence, model_override)
      model_override.present? && LegalChatbotService::AVAILABLE_MODELS.key?(model_override) &&
        !LegalChatbotService.model_in_intelligence_level?(intelligence, model_override)
    end

    def model_override_authorized?(model_override)
      return true if @service_bypass

      LegalChatbotService.model_allowed?(model_override, @user_tier)
    end
  end
end
