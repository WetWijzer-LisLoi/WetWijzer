# frozen_string_literal: true

# HTTP Permissions Policy
# https://developers.google.com/web/updates/2018/06/feature-policy

Rails.application.config.permissions_policy do |policy|
  # Restrict dangerous browser features
  policy.camera      :none
  policy.microphone  :none
  policy.geolocation :none
  policy.usb         :none
  policy.payment     :none
  policy.gyroscope   :none
  policy.magnetometer :none
  policy.fullscreen :self
end
