# frozen_string_literal: true

class MonitoringMailer < ApplicationMailer
  def canary_failure
    mail(
      to: params.fetch(:to),
      from: params.fetch(:from),
      subject: '[WetWijzer CANARY] health check FAILED',
      body: params.fetch(:body),
      content_type: 'text/plain'
    )
  end

  # Generic operational alert, subject supplied by the caller.
  #
  # This exists because the host has no mail transport at all: sendmail, msmtp
  # and mail are absent, so a shell script that needs to reach a human has no
  # route except back through the application's SMTP configuration. Scripts call
  # it with `bin/rails runner`.
  #
  # Deliberately plain text and free-form rather than a templated mailer: the
  # callers are ops scripts whose output is already a human-readable report, and
  # a template would only get in the way of pasting the exact failure in.
  def ops_alert
    mail(
      to: params.fetch(:to),
      from: params.fetch(:from),
      subject: params.fetch(:subject),
      body: params.fetch(:body),
      content_type: 'text/plain'
    )
  end
end
