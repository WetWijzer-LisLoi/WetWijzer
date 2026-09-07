# frozen_string_literal: true

module Api
  # Server-side conversation history and consent endpoints, split out of the
  # monolithic chatbot controller (FBL-060 step 7). Paths are unchanged;
  # only the routing target moved. Every action body is verbatim.
  class ChatbotConversationsController < ChatbotBaseController
    # ============================================
    # CONVERSATION MANAGEMENT (server-side history)
    # ============================================

    # GET /api/chatbot/conversations
    # List user's conversations (metadata only - no message content)
    def conversations
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      convos = ChatbotConversation.for_user(current_user.id).limit(50)
      begin
        convos.each do |conversation|
          bind_legacy_zero_knowledge_generation!(conversation)
          ensure_zero_knowledge_conversation_readable!(conversation)
        end
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end

      render json: {
        conversations: convos.map { |c| conversation_summary(c) },
        consent: current_user.conversation_storage_consented?
      }
    end

    # GET /api/chatbot/conversations/:token
    # Load full conversation (messages included)
    # ZK mode: returns encrypted blobs (client decrypts)
    # Legacy mode: returns plaintext messages array
    def show_conversation
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s
      begin
        bind_legacy_zero_knowledge_generation!(conv)
        ensure_zero_knowledge_conversation_readable!(conv)
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end

      data = {
        id: conv.token,
        message_count: conv.message_count,
        language: conv.language,
        pinned: conv.pinned || false,
        archived: conv.archived || false,
        zero_knowledge: conv.zero_knowledge?,
        revision: conv.lock_version.to_i,
        encrypted_revision: conv.lock_version.to_i,
        key_generation: conv.zk_key_generation,
        created_at: conv.created_at&.iso8601,
        updated_at: conv.updated_at&.iso8601
      }

      if conv.zero_knowledge?
        # ZK: return raw ciphertext blobs - client decrypts
        data[:encrypted_messages] = conv[:messages]
        data[:encrypted_title] = conv[:title]
      else
        data[:title] = conv.title
        data[:messages] = conv.messages_array
      end

      render json: data
    end

    # GET /api/chatbot/active_conversation
    # Returns the user's current (non-archived, non-expired) conversation WITH
    # messages so the widget and the full page can restore the same chat log
    # WITHOUT anything being stored in the browser. { active: false } if none.
    def active_conversation
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?
      return render json: { active: false } unless current_user.conversation_storage_consented?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.active_for(current_user.id)
      return render json: { active: false } unless conv
      begin
        bind_legacy_zero_knowledge_generation!(conv)
        ensure_zero_knowledge_conversation_readable!(conv)
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end

      data = {
        active: true,
        id: conv.token,
        message_count: conv.message_count,
        language: conv.language,
        archived: conv.archived || false,
        zero_knowledge: conv.zero_knowledge?,
        revision: conv.lock_version.to_i,
        encrypted_revision: conv.lock_version.to_i,
        key_generation: conv.zk_key_generation,
        updated_at: conv.updated_at&.iso8601
      }
      if conv.zero_knowledge?
        data[:encrypted_messages] = conv[:messages]
        data[:encrypted_title] = conv[:title]
      else
        data[:title] = conv.title
        data[:messages] = conv.messages_array
      end

      render json: data
    end

    # DELETE /api/chatbot/conversations/:token
    def destroy_conversation
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s

      conv.destroy
      render json: { success: true }
    end

    # PATCH /api/chatbot/conversations/:token
    # Rename or pin a conversation
    def update_conversation
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s

      # Clearing is an explicit cancellation fence for both storage modes.
      # Always use a revision CAS, even when the first read saw no token: an ask
      # can claim the row between that read and this write. Retrying against the
      # fresh revision guarantees any newly-published token is cleared instead
      # of archiving a row that remains lease-locked for five minutes.
      if params[:archived] == true && params[:cancel_active_claim] == true
        8.times do
          cancelled = ChatbotConversation.where(
            id: conv.id,
            lock_version: conv.lock_version
          ).update_all(
            lock_version: conv.lock_version.to_i + 1,
            zk_claim_token: nil,
            zk_claimed_at: nil,
            archived: true,
            updated_at: Time.current
          )
          if cancelled == 1
            conv.reload
            return render json: { success: true, conversation: conversation_summary(conv) }
          end

          conv.reload
        rescue ActiveRecord::RecordNotFound
          return render json: { error: 'Conversation not found' }, status: :not_found
        end

        return render json: { error: 'conflict, please retry' }, status: :conflict
      end

      begin
        bind_legacy_zero_knowledge_generation!(conv)
        ensure_zero_knowledge_conversation_readable!(conv)
      rescue ZeroKnowledgeStateConflict
        return render_zero_knowledge_state_conflict
      end

      # Do not overwrite a zero-knowledge title with server-readable plaintext; ZK
      # titles are set only via the /encrypted endpoint (update_encrypted_payload!).
      # Retry on an optimistic-lock conflict (e.g. an answer landing in the same
      # conversation via add_message while the user archives/renames it).
      attempts = 0
      begin
        conv.title = params[:title] if params[:title].present? && !conv.zero_knowledge?
        conv.pinned = params[:pinned] if params.key?(:pinned)
        # Archiving = the user cleared this conversation: it stays in history but
        # is no longer the active one that auto-restores on page load.
        conv.archived = params[:archived] if params.key?(:archived)
        conv.save!
      rescue ActiveRecord::StaleObjectError
        attempts += 1
        if attempts < 5
          conv.reload
          retry
        end
        return render json: { error: 'conflict, please retry' }, status: :conflict
      end

      render json: { success: true, conversation: conversation_summary(conv) }
    end

    # POST /api/chatbot/conversations/consent
    # Record GDPR Art. 6(1)(a) consent for conversation storage
    # Accepts ZK key material: encrypted_master_key + key_derivation_salt
    def grant_consent
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      # A password-backed consent request is all-or-nothing. Treat even blank
      # named fields as a ZK attempt so a failed client key-generation step
      # cannot silently fall back to server-readable conversation storage.
      zk_attrs = zero_knowledge_consent_attributes
      return render json: { error: 'Complete zero-knowledge key material is required' }, status: :bad_request unless zk_attrs

      current_user.reload
      if zk_attrs.present? && current_user.conversation_storage_consented? &&
         !zero_knowledge_key_material_present?(current_user)
        return render json: {
          error: 'conversation_storage_mode_conflict',
          message: 'Revoke existing standard history before enabling zero-knowledge storage'
        }, status: :conflict
      end

      # A single guarded UPDATE atomically claims an empty key slot or accepts
      # an idempotent retry of the exact same wrapped-key pair.
      begin
        key_generation = persist_conversation_storage_consent!(zk_attrs)
      rescue ZeroKnowledgeStateConflict
        current_user.reload
        return render_zero_knowledge_state_conflict
      rescue ActiveRecord::RecordInvalid
        current_user.reload
        return render json: { error: 'Invalid zero-knowledge key material' }, status: :unprocessable_entity
      end

      # Remove expiry from all existing conversations for this user
      ChatbotConversation.ensure_table_and_columns_exist
      ChatbotConversation.where(user_id: current_user.id)
                         .where.not(expires_at: nil)
                         .update_all(expires_at: nil)

      render json: {
        success: true,
        consented_at: current_user.conversation_storage_consented_at&.iso8601,
        zero_knowledge: key_generation.present?,
        key_generation: key_generation
      }
    end

    # DELETE /api/chatbot/conversations/consent
    # Revoke consent - deletes all stored conversations and ZK key material
    def revoke_consent
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      # Disable storage and destroy key material in the accounts database
      # first. Any in-flight provider request revalidates this flag before its
      # claimed conversation write, so it cannot recreate content after the
      # chatbot rows below have been erased. The update is idempotent, making a
      # retry safe if the cross-database deletion is temporarily unavailable.
      current_user.revoke_conversation_storage_consent!

      # Delete all user's conversations after the account fence is visible.
      ChatbotConversation.ensure_table_and_columns_exist
      ChatbotConversation.where(user_id: current_user.id).delete_all

      render json: {
        success: true,
        consent: false,
        zero_knowledge: false,
        key_generation: nil
      }
    end

    # PATCH /api/chatbot/conversations/:token/encrypted
    # Client-side encrypted payload update (zero-knowledge mode)
    # Server stores opaque ciphertext - cannot decrypt
    def update_encrypted_payload
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s

      current_user.reload
      expected_revision = nonnegative_integer_param(params[:expected_revision])
      supplied_generation = params[:key_generation].to_s
      supplied_claim_token = params[:claim_token].to_s
      current_generation = zero_knowledge_key_generation(current_user)

      unless current_user.conversation_storage_consented? &&
             conv.zero_knowledge? &&
             expected_revision.present? &&
             supplied_generation.present? &&
             current_generation.present? &&
             supplied_generation == current_generation &&
             supplied_claim_token.match?(/\A[0-9a-f]{64}\z/) &&
             conv.zk_claim_token == supplied_claim_token &&
             conv.zk_claimed_at.present? &&
             conv.zk_claimed_at >= ZERO_KNOWLEDGE_CLAIM_TTL.ago &&
             conv.lock_version.to_i == expected_revision &&
             (conv.zk_key_generation.blank? || conv.zk_key_generation == current_generation)
        return render_zero_knowledge_state_conflict
      end

      return render json: { error: 'encrypted_messages required' }, status: :bad_request unless params[:encrypted_messages].present?

      begin
        conv.update_encrypted_payload!(
          encrypted_messages: params[:encrypted_messages],
          encrypted_title: params[:encrypted_title],
          message_count: params[:message_count].to_i,
          numacs: Array(params[:numacs]),
          expected_revision: expected_revision,
          key_generation: current_generation,
          claim_token: supplied_claim_token
        )
      rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
        return render_zero_knowledge_state_conflict
      rescue StandardError => e
        Rails.logger.error(
          "Encrypted conversation persistence failed " \
          "(token=#{conv.token.to_s.first(8)}..., user=#{current_user.id}): #{e.class}"
        )
        return render json: { error: 'Encrypted conversation could not be saved' },
                      status: :internal_server_error
      end

      render json: {
        success: true,
        zero_knowledge: true,
        revision: conv.lock_version.to_i,
        encrypted_revision: conv.lock_version.to_i,
        key_generation: conv.zk_key_generation
      }
    end

    # GET /api/chatbot/zk_key_material
    # Return the user's wrapped master key for client-side unwrapping
    # Called on login to restore ZK encryption capability
    def zk_key_material
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      key_generation = zero_knowledge_key_generation(current_user)
      if key_generation.present? && current_user.conversation_storage_consented?
        render json: {
          encrypted_master_key: current_user.encrypted_master_key,
          key_derivation_salt: current_user.key_derivation_salt,
          zero_knowledge: true,
          key_generation: key_generation
        }
      else
        render json: { zero_knowledge: false, key_generation: nil }
      end
    end

    # POST /api/chatbot/conversations/import
    # Bulk import conversations from localStorage migration
    def import_conversations
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?
      return render json: { error: 'Consent required' }, status: :forbidden unless current_user.conversation_storage_consented?

      # Zero-knowledge users must not import plaintext history server-side: it would be
      # stored server-readable via Rails `encrypts`, defeating ZK. Their client encrypts
      # locally and uses the /encrypted endpoint instead.
      if current_user.encrypted_master_key.present?
        return render json: { error: 'Zero-knowledge storage enabled; plaintext import is not supported' }, status: :unprocessable_entity
      end

      items = params[:conversations]
      return render json: { error: 'No conversations provided' }, status: :bad_request unless items.is_a?(Array)

      ChatbotConversation.ensure_table_and_columns_exist
      imported = 0

      items.first(20).each do |item|
        next unless item[:messages].is_a?(Array) && item[:messages].length >= 2

        conv = ChatbotConversation.new(
          user_id: current_user.id,
          language: item[:language] || 'nl'
        )
        # Set title from first user message
        first_q = item[:messages].find { |m| m[:role] == 'user' || m['role'] == 'user' }
        conv.title = (first_q&.dig(:content) || first_q&.dig('content') || 'Conversation').truncate(100)
        conv.messages_array = item[:messages].last(20)
        conv.message_count = conv.messages_array.length
        conv.expires_at = nil # Consented - no expiry
        conv.save!
        imported += 1
      rescue StandardError => e
        Rails.logger.warn("[ConversationImport] Skipped: #{e.class}")
        next
      end

      render json: { success: true, imported: imported }
    end
  end
end
