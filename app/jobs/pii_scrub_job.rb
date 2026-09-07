# frozen_string_literal: true

# GDPR data-minimization scrub as a durable job (FBL-030). The systemd timer
# ww-gdpr-scrub currently owns the daily production run of the same logic via
# rake; this job exists so Solid Queue can take that ownership over once the
# owner verifies the in-Puma scheduler, after which the duplicate Whenever
# entry in config/schedule.rb and the systemd unit can be retired.
class PiiScrubJob < ApplicationJob
  queue_as :default

  def perform
    result = Retention::PiiScrubService.call
    Rails.logger.info(
      "[RETENTION] pii scrub analytics=#{result[:analytics_ip_hashes]} " \
      "feedback=#{result[:feedback_ip_hashes]} activity=#{result[:activity_rows]} " \
      "sign_in_ips=#{result[:user_sign_in_ips]} " \
      "site_brands=#{result[:activity_site_brands]} total=#{result[:total]} " \
      "oldest_unscrubbed_analytics=#{result[:oldest_unscrubbed_analytics_at]}"
    )
    result
  end
end
