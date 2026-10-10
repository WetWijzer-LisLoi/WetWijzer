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
      "site_brands=#{result[:activity_site_brands]} admin_sessions=#{result[:dead_admin_sessions]} " \
      "starter_clicks=#{result[:expired_starter_clicks]} " \
      "second_factor_challenges=#{result[:expired_second_factor_challenges]} " \
      "history_cleanups=#{result[:history_cleanups_finished]} " \
      "history_cleanups_pending=#{result[:history_cleanups_pending]} " \
      "log_addresses=#{result[:log_addresses_masked]} total=#{result[:total]} " \
      "oldest_unscrubbed_analytics=#{result[:oldest_unscrubbed_analytics_at]}"
    )
    result
  end
end
