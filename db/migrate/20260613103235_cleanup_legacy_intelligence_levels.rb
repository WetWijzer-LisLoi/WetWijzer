# frozen_string_literal: true

# Cleans up legacy intelligence_level values in chatbot_analytics.
#
# Before the June 2026 4-tier consolidation, the slider had different tier names:
#   'smarter'  → now 'genius'  (was the mid-tier)
#   'smartest' → now 'mastermind' (was the top tier)
#   nil/''     → now 'smart'  (anonymous/free users who queried before the tier system)
#
# This migration normalizes all historical records to the current 4-tier system:
#   smart | genius | mastermind | omniscient
class CleanupLegacyIntelligenceLevels < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:chatbot_analytics)

    # Legacy 'smarter' → current 'genius' (both are mid-tier, credits-required)
    execute <<~SQL
      UPDATE chatbot_analytics
      SET intelligence_level = 'genius'
      WHERE intelligence_level = 'smarter'
    SQL

    # Legacy 'smartest' → current 'mastermind' (both are top-tier paid)
    execute <<~SQL
      UPDATE chatbot_analytics
      SET intelligence_level = 'mastermind'
      WHERE intelligence_level = 'smartest'
    SQL

    # NULL/empty → 'smart' (free tier, before intelligence_level was tracked)
    execute <<~SQL
      UPDATE chatbot_analytics
      SET intelligence_level = 'smart'
      WHERE intelligence_level IS NULL OR intelligence_level = ''
    SQL
  end

  def down
    # Irreversible — we can't distinguish which records were originally legacy values.
    # This is safe because the legacy names are not used anywhere in the codebase.
  end
end
