# frozen_string_literal: true

# Background job to send search alert notifications
#
# This job runs daily/weekly to check for new laws matching
# user-subscribed search alerts and sends email notifications.
#
# @example Running manually
#   SearchAlertNotificationJob.perform_now('daily')
#
# @example Schedule with cron
#   # config/schedule.yml (whenever gem)
#   every 1.day, at: '6:00 am' do
#     runner "SearchAlertNotificationJob.perform_now('daily')"
#   end
class SearchAlertNotificationJob < ApplicationJob
  queue_as :default

  # @param frequency [String] 'daily' or 'weekly'
  def perform(frequency = 'daily')
    Rails.logger.info("[SearchAlertJob] Starting #{frequency} notification run")
    
    alerts_processed = 0
    notifications_sent = 0

    SearchAlert.due_for_notification(frequency).find_each do |alert|
      alerts_processed += 1
      
      begin
        new_laws = SearchAlert.find_new_matches(alert)
        
        if new_laws.any?
          SearchAlertMailer.new_results(alert, new_laws.to_a).deliver_later
          alert.mark_notified!(new_laws.size)
          notifications_sent += 1
          
          Rails.logger.info("[SearchAlertJob] Sent notification for alert ##{alert.id}: #{new_laws.size} new laws")
        else
          # Update last_notified even if no results to prevent re-checking
          alert.mark_notified!(0)
        end
      rescue StandardError => e
        Rails.logger.error("[SearchAlertJob] Error processing alert ##{alert.id}: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end
    end

    Rails.logger.info("[SearchAlertJob] Completed: #{alerts_processed} alerts processed, #{notifications_sent} notifications sent")
    
    { alerts_processed: alerts_processed, notifications_sent: notifications_sent }
  end
end
