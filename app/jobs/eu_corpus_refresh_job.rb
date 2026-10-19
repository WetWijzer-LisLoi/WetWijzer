# frozen_string_literal: true

# Maintain only sources the bounded cache already holds. This is not a full
# archive crawler, model invocation or paid infrastructure provisioner.
class EuCorpusRefreshJob < ApplicationJob
  queue_as :eu_corpus
  MAX_REFRESH_REQUESTS = 8

  def perform
    return 0 unless LegalChatbot::EuDiscovery.enabled?

    requests = LegalChatbot::EuLiveCorpus.default.refresh_requests(limit: MAX_REFRESH_REQUESTS)
    requests.count do |payload|
      next false unless LegalChatbot::EuDiscovery.valid_payload?(payload)

      key = LegalChatbot::EuDiscovery.cache_key(payload)
      claimed = Rails.cache.write(key, 'pending', expires_in: LegalChatbot::EuDiscovery::DEDUP_SECONDS,
                                                  unless_exist: true)
      next false unless claimed

      begin
        raise 'acquisition_enqueue_rejected' unless EuCorpusAcquireJob.perform_later(payload)

        true
      rescue StandardError => e
        Rails.cache.delete(key)
        Rails.logger.warn("[EuCorpusRefreshJob] refresh enqueue unavailable: #{e.class}")
        false
      end
    end
  end
end
