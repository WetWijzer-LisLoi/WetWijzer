# frozen_string_literal: true

# WW-PRIV-10 follow-up: retries the history deletion of a consent revocation
# that failed (ConversationHistoryCleanup). Each attempt holds the account's
# storage boundary and does nothing once the deletion is finished; the daily
# scrub sweeps whatever the retries leave.
class ConversationHistoryCleanupJob < ApplicationJob
  class Pending < StandardError; end

  queue_as :default
  retry_on Pending, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(user_id)
    finished = ConversationStorageBoundary.change(User.find(user_id)) do |account|
      ConversationHistoryCleanup.finish!(account)
    end
    raise Pending, 'the stored history could not be deleted yet' unless finished
  end
end
