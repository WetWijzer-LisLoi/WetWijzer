# frozen_string_literal: true

module Retention
  # Data-minimization scrub (GDPR Art. 5(1)(c)(e)). Extracted verbatim from
  # rake gdpr:scrub_pii for FBL-030 so a durable job can own it; the rake
  # task now delegates here. Retention periods are unchanged - they are the
  # legal owner's numbers and are asserted by the legal-pages tests.
  #
  # Every pass is idempotent by construction: each targets only rows whose
  # PII column is still present, so a re-run finds nothing to do.
  class PiiScrubService
    ANALYTICS_IP_RETENTION = 7.days   # current-week anonymous quota only
    FEEDBACK_IP_RETENTION = 7.days    # no functional need after creation
    ACTIVITY_RETENTION = 30.days      # security audit window
    SIGN_IN_IP_RETENTION = 30.days    # security alert window
    # ABA-007: per-EVENT brand attribution on registered/login activities.
    # The account-level projections (users.registration_brand,
    # users.last_sign_in_brand) live for the account lifetime; the detailed
    # event trail keeps its brand for this window and is then nulled - the
    # event row itself, action and timestamp, follows its existing lifecycle.
    # This period is a LEGAL-OWNER decision pinned by tests and the privacy
    # pages; it is deliberately not derived from the 30-day IP rule.
    AUTH_EVENT_BRAND_RETENTION = 90.days
    # The brand pass is batched: it may one day meet years of rows in one run
    # (the sibling ChatbotReportRetentionService sets the pattern), and an
    # unbounded UPDATE on the accounts database during a nightly job is how
    # incidents start.
    BRAND_SCRUB_BATCH_SIZE = 1_000
    BRAND_SCRUB_MAX_BATCHES = 200

    def self.call
      new.call
    end

    def call
      analytics = 0
      if ChatbotAnalytic.table_exists?
        analytics = ChatbotAnalytic
                    .where(created_at: ...ANALYTICS_IP_RETENTION.ago)
                    .where.not(ip_hash: nil)
                    .update_all(ip_hash: nil)
      end

      feedback = 0
      if ChatbotFeedback.table_exists?
        feedback = ChatbotFeedback
                   .where(created_at: ...FEEDBACK_IP_RETENTION.ago)
                   .where.not(ip_hash: nil)
                   .update_all(ip_hash: nil)
      end

      activity = AccountActivity
                 .where(created_at: ...ACTIVITY_RETENTION.ago)
                 .where.not(ip_address: [nil, ''])
                 .update_all(ip_address: nil, user_agent: nil)

      users = User
              .where(last_sign_in_at: ...SIGN_IN_IP_RETENTION.ago)
              .where.not(last_sign_in_ip: nil)
              .update_all(last_sign_in_ip: nil)

      brands = scrub_activity_site_brands

      {
        analytics_ip_hashes: analytics,
        feedback_ip_hashes: feedback,
        activity_rows: activity,
        user_sign_in_ips: users,
        activity_site_brands: brands,
        total: analytics + feedback + activity + users + brands,
        oldest_unscrubbed_analytics_at: oldest_unscrubbed_analytics_at
      }
    end

    private

    # Idempotent like every other pass, and gated on site_brand itself: by
    # day 91 the row's ip_address is ALREADY null (the 30-day pass took it),
    # so keying on any other column would find nothing. Only the one
    # attribution field is touched - never the event, its action, or its
    # timestamp.
    def scrub_activity_site_brands
      return 0 unless AccountActivity.column_names.include?('site_brand')

      cutoff = AUTH_EVENT_BRAND_RETENTION.ago
      scrubbed = 0
      BRAND_SCRUB_MAX_BATCHES.times do
        ids = AccountActivity
              .where(created_at: ...cutoff)
              .where.not(site_brand: nil)
              .limit(BRAND_SCRUB_BATCH_SIZE)
              .pluck(:id)
        break if ids.empty?

        scrubbed += AccountActivity.where(id: ids).update_all(site_brand: nil)
        break if ids.size < BRAND_SCRUB_BATCH_SIZE
      end
      scrubbed
    end

    private

    # The freshest signal that the scrub is keeping up: the oldest analytics
    # row still carrying an ip_hash must never be much older than the window.
    def oldest_unscrubbed_analytics_at
      return nil unless ChatbotAnalytic.table_exists?

      ChatbotAnalytic.where.not(ip_hash: nil).minimum(:created_at)
    end
  end
end
