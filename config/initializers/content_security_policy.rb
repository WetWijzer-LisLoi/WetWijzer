# frozen_string_literal: true

# Content Security Policy
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.media_src   :self, :https, :data
    policy.object_src  :none
    # Allow inline scripts and styles for Vite/Turbo but prefer nonces in production
    policy.script_src  :self, :https
    policy.style_src   :self, :https, :unsafe_inline
    policy.connect_src :self, :https
    # Allow same-origin frames for Turbo Frames
    policy.frame_src   :self
    # Allow ALTCHA proof-of-work Web Workers (uses blob: URLs for worker threads)
    policy.worker_src  :self, :blob
    # Restrict frames to prevent clickjacking
    # Allow Praxis desktop WebView (file:// origin) when accessed with embedded=true
    # Regular browser access remains restricted to :none via middleware override
    policy.frame_ancestors :none
  end

  # Dynamic CSP override for Praxis embedded WebView
  # When ?embedded=true is present, relax frame-ancestors to allow desktop app framing
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
