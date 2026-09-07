# frozen_string_literal: true

module Api
  # Shared plumbing for the chatbot API controllers (FBL-060 step 7): CSRF
  # policy (browser session token, HMAC service exemption), the JSON CSRF
  # failure shape, request-id thread propagation, the ZK claim protocol and
  # the consent/key-material helpers both the ask path and the conversation
  # CRUD need. Constants remain resolvable as Api::ChatbotController::*
  # through class inheritance, which existing tests use.
  class ChatbotBaseController < ApplicationController
    include Api::ZeroKnowledgeClaims
    include Api::ConversationPersistence
    include ServiceAuthentication

    rescue_from ActionController::InvalidAuthenticityToken do
      render json: { error: 'invalid_csrf_token' }, status: :unprocessable_entity
    end

    ZERO_KNOWLEDGE_WRAPPED_KEY_BYTES = 60
    ZERO_KNOWLEDGE_SALT_BYTES = 32

    # Browser calls use the authenticated Rails session and must pass CSRF
    # verification. Only a request whose HMAC signature has already been
    # verified is stateless and exempt from the browser token.
    skip_forgery_protection if: :authenticated_service_request_for_csrf?

    before_action :set_request_id_in_thread

    private

    def set_request_id_in_thread
      Thread.current[:request_id] = request.request_id
      # Puma reuses threads: clear the previous request's token usage so a
      # query that doesn't reach the LLM can't inherit stale counts
      Thread.current[:last_chat_tokens] = nil
    end

    def authenticated_service_request_for_csrf?
      return true if @service_bypass
      return false unless request.headers['X-Service-App'].present?

      if authenticate_service_request
        @service_bypass = true
        true
      else
        false
      end
    end

    def current_user_present?
      current_user.present?
    end

    # Returns an empty hash for an explicit plaintext-storage consent, the
    # complete pair for password-backed ZK consent, and nil for any partial
    # pair (including a named-but-blank field).
    def zero_knowledge_consent_attributes
      supplied = params.key?(:encrypted_master_key) || params.key?(:key_derivation_salt)
      return {} unless supplied
      return nil unless params[:encrypted_master_key].present? && params[:key_derivation_salt].present?

      encrypted_master_key = params[:encrypted_master_key].to_s
      key_derivation_salt = params[:key_derivation_salt].to_s
      return nil unless valid_zero_knowledge_key_material?(
        encrypted_master_key: encrypted_master_key,
        key_derivation_salt: key_derivation_salt
      )

      {
        encrypted_master_key: encrypted_master_key,
        key_derivation_salt: key_derivation_salt
      }
    end

    def valid_zero_knowledge_key_material?(encrypted_master_key:, key_derivation_salt:)
      Base64.strict_decode64(encrypted_master_key).bytesize == ZERO_KNOWLEDGE_WRAPPED_KEY_BYTES &&
        Base64.strict_decode64(key_derivation_salt).bytesize == ZERO_KNOWLEDGE_SALT_BYTES
    rescue ArgumentError
      false
    end

    # Always empty since 2026-08-08. This used to hand authenticated third-party traffic its
    # own Mistral workspace key so that usage billed separately. With that integration removed
    # no caller qualifies, and the remaining service identity is WetWijzer's own tooling, which
    # should bill to the ordinary workspace.
    def mistral_credential_options
      {}
    end

    def persist_conversation_storage_consent!(zk_attrs)
      now = Time.current
      relation = current_user.class.where(id: current_user.id)
      updates = {
        conversation_storage_consent: true,
        conversation_storage_consented_at: now,
        updated_at: now
      }

      if zk_attrs.empty?
        # Standard storage can only be selected while no ZK key exists. The
        # user must use the revoke endpoint first, which deletes the encrypted
        # conversations before destroying their key material.
        relation = relation.where(encrypted_master_key: nil, key_derivation_salt: nil)
      else
        encrypted_master_key = zk_attrs.fetch(:encrypted_master_key).to_s
        key_derivation_salt = zk_attrs.fetch(:key_derivation_salt).to_s

        # This conditional UPDATE is the compare-and-set primitive. SQLite
        # ignores SELECT ... FOR UPDATE, but a single guarded UPDATE is atomic:
        # one of two different grants claims an empty slot and the loser sees
        # zero changed rows. An identical retry matches the second branch and
        # is therefore idempotent.
        relation = relation.where(
          '((conversation_storage_consent = ? OR conversation_storage_consented_at IS NULL) AND ' \
          'encrypted_master_key IS NULL AND key_derivation_salt IS NULL) OR ' \
          '(conversation_storage_consent = ? AND encrypted_master_key = ? AND key_derivation_salt = ?)',
          false,
          true,
          encrypted_master_key,
          key_derivation_salt
        )
        updates.merge!(
          encrypted_master_key: encrypted_master_key,
          key_derivation_salt: key_derivation_salt
        )
      end

      updated = relation.update_all(updates)
      raise ZeroKnowledgeStateConflict unless updated == 1

      current_user.reload
      zero_knowledge_key_generation(current_user)
    end

    def render_zero_knowledge_state_conflict(**extra)
      render json: {
        error: 'zero_knowledge_state_conflict',
        key_generation: zero_knowledge_key_generation(current_user)
      }.merge(extra.compact), status: :conflict
      false
    end

    def attach_conversation_state(result, conversation, zk_claim: nil)
      result[:conversation_id] = conversation&.token
      result[:zero_knowledge] = conversation&.zero_knowledge? || false
      result[:revision] = conversation&.lock_version&.to_i
      result[:encrypted_revision] = conversation&.lock_version&.to_i
      result[:key_generation] = conversation&.zk_key_generation if conversation&.zero_knowledge?
      if zk_claim
        result[:claim_token] = zk_claim[:claim_token]
        result[:claim_expires_at] = zk_claim.fetch(:claim_expires_at).iso8601(3)
      end
    end

    def conversation_summary(conv)
      summary = {
        id: conv.token,
        message_count: conv.message_count || 0,
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
        # ZK: return encrypted title blob - client decrypts for display
        summary[:encrypted_title] = conv[:title]
        summary[:title] = nil
      else
        summary[:title] = conv.title || conv.last_question&.truncate(60) || 'Conversation'
      end

      summary
    end
  end
end
