# frozen_string_literal: true

# WW-PRIV-10: one per-account boundary for every change to stored chatbot
# history and to the consent and key state that decides whether history may
# be stored. Each holder takes the account's row lock in the accounts
# database and keeps it only for the storage change itself, never across
# retrieval or provider work.
#
# A request captures the storage generation it was admitted under (the
# consent timestamp, renewed by every grant, and the zero-knowledge key
# material). A writer re-reads the locked account and writes only while the
# account is active, still consents and still has that generation; so a
# revoke and regrant cycle, or a switch of storage mode, fences work admitted
# before it, in standard storage too. Revocation takes the same lock, records
# the denial and deletes the history before it returns: a writer either
# committed before it (and its rows are deleted) or sees it and writes
# nothing.
#
# Accounts and chatbot history live in different databases; no transaction
# spans both. The lock orders the operations; the denial is committed in the
# accounts database even when the history deletion fails, so a retry can
# finish the cleanup while every writer stays fenced.
module ConversationStorageBoundary
  class Fenced < StandardError; end

  module_function

  # nil when the account does not consent.
  def generation(user)
    return nil unless user&.conversation_storage_consented?

    material = [user.conversation_storage_consented_at.utc.iso8601(6), user.key_derivation_salt,
                user.encrypted_master_key].join("\0")
    Digest::SHA256.hexdigest(material)
  end

  # The block's value, written under the lock; Fenced when the account no
  # longer allows storage under the generation the request was admitted with.
  def write(user, admitted:)
    User.transaction do
      account = User.lock.find_by(id: user.id)
      unless admitted && account&.active? && account.conversation_storage_consented? && generation(account) == admitted
        raise Fenced, 'conversation storage is no longer allowed for this request'
      end

      yield account
    end
  end

  # A consent or key change, serialized with every writer.
  def change(user)
    User.transaction do
      yield User.lock.find(user.id)
    end
  end
end
