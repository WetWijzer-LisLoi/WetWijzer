# frozen_string_literal: true

# FBL-046 step 3: collector for the report-only CSP policy. Browsers POST
# application/csp-report JSON with no CSRF token and no session; the value
# is classified into a fixed directive/origin/page-brand vocabulary. Neither
# logs nor retained daily counts echo a client-supplied hostname: a secret can
# live in a subdomain just as easily as a path or query.
#
# WW-SEC-08 and WW-SEC-10: the body is whatever a client sends. Only an
# object whose csp-report is an object is a report; any other JSON shape is a
# 400, not a 500. Every logged field is an allowlisted directive, a keyword or
# a fixed category, so no value can carry a newline or a control character into
# the log and forge a record. Rack::Attack bounds the rate (csp_reports/ip).
class CspReportsController < ApplicationController
  skip_before_action :verify_authenticity_token

  MAX_BODY_BYTES = 8 * 1024
  def create
    body = request.body.read(MAX_BODY_BYTES + 1).to_s
    return head :content_too_large if body.bytesize > MAX_BODY_BYTES

    parsed = JSON.parse(body)
    report = parsed.is_a?(Hash) ? parsed['csp-report'] : nil
    return head :bad_request unless report.is_a?(Hash)

    categories = CspReportMetrics.classify(report)
    metric = CspReportMetrics.record(categories)
    Rails.logger.warn("[CSP-REPORT] directive=#{categories['directives']} blocked=#{categories['blocked']} " \
                      "page_brand=#{categories['page_brands']} measurement=#{metric}")
    head :no_content
  rescue JSON::ParserError
    head :bad_request
  end
end
