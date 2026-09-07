# frozen_string_literal: true

# Applies the paid-period boundary for canceled and past-due Pro subscriptions
# even when the former subscriber never triggers Subscription#pro?'s fallback.
class ExpireCancelledSubscriptionsJob < ApplicationJob
  queue_as :default

  def perform
    expired = Subscription.expire_cancelled!
    Rails.logger.info("[Subscription Expiry] expired=#{expired}")
    expired
  end
end
