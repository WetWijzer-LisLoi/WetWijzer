# frozen_string_literal: true

module Api
  # Server-side conversation history and consent endpoints, split out of the
  # monolithic chatbot controller (FBL-060 step 7). Paths are unchanged;
  # only the routing target moved. Every action body is verbatim.
  class ChatbotConversationsController < ChatbotBaseController
    # WW-SEC-09: request caps before anything parses a body, and field checks
    # before anything is stored (the per-row bounds live in ChatbotConversation;
    # nginx accepts 25 MB, which is no row limit). The browser never sends
    # numacs on the encrypted path.
    ENCRYPTED_BODY_MAX_BYTES = 3 * 1024 * 1024
    IMPORT_BODY_MAX_BYTES = 8 * 1024 * 1024
    IMPORT_MESSAGE_MAX_CHARS = 50_000
    IMPORT_CONVERSATION_MAX_BYTES = 1024 * 1024
    IMPORT_MESSAGE_KEYS = ['role', 'content', 'analytic_id', ChatbotConversation::CONTEXT_CONTENT_KEY].freeze
    CANONICAL_BASE64 = %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?\z}
    CONTEXT_NUMAC = /\A(?:\d{10}|fisconet_\d{1,12})\z/i

    # WW-PRIV-10: a grant waits until history pending deletion is gone.
    class HistoryCleanupPending < StandardError; end

    prepend_before_action :bound_payload_body, only: %i[update_encrypted_payload import_conversations]

    # ============================================
    # CONVERSATION MANAGEMENT (server-side history)
    # ============================================

    # GET /api/chatbot/conversations
    # List user's conversations (metadata only - no message content)
    def conversations
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      # WW-PRIV-10: history awaiting deletion after a revocation is no longer
      # history; the page offers the retry instead of listing it.
      if ConversationHistoryCleanup.pending?(current_user)
        return render json: { conversations: [], consent: current_user.conversation_storage_consented?,
                              history_cleanup_pending: true }
      end

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
        consent: current_user.conversation_storage_consented?,
        history_cleanup_pending: false
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

      # Same lock as the explicit clear above: a deleted conversation fences
      # a running ask's claim, and the ask's first paid request is admitted
      # under this lock after re-reading it.
      change_under_storage_boundary { conv.destroy }
      render json: { success: true }
    end

    # PATCH /api/chatbot/conversations/:token
    # Rename or pin a conversation
    def update_conversation
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      conversation_storage_admitted

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s

      # Clearing is an explicit cancellation fence for both storage modes.
      # Always use a revision CAS, even when the first read saw no token: an ask
      # can claim the row between that read and this write. Retrying against the
      # fresh revision guarantees any newly-published token is cleared instead
      # of archiving a row that remains lease-locked for five minutes.
      if params[:archived] == true && params[:cancel_active_claim] == true
        # Under the account's row lock (owner policy 2026-10-18): the first
        # paid AI request of a running ask is admitted under the same lock,
        # after re-reading this claim. So either this clear commits first and
        # that ask sends nothing and refunds, or the ask was admitted first
        # and its answer is discarded against the fenced claim while its
        # single charge stands. The lock covers only this CAS loop.
        cancelled = 0
        missing = false
        change_under_storage_boundary do
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
            break if cancelled == 1

            conv.reload
          end
        rescue ActiveRecord::RecordNotFound
          missing = true
        end
        return render json: { error: 'Conversation not found' }, status: :not_found if missing

        if cancelled == 1
          conv.reload
          return render json: { success: true, conversation: conversation_summary(conv) }
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
        # WW-PRIV-10: written under the storage boundary.
        write_under_storage_boundary { conv.save! }
      rescue ConversationStorageBoundary::Fenced
        return render json: { error: 'conversation_storage_unavailable' }, status: :conflict
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
      # an idempotent retry of the exact same wrapped-key pair; WW-PRIV-10: under
      # the storage boundary, so no writer interleaves with the change.
      begin
        key_generation = change_under_storage_boundary do |account|
          # WW-PRIV-10: history still pending deletion from an earlier
          # revocation goes first, under the same lock; a grant never adopts it.
          raise HistoryCleanupPending unless ConversationHistoryCleanup.finish!(account)

          generation_before = ConversationStorageBoundary.generation(account)
          granted = persist_conversation_storage_consent!(zk_attrs)
          # Root review 2026-10-18 (12:22): a successful grant renews the
          # storage generation (its consent time), even for the identical key
          # pair. A conversation claim taken under the old generation must
          # neither deliver its answer nor accept an encrypted snapshot
          # afterwards, so the account's active claims are cancelled here,
          # under the same gate and before it is released, with the revision
          # protocol; messages, titles and archive flags stay. A cancellation
          # that cannot be made fails the grant instead of reporting success.
          fence_active_conversation_claims!(current_user) if ConversationStorageBoundary.generation(current_user) != generation_before
          granted
        end
      rescue HistoryCleanupPending
        schedule_history_cleanup_retry
        return render json: { error: 'history_cleanup_pending', consent: false, history_cleanup_pending: true },
                      status: :service_unavailable
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

      # WW-PRIV-10: under the storage boundary, disable storage, destroy key
      # material and mark the history for deletion in the accounts database,
      # then delete the history (ConversationHistoryCleanup). Every writer
      # takes the same lock and re-checks consent and its admitted generation,
      # so none can recreate content after this. A failed deletion leaves the
      # denial and the mark committed and says so; the retry job and the daily
      # scrub try again, and this request is idempotent, so the page can retry
      # it too, with consent already withdrawn.
      deleted = change_under_storage_boundary { |account| ConversationHistoryCleanup.revoke!(account) }
      unless deleted
        schedule_history_cleanup_retry
        return render json: { error: 'history_deletion_failed', consent: false, history_cleanup_pending: true },
                      status: :service_unavailable
      end

      render json: {
        success: true,
        consent: false,
        zero_knowledge: false,
        key_generation: nil,
        history_cleanup_pending: false
      }
    end

    # DELETE /api/chatbot/conversations/history_cleanup
    # WW-PRIV-10: finishes a deletion a revocation could not complete, with
    # or without consent. Idempotent, and it never withdraws consent itself,
    # so a page left open cannot touch history stored under a newer grant.
    def finish_history_cleanup
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      finished = change_under_storage_boundary { |account| ConversationHistoryCleanup.finish!(account) }
      unless finished
        schedule_history_cleanup_retry
        return render json: { error: 'history_deletion_failed', history_cleanup_pending: true },
                      status: :service_unavailable
      end

      render json: { success: true, history_cleanup_pending: false }
    end

    # PATCH /api/chatbot/conversations/:token/encrypted
    # Client-side encrypted payload update (zero-knowledge mode)
    # Server stores opaque ciphertext - cannot decrypt
    def update_encrypted_payload
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user_present?

      ChatbotConversation.ensure_table_and_columns_exist
      conv = ChatbotConversation.find_by(token: params[:token])

      return render json: { error: 'Conversation not found' }, status: :not_found unless conv && conv.user_id.to_s == current_user.id.to_s

      conversation_storage_admitted
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

      payload = encrypted_payload_fields
      return render json: { error: 'encrypted_payload_invalid' }, status: :unprocessable_entity unless payload

      begin
        write_under_storage_boundary do
          conv.update_encrypted_payload!(
            **payload,
            expected_revision: expected_revision,
            key_generation: current_generation,
            claim_token: supplied_claim_token
          )
        end
      rescue ConversationStorageBoundary::Fenced, ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
        return render_zero_knowledge_state_conflict
      rescue ActiveRecord::RecordInvalid
        return render json: { error: 'encrypted_payload_invalid' }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error(
          'Encrypted conversation persistence failed ' \
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
      # WW-PRIV-10: the generation this import was admitted under; every row is
      # written under the storage boundary against it.
      conversation_storage_admitted
      imported = 0
      skipped = 0

      items.first(20).each do |item|
        messages = importable_messages(item)
        unless messages
          skipped += 1
          next
        end

        language = item[:language]
        conv = ChatbotConversation.new(
          user_id: current_user.id,
          language: language.is_a?(String) && language.bytesize.between?(1, 16) ? language : 'nl'
        )
        # Set title from first user message
        first_q = messages.find { |m| m['role'] == 'user' }
        conv.title = (first_q&.dig('content') || 'Conversation').truncate(100)
        conv.messages_array = messages
        conv.message_count = conv.messages_array.length
        conv.expires_at = nil # Consented - no expiry
        write_under_storage_boundary { conv.save! }
        imported += 1
      rescue ConversationStorageBoundary::Fenced
        return render json: { error: 'conversation_storage_unavailable', imported: imported }, status: :conflict
      rescue StandardError => e
        Rails.logger.warn("[ConversationImport] Skipped: #{e.class}")
        skipped += 1
        next
      end

      render json: { success: true, imported: imported, skipped: skipped }
    end

    private

    # WW-PRIV-10: false when the history could not be deleted; the denial is
    # committed either way.
    # A failed deletion is retried by ConversationHistoryCleanupJob, and by the
    # daily scrub when the job cannot even be queued.
    def schedule_history_cleanup_retry
      ConversationHistoryCleanupJob.set(wait: 1.minute).perform_later(current_user.id)
    rescue StandardError => e
      Rails.logger.error("[ConsentRevoke] history cleanup retry not queued: #{e.class}")
    end

    # WW-SEC-09 -----------------------------------------------------------

    def bound_payload_body
      limit = action_name == 'import_conversations' ? IMPORT_BODY_MAX_BYTES : ENCRYPTED_BODY_MAX_BYTES
      return if request.content_length.to_i <= limit

      render json: { error: 'payload_too_large' }, status: 413
    end

    # The snapshot's fields, or nil when any is the wrong type, malformed or
    # out of bounds. A real snapshot is canonical Base64 of IV, ciphertext and
    # tag, so even an empty history is at least 40 characters.
    # Cancels every active claim of the account's conversations, each with the
    # same compare-and-set as an explicit clear (lock_version advanced, token
    # and time cleared), so a request that still holds the old claim sees it
    # gone and an encrypted PATCH with the old revision is refused. Called
    # under the account gate, accounts before chatbot, the order every
    # writer uses. A claim that cannot be cancelled is a state conflict.
    def fence_active_conversation_claims!(account)
      ChatbotConversation.ensure_table_and_columns_exist
      ChatbotConversation.where(user_id: account.id).where.not(zk_claim_token: nil).find_each do |conv|
        cancelled = 0
        8.times do
          cancelled = ChatbotConversation.where(id: conv.id, lock_version: conv.lock_version).update_all(
            lock_version: conv.lock_version.to_i + 1,
            zk_claim_token: nil,
            zk_claimed_at: nil,
            updated_at: Time.current
          )
          break if cancelled == 1

          conv.reload
          break if conv.zk_claim_token.nil?
        rescue ActiveRecord::RecordNotFound
          cancelled = 1 # deleted meanwhile: nothing left to fence
          break
        end
        raise ZeroKnowledgeStateConflict unless cancelled == 1 || conv.zk_claim_token.nil?
      end
    end

    def encrypted_payload_fields
      messages = params[:encrypted_messages]
      title = params[:encrypted_title]
      count = nonnegative_integer_param(params[:message_count])
      numacs = params[:numacs].nil? ? [] : params[:numacs]
      return nil unless ciphertext?(messages, ChatbotConversation::MESSAGES_MAX_BYTES)
      return nil unless title.blank? || ciphertext?(title, ChatbotConversation::TITLE_MAX_BYTES)
      return nil unless count&.between?(1, ChatbotConversation::MESSAGE_COUNT_MAX)
      return nil unless numacs.is_a?(Array) && numacs.size <= ChatbotConversation::CONTEXT_NUMACS_MAX &&
                        numacs.all? { |numac| numac.is_a?(String) && numac.match?(CONTEXT_NUMAC) }

      { encrypted_messages: messages, encrypted_title: title.presence, message_count: count, numacs: numacs }
    end

    def ciphertext?(value, max_bytes)
      value.is_a?(String) && value.bytesize.between?(40, max_bytes) && value.match?(CANONICAL_BASE64)
    end

    # An imported conversation's last messages as plain hashes with the keys
    # the history uses, or nil when the item is malformed or any message is out
    # of bounds. Nothing is cut to fit: an oversized conversation is skipped
    # and counted.
    def importable_messages(item)
      return nil unless item.is_a?(ActionController::Parameters) && item[:messages].is_a?(Array)

      messages = item[:messages].last(ChatbotConversation::MAX_MESSAGES)
      return nil unless messages.length >= 2 && messages.all?(ActionController::Parameters)

      plain = messages.map { |message| message.permit(*IMPORT_MESSAGE_KEYS).to_h }
      return nil unless plain.all? { |message| importable_message?(message) }
      return nil if plain.to_json.bytesize > IMPORT_CONVERSATION_MAX_BYTES

      plain
    end

    def importable_message?(message)
      texts = [message['content'], message[ChatbotConversation::CONTEXT_CONTENT_KEY]]
      %w[user assistant].include?(message['role']) && message['content'].is_a?(String) &&
        texts.compact.all? { |text| text.is_a?(String) && text.length <= IMPORT_MESSAGE_MAX_CHARS } &&
        (message['analytic_id'].nil? || message['analytic_id'].is_a?(Integer))
    end
  end
end
