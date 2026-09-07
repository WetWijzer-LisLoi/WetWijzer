# frozen_string_literal: true

module Api
  # Zero-knowledge conversation claim protocol: key-generation fingerprinting,
  # legacy-row generation binding, pre-ask state validation, the exclusive
  # claim/rollback tuple and the pre-delivery ownership check. Extracted
  # verbatim from Api::ChatbotController (FBL-060 step 3) as a concern so
  # every method keeps its name and receiver: the white-box ZK protocol suite
  # drives these names on the controller instance and stays authoritative.
  # The claim TTL and conflict exception live here but remain resolvable as
  # Api::ChatbotController::* through ancestry, which existing rescues and
  # tests rely on.
  module ZeroKnowledgeClaims
    extend ActiveSupport::Concern

    class ZeroKnowledgeStateConflict < StandardError; end

    ZERO_KNOWLEDGE_CLAIM_TTL = 5.minutes

    private

    def zero_knowledge_key_generation(user)
      encrypted_master_key = user&.encrypted_master_key
      key_derivation_salt = user&.key_derivation_salt
      return nil unless encrypted_master_key.present? && key_derivation_salt.present?

      Digest::SHA256.hexdigest("#{key_derivation_salt}\0#{encrypted_master_key}")
    end

    def zero_knowledge_key_material_present?(user)
      user&.encrypted_master_key.present? || user&.key_derivation_salt.present?
    end

    # Rows written before the key-generation protocol contain valid ciphertext
    # but no generation fingerprint. Bind them on first authenticated read so
    # upgraded clients can decrypt and continue them without rewriting data or
    # advancing the snapshot revision.
    def bind_legacy_zero_knowledge_generation!(conversation)
      return conversation unless conversation

      unless defined?(@zero_knowledge_read_generation)
        current_user.reload
        @zero_knowledge_read_generation = zero_knowledge_key_generation(current_user)
        @zero_knowledge_read_consented = current_user.conversation_storage_consented?
      end
      generation = @zero_knowledge_read_generation

      # Never expose a row under a storage mode that disagrees with the
      # account. This also quarantines historical inconsistent transitions.
      if conversation.zero_knowledge? != generation.present?
        raise ZeroKnowledgeStateConflict
      end
      return conversation unless conversation.zero_knowledge?
      raise ZeroKnowledgeStateConflict unless @zero_knowledge_read_consented && generation.present?
      if conversation.zk_key_generation.present?
        raise ZeroKnowledgeStateConflict unless conversation.zk_key_generation == generation

        return conversation
      end

      conversation.bind_zk_key_generation!(
        generation,
        expected_revision: conversation.lock_version.to_i
      )
      conversation
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      raise ZeroKnowledgeStateConflict
    end

    def nonnegative_integer_param(value)
      string = value.to_s
      return nil unless string.match?(/\A\d+\z/)

      Integer(string, 10)
    rescue ArgumentError
      nil
    end

    def validate_zero_knowledge_chat_state!(conversation)
      return true unless conversation&.zero_knowledge?

      current_user.reload
      expected_revision = nonnegative_integer_param(params[:conversation_revision])
      supplied_generation = params[:key_generation].to_s
      current_generation = zero_knowledge_key_generation(current_user)
      clear_expired_conversation_claim!(conversation)
      return render_zero_knowledge_state_conflict if conversation.zk_claim_token.present?

      # A newly-created ZK conversation has no token/revision that the browser
      # could have supplied yet. Its account generation was bound atomically at
      # creation and revision zero is returned with this first answer. Every
      # subsequent chat and encrypted snapshot must use the normal CAS path.
      if params[:conversation_id].blank? && expected_revision.nil? &&
         supplied_generation.present? &&
         current_user.conversation_storage_consented? &&
         current_generation.present? &&
         supplied_generation == current_generation &&
         conversation.lock_version.to_i.zero? &&
         conversation.zk_key_generation == current_generation
        return true
      end

      unless current_user.conversation_storage_consented? &&
             expected_revision.present? &&
             supplied_generation.present? &&
             current_generation.present? &&
             supplied_generation == current_generation &&
             conversation.lock_version.to_i == expected_revision &&
             (conversation.zk_key_generation.blank? || conversation.zk_key_generation == current_generation)
        return render_zero_knowledge_state_conflict
      end

      if conversation.zk_key_generation.blank?
        conversation.bind_zk_key_generation!(current_generation, expected_revision: expected_revision)
      end

      true
    rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotFound
      render_zero_knowledge_state_conflict
    end

    def clear_expired_conversation_claim!(conversation)
      return conversation unless conversation&.zk_claim_token.present?
      return conversation if conversation.zk_claimed_at.present? &&
                             conversation.zk_claimed_at >= ZERO_KNOWLEDGE_CLAIM_TTL.ago

      ChatbotConversation.where(
        id: conversation.id,
        lock_version: conversation.lock_version,
        zk_claim_token: conversation.zk_claim_token
      ).update_all(
        # Advance the revision while clearing an abandoned lease. An owner that
        # passed its TTL check just before this cleanup can no longer commit on
        # the same optimistic-lock version afterward.
        lock_version: conversation.lock_version.to_i + 1,
        zk_claim_token: nil,
        zk_claimed_at: nil
      )
      conversation.reload
    end

    def ensure_zero_knowledge_conversation_readable!(conversation)
      return conversation unless conversation&.zero_knowledge?

      clear_expired_conversation_claim!(conversation)
      raise ZeroKnowledgeStateConflict if conversation.zk_claim_token.present?

      conversation
    rescue ActiveRecord::RecordNotFound
      raise ZeroKnowledgeStateConflict
    end

    def claim_zero_knowledge_chat_revision!(conversation)
      return nil unless conversation

      current_user.reload
      raise ZeroKnowledgeStateConflict unless current_user.conversation_storage_consented?

      clear_expired_conversation_claim!(conversation)
      current_generation = zero_knowledge_key_generation(current_user)
      if conversation.zero_knowledge?
        expected_revision = if params[:conversation_id].blank?
                              conversation.lock_version.to_i
                            else
                              nonnegative_integer_param(params[:conversation_revision])
                            end
        supplied_generation = params[:key_generation].to_s
        raise ZeroKnowledgeStateConflict unless expected_revision.present? &&
                                                current_generation.present? &&
                                                supplied_generation == current_generation
      else
        raise ZeroKnowledgeStateConflict if current_generation.present?

        expected_revision = conversation.lock_version.to_i
      end

      claimed_revision = expected_revision + 1
      claim_token = SecureRandom.hex(32)
      relation = ChatbotConversation.where(
        id: conversation.id,
        lock_version: expected_revision,
        zk_claim_token: nil
      )
      relation = if conversation.zero_knowledge?
                   relation.where(zero_knowledge: true, zk_key_generation: current_generation)
                 else
                   relation.where(zero_knowledge: [false, nil], zk_key_generation: nil)
                           .where('archived IS NULL OR archived = ?', false)
                 end
      updated = relation.update_all(
        lock_version: claimed_revision,
        zk_claim_token: claim_token,
        zk_claimed_at: Time.current,
        updated_at: Time.current
      )
      raise ZeroKnowledgeStateConflict unless updated == 1

      conversation.reload
      {
        conversation_id: conversation.id,
        expected_revision: expected_revision,
        claimed_revision: claimed_revision,
        key_generation: current_generation,
        claim_token: claim_token,
        claim_expires_at: conversation.zk_claimed_at + ZERO_KNOWLEDGE_CLAIM_TTL,
        zero_knowledge: conversation.zero_knowledge?
      }
    end

    def rollback_zero_knowledge_chat_revision!(conversation, claim)
      return unless conversation && claim

      relation = ChatbotConversation.where(
        id: claim[:conversation_id],
        lock_version: claim[:claimed_revision],
        zk_claim_token: claim[:claim_token]
      )
      relation = if claim[:zero_knowledge]
                   relation.where(zero_knowledge: true, zk_key_generation: claim[:key_generation])
                 else
                   relation.where(zero_knowledge: [false, nil], zk_key_generation: nil)
                 end
      updated = relation.update_all(
        lock_version: claim[:expected_revision],
        zk_claim_token: nil,
        zk_claimed_at: nil
      )
      if updated == 1
        conversation.reload
      else
        Rails.logger.error(
          "Zero-knowledge revision rollback failed " \
          "(conversation=#{claim[:conversation_id]}, claimed=#{claim[:claimed_revision]})"
        )
      end
    rescue StandardError => e
      Rails.logger.error("Zero-knowledge revision rollback errored: #{e.class}")
    end

    # Fresh ownership check immediately before answer delivery. This defines
    # the ordering between a provider completion and a concurrent explicit
    # clear: if clear already fenced the tuple, this request loses and refunds.
    def conversation_claim_owned?(claim)
      return true unless claim

      current_user.reload
      return false unless current_user.conversation_storage_consented?

      current_generation = zero_knowledge_key_generation(current_user)
      return false if claim[:zero_knowledge] ? current_generation != claim[:key_generation] : current_generation.present?

      relation = ChatbotConversation.where(
        id: claim[:conversation_id],
        lock_version: claim[:claimed_revision],
        zk_claim_token: claim[:claim_token]
      )
      relation = if claim[:zero_knowledge]
                   relation.where(zero_knowledge: true, zk_key_generation: claim[:key_generation])
                 else
                   relation.where(zero_knowledge: [false, nil], zk_key_generation: nil)
                           .where('archived IS NULL OR archived = ?', false)
                 end
      relation.where('zk_claimed_at >= ?', ZERO_KNOWLEDGE_CLAIM_TTL.ago).exists?
    end
  end
end
