# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.media_src   :self, :https, :data
    policy.object_src  :none
    # Allow inline scripts and styles for Vite/Turbo but prefer nonces in production
    policy.script_src  :self, :https, :unsafe_inline
    policy.style_src   :self, :https, :unsafe_inline
    policy.connect_src :self, :https
    # Allow same-origin frames for Turbo Frames
    policy.frame_src   :self
    # Restrict frames to prevent clickjacking
    policy.frame_ancestors :none
  end

  # Generate session nonces for permitted importmap, inline scripts, and inline styles.
  # Note: Requires session support. If sessions are disabled, remove this.
  # config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  # config.content_security_policy_nonce_directives = %w(script-src style-src)

  # Start with report-only mode, then enforce after testing
  # config.content_security_policy_report_only = true
end
