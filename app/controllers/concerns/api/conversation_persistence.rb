# frozen_string_literal: true

module Api
  # Server-side conversation persistence for the ask path: conversation
  # lookup/creation with ZK-mode fencing, the claim-guarded exchange write,
  # and cleanup of a conversation created for a request that failed before
  # commit. Extracted verbatim from Api::ChatbotController (FBL-060 step 4)
  # as a concern so every method keeps its name and receiver: the white-box
  # suites stub or drive these names on the controller instance. The typed
  # persistence error lives here but remains resolvable as
  # Api::ChatbotController::ConversationPersistenceError through ancestry.
  module ConversationPersistence
    extend ActiveSupport::Concern

    # Bare references below resolve lexically, not through the including
    # controller's ancestry, so alias the sibling concern's conflict class.
    ZeroKnowledgeStateConflict = Api::ZeroKnowledgeClaims::ZeroKnowledgeStateConflict

    class ConversationPersistenceError < StandardError
      attr_reader :outcome

      def initialize(outcome:, cause:)
        @outcome = outcome.to_sym
        super("conversation persistence #{@outcome}: #{cause.class}")
        set_backtrace(cause.backtrace)
      end
    end

    private

    def find_or_create_conversation(conversation_id, language)
      # Full column set needed: ensure_table_exists alone creates the table
      # without title/pinned/zero_knowledge, and create!(zero_knowledge: true)
      # below would then fail on a fresh database
      current = current_user

      # GDPR / privacy commitment: conversations are NOT stored server-side
      # without the user's explicit storage consent (Art. 6(1)(a)). Without
      # consent we create/persist nothing — follow-up context comes from the
      # client-sent context_messages instead. This honors the privacy notice
      # ("without consent your conversation exists only in your browser").
      return nil unless current&.conversation_storage_consented?

      key_generation = zero_knowledge_key_generation(current)
      if zero_knowledge_key_material_present?(current) && key_generation.nil?
        raise ZeroKnowledgeStateConflict, 'The account has incomplete zero-knowledge key material'
      end
      supplied_generation = params[:key_generation].to_s.presence
      if supplied_generation.present? != key_generation.present? ||
         (key_generation.present? && supplied_generation != key_generation)
        raise ZeroKnowledgeStateConflict, 'The browser key generation no longer matches the account'
      end

      ChatbotConversation.ensure_table_and_columns_exist

      if conversation_id.present?
        conv = ChatbotConversation.find_by(token: conversation_id)
        if conv && !conv.expired?
          # Ownership check: if conversation has a user_id, it must match
          # current_user. NB: user_id is a STRING column — compare as strings
          # (Integer != String was always true, which broke conversation
          # continuity for every logged-in user)
          if conv.user_id.present? && current&.id.to_s != conv.user_id.to_s
            Rails.logger.warn("Conversation ownership mismatch: token=#{conversation_id[0..7]}... user=#{current&.id}")
            # Fall through to create a new conversation instead of hijacking
          else
            account_uses_zero_knowledge = key_generation.present?
            if conv.zero_knowledge? != account_uses_zero_knowledge
              raise ZeroKnowledgeStateConflict, 'Conversation storage mode no longer matches the account'
            end

            conv.extend_expiry!
            return conv
          end
        end
      end

      # Create new conversation with user ownership
      attrs = { language: language }
      attrs[:user_id] = current.id if current

      # Mark as ZK if user has zero-knowledge key material
      if key_generation.present?
        attrs[:zero_knowledge] = true
        attrs[:zk_key_generation] = key_generation
      end

      ChatbotConversation.create!(attrs).tap do |conversation|
        conversation.instance_variable_set(:@created_for_chat_request, true)
      end
    rescue ZeroKnowledgeStateConflict
      raise
    rescue StandardError => e
      # Consented history is part of the privacy contract. Continuing after a
      # storage/schema failure could charge for an answer that cannot be saved.
      Rails.logger.error("Conversation create/find failed: #{e.class}")
      raise
    end

    def save_to_conversation(conversation, question, result, claim:)
      return unless conversation && result

      # Extract NUMACs from sources
      numacs = result[:sources]&.map { |s| s[:numac] }&.compact || []

      unless claim
        raise ConversationPersistenceError.new(
          outcome: :absent,
          cause: RuntimeError.new('Conversation claim is missing')
        )
      end
      unless conversation_claim_owned?(claim)
        raise ConversationPersistenceError.new(
          outcome: :absent,
          cause: RuntimeError.new('Conversation was cleared or storage consent was revoked')
        )
      end

      conversation.add_exchange_under_claim!(
        question: question,
        answer: result[:answer],
        numacs: numacs,
        claim: claim
      )
    rescue ConversationPersistenceError
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound => e
      Rails.logger.error("Conversation save failed before commit: #{e.class}")
      raise ConversationPersistenceError.new(outcome: :absent, cause: e)
    rescue StandardError => e
      Rails.logger.error("Conversation save failed: #{e.class}")
      # This path is reached only for an explicitly consented, server-stored
      # conversation. Statement/transport errors can be commit-uncertain, so
      # the owner-scoped delivery remains charge-retained until proven absent.
      raise ConversationPersistenceError.new(outcome: :unknown, cause: e)
    end

    def save_deep_analysis_to_conversation(conversation, question, original_answer, result, model:, claim:)
      return unless conversation && result

      numacs = result[:sources]&.map { |source| source[:numac] }&.compact || []

      raise 'Conversation claim is missing' unless claim
      raise 'Conversation was cleared or storage consent was revoked' unless conversation_claim_owned?(claim)

      conversation.add_deep_analysis_under_claim!(
        question: question,
        original_answer: original_answer,
        answer: result[:answer],
        numacs: numacs,
        model: model,
        claim: claim
      )
      true
    rescue StandardError => e
      Rails.logger.error("Deep-analysis conversation save failed: #{e.class}")
      raise
    end

    def cleanup_uncommitted_chat_conversation!(conversation)
      return unless conversation&.persisted?

      ChatbotConversation.where(id: conversation.id).delete_all
    rescue StandardError => e
      Rails.logger.error(
        "Uncommitted chatbot conversation cleanup failed " \
        "(id=#{conversation&.id}): #{e.class}"
      )
    end
  end
end
