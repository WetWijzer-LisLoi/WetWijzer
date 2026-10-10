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
      # consent we create/persist nothing; follow-up context comes from the
      # client-sent context_messages instead. This honors the privacy notice
      # ("without consent your conversation exists only in your browser").
      return nil unless current&.conversation_storage_consented?

      # WW-PRIV-10: the storage generation this request was admitted under,
      # from the account as it was loaded for the request. The new row and
      # the exchange are written under the storage boundary against it.
      conversation_storage_admitted

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
          # current_user. NB: user_id is a STRING column, so compare as strings
          # (Integer != String was always true, which broke conversation
          # continuity for every logged-in user)
          if conv.user_id.present? && current&.id.to_s != conv.user_id.to_s
            Rails.logger.warn("Conversation ownership mismatch: token=#{conversation_id[0..7]}... user=#{current&.id}")
            # Fall through to create a new conversation instead of hijacking
          else
            account_uses_zero_knowledge = key_generation.present?
            raise ZeroKnowledgeStateConflict, 'Conversation storage mode no longer matches the account' if conv.zero_knowledge? != account_uses_zero_knowledge

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

      created = write_under_storage_boundary { ChatbotConversation.create!(attrs) }
      created.tap { |conversation| conversation.instance_variable_set(:@created_for_chat_request, true) }
    rescue ConversationStorageBoundary::Fenced
      # Consent or the storage mode changed since this request was admitted:
      # the answer stays in the browser, as without consent.
      nil
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

      numacs = context_numacs_for(result)

      unless claim
        raise ConversationPersistenceError.new(
          outcome: :absent,
          cause: RuntimeError.new('Conversation claim is missing')
        )
      end
      # WW-PRIV-10: the claim check and the write, under the storage boundary.
      write_under_storage_boundary do
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
          claim: claim,
          # A German answer on gesetzguide keeps the French answer it was made
          # from, which history replay gives the model (nil everywhere else).
          context_content: result[LegalChatbot::GermanAnswerTranslation::CONTEXT_KEY],
          # And a German question the French question it was translated into
          # (GermanQuestionTranslation; nil everywhere else).
          question_context_content: result[LegalChatbot::GermanQuestionTranslation::CONTEXT_KEY]
        )
      end
    rescue ConversationStorageBoundary::Fenced => e
      raise ConversationPersistenceError.new(outcome: :absent, cause: e)
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

    # The NUMACs of the answer's sources, which the conversation keeps as
    # context for its next ask (injected and boosted by legislation search).
    # None for an ask whose retrieval was degraded: its sources are whatever
    # the incomplete search happened to return (on 2026-09-20, articles that
    # merely contained the word "kleding"), and the answer invites a re-ask
    # that those NUMACs would steer straight back to them.
    def context_numacs_for(result)
      return [] if result[:retrieval_degraded].present?

      result[:sources]&.filter_map { |source| source[:numac] } || []
    end

    def save_deep_analysis_to_conversation(conversation, question, original_answer, result, model:, claim:)
      return unless conversation && result

      numacs = context_numacs_for(result)

      raise 'Conversation claim is missing' unless claim

      # WW-PRIV-10: the claim check and the write, under the storage boundary.
      write_under_storage_boundary do
        raise 'Conversation was cleared or storage consent was revoked' unless conversation_claim_owned?(claim)

        conversation.add_deep_analysis_under_claim!(
          question: question,
          original_answer: original_answer,
          answer: result[:answer],
          numacs: numacs,
          model: model,
          claim: claim
        )
      end
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
        'Uncommitted chatbot conversation cleanup failed ' \
        "(id=#{conversation&.id}): #{e.class}"
      )
    end
  end
end
