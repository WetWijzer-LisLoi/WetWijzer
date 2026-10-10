# frozen_string_literal: true

# WW-PRIV-10 follow-up (Codex inbox 2026-10-07 18:15 CEST): a consent
# revocation is finished only when the stored history is deleted.
#
# Revoking records the denial and the pending deletion in one update of the
# account, under the storage boundary (ConversationStorageBoundary, the
# account row lock), and then deletes the history. When the deletion fails,
# the denial stays committed, so every writer stays fenced, and the account
# keeps its mark (users.conversation_storage_cleanup_requested_at) in the
# accounts database until a later attempt deletes the history: a retry from
# the page, the retry job, or the daily scrub.
#
# A new grant first finishes a pending deletion under the same lock, or is
# refused. While the mark is set the account does not consent, so nothing
# new is stored and the deletion can only reach history stored under the
# revoked consent; once a grant commits, the mark is gone and a late retry
# does nothing.
module ConversationHistoryCleanup
  module_function

  # Under the storage boundary. true when the history is deleted, false when
  # the deletion failed and stays pending.
  def revoke!(account)
    account.revoke_conversation_storage_consent!
    finish!(account)
  end

  # Under the storage boundary. true when no deletion is pending afterwards,
  # false when the deletion failed. Only the deletion's own failure counts:
  # an error of the accounts database, which holds the lock and the mark, is
  # raised like any other failure of the boundary.
  def finish!(account)
    return true unless pending?(account)

    begin
      delete_history(account)
    rescue StandardError => e
      Rails.logger.error("[ConversationHistoryCleanup] deletion failed: #{e.class}")
      return false
    end
    account.update_columns(conversation_storage_cleanup_requested_at: nil)
    true
  end

  def pending?(user)
    user.conversation_storage_cleanup_requested_at.present?
  end

  # Every pending deletion, one account at a time under its own lock (the
  # daily scrub). Returns the counts of finished and still pending ones.
  def sweep!
    finished = 0
    pending = 0
    User.where.not(conversation_storage_cleanup_requested_at: nil).find_each do |user|
      done = ConversationStorageBoundary.change(user) { |account| finish!(account) }
      done ? finished += 1 : pending += 1
    rescue ActiveRecord::RecordNotFound
      next
    end
    { finished: finished, pending: pending }
  end

  def delete_history(account)
    ChatbotConversation.where(user_id: account.id).delete_all
  end
end
