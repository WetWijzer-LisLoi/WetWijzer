# frozen_string_literal: true

# Base class for all analytics/usage-tracking models.
# Stored in a separate 'analytics' database to isolate high-write
# telemetry from the accounts database (auth, subscriptions, billing).
class AnalyticsRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :analytics, reading: :analytics }
end
