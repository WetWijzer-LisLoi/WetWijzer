# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # A durable failure record and a log line are both bounded, so a job that
  # aggregates per-item failures must not print the first few causes and stay
  # silent about the rest. Both Mollie recovery jobs report through this.
  def self.reported_failures(failures, limit)
    shown = Array(failures).first(limit)
    hidden = Array(failures).length - shown.length
    hidden.positive? ? "#{shown.join('; ')}; (+#{hidden} more)" : shown.join('; ')
  end
end
