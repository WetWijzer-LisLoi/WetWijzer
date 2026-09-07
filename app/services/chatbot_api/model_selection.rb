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
                :reasoning_effort, :requested_reasoning_effort

    def initialize(params:, conversation:, service_bypass:, user_tier:)
      @params = params
      @conversation = conversation
      @service_bypass = service_bypass
      @user_tier = user_tier
      resolve!
    end

    def model_tier_denied?
      @model_tier_denied
    end

    def model_tier_mismatch?
      @model_tier_mismatch
    end

    private

    def resolve!
      @intelligence = @params[:intelligence]&.to_s&.strip
      @model = @params[:model]&.to_s&.strip
      @model_override = @params[:model_override]&.to_s&.strip
      @credits_to_deduct = 1
      @reasoning_effort = nil
      @requested_reasoning_effort = nil
      @model_tier_denied = false
      @model_tier_mismatch = false

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

        @requested_reasoning_effort = sanitized_requested_effort ||
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
        @requested_reasoning_effort = sanitized_requested_effort
        @reasoning_effort = effective_reasoning_effort_for_chat(@model, @requested_reasoning_effort)
        @credits_to_deduct = LegalChatbotService.canonical_credits_for_model(@model) +
                             LegalChatbotService.reasoning_surcharge_for_model(@model, @reasoning_effort)
        # Legacy model param must respect tier gating like everywhere else;
        # previously a free user could request Pro-only models directly.
        @model_tier_denied = !@service_bypass &&
                             !LegalChatbotService.model_allowed?(@model, @user_tier)
      else
        @model = LegalChatbotService::CHAT_MODEL
        @credits_to_deduct = 1
      end

      return if @service_bypass

      @model_tier_denied ||= !LegalChatbotService.model_allowed?(@model, @user_tier)
    end

    def sanitized_requested_effort
      effort = @params[:reasoning_effort]&.to_s&.strip
      VALID_REASONING_EFFORTS.include?(effort) ? effort : nil
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
