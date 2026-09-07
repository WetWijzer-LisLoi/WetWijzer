# frozen_string_literal: true

# Content Security Policy
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# FBL-046 step 2 - measured inventory of real external RESOURCE origins
# (link hrefs do not count; CSP governs loads):
#   script-src : the configurable umami analytics host (layout line ~509)
#   img-src    : www.dekamer.be (MP portrait photos on parliamentary pages)
#   connect-src: the umami host (script.js posts its events there)
# Everything else the frontend loads is same-origin or data:. Step 3 (replace
# the generic :https allowances with this explicit list) must run in
# report-only mode against production traffic first; step 4 (style nonces)
# depends on auditing the remaining inline styles.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    # FBL-046 step 1: pin the document base and every form target to this
    # origin. Neither is covered by default-src, so without these a
    # successful injection could re-point relative URLs via <base> or
    # exfiltrate credentials through a foreign form action.
    policy.base_uri    :self
    policy.form_action :self
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
    # Restrict frames to prevent clickjacking. No override exists: the embedded-WebView
    # middleware that used to relax this for signed requests was removed 2026-08-08.
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end

# FBL-046 step 3: the STRICT explicit-origin policy runs in parallel as
# Content-Security-Policy-Report-Only, so production traffic reports what
# the generic :https allowances above still hide before the owner flips
# enforcement (step 6). Origins are the measured step-2 inventory:
# analytics.wetwijzer.be (umami script + its event POSTs) and
# www.dekamer.be (MP portraits). Violations POST to /csp-report, which
# logs directive + blocked host only. The enforced policy is unchanged.
module CspReportOnly
  UMAMI = 'https://analytics.wetwijzer.be'
  NONCE_ENV_KEY = 'action_dispatch.content_security_policy_nonce'

  # The candidate policy MUST carry the per-request nonce. The application
  # serves nonced inline scripts (the enforced policy allows them via
  # 'nonce-...'), so a report-only copy without the nonce reports a violation
  # for every legitimate script - which is exactly what happened: the
  # collector filled with script-src-elem/inline reports from real devices
  # (2026-08-20), drowning any genuine finding, and promoting that policy to
  # enforcing would have blocked every inline script and broken the site.
  def self.policy(nonce)
    script_src = ["'self'", UMAMI]
    script_src << "'nonce-#{nonce}'" if nonce.present?
    [
      "default-src 'self'",
      "base-uri 'self'",
      "form-action 'self'",
      "font-src 'self' data:",
      "img-src 'self' data: https://www.dekamer.be",
      "media-src 'self' data:",
      "object-src 'none'",
      "script-src #{script_src.join(' ')}",
      "style-src 'self' 'unsafe-inline'",
      "connect-src 'self' #{UMAMI}",
      "frame-src 'self'",
      "worker-src 'self' blob:",
      "frame-ancestors 'none'",
      'report-uri /csp-report'
    ].join('; ')
  end

  class Middleware
    def initialize(app) = @app = app

    def call(env)
      status, headers, body = @app.call(env)
      if headers['Content-Type'].to_s.include?('text/html') &&
         !headers.key?('Content-Security-Policy-Report-Only')
        headers['Content-Security-Policy-Report-Only'] = CspReportOnly.policy(env[NONCE_ENV_KEY])
      end
      [status, headers, body]
    end
  end
end

Rails.application.config.middleware.insert_before 0, CspReportOnly::Middleware if ENV['CSP_REPORT_ONLY'] == 'true'
