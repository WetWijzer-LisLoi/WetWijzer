# frozen_string_literal: true

# Content Security Policy
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# FBL-046 step 2 - measured inventory of real external RESOURCE origins
# (link hrefs do not count; CSP governs loads):
#   script-src : the shared, pinned umami analytics host (BrandingHelper)
#   img-src    : www.dekamer.be (MP portrait photos on parliamentary pages) and
#                docs.vlaamsparlement.be (the members' photos on
#                /vlaams-parlement, which the step-2 inventory missed: found by
#                the real-browser pass of 2026-10-15, 124 photos)
#   connect-src: the umami host (script.js posts its events there)
# Everything else the frontend loads is same-origin or data:. Step 4 (style
# nonces) depends on auditing the remaining inline styles.
module CspReportOnly
  UMAMI = 'https://analytics.wetwijzer.be'
  DEKAMER = 'https://www.dekamer.be'
  VLAAMS_PARLEMENT = 'https://docs.vlaamsparlement.be'
  NONCE_ENV_KEY = 'action_dispatch.content_security_policy_nonce'

  # The strict policy as one header value. The policy below is enforced from
  # this list (D7 step 6, 2026-10-15); the report-only middleware that staged
  # it serves the same value and is no longer installed (see the end of this
  # file). A test holds the enforced header to it, directive by directive.
  #
  # It MUST carry the per-request nonce. The application serves nonced inline
  # scripts, so a copy without the nonce reports a violation for every
  # legitimate script - which is exactly what happened: the collector filled
  # with script-src-elem/inline reports from real devices (2026-08-20),
  # drowning any genuine finding, and promoting that policy to enforcing would
  # have blocked every inline script and broken the site.
  def self.policy(nonce)
    script_src = ["'self'", UMAMI]
    script_src << "'nonce-#{nonce}'" if nonce.present?
    [
      "default-src 'self'",
      "base-uri 'self'",
      "form-action 'self'",
      "font-src 'self' data:",
      "img-src 'self' data: #{DEKAMER} #{VLAAMS_PARLEMENT}",
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

# D7 step 6 (2026-10-15): the strict explicit-origin policy is ENFORCED. It ran
# report-only from FBL-046 step 3, and the week after F15's fix (b9ee58867)
# showed nothing of ours it would block: the reports were inline scripts (both
# policies treat them alike), mostly from automated browsers, and other hosts'
# fonts that browser extensions inject. A headless browser with no extension
# then loaded 73 pages: every public page type of the four brands and the no-JS
# layout, 10 of them by a Turbo visit. The one violation was /vlaams-parlement's
# member photos (docs.vlaamsparlement.be, allowed above); every other foreign
# load was the umami host or the Chamber's portraits (docs/ops/open-items.md,
# WW-SEC-PRIV-01 D7). Enforced violations still POST to /csp-report, so the
# daily counts (security:csp_measurements) now show what the policy blocks.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # FBL-046 step 1: pin the document base and every form target to this
    # origin. Neither is covered by default-src, so without these a
    # successful injection could re-point relative URLs via <base> or
    # exfiltrate credentials through a foreign form action.
    policy.base_uri    :self
    policy.form_action :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, CspReportOnly::DEKAMER, CspReportOnly::VLAAMS_PARLEMENT
    policy.media_src   :self, :data
    policy.object_src  :none
    # Inline scripts run by their per-request nonce (added below), never by
    # 'unsafe-inline'.
    policy.script_src  :self, CspReportOnly::UMAMI
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self, CspReportOnly::UMAMI
    # Allow same-origin frames for Turbo Frames
    policy.frame_src   :self
    # Allow ALTCHA proof-of-work Web Workers (uses blob: URLs for worker threads)
    policy.worker_src  :self, :blob
    # Restrict frames to prevent clickjacking. No override exists: the embedded-WebView
    # middleware that used to relax this for signed requests was removed 2026-08-08.
    policy.frame_ancestors :none
    policy.report_uri '/csp-report'
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end

# The report-only copy is not installed any more: with the strict policy
# enforced it would only send every violation twice. A next candidate (style
# nonces, step 4) can be staged the same way, through CspReportOnly::Middleware
# with its own policy.
