# frozen_string_literal: true

# FBL-046 step 3: collector for the report-only CSP policy. Browsers POST
# application/csp-report JSON with no CSRF token and no session; the value
# is the violated directive and the blocked origin, so that is ALL that is
# logged - no query strings, no full URIs, nothing user-identifying.
class CspReportsController < ApplicationController
  skip_before_action :verify_authenticity_token

  MAX_BODY_BYTES = 8 * 1024

  def create
    body = request.body.read(MAX_BODY_BYTES + 1).to_s
    return head :payload_too_large if body.bytesize > MAX_BODY_BYTES

    report = JSON.parse(body)['csp-report'] || {}
    directive = report['effective-directive'] || report['violated-directive']
    blocked = begin
      URI.parse(report['blocked-uri'].to_s).host
    rescue URI::Error
      nil
    end
    blocked ||= report['blocked-uri'].to_s.first(40)
    document_host = begin
      URI.parse(report['document-uri'].to_s).host
    rescue URI::Error
      nil
    end
    Rails.logger.warn(
      "[CSP-REPORT] directive=#{directive.to_s.first(60)} " \
      "blocked=#{blocked.to_s.first(120)} page_host=#{document_host}"
    )
    head :no_content
  rescue JSON::ParserError
    head :bad_request
  end
end
